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
      // Snapshot mutable state under the lock, then perform GPU work outside the lock to
      // avoid serializing concurrent callers on long GPU submissions.
      lock.lock()
      let snapshotInput = _inputImage
      let snapshotOutputSize = _outputSize
      lock.unlock()

      guard let device = Self.sharedDevice,
        let inputImage = snapshotInput,
        let outputSize = snapshotOutputSize
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

      lock.lock()
      if spatialScaler?.inputSize != normalizedInputSize
        || spatialScaler?.outputSize != normalizedOutputSize
      {
        let spatialScalerDescriptor = MTLFXSpatialScalerDescriptor.bgra8Perceptual(
          inputSize: normalizedInputSize, outputSize: normalizedOutputSize)
        spatialScaler = spatialScalerDescriptor.makeSpatialScaler(device: device)

        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.width = Int(normalizedOutputSize.width)
        textureDescriptor.height = Int(normalizedOutputSize.height)
        textureDescriptor.pixelFormat = .bgra8Unorm
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        intermediateOutputTexture = device.makeTexture(descriptor: textureDescriptor)
      }
      let scaler = spatialScaler
      let intermediate = intermediateOutputTexture
      lock.unlock()

      guard let scaler, let intermediate else { return nil }

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

  private static let sharedDevice = MTLCreateSystemDefaultDevice()

  private var _inputImage: CIImage?
  private var _outputSize: CGSize?
  private let lock = NSLock()

  #if canImport(MetalFX)
    private var spatialScaler: MTLFXSpatialScaler?
    private var intermediateOutputTexture: MTLTexture?
  #endif
}
