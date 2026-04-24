import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// MARK: - VideoColorMetadata

/// Source/video color metadata normalized from a `CMFormatDescription`.
///
/// Keep both the raw CoreMedia/CoreVideo strings and the AVFoundation writer-facing strings:
/// the raw values are useful for attachment/format-description comparisons, while
/// `AVVideoColorPropertiesKey` wants the AV constants where they exist.
public struct VideoColorMetadata: Sendable, Hashable {
  public init(
    rawColorPrimaries: String? = nil,
    rawTransferFunction: String? = nil,
    rawYCbCrMatrix: String? = nil,
    iccProfile: Data? = nil,
    gammaLevel: Double? = nil,
    bitsPerComponent: Int? = nil,
    isFullRange: Bool = false,
    masteringDisplayColorVolume: Data? = nil,
    contentLightLevelInfo: Data? = nil,
    hasDolbyVision: Bool = false
  ) {
    self.rawColorPrimaries = rawColorPrimaries
    self.rawTransferFunction = rawTransferFunction
    self.rawYCbCrMatrix = rawYCbCrMatrix
    self.iccProfile = iccProfile
    self.gammaLevel = gammaLevel
    self.bitsPerComponent = bitsPerComponent
    self.isFullRange = isFullRange
    self.masteringDisplayColorVolume = masteringDisplayColorVolume
    self.contentLightLevelInfo = contentLightLevelInfo
    self.hasDolbyVision = hasDolbyVision
  }

