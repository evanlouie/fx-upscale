import AVFoundation

extension CMVideoDimensions {
  public var cgSize: CGSize {
    CGSize(width: Int(width), height: Int(height))
  }
}

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

  /// True when the source's transfer function is PQ (ST 2084) or HLG — i.e. HDR.
  public var isHDR: Bool {
    guard let transfer = colorTransferFunction else { return false }
    return transfer == (AVVideoTransferFunction_SMPTE_ST_2084_PQ as String)
      || transfer == (AVVideoTransferFunction_ITU_R_2100_HLG as String)
  }

  /// Raw ST 2086 mastering-display color-volume blob (24 bytes) when present. Carried
  /// through to VideoToolbox's compression properties under
  /// `kVTCompressionPropertyKey_MasteringDisplayColorVolume` so HDR10 side-data round-trips.
  public var masteringDisplayColorVolume: Data? {
    extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] as? Data
  }

  /// Raw CTA-861.3 content-light-level info blob (4 bytes: MaxCLL, MaxFALL). Round-tripped
  /// as `kVTCompressionPropertyKey_ContentLightLevelInfo`.
  public var contentLightLevelInfo: Data? {
    extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] as? Data
  }

  /// Declared bits-per-component from the format description extensions, or `nil` if the
  /// codec didn't report it. Used by the tightened `isUnsupportedForSRGBPath` check so
  /// 10-bit Rec. 709 sources stop silently truncating to 8-bit on the spatial path.
  public var bitsPerComponent: Int? {
    (extensions[kCMFormatDescriptionExtension_BitsPerComponent] as? NSNumber)?.intValue
  }

  /// True when the source carries a Dolby Vision configuration record. This tool does not
  /// preserve DV RPU side-data — callers warn and continue as HDR10.
  public var hasDolbyVision: Bool {
    // Extension key is a CFString published by CoreMedia on macOS builds where the OS
    // supports DV; fall back to the documented string name so this also compiles on builds
    // that haven't bridged the constant yet.
    if extensions["DolbyVisionConfiguration" as CFString] != nil { return true }
    switch mediaSubType.rawValue {
    case 0x64766831 /* 'dvh1' */, 0x64766865 /* 'dvhe' */: return true
    default: return false
    }
  }

  /// True when the source's color characteristics can't be faithfully processed by the 8-bit
  /// BGRA sRGB-perceptual MetalFX path — HDR, Rec. 2020 primaries, or ≥10-bit would clip
  /// highlights, shift gamut, or silently truncate precision through a BGRA8 detour.
  var isUnsupportedForSRGBPath: Bool {
    if isHDR { return true }
    if colorPrimaries == (AVVideoColorPrimaries_ITU_R_2020 as String) { return true }
    if let bpc = bitsPerComponent, bpc >= 10 { return true }
    return false
  }
}
