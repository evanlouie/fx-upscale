import CoreVideo
import Foundation

extension CVPixelBuffer {
  var width: Int { CVPixelBufferGetWidth(self) }
  var height: Int { CVPixelBufferGetHeight(self) }
  var size: CGSize { .init(width: width, height: height) }
}

// MARK: - PixelBufferAttributes

/// Shared pixel-buffer attribute dictionaries used when creating pools or adaptor-backed
/// pixel buffers that must be Metal-compatible and IOSurface-backed.
enum PixelBufferAttributes {
  /// Metal-compatible, IOSurface-backed attributes for the given pixel format, without
  /// dimensions. Use this for reader-output settings where the source's natural size should
  /// be preserved.
  static func formatted(_ format: OSType) -> [String: Any] {
    [
      kCVPixelBufferPixelFormatTypeKey as String: format,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
    ]
  }

  /// Same attributes as `formatted(_:)` but with fixed width/height for pools and adaptors
  /// that need to allocate buffers at a specific output size.
  static func formatted(_ format: OSType, size: CGSize) -> [String: Any] {
    var attrs = formatted(format)
    attrs[kCVPixelBufferWidthKey as String] = Int(size.width)
    attrs[kCVPixelBufferHeightKey as String] = Int(size.height)
    return attrs
  }
}

// MARK: - PixelBufferPool

/// Creates an IOSurface-backed `CVPixelBufferPool` at a fixed size and pixel format. The pool
/// releases idle buffers after one second so long-running exports don't hold memory
/// proportional to the worst-case in-flight burst.
func makePixelBufferPool(
  format: OSType,
  size: CGSize,
  minimumBufferCount: Int
) -> CVPixelBufferPool? {
  let poolAttributes: [String: Any] = [
    kCVPixelBufferPoolMinimumBufferCountKey as String: minimumBufferCount,
    kCVPixelBufferPoolMaximumBufferAgeKey as String: 1.0 as CFNumber,
  ]
  var pool: CVPixelBufferPool?
  CVPixelBufferPoolCreate(
    nil,
    poolAttributes as CFDictionary,
    PixelBufferAttributes.formatted(format, size: size) as CFDictionary,
    &pool
  )
  return pool
}

/// Thin BGRA call-through kept so existing call sites that don't care about non-sRGB formats
/// keep reading naturally.
func makeBGRAPixelBufferPool(size: CGSize, minimumBufferCount: Int) -> CVPixelBufferPool? {
  makePixelBufferPool(
    format: kCVPixelFormatType_32BGRA, size: size, minimumBufferCount: minimumBufferCount)
}

// MARK: - PixelBufferIOError

/// Shared input/output validation errors used by the frame-processor backends.
enum PixelBufferIOError: Swift.Error, LocalizedError {
  case unsupportedPixelFormat
  case inputSizeMismatch
  case outputSizeMismatch
  case couldNotCreatePixelBuffer

  var errorDescription: String? {
    switch self {
    case .unsupportedPixelFormat:
      "Unsupported pixel format for this processor stage."
    case .inputSizeMismatch:
      "Input pixel buffer dimensions do not match the processor's input size."
    case .outputSizeMismatch:
      "Output pixel buffer dimensions do not match the processor's output size."
    case .couldNotCreatePixelBuffer:
      "Failed to create output pixel buffer from pool."
    }
  }
}

/// Validates `pixelBuffer`'s format and size, and returns an output buffer — either the caller's
/// provided one (after size validation) or a fresh allocation from `externalPool ?? internalPool`.
///
/// The returned buffer is either caller-provided (already crossed the isolation boundary as
/// `sending`) or freshly allocated from a pool. Actor-isolated callers that want to return it
/// as `sending` must use `nonisolated(unsafe)` to escape the compiler's regional check.
func resolveProcessorOutputBuffer(
  input pixelBuffer: CVPixelBuffer,
  expectedInputSize inputSize: CGSize,
  expectedOutputSize outputSize: CGSize,
  externalPool: CVPixelBufferPool?,
  internalPool: CVPixelBufferPool,
  providedOutput: CVPixelBuffer?,
  expectedPixelFormat: OSType = kCVPixelFormatType_32BGRA
) throws -> CVPixelBuffer {
  try validateProcessorInput(
    pixelBuffer, expectedInputSize: inputSize, expectedPixelFormat: expectedPixelFormat)

  if let providedOutput {
    guard providedOutput.width == Int(outputSize.width),
      providedOutput.height == Int(outputSize.height)
    else {
      throw PixelBufferIOError.outputSizeMismatch
    }
    return providedOutput
  }

  var buffer: CVPixelBuffer?
  let status = CVPixelBufferPoolCreatePixelBuffer(nil, externalPool ?? internalPool, &buffer)
  guard status == kCVReturnSuccess, let buffer else {
    throw PixelBufferIOError.couldNotCreatePixelBuffer
  }
  return buffer
}

func validateProcessorInput(
  _ pixelBuffer: CVPixelBuffer,
  expectedInputSize inputSize: CGSize,
  expectedPixelFormat: OSType = kCVPixelFormatType_32BGRA
) throws {
  guard CVPixelBufferGetPixelFormatType(pixelBuffer) == expectedPixelFormat else {
    throw PixelBufferIOError.unsupportedPixelFormat
  }
  guard pixelBuffer.width == Int(inputSize.width),
    pixelBuffer.height == Int(inputSize.height)
  else {
    throw PixelBufferIOError.inputSizeMismatch
  }
}
