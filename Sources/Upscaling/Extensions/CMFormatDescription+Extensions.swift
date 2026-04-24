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

  public var colorMetadata: VideoColorMetadata {
    VideoColorMetadata(formatDescription: self)
  }

  var colorPrimaries: String? {
    colorMetadata.avColorPrimaries
  }

  var colorTransferFunction: String? {
    colorMetadata.avTransferFunction
  }

  var colorYCbCrMatrix: String? {
    colorMetadata.avYCbCrMatrix
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
    colorMetadata.isHDR
  }

  /// Raw ST 2086 mastering-display color-volume blob (24 bytes) when present. Carried
  /// through to VideoToolbox's compression properties under
  /// `kVTCompressionPropertyKey_MasteringDisplayColorVolume` so HDR10 side-data round-trips.
  public var masteringDisplayColorVolume: Data? {
    colorMetadata.masteringDisplayColorVolume
  }

  /// Raw CTA-861.3 content-light-level info blob (4 bytes: MaxCLL, MaxFALL). Round-tripped
  /// as `kVTCompressionPropertyKey_ContentLightLevelInfo`.
  public var contentLightLevelInfo: Data? {
    colorMetadata.contentLightLevelInfo
  }

  /// Declared bits-per-component from the format description extensions, or `nil` if the
  /// codec didn't report it.
  public var bitsPerComponent: Int? {
    colorMetadata.bitsPerComponent
  }

  /// True when the source carries a Dolby Vision configuration record. This tool does not
  /// preserve DV RPU side-data — callers warn and continue as HDR10.
  public var hasDolbyVision: Bool {
    colorMetadata.hasDolbyVision
  }

  /// True when the source's color characteristics can't be faithfully processed by the 8-bit
  /// BGRA MetalFX path. P3 SDR is allowed and handled through explicit color metadata; HDR,
  /// Rec. 2020, or ≥10-bit would still clip or silently truncate precision.
  var isUnsupportedForSRGBPath: Bool {
    colorMetadata.isUnsupportedForBGRAPath
  }
}
