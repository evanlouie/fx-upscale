import AVFoundation

extension CMFormatDescription {
  public var videoCodecType: AVVideoCodecType? {
    switch mediaSubType {
    case .hevc: .hevc
    case .h264: .h264
    case .jpeg: .jpeg
    case .hevcWithAlpha: .hevcWithAlpha
    default: nil
    }
  }

  private static let colorPrimariesMap: [String: String] = [
    kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String: AVVideoColorPrimaries_ITU_R_709_2,
    kCMFormatDescriptionColorPrimaries_EBU_3213 as String: AVVideoColorPrimaries_EBU_3213,
    kCMFormatDescriptionColorPrimaries_SMPTE_C as String: AVVideoColorPrimaries_SMPTE_C,
    kCMFormatDescriptionColorPrimaries_P3_D65 as String: AVVideoColorPrimaries_P3_D65,
    kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String: AVVideoColorPrimaries_ITU_R_2020,
  ]

  private static let colorTransferFunctionMap: [String: String] = [
    kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String: AVVideoTransferFunction_ITU_R_709_2,
    kCMFormatDescriptionTransferFunction_SMPTE_240M_1995 as String:
      AVVideoTransferFunction_SMPTE_240M_1995,
    kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String:
      AVVideoTransferFunction_SMPTE_ST_2084_PQ,
    kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String:
      AVVideoTransferFunction_ITU_R_2100_HLG,
    kCMFormatDescriptionTransferFunction_Linear as String: AVVideoTransferFunction_Linear,
  ]

  private static let colorYCbCrMatrixMap: [String: String] = [
    kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String: AVVideoYCbCrMatrix_ITU_R_709_2,
    kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String: AVVideoYCbCrMatrix_ITU_R_601_4,
    kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995 as String:
      AVVideoYCbCrMatrix_SMPTE_240M_1995,
    kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String: AVVideoYCbCrMatrix_ITU_R_2020,
  ]

  var colorPrimaries: String? {
    (extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String)
      .flatMap { Self.colorPrimariesMap[$0] }
  }

  var colorTransferFunction: String? {
    (extensions[kCMFormatDescriptionExtension_TransferFunction] as? String)
      .flatMap { Self.colorTransferFunctionMap[$0] }
  }

  var colorYCbCrMatrix: String? {
    (extensions[kCMFormatDescriptionExtension_YCbCrMatrix] as? String)
      .flatMap { Self.colorYCbCrMatrixMap[$0] }
  }

  var hasLeftAndRightEye: Bool {
    var hasLeftEye = false
    var hasRightEye = false
    for collection in tagCollections ?? [] {
      for tag in collection {
        if tag == .stereoView(.leftEye) { hasLeftEye = true }
        if tag == .stereoView(.rightEye) { hasRightEye = true }
        if hasLeftEye && hasRightEye { return true }
      }
    }
    return false
  }

  /// True when the source's color characteristics can't be faithfully processed by the 8-bit
  /// BGRA sRGB-perceptual MetalFX path. Covers:
  ///
  /// - HDR transfer functions (PQ / HLG). Decoding to 8-bit BGRA would silently clip.
  /// - Rec. 2020 primaries. The perceptual-sRGB scaler squeezes the wider gamut through an
  ///   sRGB-shaped curve; re-tagging the output Rec. 2020 produces shifted colors.
  ///
  /// Rec. 2020 content also happens to always be 10-bit in practice, so this single check also
  /// protects against 10-bit sources silently losing precision on the BGRA path.
  var isUnsupportedForSRGBPath: Bool {
    if let transfer = colorTransferFunction,
      transfer == (AVVideoTransferFunction_SMPTE_ST_2084_PQ as String)
        || transfer == (AVVideoTransferFunction_ITU_R_2100_HLG as String)
    {
      return true
    }
    if let primaries = colorPrimaries,
      primaries == (AVVideoColorPrimaries_ITU_R_2020 as String)
    {
      return true
    }
    return false
  }
}
