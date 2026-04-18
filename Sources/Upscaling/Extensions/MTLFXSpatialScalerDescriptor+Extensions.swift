#if canImport(MetalFX)
  import MetalFX

  extension MTLFXSpatialScalerDescriptor {
    var inputSize: CGSize {
      get {
        CGSize(width: inputWidth, height: inputHeight)
      }
      set {
        inputWidth = Int(newValue.width)
        inputHeight = Int(newValue.height)
      }
    }

    var outputSize: CGSize {
      get {
        CGSize(width: outputWidth, height: outputHeight)
      }
      set {
        outputWidth = Int(newValue.width)
        outputHeight = Int(newValue.height)
      }
    }

    /// Standard 8-bit BGRA, perceptual-color-space scaler descriptor used throughout the
    /// upscaling pipeline. Consolidates the five-property boilerplate that otherwise has to be
    /// kept in sync between call sites.
    static func bgra8Perceptual(
      inputSize: CGSize,
      outputSize: CGSize
    ) -> MTLFXSpatialScalerDescriptor {
      let descriptor = MTLFXSpatialScalerDescriptor()
      descriptor.inputSize = inputSize
      descriptor.outputSize = outputSize
      descriptor.colorTextureFormat = .bgra8Unorm
      descriptor.outputTextureFormat = .bgra8Unorm
      descriptor.colorProcessingMode = .perceptual
      return descriptor
    }
  }
#endif
