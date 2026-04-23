import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// MARK: - VTMotionBlurProcessor

/// Performs `VTFrameProcessor` motion-blur synthesis on `CVPixelBuffer`s.
///
/// Motion blur is a 1:1 effect: one input frame produces one output frame at the same
/// dimensions. The processor is **stateful** — it retains the prior source frame across
/// `process(...)` calls to derive motion. Feed frames in presentation-time order; concurrent
/// calls serialize on the actor.
///
/// - Important: The motion-blur processor has strict input constraints that are checked at
///   init time and surface as `Error` cases before any pixels are touched:
///   - Input size must be within the processor's `maximumDimensions` (macOS: 8192×4320).
///   - The device must return `true` for `VTMotionBlurConfiguration.isSupported`.
///   - `strength` must be in the 1–100 range documented by the configuration.
public actor VTMotionBlurProcessor: FrameProcessorBackend {
  // MARK: Lifecycle

  /// Creates a motion-blur processor for frames at the given size.
  ///
  /// Motion blur preserves dimensions, so `inputSize == outputSize == frameSize`.
  public init(frameSize: CGSize, strength: Int) async throws {
    self.frameSize = frameSize
    self.strength = try Self.validateStrength(strength)

    self.core = try VTStatefulBackendCore(
      configuration: try Self.makeConfiguration(frameSize: frameSize),
      poolSize: frameSize,
      minimumPoolBufferCount: Self.minimumPoolBufferCount,
      backend: .motionBlur)
  }

  /// Cheap synchronous validation that only checks strength bounds and whether the
  /// configuration can be constructed at the requested dimensions. Does not start a session.
  public static func preflight(frameSize: CGSize, strength: Int) throws {
    _ = try validateStrength(strength)
    _ = try makeConfiguration(frameSize: frameSize)
  }

  // MARK: Public

  public nonisolated var inputSize: CGSize { frameSize }
  public nonisolated var outputSize: CGSize { frameSize }
  public static let displayName = "Motion blur"
  public nonisolated var displayName: String { Self.displayName }

  public nonisolated var requiresInstancePerStream: Bool { true }

  public func process(
    _ pixelBuffer: sending CVPixelBuffer,
    presentationTimeStamp: CMTime,
    outputPool externalPool: sending CVPixelBufferPool?
  ) async throws -> [FrameProcessorOutput] {
    guard await processingGate.acquire() else { throw CancellationError() }
    do {
      try Task.checkCancellation()
      try validateProcessorInput(pixelBuffer, expectedInputSize: frameSize)

      let vtPts = core.nextPts(frameIndex: &frameIndex)
      let sourceFrame = try core.makeFrame(pixelBuffer, pts: vtPts)

      // VT returns -19730 if both previous and next reference frames are missing. This backend
      // doesn't look ahead, so the first frame has neither — pass it through unchanged and
      // apply motion blur from the second frame onward.
      guard let previousSourceFrame else {
        self.previousSourceFrame = sourceFrame
        nonisolated(unsafe) let passthrough = pixelBuffer
        let result = [
          FrameProcessorOutput(pixelBuffer: passthrough, presentationTimeStamp: presentationTimeStamp)
        ]
        await processingGate.release()
        return result
      }

      let output = try resolveProcessorOutputBuffer(
        input: pixelBuffer,
        expectedInputSize: frameSize,
        expectedOutputSize: frameSize,
        externalPool: externalPool,
        internalPool: core.pixelBufferPool,
        providedOutput: nil
      )

      let destinationFrame = try core.makeFrame(output, pts: vtPts)
      guard
        let parameters = VTMotionBlurParameters(
          sourceFrame: sourceFrame,
          nextFrame: nil,
          previousFrame: previousSourceFrame,
          nextOpticalFlow: nil,
          previousOpticalFlow: nil,
          motionBlurStrength: strength,
          submissionMode: .sequential,
          destinationFrame: destinationFrame
        )
      else {
        throw VTBackendError.vtFrameConstructionFailed(backend: .motionBlur)
      }

      try await core.run(parameters: SendableBox(parameters))

      self.previousSourceFrame = sourceFrame

      let result = [FrameProcessorOutput(pixelBuffer: output, presentationTimeStamp: presentationTimeStamp)]
      await processingGate.release()
      return result
    } catch {
      await processingGate.release()
      throw error
    }
  }

  public func finish(
    outputPool _: sending CVPixelBufferPool?
  ) async throws -> [FrameProcessorOutput] {
    guard await processingGate.acquire() else { throw CancellationError() }
    do {
      try Task.checkCancellation()
      // Release the retained previous source wrapper so its buffer isn't kept alive past the
      // end of the stream. This backend doesn't look ahead, so nothing is flushed.
      previousSourceFrame = nil
      await processingGate.release()
      return []
    } catch {
      await processingGate.release()
      throw error
    }
  }

  // MARK: Private

  /// `kCVPixelBufferPoolMinimumBufferCountKey` value. We hold the previous source wrapper
  /// across calls, and the next stage may hold our output while we start the next frame.
  private static let minimumPoolBufferCount = 4

  /// API-documented strength bounds from `VTMotionBlurParameters`.
  private static let minStrength = 1
  private static let maxStrength = 100

  private let frameSize: CGSize
  private let strength: Int
  private let core: VTStatefulBackendCore
  private let processingGate = NonReentrantAsyncGate()

  private var frameIndex: UInt64 = 0
  private var previousSourceFrame: VTFrameProcessorFrame?

  @discardableResult
  private static func validateStrength(_ strength: Int) throws -> Int {
    guard (minStrength...maxStrength).contains(strength) else {
      throw Error.strengthOutOfRange(
        requested: strength, minimum: minStrength, maximum: maxStrength)
    }
    return strength
  }

  /// Builds and validates a `VTMotionBlurConfiguration` for this frame size.
  ///
  /// Factored out so `preflight(...)` and `init(...)` share one source of truth for the
  /// dimension / device-support rules. Construction is cheap — it does not start a session.
  private static func makeConfiguration(
    frameSize: CGSize
  ) throws -> VTMotionBlurConfiguration {
    guard VTMotionBlurConfiguration.isSupported else {
      throw VTBackendError.notSupportedOnDevice(backend: .motionBlur)
    }

    let (frameWidth, frameHeight) = frameSize.intDimensions

    guard
      let configuration = VTMotionBlurConfiguration(
        frameWidth: frameWidth,
        frameHeight: frameHeight,
        usePrecomputedFlow: false,
        qualityPrioritization: .normal,
        revision: VTMotionBlurConfiguration.defaultRevision
      )
    else {
      throw Error.configurationInitFailed(frameWidth: frameWidth, frameHeight: frameHeight)
    }

    return configuration
  }
}

// MARK: VTMotionBlurProcessor.Error

extension VTMotionBlurProcessor {
  public enum Error: Swift.Error, LocalizedError {
    case strengthOutOfRange(requested: Int, minimum: Int, maximum: Int)
    case configurationInitFailed(frameWidth: Int, frameHeight: Int)

    public var errorDescription: String? {
      switch self {
      case .strengthOutOfRange(let requested, let minimum, let maximum):
        "Motion-blur strength \(requested) is out of range. "
          + "Valid range is \(minimum)–\(maximum) (50 matches a 180° film shutter)."
      case .configurationInitFailed(let frameWidth, let frameHeight):
        "Motion blur rejected the input configuration (\(frameWidth)×\(frameHeight)). "
          + "On macOS, inputs must be ≤ 8192×4320."
      }
    }
  }
}
