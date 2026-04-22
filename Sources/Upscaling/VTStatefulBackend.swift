import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// MARK: - VTStatefulBackendCore

/// Shared plumbing for the three stateful `VTFrameProcessor` backends
/// (`VTSuperResolutionUpscaler`, `VTMotionBlurProcessor`, `VTTemporalNoiseProcessor`).
///
/// The three backends are otherwise ~90% copy-paste: they all validate a configuration,
/// construct a `VTFrameProcessor`, start a session, allocate a BGRA pixel-buffer pool, wrap
/// source/destination buffers as `VTFrameProcessorFrame`s on synthetic monotonic PTS, and
/// bridge the completion-handler API to `async` via `runVT`. This class consolidates that
/// plumbing so each backend shrinks to the parts that actually differ: its `Configuration`
/// / parameter types, its validation rules, and its parameter-builder.
///
/// The core is a `final class` (not an actor) so its `deinit` can end the VT session
/// without tripping the Swift 6.3 `ActorIsolationRequest` cycle that a `deinit` on an actor
/// hits under release-mode WMO — each backend actor merely holds this class, and the class's
/// own deinit runs when the actor is deallocated.
///
/// `@unchecked Sendable`: `VTFrameProcessor` and `CVPixelBufferPool` aren't declared
/// `Sendable` by Apple but are thread-safe for the access pattern this module uses (see the
/// doc comment on `SendableBox`). Passing a reference to this core across the actor boundary
/// is the same admission, scoped to one type.
final class VTStatefulBackendCore: @unchecked Sendable {
  // MARK: Lifecycle

  /// Builds a processor + pool pair for a backend.
  ///
  /// Construction order matches the three backends' original inits:
  ///   1. `VTFrameProcessor()` + `startSession(configuration:)`
  ///   2. `makeBGRAPixelBufferPool(size:minimumBufferCount:)`
  /// Any failure is reported through `VTBackendError` tagged with `backend`.
  init(
    configuration: some VTFrameProcessorConfiguration,
    poolSize: CGSize,
    minimumPoolBufferCount: Int,
    backend: VTBackendError.Backend
  ) throws {
    self.backend = backend

    let processor = VTFrameProcessor()
    try processor.startSession(configuration: configuration)
    self.processor = processor

    guard
      let pixelBufferPool = makeBGRAPixelBufferPool(
        size: poolSize, minimumBufferCount: minimumPoolBufferCount)
    else { throw VTBackendError.pixelBufferPoolCreationFailed(backend: backend) }
    self.pixelBufferPool = pixelBufferPool
  }

  deinit {
    processor.endSession()
  }

  // MARK: Internal

  let processor: VTFrameProcessor
  let pixelBufferPool: CVPixelBufferPool
  let backend: VTBackendError.Backend

  /// Yields the next synthetic VT presentation timestamp and increments the counter.
  ///
  /// VT only checks monotonicity across a session, so any constant-timescale integer stream
  /// works; callers still pass the source's real PTS through on their emitted
  /// `FrameProcessorOutput`s.
  func nextPts(frameIndex: inout UInt64) -> CMTime {
    let pts = CMTime(value: Int64(frameIndex), timescale: vtSyntheticTimescale)
    frameIndex += 1
    return pts
  }

  /// Wraps a `CVPixelBuffer` as a `VTFrameProcessorFrame`, or throws a tagged
  /// `vtFrameConstructionFailed` error if the buffer isn't IOSurface-backed.
  func makeFrame(
    _ buffer: CVPixelBuffer, pts: CMTime
  ) throws -> VTFrameProcessorFrame {
    guard let frame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: pts)
    else { throw VTBackendError.vtFrameConstructionFailed(backend: backend) }
    return frame
  }

  /// `async` wrapper over `VTFrameProcessor.process(parameters:completionHandler:)` that
  /// hides the processor-side `SendableBox` at call sites. Callers still wrap the
  /// `parameters` value themselves because it typically captures other actor-isolated
  /// references (e.g. cached previous `VTFrameProcessorFrame`s), which `sending` can't
  /// launder.
  func run(parameters: SendableBox<some VTFrameProcessorParameters>) async throws {
    try await runVT(on: SendableBox(processor), parameters: parameters)
  }
}