  public init(formatDescription: CMFormatDescription) {
    let extensions = formatDescription.extensions
    self.init(
      rawColorPrimaries: extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String,
      rawTransferFunction: extensions[kCMFormatDescriptionExtension_TransferFunction] as? String,
      rawYCbCrMatrix: extensions[kCMFormatDescriptionExtension_YCbCrMatrix] as? String,
      iccProfile: extensions[kCMFormatDescriptionExtension_ICCProfile] as? Data,
      gammaLevel: (extensions[kCMFormatDescriptionExtension_GammaLevel] as? NSNumber)?
        .doubleValue,
      bitsPerComponent: (extensions[kCMFormatDescriptionExtension_BitsPerComponent] as? NSNumber)?
        .intValue,
      isFullRange: (extensions[kCMFormatDescriptionExtension_FullRangeVideo] as? NSNumber)?
        .boolValue ?? false,
      masteringDisplayColorVolume:
        extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] as? Data,
      contentLightLevelInfo:
        extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] as? Data,
      hasDolbyVision: Self.detectDolbyVision(
        mediaSubType: formatDescription.mediaSubType, extensions: extensions)
    )
  }

  public static let rec709 = VideoColorMetadata(
    rawColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
    rawTransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
    rawYCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)

  public let rawColorPrimaries: String?
  public let rawTransferFunction: String?
  public let rawYCbCrMatrix: String?
  public let iccProfile: Data?
  public let gammaLevel: Double?
  public let bitsPerComponent: Int?
  public let isFullRange: Bool
  public let masteringDisplayColorVolume: Data?
  public let contentLightLevelInfo: Data?
  public let hasDolbyVision: Bool

  public var avColorPrimaries: String? {
    rawColorPrimaries.flatMap { Self.colorPrimariesMap[$0] }
  }

  public var avTransferFunction: String? {
    rawTransferFunction.map { Self.transferFunctionMap[$0] ?? $0 }
  }

  public var avYCbCrMatrix: String? {
    rawYCbCrMatrix.map { Self.yCbCrMatrixMap[$0] ?? $0 }
  }

  public var avColorProperties: [String: Any]? {
    let hasExplicitColorTag =
      rawColorPrimaries != nil || rawTransferFunction != nil || rawYCbCrMatrix != nil
    guard hasExplicitColorTag else {
      return nil
    }
    let colorPrimaries = avColorPrimaries ?? Self.defaultColorPrimaries(for: self)
    let transferFunction = avTransferFunction ?? Self.defaultTransferFunction(for: self)
    let yCbCrMatrix = avYCbCrMatrix ?? Self.defaultYCbCrMatrix(for: self)
    return [
      AVVideoColorPrimariesKey: colorPrimaries,
      AVVideoTransferFunctionKey: transferFunction,
      AVVideoYCbCrMatrixKey: yCbCrMatrix,
    ]
  }

  public var isHDR: Bool {
    guard let transfer = rawTransferFunction else { return false }
    return transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
      || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
  }

  public var isRec2020: Bool {
    rawColorPrimaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
  }

  public var isWideGamut: Bool {
    rawColorPrimaries == (kCMFormatDescriptionColorPrimaries_P3_D65 as String)
      || rawColorPrimaries == (kCMFormatDescriptionColorPrimaries_DCI_P3 as String)
      || rawColorPrimaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
  }

  public var isWideGamutSDR: Bool { isWideGamut && !isHDR }

  public var requiresMain10: Bool {
    isHDR || (bitsPerComponent ?? 8) >= 10
  }

  /// True when the source cannot safely go through the 8-bit RGB processing path.
  ///
  /// P3 SDR is intentionally allowed: we color-manage and preserve P3 tags now. HDR, Rec. 2020,
  /// and 10-bit still need a YUV/10-bit path to avoid clipping or precision loss.
  public var isUnsupportedForBGRAPath: Bool {
    if isHDR { return true }
    if isRec2020 { return true }
    if let bitsPerComponent, bitsPerComponent >= 10 { return true }
    return false
  }

  public var cgColorSpace: CGColorSpace {
    if let iccProfile,
      let space = CGColorSpace(iccData: iccProfile as CFData)
    {
      return space
    }

    let name: CFString
    if rawColorPrimaries == (kCMFormatDescriptionColorPrimaries_P3_D65 as String) {
      name = CGColorSpace.displayP3
    } else if rawColorPrimaries == (kCMFormatDescriptionColorPrimaries_DCI_P3 as String) {
      name = CGColorSpace.dcip3
    } else if rawColorPrimaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) {
      if rawTransferFunction == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
        name = CGColorSpace.itur_2100_PQ
      } else if rawTransferFunction == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
        name = CGColorSpace.itur_2100_HLG
      } else {
        name = CGColorSpace.itur_2020
      }
    } else if rawColorPrimaries == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String) {
      if rawTransferFunction == (kCMFormatDescriptionTransferFunction_sRGB as String) {
        name = CGColorSpace.sRGB
      } else {
        name = CGColorSpace.itur_709
      }
    } else {
      name = CGColorSpace.sRGB
    }
    return CGColorSpace(name: name) ?? CGColorSpaceCreateDeviceRGB()
  }

  public var compressionColorProperties: [String: Any] {
    var properties: [String: Any] = [:]
    if let iccProfile {
      properties[kVTCompressionPropertyKey_ICCProfile as String] = iccProfile
    }
    if let gammaLevel {
      properties[kVTCompressionPropertyKey_GammaLevel as String] = gammaLevel
    }
    if let masteringDisplayColorVolume {
      properties[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String] =
        masteringDisplayColorVolume
    }
    if let contentLightLevelInfo {
      properties[kVTCompressionPropertyKey_ContentLightLevelInfo as String] = contentLightLevelInfo
    }
    if isHDR {
      properties[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] =
        kVTHDRMetadataInsertionMode_Auto
    }
    return properties
  }

  private static let colorPrimariesMap: [String: String] = [
    kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String:
      AVVideoColorPrimaries_ITU_R_709_2,
    kCMFormatDescriptionColorPrimaries_EBU_3213 as String:
      AVVideoColorPrimaries_EBU_3213,
    kCMFormatDescriptionColorPrimaries_SMPTE_C as String:
      AVVideoColorPrimaries_SMPTE_C,
    kCMFormatDescriptionColorPrimaries_P3_D65 as String:
      AVVideoColorPrimaries_P3_D65,
    kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String:
      AVVideoColorPrimaries_ITU_R_2020,
    // AVAssetWriter does not accept the CoreMedia P22 token for H.264/HEVC color properties.
    // SMPTE-C is the closest writer-supported SD-video primary set and keeps the settings valid.
    kCMFormatDescriptionColorPrimaries_P22 as String:
      AVVideoColorPrimaries_SMPTE_C,
    // AVFoundation does not publish a Swift constant for DCI-P3 here, but the writer accepts
    // the CoreMedia token.
    kCMFormatDescriptionColorPrimaries_DCI_P3 as String:
      kCMFormatDescriptionColorPrimaries_DCI_P3 as String,
  ]

  private static let transferFunctionMap: [String: String] = [
    kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String:
      AVVideoTransferFunction_ITU_R_709_2,
    // ITU-R 2020 transfer is semantically equivalent to 709; the CoreMedia header says 709 is
    // preferred, and AVFoundation's public writer key list does not expose a separate constant.
    kCMFormatDescriptionTransferFunction_ITU_R_2020 as String:
      AVVideoTransferFunction_ITU_R_709_2,
    kCMFormatDescriptionTransferFunction_SMPTE_240M_1995 as String:
      AVVideoTransferFunction_SMPTE_240M_1995,
    kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String:
      AVVideoTransferFunction_SMPTE_ST_2084_PQ,
    kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String:
      AVVideoTransferFunction_ITU_R_2100_HLG,
    kCMFormatDescriptionTransferFunction_Linear as String:
      AVVideoTransferFunction_Linear,
    kCMFormatDescriptionTransferFunction_sRGB as String:
      AVVideoTransferFunction_IEC_sRGB,
  ]

  private static let yCbCrMatrixMap: [String: String] = [
    kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String:
      AVVideoYCbCrMatrix_ITU_R_709_2,
    kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String:
      AVVideoYCbCrMatrix_ITU_R_601_4,
    kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995 as String:
      AVVideoYCbCrMatrix_SMPTE_240M_1995,
    kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String:
      AVVideoYCbCrMatrix_ITU_R_2020,
  ]

  private static func defaultColorPrimaries(for color: VideoColorMetadata) -> String {
    if color.rawYCbCrMatrix == (kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String) {
      return AVVideoColorPrimaries_SMPTE_C
    }
    return AVVideoColorPrimaries_ITU_R_709_2
  }

  private static func defaultTransferFunction(for _: VideoColorMetadata) -> String {
    AVVideoTransferFunction_ITU_R_709_2
  }

  private static func defaultYCbCrMatrix(for color: VideoColorMetadata) -> String {
    if color.rawColorPrimaries == (kCMFormatDescriptionColorPrimaries_EBU_3213 as String)
      || color.rawColorPrimaries == (kCMFormatDescriptionColorPrimaries_SMPTE_C as String)
      || color.rawColorPrimaries == (kCMFormatDescriptionColorPrimaries_P22 as String)
    {
      return AVVideoYCbCrMatrix_ITU_R_601_4
    }
    return AVVideoYCbCrMatrix_ITU_R_709_2
  }

  private static func detectDolbyVision(
    mediaSubType: CMFormatDescription.MediaSubType,
    extensions: CMFormatDescription.Extensions
  ) -> Bool {
    if extensions["DolbyVisionConfiguration" as CFString] != nil { return true }
    switch mediaSubType.rawValue {
    case 0x6476_6831 /* 'dvh1' */, 0x6476_6865 /* 'dvhe' */: return true
    default: return false
    }
  }
}

