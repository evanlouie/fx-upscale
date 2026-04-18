#if canImport(MetalFX)
  import MetalFX

  extension MTLFXSpatialScalerDescriptor {
    var inputSize: CGSize {
      get { CGSize(width: inputWidth, height: inputHeight) }
      set {
        inputWidth = Int(newValue.width.rounded())
        inputHeight = Int(newValue.height.rounded())
      }
    }

    var outputSize: CGSize {
      get { CGSize(width: outputWidth, height: outputHeight) }
      set {
        outputWidth = Int(newValue.width.rounded())
        outputHeight = Int(newValue.height.rounded())
      }
    }

    /// 8-bit BGRA perceptual-color-space scaler: inputs are sRGB-gamma-encoded pixels, such as
    /// those produced by `AVAssetReaderTrackOutput` when decoding Rec. 709 / sRGB source into
    /// `kCVPixelFormatType_32BGRA`.
    static func bgra8Perceptual(
      inputSize: CGSize,
      outputSize: CGSize
    ) -> MTLFXSpatialScalerDescriptor {
      bgra8(inputSize: inputSize, outputSize: outputSize, colorProcessingMode: .perceptual)
    }

    /// 8-bit BGRA linear-color-space scaler: inputs are linear-light pixels, such as those
    /// CoreImage produces in its default working color space (linear sRGB) when sampling a
    /// `CIImage` into a `.BGRA8` texture.
    static func bgra8Linear(
      inputSize: CGSize,
      outputSize: CGSize
    ) -> MTLFXSpatialScalerDescriptor {
      bgra8(inputSize: inputSize, outputSize: outputSize, colorProcessingMode: .linear)
    }

    private static func bgra8(
      inputSize: CGSize,
      outputSize: CGSize,
      colorProcessingMode: MTLFXSpatialScalerColorProcessingMode
    ) -> MTLFXSpatialScalerDescriptor {
      let descriptor = MTLFXSpatialScalerDescriptor()
      descriptor.inputSize = inputSize
      descriptor.outputSize = outputSize
      descriptor.colorTextureFormat = .bgra8Unorm
      descriptor.outputTextureFormat = .bgra8Unorm
      descriptor.colorProcessingMode = colorProcessingMode
      return descriptor
    }
  }
#endif
