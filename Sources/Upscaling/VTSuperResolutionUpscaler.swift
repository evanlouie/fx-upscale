import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// MARK: - VTSuperResolutionUpscaler

/// Performs `VTFrameProcessor` super-resolution upscaling of `CVPixelBuffer`s.
///
/// Unlike `Upscaler` (which wraps the stateless `MTLFXSpatialScaler`), this backend is
/// **stateful**: the processor retains prior source and output frames across `upscale(...)` calls
/// to accumulate detail temporally. Concurrent calls serialize on the actor — feed frames in
/// presentation-time order for best quality.
///
/// - Important: The super-resolution processor has strict input constraints that are checked at
///   init time and surface as `Error` cases before any pixels are touched:
///   - Input size must be ≤ 1920×1080 (macOS video mode).
///   - Output size must be an integer multiple of input size on both axes, and the ratio must
///     be one of `VTSuperResolutionScalerConfiguration.supportedScaleFactors`.
///   - The device must return `true` for `VTSuperResolutionScalerConfiguration.isSupported`.
///   - The backing ML model must be present or downloadable.
public actor VTSuperResolutionUpscaler: FrameProcessorBackend {
  // MARK: Lifecycle

  /// Creates a super-resolution upscaler for the given sizes.
  ///
  /// May download a ~tens-of-MB ML model on first use; the download is surfaced through
  /// `VTSuperResolutionScalerConfiguration.downloadConfigurationModel(completionHandler:)` and
  /// reported as `Error.modelDownloadFailed` on failure.
  ///
  /// `pixelFormat` selects the buffer format used end-to-end through this stage. Pass
  /// `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` for an HDR round-trip.
  public init(
    inputSize: CGSize,
    outputSize: CGSize,
    pixelFormat: OSType = kCVPixelFormatType_32BGRA
  ) async throws {
    self.inputSize = inputSize
    self.outputSize = outputSize
    self.pixelFormat = pixelFormat

    let configuration = try Self.makeConfiguration(
      inputSize: inputSize, outputSize: outputSize)
    guard frameSupportedPixelFormats(of: configuration).contains(pixelFormat)
    else {
      throw Error.unsupportedPixelFormat(
        pixelFormat, supported: frameSupportedPixelFormats(of: configuration))
    }

    // The model ships separately from the OS and may need to be fetched on first use. Drive the
    // download synchronously so the first frame doesn't race against an unready processor.
    switch configuration.configurationModelStatus {
    case .ready:
      break
    case .downloading, .downloadRequired:
      try await Self.downloadModel(configuration: configuration)
    @unknown default:
      try await Self.downloadModel(configuration: configuration)
    }

    self.core = try VTStatefulBackendCore(
      configuration: configuration,
      poolSize: outputSize,
      minimumPoolBufferCount: Self.minimumPoolBufferCount,
      backend: .superResolution,
      pixelFormat: pixelFormat)
  }

  /// Cheap synchronous validation that only checks dimensions / scale factor / device support.
  /// Does not start a session or download the ML model — intended for CLI preflight so users
  /// get a clear diagnostic before any file I/O.
  public static func preflight(inputSize: CGSize, outputSize: CGSize) throws {
    _ = try makeConfiguration(inputSize: inputSize, outputSize: outputSize)
  }

  public static func supportedPixelFormats(
    inputSize: CGSize,
    outputSize: CGSize
  ) throws -> Set<OSType> {
    let configuration = try makeConfiguration(inputSize: inputSize, outputSize: outputSize)
    return frameSupportedPixelFormats(of: configuration)
  }

  // MARK: Public

  public nonisolated let inputSize: CGSize
  public nonisolated let outputSize: CGSize
  public static let displayName = "Super resolution"
  public nonisolated var displayName: String { Self.displayName }

  public nonisolated var requiresInstancePerStream: Bool { true }

  /// The buffer format this stage accepts and emits (VT super-resolution does not
  /// transcode, so input and output format agree).
  public nonisolated let pixelFormat: OSType

  public nonisolated var supportedInputFormats: Set<OSType> { [pixelFormat] }
  public nonisolated var producedOutputFormat: OSType { pixelFormat }

  public func process(
    _ pixelBuffer: sending CVPixelBuffer,
    presentationTimeStamp: CMTime,
    outputPool externalPool: sending CVPixelBufferPool?
  ) async throws -> [FrameProcessorOutput] {
    guard await processingGate.acquire() else { throw CancellationError() }
    do {
      try Task.checkCancellation()
      let output = try resolveProcessorOutputBuffer(
        input: pixelBuffer,
        expectedInputSize: inputSize,
        expectedOutputSize: outputSize,
        externalPool: externalPool,
        internalPool: core.pixelBufferPool,
        providedOutput: nil,
        expectedPixelFormat: pixelFormat
      )

      let vtPts = core.nextPts(frameIndex: &frameIndex)
      let sourceFrame = try core.makeFrame(pixelBuffer, pts: vtPts)
      let destinationFrame = try core.makeFrame(output, pts: vtPts)

      guard
        let parameters = VTSuperResolutionScalerParameters(
          sourceFrame: sourceFrame,
          previousFrame: previousSourceFrame,
          previousOutputFrame: previousOutputFrame,
          opticalFlow: nil,
          submissionMode: .sequential,
          destinationFrame: destinationFrame
        )
      else {
        throw VTBackendError.vtFrameConstructionFailed(backend: .superResolution)
      }

      try await core.run(parameters: SendableBox(parameters))

      // Stash this call's source/destination wrappers as the "previous" pair for the next
      // submission. `VTFrameProcessorFrame` retains the underlying `CVPixelBuffer`, so caching
      // the wrappers avoids re-allocating two wrappers per frame — and also retains the output
      // buffer past the return. The caller consumes `output` via the asset writer (pixel reads);
      // the next call passes it to VT as a temporal reference (also pixel reads). Both are
      // reads of a finalized buffer — safe despite the compiler not being able to prove it.
      previousSourceFrame = sourceFrame
      previousOutputFrame = destinationFrame

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
      // Release retained temporal references so output buffers aren't kept alive past the
      // end of the stream. This backend doesn't look ahead, so nothing is flushed.
      previousSourceFrame = nil
      previousOutputFrame = nil
      await processingGate.release()
      return []
    } catch {
      await processingGate.release()
      throw error
    }
  }

  // MARK: Private

  /// `kCVPixelBufferPoolMinimumBufferCountKey` value. We hold the previous output across calls,
  /// and the next stage may hold our output buffer while we start the next frame.
  private static let minimumPoolBufferCount = 5

  /// Tolerance for "isotropic" check between width/height ratios.
  private static let ratioEpsilon: Double = 1e-3

  private let core: VTStatefulBackendCore
  private let processingGate = NonReentrantAsyncGate()

  private var frameIndex: UInt64 = 0
  private var previousSourceFrame: VTFrameProcessorFrame?
  private var previousOutputFrame: VTFrameProcessorFrame?

  /// Returns `(scaleFactor, widthRatio, heightRatio)`. `scaleFactor` is nil when the ratio
  /// isn't integer within `ratioEpsilon`.
  private static func resolveScaleFactor(
    inputSize: CGSize, outputSize: CGSize
  ) -> (scaleFactor: Int?, widthRatio: Double, heightRatio: Double) {
    let widthRatio = outputSize.width / inputSize.width
    let heightRatio = outputSize.height / inputSize.height
    let rounded = widthRatio.rounded()
    let scaleFactor: Int? =
      abs(rounded - widthRatio) < ratioEpsilon ? Int(rounded) : nil
    return (scaleFactor, widthRatio, heightRatio)
  }

  /// Builds and validates a `VTSuperResolutionScalerConfiguration` for these sizes.
  ///
  /// Factored out so `preflight(...)` and `init(...)` share one source of truth for the
  /// dimension / ratio / scale-factor / device-support rules. Construction is cheap — it does
  /// not start a session or download any ML model.
  private static func makeConfiguration(
    inputSize: CGSize, outputSize: CGSize
  ) throws -> VTSuperResolutionScalerConfiguration {
    guard VTSuperResolutionScalerConfiguration.isSupported else {
      throw VTBackendError.notSupportedOnDevice(backend: .superResolution)
    }

    let (scaleFactor, widthRatio, heightRatio) = resolveScaleFactor(
      inputSize: inputSize, outputSize: outputSize)

    guard abs(widthRatio - heightRatio) < ratioEpsilon else {
      throw Error.anisotropicScalingNotSupported(
        widthRatio: widthRatio, heightRatio: heightRatio)
    }
    guard let scaleFactor, scaleFactor >= 2 else {
      throw Error.nonIntegerScaleFactor(ratio: widthRatio)
    }

    let supported = VTSuperResolutionScalerConfiguration.supportedScaleFactors
    guard supported.contains(scaleFactor) else {
      throw Error.unsupportedScaleFactor(requested: scaleFactor, supported: supported)
    }

    let (inputWidth, inputHeight) = inputSize.intDimensions

    guard
      let configuration = VTSuperResolutionScalerConfiguration(
        frameWidth: inputWidth,
        frameHeight: inputHeight,
        scaleFactor: scaleFactor,
        inputType: .video,
        usePrecomputedFlow: false,
        qualityPrioritization: .normal,
        revision: VTSuperResolutionScalerConfiguration.defaultRevision
      )
    else {
      throw Error.configurationInitFailed(
        inputWidth: inputWidth, inputHeight: inputHeight, scaleFactor: scaleFactor)
    }

    return configuration
  }

  private static func downloadModel(
    configuration: VTSuperResolutionScalerConfiguration
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Swift.Error>) in
      configuration.downloadConfigurationModel { error in
        if let error {
          continuation.resume(throwing: Error.modelDownloadFailed(error))
        } else {
          continuation.resume()
        }
      }
    }
  }
}

