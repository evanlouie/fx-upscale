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
/// evaluated in sRGB on both ends so it stays in the same perceptual space as
/// `MTLFXSpatialScaler.bgra8Perceptual` — mixing linear-light resampling after a perceptual
/// upscale would shift highlights and shadows.
///
/// `requiresInstancePerStream` is `true` so stereo pairs don't contend on one output pool.
public actor CILanczosDownsampler: FrameProcessorBackend {
  // MARK: Lifecycle

  public init(inputSize: CGSize, outputSize: CGSize) throws {
    try Self.validate(inputSize: inputSize, outputSize: outputSize)
    self.inputSize = inputSize
    self.outputSize = outputSize

    let verticalScale = Double(outputSize.height) / Double(inputSize.height)
    self.filterScale = Float(verticalScale)
    self.filterAspectRatio =
      Float((Double(outputSize.width) / Double(inputSize.width)) / verticalScale)
    self.outputRect = CGRect(origin: .zero, size: outputSize)

    guard
      let pool = makeBGRAPixelBufferPool(
        size: outputSize, minimumBufferCount: Self.minimumPoolBufferCount)
    else {
      throw Error.poolAllocationFailed
    }
    self.pixelBufferPool = pool

    guard let device = MTLCreateSystemDefaultDevice() else {
      throw Error.metalDeviceUnavailable
    }
    // sRGB working + output space skips CoreImage's default linearize/relinearize around the
    // kernel — same perceptual-space invariant enforced per-frame by the render's `colorSpace:`
    // argument, moved into context options so CI can optimize the graph.
    self.context = CIContext(
      mtlDevice: device,
      options: [
        .workingColorSpace: Self.sRGB,
        .outputColorSpace: Self.sRGB,
        .cacheIntermediates: false,
      ])
  }

  public static func preflight(inputSize: CGSize, outputSize: CGSize) throws {
    try validate(inputSize: inputSize, outputSize: outputSize)
  }

  // MARK: Public

  public nonisolated let inputSize: CGSize
  public nonisolated let outputSize: CGSize
  public static let displayName = "Lanczos downsample"
  public nonisolated var displayName: String { Self.displayName }
  public nonisolated var requiresInstancePerStream: Bool { true }
  public nonisolated var maxConcurrentFrames: Int { 2 }

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

    // Pin sRGB on the input: scaler-output CVPixelBuffers carry no attached CGColorSpace and
    // CoreImage's default inference has shifted across OS versions.
    let input = CIImage(
      cvPixelBuffer: pixelBuffer,
      options: [.colorSpace: Self.sRGB]
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
    nonisolated(unsafe) let capturedOutput = output
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global(qos: .userInitiated).async {
        capturedContext.render(
          capturedImage,
          to: capturedOutput,
          bounds: capturedBounds,
          colorSpace: Self.sRGB
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

  private static let sRGB: CGColorSpace =
    CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

  private let context: CIContext
  private let pixelBufferPool: CVPixelBufferPool
  private let filterScale: Float
  private let filterAspectRatio: Float
  private let outputRect: CGRect

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
