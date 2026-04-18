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

      // Snapshot state, lazily (re)allocate the scaler/intermediate texture, and capture the
      // matched pair under a single critical section. Splitting this across multiple lock
      // regions risks pairing a scaler from thread A with an intermediate texture from thread
      // B when the input size changes mid-flight.
      let captured: (MTLFXSpatialScaler, MTLTexture, CIImage)? = lock.withLock {
        guard let inputImage = _inputImage,
          let outputSize = _outputSize
        else { return nil }

        // Normalize to integer pixel dimensions to avoid re-creating the scaler on fractional
        // extent differences.
        let normalizedInputSize = CGSize(
          width: Int(inputImage.extent.width.rounded()),
          height: Int(inputImage.extent.height.rounded())
        )
        let normalizedOutputSize = CGSize(
          width: Int(outputSize.width.rounded()),
          height: Int(outputSize.height.rounded())
        )

        if spatialScaler?.inputSize != normalizedInputSize
          || spatialScaler?.outputSize != normalizedOutputSize
        {
          let descriptor = MTLFXSpatialScalerDescriptor.bgra8Perceptual(
            inputSize: normalizedInputSize, outputSize: normalizedOutputSize)
          spatialScaler = descriptor.makeSpatialScaler(device: device)

          let textureDescriptor = MTLTextureDescriptor()
          textureDescriptor.width = Int(normalizedOutputSize.width)
          textureDescriptor.height = Int(normalizedOutputSize.height)
          textureDescriptor.pixelFormat = .bgra8Unorm
          textureDescriptor.storageMode = .private
          textureDescriptor.usage = [.renderTarget, .shaderRead]
          intermediateOutputTexture = device.makeTexture(descriptor: textureDescriptor)
        }

        guard let scaler = spatialScaler,
          let intermediate = intermediateOutputTexture
        else { return nil }

        return (scaler, intermediate, inputImage)
      }

      guard let (scaler, intermediate, inputImage) = captured else { return nil }

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

  #if canImport(MetalFX)
    private var spatialScaler: MTLFXSpatialScaler?
    private var intermediateOutputTexture: MTLTexture?
  #endif
}
