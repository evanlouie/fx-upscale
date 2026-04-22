import os

// MARK: - PipelineChannel

/// Bounded, single-producer / single-consumer async channel with backpressure.
///
/// When the internal buffer is full, ``send(_:)`` suspends the producer until the consumer
/// drains at least one element via iteration. When the buffer is empty, the consumer suspends
/// until the producer yields a new element or calls ``finish()``.
///
/// Designed for the inter-stage links of a pipelined ``FrameProcessorChain``, where each stage
/// runs as an independent task and channels provide both buffering and flow control. A capacity
/// of 1 is typical — enough to decouple adjacent stages without holding extra frames in memory
/// (each 4K BGRA frame is ~24 MiB).
///
/// ## Cancellation
///
/// Both ``send(_:)`` and the ``AsyncIterator/next()`` method respect cooperative task
/// cancellation. If the current task is cancelled while suspended:
///
/// - `send` drops the element and returns immediately.
/// - `next` returns `nil`, signalling end-of-stream.
///
/// This prevents deadlocks when a `ThrowingTaskGroup` cancels sibling tasks that are parked
/// on a channel.
///
/// ## Concurrency Safety
///
/// Internal state is protected by an `OSAllocatedUnfairLock`. The lock is held only long enough
/// to enqueue/dequeue an element and swap continuations, so hold times are sub-microsecond and
/// contention between the producer and consumer is negligible.
///
/// The channel is safe to share across isolation domains (`Sendable`), but the **single-producer /
/// single-consumer** invariant is the caller's responsibility. Multiple concurrent `send` or
/// `next` calls are a programmer error that will trap via `precondition`.
package final class PipelineChannel<Element: Sendable>: Sendable, AsyncSequence {

  // MARK: Lifecycle

  /// Creates a channel that buffers up to `capacity` elements before suspending the producer.
  ///
  /// - Parameter capacity: Maximum number of elements the channel holds. Must be at least 1.
  package init(capacity: Int) {
    precondition(capacity >= 1, "PipelineChannel capacity must be at least 1")
    state = OSAllocatedUnfairLock(initialState: State(capacity: capacity))
  }

  // MARK: Package

  /// Sends an element into the channel, suspending if the buffer is at capacity.
  ///
  /// If the current task is cancelled while suspended, the element is dropped and `send`
  /// returns immediately. After ``finish()`` has been called, further `send` calls are a
  /// programmer error.
  package func send(_ element: Element) async {
    // Bail out early if the task is already cancelled — the pipeline is shutting down.
    guard !Task.isCancelled else { return }

    // Fast path: space available — enqueue under the lock and return.
    let maySuspend: Bool = state.withLock { state in
      precondition(!state.finished, "send() called after finish()")
      precondition(
        state.senderContinuation == nil,
        "PipelineChannel supports only a single producer")

      if state.buffer.count < state.capacity {
        // If the consumer was waiting (buffer was empty), hand the element directly to it
        // without buffering — otherwise the element would be returned twice: once from the
        // resumed continuation and again from the buffer on the next next() call.
        if let receiver = state.receiverContinuation {
          state.receiverContinuation = nil
          receiver.resume(returning: element)
        } else {
          state.buffer.append(element)
        }
        return false // no suspension needed
      }
      return true // buffer full — must suspend
    }

    guard maySuspend else { return }

    // Slow path: buffer is full — park until the consumer drains a slot, or
    // the task is cancelled.
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let action: SenderSetupAction = state.withLock { state in
          // Re-check cancellation under lock: the handler may have fired between the
          // outer guard and this point, but since the continuation wasn't stored yet,
          // the handler couldn't resume it. Detect that here.
          if Task.isCancelled {
            return .resumeImmediately
          }
          // Re-check space: a consumer may have drained between the fast-path check
          // and this continuation setup.
          if state.buffer.count < state.capacity {
            if let receiver = state.receiverContinuation {
              // Deliver directly — same logic as the fast path.
              state.receiverContinuation = nil
              return .spaceAvailable(wakeReceiver: receiver)
            }
            state.buffer.append(element)
            return .spaceAvailable(wakeReceiver: nil)
          }
          state.pendingElement = element
          state.senderContinuation = continuation
          return .parked
        }
        switch action {
        case .resumeImmediately:
          continuation.resume()
        case .spaceAvailable(let receiver):
          continuation.resume()
          receiver?.resume(returning: element)
        case .parked:
          break // will be resumed by next() or the cancellation handler
        }
      }
    } onCancel: {
      // Resume the sender so it can exit. The element is dropped.
      let sender: CheckedContinuation<Void, Never>? = state.withLock { state in
        let s = state.senderContinuation
        state.senderContinuation = nil
        state.pendingElement = nil
        return s
      }
      sender?.resume()
    }
  }

  /// Signals that no more elements will be sent. The consumer's iterator will return `nil`
  /// after all buffered elements have been drained. Idempotent.
  package func finish() {
    let receiver: CheckedContinuation<Element?, Never>? = state.withLock { state in
      guard !state.finished else { return nil }
      state.finished = true
      let r = state.receiverContinuation
      state.receiverContinuation = nil
      return r
    }
    receiver?.resume(returning: nil)
  }

  // MARK: AsyncSequence conformance

  package struct AsyncIterator: AsyncIteratorProtocol {
    let channel: PipelineChannel

    package mutating func next() async -> Element? {
      await channel.next()
    }
  }

  package func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(channel: self)
  }

  // MARK: Private

  /// Dequeues the next element, suspending if the buffer is empty and the channel is still open.
  /// Returns `nil` when the channel is finished and drained, or when the current task is
  /// cancelled.
  private func next() async -> Element? {
    // Bail out early if the task is already cancelled.
    guard !Task.isCancelled else { return nil }

    // Fast path: element available or channel finished.
    let result: FastPathResult = state.withLock { state in
      precondition(
        state.receiverContinuation == nil,
        "PipelineChannel supports only a single consumer")

      if !state.buffer.isEmpty {
        let element = state.buffer.removeFirst()
        // If the producer was parked (buffer was full), admit its pending element and wake it.
        if let continuation = state.senderContinuation {
          if let pending = state.pendingElement {
            state.buffer.append(pending)
            state.pendingElement = nil
          }
          state.senderContinuation = nil
          return .element(element, wakeSender: continuation)
        }
        return .element(element, wakeSender: nil)
      }
      if state.finished {
        return .finished
      }
      return .needsSuspend
    }

    switch result {
    case .element(let element, let sender):
      sender?.resume()
      return element
    case .finished:
      return nil
    case .needsSuspend:
      break
    }

    // Slow path: buffer is empty, channel still open — park until the producer sends,
    // the channel finishes, or the task is cancelled.
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Element?, Never>) in
        let action: ReceiverSetupAction = state.withLock { state in
          // Re-check cancellation under lock.
          if Task.isCancelled {
            return .resumeNil
          }
          // Re-check: the producer may have sent between the fast-path check and here.
          if !state.buffer.isEmpty {
            let element = state.buffer.removeFirst()
            if let senderCont = state.senderContinuation {
              if let pending = state.pendingElement {
                state.buffer.append(pending)
                state.pendingElement = nil
              }
              state.senderContinuation = nil
              return .element(element, wakeSender: senderCont)
            }
            return .element(element, wakeSender: nil)
          }
          if state.finished {
            return .resumeNil
          }
          state.receiverContinuation = continuation
          return .parked
        }
        switch action {
        case .resumeNil:
          continuation.resume(returning: nil)
        case .element(let element, let sender):
          continuation.resume(returning: element)
          sender?.resume()
        case .parked:
          break // will be resumed by send(), finish(), or the cancellation handler
        }
      }
    } onCancel: {
      // Resume the receiver with nil so its task can exit cleanly.
      let receiver: CheckedContinuation<Element?, Never>? = state.withLock { state in
        let r = state.receiverContinuation
        state.receiverContinuation = nil
        return r
      }
      receiver?.resume(returning: nil)
    }
  }

  private enum FastPathResult {
    case element(Element, wakeSender: CheckedContinuation<Void, Never>?)
    case finished
    case needsSuspend
  }

  private enum SenderSetupAction {
    case resumeImmediately
    case spaceAvailable(wakeReceiver: CheckedContinuation<Element?, Never>?)
    case parked
  }

  private enum ReceiverSetupAction {
    case resumeNil
    case element(Element, wakeSender: CheckedContinuation<Void, Never>?)
    case parked
  }

  private struct State {
    let capacity: Int
    var buffer: [Element] = []
    var finished = false
    /// Continuation of a producer parked because the buffer was full.
    var senderContinuation: CheckedContinuation<Void, Never>?
    /// The element the sender wants to enqueue once space opens.
    var pendingElement: Element?
    /// Continuation of a consumer parked because the buffer was empty.
    var receiverContinuation: CheckedContinuation<Element?, Never>?
  }

  private let state: OSAllocatedUnfairLock<State>
}
