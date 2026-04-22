import CoreImage
import Foundation

#if canImport(MetalFX)
  import MetalFX
#endif

// MARK: - UpscalingFilter

public final class UpscalingFilter: CIFilter, @unchecked Sendable {
  // MARK: Public

  override public var outputImage: CIImage? {
    #if canImport(MetalFX)
      guard let device = Self.sharedDevice else { return nil }

      let (inputImage, outputSize): (CIImage, CGSize)
      do {
        let snapshot = lock.withLock { (_inputImage, _outputSize) }
        guard let image = snapshot.0, let size = snapshot.1 else { return nil }
        inputImage = image
        outputSize = size
      }

      // Normalize to integer pixel dimensions so fractional `extent` differences don't create
      // mismatched scaler/texture pairs.
      let (inW, inH) = inputImage.extent.size.intDimensions
      let normalizedInputSize = CGSize(width: inW, height: inH)
      let (outW, outH) = outputSize.intDimensions
      let normalizedOutputSize = CGSize(width: outW, height: outH)

      // Allocate a fresh scaler and intermediate texture per call. Sharing a single scaler across
      // concurrent `outputImage` evaluations was a data race: CoreImage invokes the kernel's
      // `process` lazily (and potentially off the calling thread), and `process` mutates the
      // scaler's `colorTexture` / `outputTexture` properties before encoding. macOS 26 caches
      // MetalFX shaders, so per-call construction is cheap after the first use.
      let descriptor = MTLFXSpatialScalerDescriptor.bgra8Linear(
        inputSize: normalizedInputSize, outputSize: normalizedOutputSize)
      guard let scaler = descriptor.makeSpatialScaler(device: device) else { return nil }

      let textureDescriptor = MTLTextureDescriptor()
      textureDescriptor.width = Int(normalizedOutputSize.width)
      textureDescriptor.height = Int(normalizedOutputSize.height)
      textureDescriptor.pixelFormat = .bgra8Unorm
      textureDescriptor.storageMode = .private
      textureDescriptor.usage = [.renderTarget, .shaderRead]
      guard let intermediate = device.makeTexture(descriptor: textureDescriptor) else {
        return nil
      }

      return try? UpscalingImageProcessorKernel.apply(
        withExtent: CGRect(origin: .zero, size: scaler.outputSize),
        inputs: [inputImage],
        arguments: [
          "spatialScaler": scaler,
          "intermediateOutputTexture": intermediate,
        ]
      )
    #else
      return inputImage
    #endif
  }

  public var inputImage: CIImage? {
    get { lock.withLock { _inputImage } }
    set { lock.withLock { _inputImage = newValue } }
  }

  public var outputSize: CGSize? {
    get { lock.withLock { _outputSize } }
    set { lock.withLock { _outputSize = newValue } }
  }

  // MARK: Private

  /// `MTLDevice` is documented as thread-safe and the returned instance is effectively a
  /// process-wide singleton.
  private static let sharedDevice = MTLCreateSystemDefaultDevice()

  private var _inputImage: CIImage?
  private var _outputSize: CGSize?
  private let lock = NSLock()
}
