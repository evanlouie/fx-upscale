import Foundation

/// FIFO async gate for actor methods whose invariants span suspension points.
///
/// Swift actors are reentrant while an isolated method is suspended. Stateful VideoToolbox
/// backends need a stricter guarantee: only one `process` / `finish` operation may be inside
/// the state machine at a time, including while awaiting VT completion.
actor NonReentrantAsyncGate {
  func acquire() async -> Bool {
    guard !Task.isCancelled else { return false }
    if isAvailable {
      isAvailable = false
      return true
    }

    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(returning: false)
          return
        }
        waiters[id] = continuation
        waiterOrder.append(id)
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  func release() {
    while !waiterOrder.isEmpty {
      let id = waiterOrder.removeFirst()
      if let waiter = waiters.removeValue(forKey: id) {
        waiter.resume(returning: true)
        return
      }
    }
    isAvailable = true
  }

  private var isAvailable = true
  private var waiterOrder: [UUID] = []
  private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

  private func cancelWaiter(_ id: UUID) {
    if let waiter = waiters.removeValue(forKey: id) {
      waiterOrder.removeAll { $0 == id }
      waiter.resume(returning: false)
    }
  }
}