// MARK: - FrameFormat

public struct FrameFormat: Sendable, Hashable {
  public init(pixelFormat: OSType, color: VideoColorMetadata) {
    self.pixelFormat = pixelFormat
    self.color = color
  }

  public let pixelFormat: OSType
  public let color: VideoColorMetadata

  public var isFullRange: Bool { Self.isFullRange(pixelFormat) }
  public var isTenBit: Bool { Self.isTenBit(pixelFormat) }

  public static func preferredPixelFormats(for color: VideoColorMetadata) -> [OSType] {
    if color.requiresMain10 {
      return color.isFullRange
        ? [
          kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
          kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
          kCVPixelFormatType_64RGBAHalf,
          kCVPixelFormatType_32BGRA,
        ]
        : [
          kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
          kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
          kCVPixelFormatType_64RGBAHalf,
          kCVPixelFormatType_32BGRA,
        ]
    }
    if color.isFullRange {
      return [
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_64RGBAHalf,
        kCVPixelFormatType_32BGRA,
      ]
    }
    return [
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelFormatType_64RGBAHalf,
      kCVPixelFormatType_32BGRA,
    ]
  }

  public static func resolvePreferredPixelFormat(
    for color: VideoColorMetadata,
    accepted: Set<OSType>
  ) -> OSType {
    for candidate in preferredPixelFormats(for: color) where accepted.contains(candidate) {
      return candidate
    }
    if let firstAccepted = accepted.sorted().first {
      return firstAccepted
    }
    return kCVPixelFormatType_32BGRA
  }

  public static func isFullRange(_ pixelFormat: OSType) -> Bool {
    switch pixelFormat {
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
      true
    default:
      false
    }
  }

  public static func isTenBit(_ pixelFormat: OSType) -> Bool {
    switch pixelFormat {
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
      true
    default:
      false
    }
  }
}

func pixelFormatSet(from numbers: [NSNumber]) -> Set<OSType> {
  Set(numbers.map { OSType(truncating: $0) })
}

func pixelFormatSet(from formats: [OSType]) -> Set<OSType> {
  Set(formats)
}

func frameSupportedPixelFormats(of configuration: NSObject) -> Set<OSType> {
  guard let value = configuration.value(forKey: "frameSupportedPixelFormats") else {
    return []
  }
  if let numbers = value as? [NSNumber] {
    return pixelFormatSet(from: numbers)
  }
  if let formats = value as? [OSType] {
    return pixelFormatSet(from: formats)
  }
  if let array = value as? [Any] {
    return Set(array.compactMap { element in
      if let number = element as? NSNumber {
        return OSType(truncating: number)
      }
      return element as? OSType
    })
  }
  return []
}
