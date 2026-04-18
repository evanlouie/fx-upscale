import CoreImage
import Foundation

#if canImport(MetalFX)
  import MetalFX
#endif

// MARK: - UpscalingImageProcessorKernel

/// A CoreImage processor kernel that uses MetalFX spatial scaling for upscaling.
///
/// - Warning: MetalFX spatial scaling does not support tiled rendering. The entire input image
///   must fit in GPU memory. For very large images, consider using `Upscaler` directly with
///   chunked processing at the application level.
public final class UpscalingImageProcessorKernel: CIImageProcessorKernel {
  override public class var synchronizeInputs: Bool { false }
  override public class var outputFormat: CIFormat { .BGRA8 }

  override public class func formatForInput(at _: Int32) -> CIFormat { .BGRA8 }

  override public class func process(
    with inputs: [any CIImageProcessorInput]?,
    arguments: [String: Any]?,
    output: any CIImageProcessorOutput
  ) throws {
    #if canImport(MetalFX)
      guard let spatialScaler = arguments?["spatialScaler"] as? MTLFXSpatialScaler else {
        throw Error.missingSpatialScaler
      }
      guard let inputTexture = inputs?.first?.metalTexture else {
        throw Error.missingInputTexture
      }
      guard let outputTexture = output.metalTexture else {
        throw Error.missingOutputTexture
      }
      guard let commandBuffer = output.metalCommandBuffer else {
        throw Error.missingCommandBuffer
      }
      spatialScaler.colorTexture = inputTexture
      if outputTexture.storageMode == .private {
        spatialScaler.outputTexture = outputTexture
        spatialScaler.encode(commandBuffer: commandBuffer)
      } else {
        guard let intermediateOutputTexture = arguments?["intermediateOutputTexture"] as? MTLTexture
        else {
          throw Error.missingIntermediateOutputTexture
        }
        spatialScaler.outputTexture = intermediateOutputTexture
        spatialScaler.encode(commandBuffer: commandBuffer)
        guard let blitCommandEncoder = commandBuffer.makeBlitCommandEncoder() else {
          throw Error.couldNotMakeBlitCommandEncoder
        }
        // The whole-texture `copy(from:to:)` overload traps when the two textures don't have
        // identical dimensions, which CoreImage may produce when it tiles output. Use the
        // explicit-region overload and clamp the copy size to the smaller of the two.
        guard intermediateOutputTexture.pixelFormat == outputTexture.pixelFormat else {
          blitCommandEncoder.endEncoding()
          throw Error.textureFormatMismatch
        }
        let copyWidth = min(intermediateOutputTexture.width, outputTexture.width)
        let copyHeight = min(intermediateOutputTexture.height, outputTexture.height)
        blitCommandEncoder.copy(
          from: intermediateOutputTexture,
          sourceSlice: 0,
          sourceLevel: 0,
          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
          sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
          to: outputTexture,
          destinationSlice: 0,
          destinationLevel: 0,
          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitCommandEncoder.endEncoding()
      }
    #endif
  }

  /// Returns the region of interest for the given output rectangle.
  ///
  /// - Important: This method intentionally returns the full input size regardless of `outputRect`.
  ///   MetalFX's `MTLFXSpatialScaler` does not support partial/tiled upscaling—it requires the
  ///   complete input image to produce the complete output image. This is a fundamental limitation
  ///   of the MetalFX API, not a bug.
  override public class func roi(
    forInput _: Int32,
    arguments: [String: Any]?,
    outputRect: CGRect
  ) -> CGRect {
    #if canImport(MetalFX)
      guard let spatialScaler = arguments?["spatialScaler"] as? MTLFXSpatialScaler else {
        return .null
      }
      return CGRect(origin: .zero, size: spatialScaler.inputSize)
    #else
      return outputRect
    #endif
  }
}

// MARK: - UpscalingImageProcessorKernel.Error

extension UpscalingImageProcessorKernel {
  public enum Error: Swift.Error, LocalizedError {
    case missingSpatialScaler
    case missingInputTexture
    case missingOutputTexture
    case missingCommandBuffer
    case missingIntermediateOutputTexture
    case couldNotMakeBlitCommandEncoder
    case textureFormatMismatch

    public var errorDescription: String? {
      switch self {
      case .missingSpatialScaler: "Missing MetalFX spatial scaler argument."
      case .missingInputTexture: "Input CoreImage processor did not provide a Metal texture."
      case .missingOutputTexture: "Output CoreImage processor did not provide a Metal texture."
      case .missingCommandBuffer: "Output CoreImage processor did not provide a Metal command buffer."
      case .missingIntermediateOutputTexture: "Missing intermediate output texture argument."
      case .couldNotMakeBlitCommandEncoder: "Failed to create Metal blit command encoder."
      case .textureFormatMismatch: "Intermediate and output texture pixel formats must match."
      }
    }
  }
}
