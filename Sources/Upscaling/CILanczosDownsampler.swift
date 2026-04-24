import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
import Foundation
import Metal

// MARK: - CILanczosDownsampler

/// Performs a terminal `CILanczosScaleTransform` downsample on `CVPixelBuffer`s.
///
/// Only valid as a downsample: `outputSize` must be ≤ `inputSize` on both axes. The filter is
/// evaluated in the source color space on both ends. That keeps P3 / Rec. 709 SDR tagged
/// sources in their intended transfer function instead of forcing every downsample through
/// an sRGB interpretation.
///
/// `requiresInstancePerStream` is `true` so stereo pairs don't contend on one output pool.
public actor CILanczosDownsampler: FrameProcessorBackend {
  // MARK: Lifecycle

  public init(
    inputSize: CGSize,
    outputSize: CGSize,
    pixelFormat: OSType = kCVPixelFormatType_32BGRA,
    colorMetadata: VideoColorMetadata = .rec709
  ) throws {
    try Self.validate(inputSize: inputSize, outputSize: outputSize)
    self.inputSize = inputSize
    self.outputSize = outputSize
    self.pixelFormat = pixelFormat
    self.colorSpace = colorMetadata.cgColorSpace

    let verticalScale = Double(outputSize.height) / Double(inputSize.height)
    self.filterScale = Float(verticalScale)
    self.filterAspectRatio =
      Float((Double(outputSize.width) / Double(inputSize.width)) / verticalScale)
    self.outputRect = CGRect(origin: .zero, size: outputSize)

    guard
      let pool = makePixelBufferPool(
        format: pixelFormat,
        size: outputSize, minimumBufferCount: Self.minimumPoolBufferCount)
    else {
      throw Error.poolAllocationFailed
    }
    self.pixelBufferPool = pool

    guard let device = MTLCreateSystemDefaultDevice() else {
      throw Error.metalDeviceUnavailable
    }
    self.context = CIContext(
      mtlDevice: device,
      options: [
        .workingColorSpace: colorSpace,
        .outputColorSpace: colorSpace,
        .cacheIntermediates: false,
      ])
  }

  public static func preflight(inputSize: CGSize, outputSize: CGSize) throws {
    try validate(inputSize: inputSize, outputSize: outputSize)
  }

  public static func supportedPixelFormats(
    inputSize: CGSize,
    outputSize: CGSize,
    colorMetadata: VideoColorMetadata
  ) throws -> Set<OSType> {
    try validate(inputSize: inputSize, outputSize: outputSize)
    let colorSpace = colorMetadata.cgColorSpace
    return Set(
      FrameFormat.preferredPixelFormats(for: colorMetadata)
        .filter { canRender(pixelFormat: $0, colorSpace: colorSpace) })
  }

  // MARK: Public

  public nonisolated let inputSize: CGSize
  public nonisolated let outputSize: CGSize
  public static let displayName = "Lanczos downsample"
  public nonisolated var displayName: String { Self.displayName }
  public nonisolated var requiresInstancePerStream: Bool { true }
  public nonisolated var maxConcurrentFrames: Int { 2 }
  public nonisolated var supportedInputFormats: Set<OSType> { [pixelFormat] }
  public nonisolated var producedOutputFormat: OSType { pixelFormat }

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
      providedOutput: nil,
      expectedPixelFormat: pixelFormat
    )

    let input = CIImage(
      cvPixelBuffer: pixelBuffer,
      options: [.colorSpace: colorSpace]
    )
    let filter = CIFilter.lanczosScaleTransform()
    filter.inputImage = input
    filter.scale = filterScale
    filter.aspectRatio = filterAspectRatio
    let scaled = filter.outputImage ?? input

    // Render off-actor. Holding the actor across the synchronous `CIContext.render` would
    // serialize pipelined stages on this actor's queue and halve steady-state throughput.
    let capturedContext = context
    let capturedImage = scaled
    let capturedBounds = outputRect
    let capturedColorSpace = colorSpace
    nonisolated(unsafe) let capturedOutput = output
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global(qos: .userInitiated).async {
        capturedContext.render(
          capturedImage,
          to: capturedOutput,
          bounds: capturedBounds,
          colorSpace: capturedColorSpace
        )
        continuation.resume()
      }
    }

    nonisolated(unsafe) let resultBuffer = output
    return [
      FrameProcessorOutput(
        pixelBuffer: resultBuffer,
        presentationTimeStamp: presentationTimeStamp
      )
    ]
  }

  // MARK: Private

  /// Matches `Upscaler.minimumPoolBufferCount`: one in the chain's input channel, one in-flight,
  /// plus headroom for the 2-capacity output channel downstream.
  private static let minimumPoolBufferCount = 5

  private let context: CIContext
  private let pixelBufferPool: CVPixelBufferPool
  private let pixelFormat: OSType
  private let colorSpace: CGColorSpace
  private let filterScale: Float
  private let filterAspectRatio: Float
  private let outputRect: CGRect

  private static func canRender(pixelFormat: OSType, colorSpace: CGColorSpace) -> Bool {
    guard let device = MTLCreateSystemDefaultDevice() else { return false }
    let probeSize = CGSize(width: 16, height: 16)
    guard
      let pool = makePixelBufferPool(
        format: pixelFormat, size: probeSize, minimumBufferCount: 1)
    else { return false }

    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
      let buffer
    else { return false }

    let context = CIContext(
      mtlDevice: device,
      options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace])
    let image = CIImage(color: .black).cropped(
      to: CGRect(origin: .zero, size: probeSize))
    context.render(
      image,
      to: buffer,
      bounds: CGRect(origin: .zero, size: probeSize),
      colorSpace: colorSpace)
    return true
  }

  private static func validate(inputSize: CGSize, outputSize: CGSize) throws {
    guard inputSize.width > 0, inputSize.height > 0 else {
      throw Error.invalidInputSize(inputSize)
    }
    guard outputSize.width > 0, outputSize.height > 0 else {
      throw Error.invalidOutputSize(outputSize)
    }
    guard
      Int(inputSize.width) % 2 == 0, Int(inputSize.height) % 2 == 0,
      Int(outputSize.width) % 2 == 0, Int(outputSize.height) % 2 == 0
    else {
      throw Error.oddDimensions(inputSize: inputSize, outputSize: outputSize)
    }
    guard
      outputSize.width <= inputSize.width,
      outputSize.height <= inputSize.height
    else {
      throw Error.outputLargerThanInput(inputSize: inputSize, outputSize: outputSize)
    }
  }
}

