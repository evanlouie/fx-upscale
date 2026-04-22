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
