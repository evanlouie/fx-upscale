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
  /// 32BGRA, Metal-compatible, IOSurface-backed attributes at the given pixel size.
  static func bgra(size: CGSize) -> [String: Any] {
    [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
      kCVPixelBufferWidthKey as String: Int(size.width),
      kCVPixelBufferHeightKey as String: Int(size.height),
    ]
  }
}
