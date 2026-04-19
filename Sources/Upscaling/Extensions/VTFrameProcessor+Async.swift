import CoreMedia
import Foundation
import VideoToolbox

// MARK: - Shared VT synthetic PTS timescale

/// Fixed timescale for VT `presentationTimeStamp`s that the pipeline synthesizes. VT only
/// checks monotonicity across a session, so any constant timescale works; the value itself
/// never leaves the backend.
let vtSyntheticTimescale: CMTimeScale = 600

/// Async/await bridge over `VTFrameProcessor.process(parameters:completionHandler:)`.
///
/// All VT backends invoke a completion-handler API; this wraps it in a `CheckedContinuation`
/// so call sites can `try await runVT(on: processor, parameters: ...)` instead of hand-rolling
/// the same continuation block per site.
///
/// `VTFrameProcessor` is a non-`Sendable` class, so the caller must transfer its reference
/// through a `sending` argument — typically via `nonisolated(unsafe) let p = self.processor`
/// before the call, which matches the pattern the rest of the codebase already uses for CF
/// types.
func runVT(
  on processor: sending VTFrameProcessor,
  parameters: sending some VTFrameProcessorParameters
) async throws {
  try await withCheckedThrowingContinuation {
    (continuation: CheckedContinuation<Void, Swift.Error>) in
    processor.process(parameters: parameters) { _, error in
      if let error {
        continuation.resume(throwing: error)
      } else {
        continuation.resume()
      }
    }
  }
}
