import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// MARK: - computeTargetPTS

/// The k-th target-output PTS relative to `anchor`, using `period` as the step.
///
/// Uses Int64-native arithmetic on `CMTime.value`, so the result is exact whenever
/// `period.value * index` does not overflow `Int64`. With the 1 GHz fallback timescale
/// used by `VTFrameRateConverter` this tolerates centuries of continuous output at any
/// realistic rate — far past the old `Int32` ceiling that was silently clamping and
/// freezing output PTSs. A checked multiply crashes loudly if the bound is ever crossed,
/// instead of corrupting the stream.
///
/// Pure function so its regression tests do not need an actor or a live VT session.
func computeTargetPTS(anchor: CMTime, period: CMTime, index: Int64) -> CMTime {
  let (scaled, overflow) = period.value.multipliedReportingOverflow(by: index)
  precondition(
    !overflow,
    "computeTargetPTS: Int64 overflow at index \(index); "
      + "period.value=\(period.value), timescale=\(period.timescale)")
  return anchor + CMTime(value: scaled, timescale: period.timescale)
}

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
      self.targetPeriod = CMTime(value: 1, timescale: Int32(rounded))
    } else {
      self.targetPeriod = CMTime(
        seconds: 1.0 / targetFrameRate, preferredTimescale: Self.fallbackPeriodTimescale)
    }

    let configuration = try Self.makeConfiguration(frameSize: frameSize)

    let processor = VTFrameProcessor()
    try processor.startSession(configuration: configuration)
    self.processor = processor

    guard
      let pixelBufferPool = makeBGRAPixelBufferPool(
        size: frameSize, minimumBufferCount: Self.minimumPoolBufferCount)
    else { throw VTBackendError.pixelBufferPoolCreationFailed(backend: .frameRateConversion) }
    self.pixelBufferPool = pixelBufferPool
  }

  // Swift 6.3 cycles `ActorIsolationRequest` on `isolated deinit` under release-mode WMO,
  // so use a plain `deinit` and mark `processor` `nonisolated(unsafe)` to reach it from here.
  deinit {
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
  public static let displayName = "Frame rate conversion"
  public nonisolated var displayName: String { Self.displayName }

  public nonisolated var requiresInstancePerStream: Bool { true }

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

    let vtPts = CMTime(value: Int64(frameIndex), timescale: vtSyntheticTimescale)
    frameIndex += 1
    guard
      let newFrameWrapper = VTFrameProcessorFrame(
        buffer: pixelBuffer, presentationTimeStamp: vtPts)
    else {
      throw VTBackendError.vtFrameConstructionFailed(backend: .frameRateConversion)
    }

    nonisolated(unsafe) let capturedBuffer = pixelBuffer

    // First frame: buffer and return empty. Anchor the output schedule on the first source
    // PTS so outputs begin at the same instant as the source.
    guard let buffered = bufferedFrame else {
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
      bufferedFrame = BufferedFrame(
        wrapper: newFrameWrapper, buffer: capturedBuffer, pts: nextPTS)
      return []
    }

    // `targetOutputIndex` is monotonic, so `phase` grows through `[0, 1)`. Any `phase <= 0`
    // entries therefore land at the start, before all interpolated PTSs — we can append in
    // order instead of sorting at the end.
    //
    // Upper bound on emitted frames from this pair: one target period per slot plus one for
    // rounding. `nextPTS - prevPTS` is at most one source period at steady rates, so this is
    // `ceil(target/source) + 1` in the common case. Planning scratch (`interpolationPhases`,
    // `interpolatedOutputPTSs`, `destinationBuffers`, `destinationFrames`) lives on the actor
    // and is reused with `keepingCapacity: true` so the steady-state case hits no heap growth.
    let emittedUpperBound = max(1, Int((intervalSeconds * targetFrameRate).rounded(.up)) + 1)
    var outputs: [FrameProcessorOutput] = []
    outputs.reserveCapacity(emittedUpperBound)
    interpolationPhases.removeAll(keepingCapacity: true)
    interpolatedOutputPTSs.removeAll(keepingCapacity: true)
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
      targetOutputIndex += 1
    }

    if !interpolationPhases.isEmpty {
      // Allocate one destination buffer per interpolated frame and wrap each. VT needs the
      // same count in `interpolationPhase` and `destinationFrames`.
      destinationBuffers.removeAll(keepingCapacity: true)
      destinationFrames.removeAll(keepingCapacity: true)
      for _ in interpolationPhases {
        let dest = try resolveProcessorOutputBuffer(
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
          throw VTBackendError.vtFrameConstructionFailed(backend: .frameRateConversion)
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
        throw VTBackendError.vtFrameConstructionFailed(backend: .frameRateConversion)
      }

      try await runVT(on: SendableBox(processor), parameters: SendableBox(parameters))

      outputs.reserveCapacity(outputs.count + destinationBuffers.count)
      for (buffer, outputPTS) in zip(destinationBuffers, interpolatedOutputPTSs) {
        nonisolated(unsafe) let interpolatedBuffer = buffer
        outputs.append(
          FrameProcessorOutput(
            pixelBuffer: interpolatedBuffer, presentationTimeStamp: outputPTS))
      }
    }

    // Slide: the just-received frame becomes the new buffered "prev" for the next call.
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
    // Release retained planning scratch so the last emitted frame doesn't keep destination
    // buffers alive past the end of the stream.
    destinationBuffers.removeAll(keepingCapacity: false)
    destinationFrames.removeAll(keepingCapacity: false)
    nonisolated(unsafe) let passthroughBuffer = buffered.buffer
    return [
      FrameProcessorOutput(pixelBuffer: passthroughBuffer, presentationTimeStamp: buffered.pts)
    ]
  }

  // MARK: Private

  /// `kCVPixelBufferPoolMinimumBufferCountKey` value. Each source pair emits up to
  /// `target/source - 1` destination buffers in one shot, plus in-flight consumption
  /// downstream (including one held by the next stage while we start the next frame).
  /// 13 covers every realistic ratio (≤ ~10×) without fall-back to
  /// `CVPixelBufferPoolCreatePixelBuffer`.
  private static let minimumPoolBufferCount = 13

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

  private let frameSize: CGSize
  private let targetFrameRate: Double
  /// Period between consecutive target-output PTSs. For integer rates we use
  /// `timescale == rate, value == 1` so `period.value * k` is exact; for non-integer rates
  /// we use a 1 GHz fallback timescale, which bounds per-period rounding to under half a
  /// nanosecond.
  private let targetPeriod: CMTime
  private nonisolated(unsafe) let processor: VTFrameProcessor
  private let pixelBufferPool: CVPixelBufferPool

  private var frameIndex: UInt64 = 0
  private var bufferedFrame: BufferedFrame?
  private var anchorPTS: CMTime = .zero
  private var targetOutputIndex: Int64 = 0

  // Per-call planning scratch. Stored on the actor and reused with `removeAll(keepingCapacity:)`
  // so steady-state processing allocates nothing beyond the per-call output array.
  private var interpolationPhases: [Float] = []
  private var interpolatedOutputPTSs: [CMTime] = []
  private var destinationBuffers: [CVPixelBuffer] = []
  private var destinationFrames: [VTFrameProcessorFrame] = []

  /// PTS of the target output at index `k`, computed exactly (for integer rates) or with
  /// sub-nanosecond drift (for non-integer rates).
  private func targetPTS(forIndex index: Int64) -> CMTime {
    computeTargetPTS(anchor: anchorPTS, period: targetPeriod, index: index)
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
      throw VTBackendError.notSupportedOnDevice(backend: .frameRateConversion)
    }

    let (frameWidth, frameHeight) = frameSize.intDimensions

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
    case targetFrameRateOutOfRange(requested: Double, maximum: Double)
    case configurationInitFailed(frameWidth: Int, frameHeight: Int)

    public var errorDescription: String? {
      switch self {
      case .targetFrameRateOutOfRange(let requested, let maximum):
        "Target frame rate \(requested) is out of range. "
          + "Must be finite, positive, and ≤ \(Int(maximum)) fps."
      case .configurationInitFailed(let frameWidth, let frameHeight):
        "Frame-rate conversion rejected the input configuration "
          + "(\(frameWidth)×\(frameHeight)). On macOS, inputs must be ≤ 8192×4320."
      }
    }
  }
}
