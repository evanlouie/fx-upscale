import CoreVideo
import Foundation

// MARK: - UpscalerBackend

/// Backend-agnostic contract for a stateful per-(inputSize, outputSize) upscaler.
///
/// Conforming types are actors. Input buffers must be `kCVPixelFormatType_32BGRA` in the
/// Rec. 709 / sRGB range; HDR / wide-gamut inputs are rejected upstream in
/// `UpscalingExportSession`.
public protocol UpscalerBackend: Sendable {
  var inputSize: CGSize { get }
  var outputSize: CGSize { get }

  /// Upscales a single pixel buffer. See `Upscaler.upscale(_:pixelBufferPool:outputPixelBuffer:)`
  /// for parameter semantics — the contract is identical across backends.
  @discardableResult func upscale(
    _ pixelBuffer: sending CVPixelBuffer,
    pixelBufferPool: sending CVPixelBufferPool?,
    outputPixelBuffer: sending CVPixelBuffer?
  ) async throws -> sending CVPixelBuffer
}

extension UpscalerBackend {
  @discardableResult public func upscale(
    _ pixelBuffer: sending CVPixelBuffer
  ) async throws -> sending CVPixelBuffer {
    try await upscale(pixelBuffer, pixelBufferPool: nil, outputPixelBuffer: nil)
  }
}

// MARK: - UpscalerKind

/// Selector for the upscaling algorithm an `UpscalingExportSession` uses.
public enum UpscalerKind: String, Sendable, CaseIterable {
  /// `MTLFXSpatialScaler` — single-frame perceptual upscaler. Fast, arbitrary ratios, no ML
  /// model download.
  case spatial

  /// `VTFrameProcessor` super-resolution — ML-based temporal upscaler that accumulates detail
  /// from prior frames. Integer scale factors only; capped at 1920×1080 input on macOS. May
  /// require a one-time ML model download on first use.
  case superResolution = "super-resolution"

  public var displayName: String {
    switch self {
    case .spatial: "MetalFX spatial"
    case .superResolution: "VideoToolbox super resolution"
    }
  }

  /// `true` if the backend accumulates temporal state across calls and therefore needs a
  /// dedicated instance per independent frame stream (e.g. per eye in a stereo pair).
  /// `false` if one backend can safely be shared across streams.
  public var requiresInstancePerStream: Bool {
    switch self {
    case .spatial: false
    case .superResolution: true
    }
  }

  /// Creates a fresh backend instance for the given sizes.
  ///
  /// Throws backend-specific errors (e.g. unsupported resolution, non-integer scale factor,
  /// model download failure) before any file I/O, so callers can surface a clear diagnostic
  /// without leaving a partial output behind.
  public func makeBackend(
    inputSize: CGSize,
    outputSize: CGSize
  ) async throws -> any UpscalerBackend {
    switch self {
    case .spatial:
      guard let upscaler = Upscaler(inputSize: inputSize, outputSize: outputSize) else {
        throw UpscalerKindError.spatialInitFailed
      }
      return upscaler
    case .superResolution:
      return try await VTSuperResolutionUpscaler(inputSize: inputSize, outputSize: outputSize)
    }
  }

  /// Cheap synchronous validation of whether this backend can handle the given sizes on this
  /// device. Does not start a session, allocate Metal resources, or download ML models.
  ///
  /// Call this before opening output files so the user sees a clear diagnostic if the input
  /// is incompatible with the selected backend.
  public func preflight(inputSize: CGSize, outputSize: CGSize) throws {
    switch self {
    case .spatial:
      // MetalFX descriptor validation isn't meaningfully cheaper than constructing the scaler.
      break
    case .superResolution:
      try VTSuperResolutionUpscaler.preflight(inputSize: inputSize, outputSize: outputSize)
    }
  }
}

// MARK: - UpscalerKindError

public enum UpscalerKindError: Swift.Error, LocalizedError {
  case spatialInitFailed

  public var errorDescription: String? {
    switch self {
    case .spatialInitFailed:
      "Failed to create the MetalFX spatial upscaler. This device may not support MetalFX."
    }
  }
}
