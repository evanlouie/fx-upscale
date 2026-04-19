import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// MARK: - VTFrameRateConverter

/// Performs `VTFrameProcessor` frame-rate conversion on `CVPixelBuffer`s.
///
/// FRC is the one stage in this pipeline that does **not** preserve frame count: it emits
/// target-rate frames between each adjacent pair of source frames, so the output stream has
/// roughly `source_count * (target / source)` frames. Dimensions pass through unchanged.
///
/// Streaming shape: `VTFrameRateConversionParameters` requires both `sourceFrame` and
/// `nextFrame`, but callers feed us one frame at a time. We buffer each incoming frame as
/// the candidate "next" and, when a new frame arrives, we have a full `(prev, next)` pair
/// and can emit all target-rate frames whose PTS fall in `[prev.pts, next.pts)`. The first
/// `process(...)` therefore emits nothing; the final source frame is flushed on `finish(...)`.
///
/// - Important: FRC has strict input constraints checked at init time:
///   - The device must return `true` for `VTFrameRateConversionConfiguration.isSupported`.
///   - Frame size must fit within the processor's supported dimensions
///     (macOS: ≤ 8192×4320).
///   - `targetFrameRate` must be finite and positive. Callers should additionally validate
///     `target > source` upstream (this backend doesn't know the source rate).
public actor VTFrameRateConverter: FrameProcessorBackend {
  // MARK: FrameProcessorBackend

  public nonisolated let requiresInstancePerStream: Bool = true

  // MARK: Lifecycle

  /// Creates a frame-rate converter for frames at the given size and target rate.
  ///
  /// Frame-rate conversion preserves dimensions, so `inputSize == outputSize == frameSize`.
  public init(frameSize: CGSize, targetFrameRate: Double) async throws {
    self.frameSize = frameSize
    self.targetFrameRate = try Self.validateTargetFrameRate(targetFrameRate)
    // For integer target rates, use the rate itself as the timescale so that
    // `CMTime(value: k, timescale: rate)` represents exactly `k/rate` with no rounding
    // drift. For non-integer rates, fall back to a very high timescale — drift per period
    // is bounded by `0.5 / fallbackTimescale` seconds, well below any meaningful threshold.
    let rounded = targetFrameRate.rounded()
    if abs(rounded - targetFrameRate) < 1e-9, rounded >= 1, rounded <= Double(Int32.max) {
      self.targetPeriod = .integerRate(Int32(rounded))
    } else {
      self.targetPeriod = .fractional(
        CMTime(
          seconds: 1.0 / targetFrameRate, preferredTimescale: Self.fallbackPeriodTimescale))
    }

    let configuration = try Self.makeConfiguration(frameSize: frameSize)

    let processor = VTFrameProcessor()
    try processor.startSession(configuration: configuration)
    self.processor = processor

    guard
      let pixelBufferPool = makeBGRAPixelBufferPool(
        size: frameSize, minimumBufferCount: Self.minimumPoolBufferCount)
    else { throw Error.pixelBufferPoolCreationFailed }
    self.pixelBufferPool = pixelBufferPool
  }

  isolated deinit {
    processor.endSession()
  }

  /// Cheap synchronous validation that only checks target-rate bounds and whether the
  /// configuration can be constructed at the requested dimensions. Does not start a session.
  public static func preflight(frameSize: CGSize, targetFrameRate: Double) throws {
    _ = try validateTargetFrameRate(targetFrameRate)
    _ = try makeConfiguration(frameSize: frameSize)
  }

  // MARK: Public

  public nonisolated var inputSize: CGSize { frameSize }
  public nonisolated var outputSize: CGSize { frameSize }

  public func process(
    _ pixelBuffer: sending CVPixelBuffer,
    presentationTimeStamp: CMTime,
    outputPool externalPool: sending CVPixelBufferPool?
  ) async throws -> [FrameProcessorOutput] {
    // Validate and wrap the incoming frame. Each source frame is wrapped exactly once; the
    // same wrapper serves as `nextFrame` on this submission and `sourceFrame` on the next.
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
      throw PixelBufferIOError.unsupportedPixelFormat
    }
    guard pixelBuffer.width == Int(frameSize.width),
      pixelBuffer.height == Int(frameSize.height)
    else {
      throw PixelBufferIOError.inputSizeMismatch
    }

    let vtPts = CMTime(value: Int64(frameIndex), timescale: Self.syntheticTimescale)
    frameIndex &+= 1
    guard
      let newFrameWrapper = VTFrameProcessorFrame(
        buffer: pixelBuffer, presentationTimeStamp: vtPts)
    else {
      throw Error.vtFrameConstructionFailed
    }

    // First frame: buffer and return empty. Anchor the output schedule on the first source
    // PTS so outputs begin at the same instant as the source.
    guard let buffered = bufferedFrame else {
      nonisolated(unsafe) let capturedBuffer = pixelBuffer
      bufferedFrame = BufferedFrame(
        wrapper: newFrameWrapper, buffer: capturedBuffer, pts: presentationTimeStamp)
      anchorPTS = presentationTimeStamp
      targetOutputIndex = 0
      return []
    }

    // Plan the target PTS that fall within `[prev.pts, next.pts)`. `phase == 0` exactly
    // coincides with the previous source frame, which is emitted as pass-through (VT
    // documents phase values between 0 and 1 for actual interpolation).
    let prevPTS = buffered.pts
    let nextPTS = presentationTimeStamp
    let intervalSeconds = nextPTS.seconds - prevPTS.seconds
    guard intervalSeconds > 0 else {
      // Non-monotonic PTS. Skip planning but still buffer the new frame so forward progress
      // continues on the next call.
      nonisolated(unsafe) let capturedBuffer = pixelBuffer
      bufferedFrame = BufferedFrame(
        wrapper: newFrameWrapper, buffer: capturedBuffer, pts: nextPTS)
      return []
    }

    // `targetOutputIndex` is monotonic, so `phase` grows through `[0, 1)`. Any `phase <= 0`
    // entries therefore land at the start, before all interpolated PTSs — we can append in
    // order instead of sorting at the end.
    var outputs: [FrameProcessorOutput] = []
    var interpolationPhases: [Float] = []
    var interpolatedOutputPTSs: [CMTime] = []
    while true {
      let candidatePTS = targetPTS(forIndex: targetOutputIndex)
      if candidatePTS >= nextPTS { break }
      let phase = (candidatePTS.seconds - prevPTS.seconds) / intervalSeconds
      if phase <= 0 {
        nonisolated(unsafe) let passthroughBuffer = buffered.buffer
        outputs.append(
          FrameProcessorOutput(
            pixelBuffer: passthroughBuffer, presentationTimeStamp: candidatePTS))
      } else {
        interpolationPhases.append(Float(phase))
        interpolatedOutputPTSs.append(candidatePTS)
      }
      targetOutputIndex &+= 1
    }

    if !interpolationPhases.isEmpty {
      // Allocate one destination buffer per interpolated frame and wrap each. VT needs the
      // same count in `interpolationPhase` and `destinationFrames`.
      var destinationBuffers: [CVPixelBuffer] = []
      var destinationFrames: [VTFrameProcessorFrame] = []
      destinationBuffers.reserveCapacity(interpolationPhases.count)
      destinationFrames.reserveCapacity(interpolationPhases.count)
      for _ in interpolationPhases {
        let dest = try resolveUpscalerOutputBuffer(
          input: pixelBuffer,
          expectedInputSize: frameSize,
          expectedOutputSize: frameSize,
          externalPool: externalPool,
          internalPool: pixelBufferPool,
          providedOutput: nil
        )
        guard
          let wrapper = VTFrameProcessorFrame(
            buffer: dest, presentationTimeStamp: vtPts)
        else {
          throw Error.vtFrameConstructionFailed
        }
        destinationBuffers.append(dest)
        destinationFrames.append(wrapper)
      }

      guard
        let parameters = VTFrameRateConversionParameters(
          sourceFrame: buffered.wrapper,
          nextFrame: newFrameWrapper,
          opticalFlow: nil,
          interpolationPhase: interpolationPhases,
          submissionMode: .sequential,
          destinationFrames: destinationFrames
        )
      else {
        throw Error.vtFrameConstructionFailed
      }

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

      outputs.reserveCapacity(outputs.count + destinationBuffers.count)
      for (buffer, outputPTS) in zip(destinationBuffers, interpolatedOutputPTSs) {
        nonisolated(unsafe) let interpolatedBuffer = buffer
        outputs.append(
          FrameProcessorOutput(
            pixelBuffer: interpolatedBuffer, presentationTimeStamp: outputPTS))
      }
    }

    // Slide: the just-received frame becomes the new buffered "prev" for the next call.
    nonisolated(unsafe) let capturedBuffer = pixelBuffer
    bufferedFrame = BufferedFrame(
      wrapper: newFrameWrapper, buffer: capturedBuffer, pts: nextPTS)

    return outputs
  }

  public func finish(
    outputPool _: sending CVPixelBufferPool?
  ) async throws -> [FrameProcessorOutput] {
    // Emit the final buffered source frame at its original PTS. Any target PTS that fall
    // strictly beyond the last source frame are dropped — we have no "next" frame to
    // interpolate against, and synthesising pixels past the input would distort duration.
    guard let buffered = bufferedFrame else { return [] }
    bufferedFrame = nil
    nonisolated(unsafe) let passthroughBuffer = buffered.buffer
    return [
      FrameProcessorOutput(pixelBuffer: passthroughBuffer, presentationTimeStamp: buffered.pts)
    ]
  }

  // MARK: Private

  /// `kCVPixelBufferPoolMinimumBufferCountKey` value. Each source pair emits up to
  /// `target/source - 1` destination buffers in one shot, plus in-flight consumption
  /// downstream. 12 covers every realistic ratio (≤ ~10×) without forcing the pool to
  /// fall back to `CVPixelBufferPoolCreatePixelBuffer`.
  private static let minimumPoolBufferCount = 12

  /// Fixed timescale for synthesized PTS. Any constant works — VT only cares about monotonicity.
  private static let syntheticTimescale: CMTimeScale = 600

  /// Fallback `CMTime` timescale used for the target period when `targetFrameRate` isn't a
  /// clean integer. Chosen large enough that per-period rounding stays well under one frame
  /// for any realistic rate.
  private static let fallbackPeriodTimescale: CMTimeScale = 1_000_000_000

  /// Upper bound on target-rate requests. 1 kHz is comfortably beyond any real playback
  /// need and caps pathological memory blowups from extreme ratios.
  private static let maxTargetFrameRate: Double = 1_000

  private struct BufferedFrame {
    let wrapper: VTFrameProcessorFrame
    let buffer: CVPixelBuffer
    let pts: CMTime
  }

  /// How to compute the k-th target output PTS relative to the anchor. Integer rates use an
  /// exact CMTime timescale; everything else accumulates the fallback period `k` times.
  private enum TargetPeriod {
    case integerRate(Int32)
    case fractional(CMTime)
  }

  private let frameSize: CGSize
  private let targetFrameRate: Double
  private let targetPeriod: TargetPeriod
  private let processor: VTFrameProcessor
  private let pixelBufferPool: CVPixelBufferPool

  private var frameIndex: UInt64 = 0
  private var bufferedFrame: BufferedFrame?
  private var anchorPTS: CMTime = .zero
  private var targetOutputIndex: Int64 = 0

  /// PTS of the target output at index `k`, computed exactly (for integer rates) or with
  /// sub-nanosecond drift (for non-integer rates).
  private func targetPTS(forIndex index: Int64) -> CMTime {
    switch targetPeriod {
    case .integerRate(let timescale):
      return anchorPTS + CMTime(value: index, timescale: timescale)
    case .fractional(let period):
      return anchorPTS + CMTimeMultiply(period, multiplier: Int32(clamping: index))
    }
  }

  @discardableResult
  private static func validateTargetFrameRate(_ rate: Double) throws -> Double {
    guard rate.isFinite, rate > 0, rate <= maxTargetFrameRate else {
      throw Error.targetFrameRateOutOfRange(requested: rate, maximum: maxTargetFrameRate)
    }
    return rate
  }

  /// Builds and validates a `VTFrameRateConversionConfiguration` for this frame size.
  ///
  /// Factored out so `preflight(...)` and `init(...)` share one source of truth for the
  /// dimension / device-support rules. Construction is cheap — it does not start a session.
  private static func makeConfiguration(
    frameSize: CGSize
  ) throws -> VTFrameRateConversionConfiguration {
    guard VTFrameRateConversionConfiguration.isSupported else {
      throw Error.notSupportedOnDevice
    }

    let frameWidth = Int(frameSize.width.rounded())
    let frameHeight = Int(frameSize.height.rounded())

    guard
      let configuration = VTFrameRateConversionConfiguration(
        frameWidth: frameWidth,
        frameHeight: frameHeight,
        usePrecomputedFlow: false,
        qualityPrioritization: .normal,
        revision: VTFrameRateConversionConfiguration.defaultRevision
      )
    else {
      throw Error.configurationInitFailed(frameWidth: frameWidth, frameHeight: frameHeight)
    }

    return configuration
  }
}

