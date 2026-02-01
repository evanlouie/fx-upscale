import CoreImage
import Foundation

#if canImport(MetalFX)
  import MetalFX
#endif

// MARK: - UpscalingFilter

public final class UpscalingFilter: CIFilter {
  // MARK: Public

  override public var outputImage: CIImage? {
    #if canImport(MetalFX)
      lock.lock()
      defer { lock.unlock() }

      guard let device, let inputImage = _inputImage, let outputSize = _outputSize else { return nil }

      if spatialScaler?.inputSize != inputImage.extent.size
        || spatialScaler?.outputSize != outputSize
      {
        let spatialScalerDescriptor = MTLFXSpatialScalerDescriptor()
        spatialScalerDescriptor.inputSize = inputImage.extent.size
        spatialScalerDescriptor.outputSize = outputSize
        spatialScalerDescriptor.colorTextureFormat = .bgra8Unorm
        spatialScalerDescriptor.outputTextureFormat = .bgra8Unorm
        spatialScalerDescriptor.colorProcessingMode = .perceptual
        spatialScaler = spatialScalerDescriptor.makeSpatialScaler(device: device)

        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.width = Int(outputSize.width)
        textureDescriptor.height = Int(outputSize.height)
        textureDescriptor.pixelFormat = .bgra8Unorm
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        intermediateOutputTexture = device.makeTexture(descriptor: textureDescriptor)
      }

      guard let spatialScaler, let intermediateOutputTexture else { return nil }

      return try? UpscalingImageProcessorKernel.apply(
        withExtent: CGRect(origin: .zero, size: spatialScaler.outputSize),
        inputs: [inputImage],
        arguments: [
          "spatialScaler": spatialScaler,
          "intermediateOutputTexture": intermediateOutputTexture,
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

  private var _inputImage: CIImage?
  private var _outputSize: CGSize?
  private let device = MTLCreateSystemDefaultDevice()
  private let lock = NSLock()

  #if canImport(MetalFX)
    private var spatialScaler: MTLFXSpatialScaler?
  #endif
  private var intermediateOutputTexture: MTLTexture?
}