// MARK: - CILanczosDownsampler.Error

extension CILanczosDownsampler {
  public enum Error: Swift.Error, LocalizedError {
    case invalidInputSize(CGSize)
    case invalidOutputSize(CGSize)
    case oddDimensions(inputSize: CGSize, outputSize: CGSize)
    case outputLargerThanInput(inputSize: CGSize, outputSize: CGSize)
    case poolAllocationFailed
    case metalDeviceUnavailable

    public var errorDescription: String? {
      switch self {
      case .invalidInputSize(let size):
        "Lanczos downsample: input size \(Int(size.width))x\(Int(size.height)) "
          + "must be positive on both axes."
      case .invalidOutputSize(let size):
        "Lanczos downsample: output size \(Int(size.width))x\(Int(size.height)) "
          + "must be positive on both axes."
      case .oddDimensions(let input, let output):
        "Lanczos downsample: input \(Int(input.width))x\(Int(input.height)) and "
          + "output \(Int(output.width))x\(Int(output.height)) must both have even "
          + "dimensions (H.264 / HEVC requirement)."
      case .outputLargerThanInput(let input, let output):
        "Lanczos downsample: output \(Int(output.width))x\(Int(output.height)) must not "
          + "exceed input \(Int(input.width))x\(Int(input.height)) on either axis. "
          + "Lanczos is downsample-only."
      case .poolAllocationFailed:
        "Lanczos downsample: failed to allocate output pixel buffer pool."
      case .metalDeviceUnavailable:
        "Lanczos downsample: no Metal device available."
      }
    }
  }
}
