import CoreMedia
import CoreVideo
import Foundation

// MARK: - FrameProcessorChain

/// Composes zero or more `FrameProcessorBackend` stages into a single pipeline from
/// `inputSize` to `outputSize`.
///
/// Intermediate buffers flow from each stage's output into the next stage's input; the last
/// stage's outputs propagate to the caller. An empty chain is a valid identity pass
/// (`inputSize == outputSize` required) — it forwards each input frame unchanged, which is
/// how a pure re-encode (codec/quality change only) flows through the pipeline without any
/// per-frame pixel work.
///
/// The chain is itself a `FrameProcessorBackend`, which keeps the pipeline order as *data*
/// in the stage array rather than encoded in the type system — callers can reorder the
/// pipeline without touching any backend.
public actor FrameProcessorChain: FrameProcessorBackend {
  // MARK: Lifecycle

  /// Builds a chain that routes frames from `inputSize` to `outputSize` through `stages`.
  ///
  /// Validates that each boundary — chain input → first stage, each adjacent pair, last
  /// stage → chain output — agrees on size. For an empty chain, this collapses to the
  /// single check `inputSize == outputSize`. Throws on any mismatch so callers catch the
  /// error at preflight time, before any file I/O.
  ///
  /// - Parameters:
  ///   - inputSize: Expected input dimensions for the first stage.
  ///   - outputSize: Expected output dimensions from the last stage.
  ///   - stages: Ordered list of backends that frames pass through.
  ///   - metricsCollector: Optional collector for per-stage timing. When provided, the chain
  ///     registers each stage's ``FrameProcessorBackend/displayName`` and records wall-clock
  ///     durations on every `process(...)` and `finish(...)` call. Pass `nil` to opt out.
  public init(
    inputSize: CGSize,
    outputSize: CGSize,
    stages: [any FrameProcessorBackend],
    metricsCollector: PipelineMetricsCollector? = nil
  ) throws {
    self.inputSize = inputSize
    self.outputSize = outputSize
    self.stages = stages
    self.metricsCollector = metricsCollector

    if let metricsCollector {
      self.stageMetricsIndices = stages.map { stage in
        metricsCollector.addStage(name: stage.displayName)
      }
    } else {
      self.stageMetricsIndices = nil
    }

    var cursor = inputSize
    for (index, stage) in stages.enumerated() {
      guard stage.inputSize == cursor else {
        throw Error.sizeMismatch(
          expected: cursor, actual: stage.inputSize,
          at: index == 0 ? "chain input → stage 0" : "stage \(index - 1) output → stage \(index) input")
      }
      cursor = stage.outputSize
    }
    guard cursor == outputSize else {
      throw Error.sizeMismatch(
        expected: outputSize, actual: cursor,
        at: stages.isEmpty ? "identity chain" : "stage \(stages.count - 1) output → chain output")
    }
  }

  // MARK: Public

  public nonisolated let inputSize: CGSize
  public nonisolated let outputSize: CGSize

  /// A chain needs per-stream instances whenever any of its stages does — sharing a single
  /// chain across streams would route every stream through that stage's shared state.
  public nonisolated var requiresInstancePerStream: Bool {
    stages.contains { $0.requiresInstancePerStream }
  }

  public func process(
    _ pixelBuffer: sending CVPixelBuffer,
    presentationTimeStamp: CMTime,
    outputPool: sending CVPixelBufferPool?
  ) async throws -> [FrameProcessorOutput] {
    // The writer-adaptor pool is meaningful only for the stage that produces the final
    // output. Intermediate stages allocate from their own internal pools so dimensions
    // match each stage's `outputSize`.
    nonisolated(unsafe) let terminalPool = outputPool

    nonisolated(unsafe) let seedBuffer = pixelBuffer
    var currentFrames: [FrameProcessorOutput] = [
      FrameProcessorOutput(pixelBuffer: seedBuffer, presentationTimeStamp: presentationTimeStamp)
    ]

    let lastIndex = stages.count - 1
    for (stageIndex, stage) in stages.enumerated() {
      nonisolated(unsafe) let poolForStage: CVPixelBufferPool? =
        (stageIndex == lastIndex) ? terminalPool : nil
      var nextFrames: [FrameProcessorOutput] = []
      nextFrames.reserveCapacity(currentFrames.count)

      let stageStart = ContinuousClock.now

      for frame in currentFrames {
        nonisolated(unsafe) let inputBuffer = frame.pixelBuffer
        let outputs = try await stage.process(
          inputBuffer,
          presentationTimeStamp: frame.presentationTimeStamp,
          outputPool: poolForStage
        )
        nextFrames.append(contentsOf: outputs)
      }

      if let metricsCollector, let indices = stageMetricsIndices {
        let elapsed = ContinuousClock.now - stageStart
        metricsCollector.record(stageIndex: indices[stageIndex], duration: elapsed)
      }

      currentFrames = nextFrames
    }

    if let metricsCollector {
      metricsCollector.recordChainCompletion(outputCount: currentFrames.count)
    }

    return currentFrames
  }

  public func finish(
    outputPool: sending CVPixelBufferPool?
  ) async throws -> [FrameProcessorOutput] {
    // Walk stages in order: for each, first feed any upstream-flushed frames through its
    // `process(...)` (so they pick up this stage's effect), then ask this stage to flush
    // its own buffered state. Downstream stages see those flushed frames on the next
    // iteration and, again, run them through `process(...)` before flushing themselves.
    //
    // Only the last stage receives the terminal pool — earlier stages allocate from their
    // internal pools because the buffers are intermediate.
    nonisolated(unsafe) let terminalPool = outputPool
    var running: [FrameProcessorOutput] = []
    let lastIndex = stages.count - 1
    for (stageIndex, stage) in stages.enumerated() {
      nonisolated(unsafe) let poolForStage: CVPixelBufferPool? =
        (stageIndex == lastIndex) ? terminalPool : nil

      let stageStart = ContinuousClock.now

      var nextFrames: [FrameProcessorOutput] = []
      for frame in running {
        nonisolated(unsafe) let inputBuffer = frame.pixelBuffer
        let outputs = try await stage.process(
          inputBuffer,
          presentationTimeStamp: frame.presentationTimeStamp,
          outputPool: poolForStage
        )
        nextFrames.append(contentsOf: outputs)
      }
      let flushed = try await stage.finish(outputPool: poolForStage)
      nextFrames.append(contentsOf: flushed)

      if let metricsCollector, let indices = stageMetricsIndices {
        let elapsed = ContinuousClock.now - stageStart
        metricsCollector.record(stageIndex: indices[stageIndex], duration: elapsed)
      }

      running = nextFrames
    }

    if let metricsCollector, !running.isEmpty {
      metricsCollector.recordChainCompletion(outputCount: running.count)
    }

    return running
  }

  // MARK: Pipelined Processing

  /// Processes all frames from `input` through the chain with inter-stage pipelining.
  ///
  /// Each stage runs as an independent concurrent task connected by bounded channels, so while
  /// stage K processes frame N, stage K-1 can simultaneously process frame N+1. Within each
  /// stage, frames are still processed strictly in order (required for temporal backends).
  ///
  /// - Parameters:
  ///   - input: Async sequence of source frames.
  ///   - outputPool: Terminal pixel-buffer pool (from the writer adaptor). Only the last stage
  ///     receives this; intermediate stages allocate from their own internal pools.
  ///   - handler: Called for each batch of output frames in source order. Runs on the
  ///     cooperative pool, not on this actor.
  public func processAll<Input: AsyncSequence & Sendable>(
    from input: Input,
    outputPool: CVPixelBufferPool?,
    handler: @escaping @Sendable ([FrameProcessorOutput]) async throws -> Void
  ) async throws where Input.Element == FrameProcessorOutput {
    if stages.isEmpty {
      for try await frame in input {
        metricsCollector?.recordChainCompletion(outputCount: 1)
        try await handler([frame])
      }
      return
    }

    // N stages ⟹ N+1 channels (feeder→stage[0], stage[k]→stage[k+1], stage[N-1]→consumer).
    // Capacity 2 lets adjacent stages overlap: one frame buffered in the channel plus one
    // in-flight in the downstream stage, so a stage need not wait for the next to drain
    // before producing its next output. This roughly doubles steady-state throughput for
    // multi-stage chains while still bounding extra memory (≤ one additional 4K frame per
    // channel, ~24 MiB — comparable to the existing `sampleBufferBufferDepth = 4` reader
    // buffer) and keeping ordering strict within each stage.
    let channels = (0...stages.count).map { _ in
      PipelineChannel<[FrameProcessorOutput]>(capacity: Self.interStageChannelCapacity)
    }

    nonisolated(unsafe) let terminalPool = outputPool

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        defer { channels[0].finish() }
        for try await frame in input {
          await channels[0].send([frame])
        }
      }

      let lastStageIndex = stages.count - 1
      for (stageIndex, stage) in stages.enumerated() {
        let inputChannel = channels[stageIndex]
        let outputChannel = channels[stageIndex + 1]
        nonisolated(unsafe) let poolForStage: CVPixelBufferPool? =
          (stageIndex == lastStageIndex) ? terminalPool : nil
        let metricsIndex = stageMetricsIndices?[stageIndex]

        group.addTask { [metricsCollector = self.metricsCollector] in
          defer { outputChannel.finish() }

          for await batch in inputChannel {
            try Task.checkCancellation()
            let stageStart = ContinuousClock.now

            let outputs: [FrameProcessorOutput]
            if batch.count == 1 {
              let frame = batch[0]
              nonisolated(unsafe) let inputBuffer = frame.pixelBuffer
              outputs = try await stage.process(
                inputBuffer,
                presentationTimeStamp: frame.presentationTimeStamp,
                outputPool: poolForStage)
            } else {
              var accumulator: [FrameProcessorOutput] = []
              accumulator.reserveCapacity(batch.count)
              for frame in batch {
                nonisolated(unsafe) let inputBuffer = frame.pixelBuffer
                accumulator.append(contentsOf: try await stage.process(
                  inputBuffer,
                  presentationTimeStamp: frame.presentationTimeStamp,
                  outputPool: poolForStage))
              }
              outputs = accumulator
            }

            if let metricsCollector, let idx = metricsIndex {
              metricsCollector.record(
                stageIndex: idx, duration: ContinuousClock.now - stageStart)
            }

            // Send even empty batches so the consumer's per-source-frame accounting stays
            // aligned with the input cadence (FRC returns [] for its first input).
            await outputChannel.send(outputs)
          }

          try Task.checkCancellation()
          let flushStart = ContinuousClock.now
          let flushed = try await stage.finish(outputPool: poolForStage)
          // NOTE: flush emission must be symmetric across identical chains run on
          // identical input cadences. `UpscalingExportSession`'s stereo path pairs
          // left/right batches positionally (including this terminal flush batch) and
          // relies on both eyes producing the same number of batches in the same order.
          // If a future stage's flush becomes content-dependent (e.g. motion-adaptive
          // lookahead that emits on one eye but not the other), the stereo assembly
          // will desync — revisit that pairing before introducing such a stage.
          if !flushed.isEmpty {
            if let metricsCollector, let idx = metricsIndex {
              metricsCollector.record(
                stageIndex: idx, duration: ContinuousClock.now - flushStart)
            }
            await outputChannel.send(flushed)
          }
        }
      }

      group.addTask { [metricsCollector = self.metricsCollector] in
        for await outputs in channels[lastStageIndex + 1] {
          try Task.checkCancellation()
          metricsCollector?.recordChainCompletion(outputCount: outputs.count)
          try await handler(outputs)
        }
      }

      try await group.waitForAll()
    }
  }

  private static let interStageChannelCapacity = 2

  // MARK: Private

  private nonisolated let stages: [any FrameProcessorBackend]
  private nonisolated let metricsCollector: PipelineMetricsCollector?
  /// Maps each stage's position in `stages` to its registered index in `metricsCollector`.
  /// `nil` when no collector is attached.
  private nonisolated let stageMetricsIndices: [Int]?
}

// MARK: FrameProcessorChain.Error

extension FrameProcessorChain {
  public enum Error: Swift.Error, LocalizedError {
    case sizeMismatch(expected: CGSize, actual: CGSize, at: String)

    public var errorDescription: String? {
      switch self {
      case .sizeMismatch(let expected, let actual, let at):
        "Frame processor chain size mismatch at \(at): expected "
          + "\(Int(expected.width))×\(Int(expected.height)), got "
          + "\(Int(actual.width))×\(Int(actual.height))."
      }
    }
  }
}