// MARK: VTFrameRateConverter.Error

extension VTFrameRateConverter {
  public enum Error: Swift.Error, LocalizedError {
    case notSupportedOnDevice
    case targetFrameRateOutOfRange(requested: Double, maximum: Double)
    case configurationInitFailed(frameWidth: Int, frameHeight: Int)
    case pixelBufferPoolCreationFailed
    case vtFrameConstructionFailed

    public var errorDescription: String? {
      switch self {
      case .notSupportedOnDevice:
        "The VideoToolbox frame-rate conversion processor is not supported on this device."
      case .targetFrameRateOutOfRange(let requested, let maximum):
        "Target frame rate \(requested) is out of range. "
          + "Must be finite, positive, and ≤ \(Int(maximum)) fps."
      case .configurationInitFailed(let frameWidth, let frameHeight):
        "Frame-rate conversion rejected the input configuration "
          + "(\(frameWidth)×\(frameHeight)). On macOS, inputs must be ≤ 8192×4320."
      case .pixelBufferPoolCreationFailed:
        "Failed to create the frame-rate conversion output pixel buffer pool."
      case .vtFrameConstructionFailed:
        "Failed to construct frame-rate conversion frame parameters "
          + "(pixel buffers must be IOSurface-backed)."
      }
    }
  }
}
