import CoreMedia
import Foundation
import VideoToolbox

// MARK: - VTBackendError

/// Error cases shared across the four `VTFrameProcessor` backends. Backend-specific cases
/// (strength bounds, scale factor, model download, configuration-init dimension prose) stay
/// on each backend's own `Error` enum.
public enum VTBackendError: Swift.Error, LocalizedError {
  public enum Backend: Sendable {
    case superResolution
    case motionBlur
    case temporalNoise
    case frameRateConversion

    fileprivate var displayName: String {
      switch self {
      case .superResolution: "super-resolution"
      case .motionBlur: "motion-blur"
      case .temporalNoise: "temporal noise filter"
      case .frameRateConversion: "frame-rate conversion"
      }
    }
  }

  case notSupportedOnDevice(backend: Backend)
  case pixelBufferPoolCreationFailed(backend: Backend)
  case vtFrameConstructionFailed(backend: Backend)

  public var errorDescription: String? {
    switch self {
    case .notSupportedOnDevice(let backend):
      "The VideoToolbox \(backend.displayName) is not supported on this device."
    case .pixelBufferPoolCreationFailed(let backend):
      "Failed to create the \(backend.displayName) output pixel buffer pool."
    case .vtFrameConstructionFailed(let backend):
      "Failed to construct \(backend.displayName) frame parameters "
        + "(pixel buffers must be IOSurface-backed)."
    }
  }
}

// MARK: - Shared VT synthetic PTS timescale

/// Fixed timescale for VT `presentationTimeStamp`s that the pipeline synthesizes. VT only
/// checks monotonicity across a session, so any constant timescale works; the value itself
/// never leaves the backend.
let vtSyntheticTimescale: CMTimeScale = 600

// MARK: - SendableBox

/// Carries a non-`Sendable` reference across an isolation boundary.
///
/// The CF / VT types the pipeline threads through (`CVPixelBuffer`, `CVPixelBufferPool`,
/// `VTFrameProcessor`, `VTFrameProcessorFrame`, `VTFrameProcessorParameters`) are thread-safe
/// for reads but aren't declared `Sendable` by Apple. Wrapping a value in `SendableBox` is
/// an explicit, one-line admission that the caller guarantees the same invariant the rest of
/// this module upholds for these types: only read-only views cross the boundary, no concurrent
/// writers. Prefer this over scattering `nonisolated(unsafe) let x = y` rebinds at call sites.
struct SendableBox<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}

/// Async/await bridge over `VTFrameProcessor.process(parameters:completionHandler:)`.
///
/// All VT backends invoke a completion-handler API; this wraps it in a `CheckedContinuation`
/// so call sites can `try await runVT(on: processor, parameters: ...)` instead of hand-rolling
/// the same continuation block per site. The `SendableBox` wrappers let callers pass the
/// non-Sendable `VTFrameProcessor` and its parameters without a local `nonisolated(unsafe)`
/// rebind at every site.
func runVT(
  on processor: SendableBox<VTFrameProcessor>,
  parameters: SendableBox<some VTFrameProcessorParameters>
) async throws {
  try await withCheckedThrowingContinuation {
    (continuation: CheckedContinuation<Void, Swift.Error>) in
    processor.value.process(parameters: parameters.value) { _, error in
      if let error {
        continuation.resume(throwing: error)
      } else {
        continuation.resume()
      }
    }
  }
}