// MARK: VTSuperResolutionUpscaler.Error

extension VTSuperResolutionUpscaler {
  public enum Error: Swift.Error, LocalizedError {
    case anisotropicScalingNotSupported(widthRatio: Double, heightRatio: Double)
    case nonIntegerScaleFactor(ratio: Double)
    case unsupportedScaleFactor(requested: Int, supported: [Int])
    case unsupportedPixelFormat(OSType, supported: Set<OSType>)
    case configurationInitFailed(inputWidth: Int, inputHeight: Int, scaleFactor: Int)
    case modelDownloadFailed(Swift.Error)

    public var errorDescription: String? {
      switch self {
      case .anisotropicScalingNotSupported(let widthRatio, let heightRatio):
        "Super resolution requires uniform scaling on both axes "
          + "(got \(String(format: "%.3f", widthRatio))× wide, "
          + "\(String(format: "%.3f", heightRatio))× tall). "
          + "Use --scaler spatial, or choose output dimensions that preserve the input aspect ratio."
      case .nonIntegerScaleFactor(let ratio):
        "Super resolution requires an integer scale factor "
          + "(got \(String(format: "%.3f", ratio))×). "
          + "Use --scaler spatial, or choose output dimensions that are an integer multiple "
          + "of the input size."
      case .unsupportedScaleFactor(let requested, let supported):
        "Super resolution doesn't support \(requested)× scaling on this device. "
          + "Supported scale factors: "
          + (supported.isEmpty ? "none" : supported.map { "\($0)×" }.joined(separator: ", "))
          + "."
      case .unsupportedPixelFormat(let requested, let supported):
        "Super resolution doesn't support pixel format \(describePixelFormat(requested)). "
          + "Supported formats: "
          + (supported.isEmpty
            ? "none"
            : supported.map(describePixelFormat).sorted().joined(separator: ", "))
          + "."
      case .configurationInitFailed(let inputWidth, let inputHeight, let scaleFactor):
        "Super resolution rejected the input configuration "
          + "(\(inputWidth)×\(inputHeight) @ \(scaleFactor)×). "
          + "On macOS, video inputs must be ≤ 1920×1080. Use --scaler spatial for larger sources."
      case .modelDownloadFailed(let underlying):
        "Failed to download the super-resolution ML model: \(underlying.localizedDescription)"
      }
    }
  }
}
