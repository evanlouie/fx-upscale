import CoreMedia
import CoreVideo
import Foundation

// MARK: - FrameProcessorChain

/// Composes multiple `FrameProcessorBackend` stages into a single pipeline.
///
/// Intermediate buffers flow from each stage's output into the next stage's input; the last
/// stage's outputs propagate to the caller. The chain is itself a `FrameProcessorBackend`,
/// which keeps the pipeline order as *data* in the stage array rather than encoded in the
/// type system — future callers can reorder the pipeline without touching any backend.
///
/// A single-stage chain is semantically identical to calling that stage's `process` directly,
/// which is how this is introduced without changing behaviour of the existing CLI.
public actor FrameProcessorChain: FrameProcessorBackend {
  // MARK: Lifecycle

  /// Builds a chain from an ordered list of stages.
  ///
  /// Validates that each stage's `outputSize` matches the next stage's `inputSize`. Throws
  /// if the list is empty or if any adjacent pair disagrees on size — catch these at
  /// preflight time so the user gets a clear diagnostic before any file I/O.
  public init(stages: [any FrameProcessorBackend]) throws {
    guard !stages.isEmpty else { throw Error.emptyChain }
    for index in 1..<stages.count {
      let upstream = stages[index - 1]
      let downstream = stages[index]
      guard upstream.outputSize == downstream.inputSize else {
        throw Error.sizeMismatchBetweenStages(
          upstreamIndex: index - 1,
          upstreamOutputSize: upstream.outputSize,
          downstreamIndex: index,
          downstreamInputSize: downstream.inputSize
        )
      }
    }
    self.stages = stages
  }

  // MARK: Public

  public nonisolated var inputSize: CGSize { stages.first!.inputSize }
  public nonisolated var outputSize: CGSize { stages.last!.outputSize }

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
      for frame in currentFrames {
        nonisolated(unsafe) let inputBuffer = frame.pixelBuffer
        let outputs = try await stage.process(
          inputBuffer,
          presentationTimeStamp: frame.presentationTimeStamp,
          outputPool: poolForStage
        )
        nextFrames.append(contentsOf: outputs)
      }
      currentFrames = nextFrames
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
      running = nextFrames
    }
    return running
  }

  // MARK: Private

  private nonisolated let stages: [any FrameProcessorBackend]
}

// MARK: FrameProcessorChain.Error

extension FrameProcessorChain {
  public enum Error: Swift.Error, LocalizedError {
    case emptyChain
    case sizeMismatchBetweenStages(
      upstreamIndex: Int,
      upstreamOutputSize: CGSize,
      downstreamIndex: Int,
      downstreamInputSize: CGSize
    )

    public var errorDescription: String? {
      switch self {
      case .emptyChain:
        "Frame processor chain must contain at least one stage."
      case .sizeMismatchBetweenStages(
        let upstreamIndex, let upstreamOutputSize,
        let downstreamIndex, let downstreamInputSize
      ):
        "Frame processor chain size mismatch: stage \(upstreamIndex) outputs "
          + "\(Int(upstreamOutputSize.width))×\(Int(upstreamOutputSize.height)) but "
          + "stage \(downstreamIndex) expects "
          + "\(Int(downstreamInputSize.width))×\(Int(downstreamInputSize.height))."
      }
    }
  }
}
