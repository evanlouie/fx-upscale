import CoreVideo

extension CVPixelBuffer {
  var width: Int { CVPixelBufferGetWidth(self) }
  var height: Int { CVPixelBufferGetHeight(self) }
  var size: CGSize { .init(width: width, height: height) }
}

// MARK: - PixelBufferAttributes

/// Shared pixel-buffer attribute dictionaries used when creating pools or adaptor-backed
/// pixel buffers that must be Metal-compatible and IOSurface-backed.
enum PixelBufferAttributes {
  /// 32BGRA, Metal-compatible, IOSurface-backed format attributes without dimensions. Use this
  /// for reader-output settings where the source's natural size should be preserved.
  static var bgra: [String: Any] {
    [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
    ]
  }

  /// Same attributes as `bgra` but with fixed width/height for pools and adaptors that need to
  /// allocate buffers at a specific output size.
  static func bgra(size: CGSize) -> [String: Any] {
    var attrs = bgra
    attrs[kCVPixelBufferWidthKey as String] = Int(size.width)
    attrs[kCVPixelBufferHeightKey as String] = Int(size.height)
    return attrs
  }
}
