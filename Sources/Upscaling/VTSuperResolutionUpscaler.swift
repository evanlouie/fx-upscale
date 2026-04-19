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
  // MARK: FrameProcessorBackend

  public nonisolated let requiresInstancePerStream: Bool = true

  // MARK: Lifecycle

  /// Creates a super-resolution upscaler for the given sizes.
  ///
  /// May download a ~tens-of-MB ML model on first use; the download is surfaced through
  /// `VTSuperResolutionScalerConfiguration.downloadConfigurationModel(completionHandler:)` and
  /// reported as `Error.modelDownloadFailed` on failure.
  public init(inputSize: CGSize, outputSize: CGSize) async throws {
    self.inputSize = inputSize
    self.outputSize = outputSize

    let configuration = try Self.makeConfiguration(
      inputSize: inputSize, outputSize: outputSize)

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

    let processor = VTFrameProcessor()
    try processor.startSession(configuration: configuration)
    self.processor = processor

    guard
      let pixelBufferPool = makeBGRAPixelBufferPool(
        size: outputSize, minimumBufferCount: Self.minimumPoolBufferCount)
    else { throw Error.pixelBufferPoolCreationFailed }
    self.pixelBufferPool = pixelBufferPool
  }

  isolated deinit {
    processor.endSession()
  }

  /// Cheap synchronous validation that only checks dimensions / scale factor / device support.
  /// Does not start a session or download the ML model — intended for CLI preflight so users
  /// get a clear diagnostic before any file I/O.
  public static func preflight(inputSize: CGSize, outputSize: CGSize) throws {
    _ = try makeConfiguration(inputSize: inputSize, outputSize: outputSize)
  }

  // MARK: Public

  public nonisolated let inputSize: CGSize
  public nonisolated let outputSize: CGSize

  public func process(
    _ pixelBuffer: sending CVPixelBuffer,
    presentationTimeStamp: CMTime,
    outputPool externalPool: sending CVPixelBufferPool?
  ) async throws -> [FrameProcessorOutput] {
    let output = try resolveProcessorOutputBuffer(
      input: pixelBuffer,
      expectedInputSize: inputSize,
      expectedOutputSize: outputSize,
      externalPool: externalPool,
      internalPool: pixelBufferPool,
      providedOutput: nil
    )

    // Synthesize a monotonically increasing PTS for VT's internal ordering check. VT rejects
    // out-of-order timestamps but doesn't care what base they use; the `presentationTimeStamp`
    // we expose to the caller on the returned `FrameProcessorOutput` is the real source PTS.
    let vtPts = CMTime(value: Int64(frameIndex), timescale: vtSyntheticTimescale)
    frameIndex &+= 1

    guard
      let sourceFrame = VTFrameProcessorFrame(
        buffer: pixelBuffer, presentationTimeStamp: vtPts),
      let destinationFrame = VTFrameProcessorFrame(
        buffer: output, presentationTimeStamp: vtPts),
      let parameters = VTSuperResolutionScalerParameters(
        sourceFrame: sourceFrame,
        previousFrame: previousSourceFrame,
        previousOutputFrame: previousOutputFrame,
        opticalFlow: nil,
        submissionMode: .sequential,
        destinationFrame: destinationFrame
      )
    else {
      throw Error.vtFrameConstructionFailed
    }

    nonisolated(unsafe) let vtProcessor = processor
    nonisolated(unsafe) let vtParameters = parameters
    try await runVT(on: vtProcessor, parameters: vtParameters)

    // Stash this call's source/destination wrappers as the "previous" pair for the next
    // submission. `VTFrameProcessorFrame` retains the underlying `CVPixelBuffer`, so caching
    // the wrappers avoids re-allocating two wrappers per frame — and also retains the output
    // buffer past the return. The caller consumes `output` via the asset writer (pixel reads);
    // the next call passes it to VT as a temporal reference (also pixel reads). Both are
    // reads of a finalized buffer — safe despite the compiler not being able to prove it.
    previousSourceFrame = sourceFrame
    previousOutputFrame = destinationFrame

    return [FrameProcessorOutput(pixelBuffer: output, presentationTimeStamp: presentationTimeStamp)]
  }

  // MARK: Private

  /// `kCVPixelBufferPoolMinimumBufferCountKey` value. We hold the previous output across calls,
  /// so the pool needs at least one more live buffer than the MetalFX path.
  private static let minimumPoolBufferCount = 4

  /// Tolerance for "isotropic" check between width/height ratios.
  private static let ratioEpsilon: Double = 1e-3

  private let processor: VTFrameProcessor
  private let pixelBufferPool: CVPixelBufferPool

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
      throw Error.notSupportedOnDevice
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

    let inputWidth = Int(inputSize.width.rounded())
    let inputHeight = Int(inputSize.height.rounded())

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
    case notSupportedOnDevice
    case anisotropicScalingNotSupported(widthRatio: Double, heightRatio: Double)
    case nonIntegerScaleFactor(ratio: Double)
    case unsupportedScaleFactor(requested: Int, supported: [Int])
    case configurationInitFailed(inputWidth: Int, inputHeight: Int, scaleFactor: Int)
    case modelDownloadFailed(Swift.Error)
    case pixelBufferPoolCreationFailed
    case vtFrameConstructionFailed

    public var errorDescription: String? {
      switch self {
      case .notSupportedOnDevice:
        "The VideoToolbox super-resolution processor is not supported on this device."
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
      case .configurationInitFailed(let inputWidth, let inputHeight, let scaleFactor):
        "Super resolution rejected the input configuration "
          + "(\(inputWidth)×\(inputHeight) @ \(scaleFactor)×). "
          + "On macOS, video inputs must be ≤ 1920×1080. Use --scaler spatial for larger sources."
      case .modelDownloadFailed(let underlying):
        "Failed to download the super-resolution ML model: \(underlying.localizedDescription)"
      case .pixelBufferPoolCreationFailed:
        "Failed to create the super-resolution output pixel buffer pool."
      case .vtFrameConstructionFailed:
        "Failed to construct super-resolution frame parameters "
          + "(pixel buffers must be IOSurface-backed)."
      }
    }
  }
}
