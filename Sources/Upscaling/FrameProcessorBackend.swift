import CoreMedia
import CoreVideo
import Foundation

// MARK: - FrameProcessorOutput

/// A single frame emitted by a `FrameProcessorBackend`.
///
/// 1:1 backends (super resolution, motion blur, temporal noise, MetalFX spatial) return one
/// `FrameProcessorOutput` per input. 1:N backends (frame-rate conversion) return multiple
/// with synthesised presentation timestamps.
///
/// The struct is `@unchecked Sendable` because `CVPixelBuffer` is a CF type. Backends that
/// retain the buffer as temporal carry-over must guarantee that both the caller and the
/// next call only read from the buffer — the same invariant already documented on
/// `VTSuperResolutionUpscaler`.
public struct FrameProcessorOutput: @unchecked Sendable {
  public let pixelBuffer: CVPixelBuffer
  public let presentationTimeStamp: CMTime

  public init(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
    self.pixelBuffer = pixelBuffer
    self.presentationTimeStamp = presentationTimeStamp
  }
}

// MARK: - FrameProcessorBackend

/// Backend-agnostic contract for a stateful per-(inputSize, outputSize) frame processor.
///
/// Conforming types are actors. Input buffers must be `kCVPixelFormatType_32BGRA` in the
/// Rec. 709 / sRGB range; HDR / wide-gamut inputs are rejected upstream in
/// `UpscalingExportSession`.
///
/// The contract is uniform across 1:1 and 1:N stages so that a `FrameProcessorChain` can
/// compose them in any order without special-casing. 1:1 backends return a single-element
/// output array; 1:N backends (frame-rate conversion) return multiple with interpolated PTS.
public protocol FrameProcessorBackend: Sendable {
  var inputSize: CGSize { get }
  var outputSize: CGSize { get }

  /// Processes a single input frame, returning one or more output frames.
  ///
  /// - Parameters:
  ///   - pixelBuffer: Input buffer at `inputSize` in `kCVPixelFormatType_32BGRA`.
  ///   - presentationTimeStamp: The source frame's PTS. 1:1 stages pass this through on
  ///     their single output; 1:N stages derive interpolated timestamps from it. Stages
  ///     that talk to `VTFrameProcessor` still synthesise their own monotonic PTS
  ///     internally (VT rejects out-of-order timestamps but doesn't care about the base).
  ///   - outputPool: Optional pool to allocate the *terminal* output buffer from. In a
  ///     `FrameProcessorChain`, only the last stage receives the writer-adaptor pool;
  ///     intermediate stages use their own internal pools.
  func process(
    _ pixelBuffer: sending CVPixelBuffer,
    presentationTimeStamp: CMTime,
    outputPool: sending CVPixelBufferPool?
  ) async throws -> [FrameProcessorOutput]

  /// Emits any frames the backend was holding back waiting for more input.
  ///
  /// Call this exactly once after the input stream ends. Most backends (1:1, no look-ahead)
  /// buffer nothing and return `[]`. Frame-rate conversion, which needs `(prev, next)` pairs,
  /// buffers the last source frame and flushes it here so the output covers the full source
  /// duration.
  ///
  /// `outputPool` has the same meaning as on `process(...)`: in a `FrameProcessorChain` only
  /// the last stage receives the terminal pool.
  func finish(
    outputPool: sending CVPixelBufferPool?
  ) async throws -> [FrameProcessorOutput]
}

extension FrameProcessorBackend {
  public func finish(
    outputPool: sending CVPixelBufferPool?
  ) async throws -> [FrameProcessorOutput] { [] }

  /// 1:1 convenience wrapper for single-frame callers. Returns the first (and only, for
  /// 1:1 backends) output buffer. Throws if the backend produced zero outputs — that would
  /// be a backend bug.
  @discardableResult public func processSingle(
    _ pixelBuffer: sending CVPixelBuffer
  ) async throws -> sending CVPixelBuffer {
    let outputs = try await process(
      pixelBuffer, presentationTimeStamp: .zero, outputPool: nil)
    guard let first = outputs.first else {
      throw FrameProcessorError.noOutputProduced
    }
    nonisolated(unsafe) let transferred = first.pixelBuffer
    return transferred
  }
}

// MARK: - FrameProcessorError

public enum FrameProcessorError: Swift.Error, LocalizedError {
  case noOutputProduced

  public var errorDescription: String? {
    switch self {
    case .noOutputProduced:
      "Frame processor returned no output buffers for an input frame."
    }
  }
}

// MARK: - UpscalerKind

/// Selector for the scaling stage an `UpscalingExportSession` uses.
///
/// Scaling is one specific stage in the (potentially multi-stage) frame-processing
/// pipeline. Non-scaling effects (motion blur, temporal noise, frame-rate conversion)
/// are selected by separate CLI flags, not by this enum.
public enum UpscalerKind: String, Sendable, CaseIterable {
  /// `MTLFXSpatialScaler` — single-frame perceptual upscaler. Fast, arbitrary ratios, no ML
  /// model download.
  case spatial

  /// `VTFrameProcessor` super-resolution — ML-based temporal upscaler that accumulates
  /// detail from prior frames. Integer scale factors only; capped at 1920×1080 input on
  /// macOS. May require a one-time ML model download on first use.
  case superResolution = "super-resolution"

  public var displayName: String {
    switch self {
    case .spatial: "MetalFX spatial"
    case .superResolution: "VideoToolbox super resolution"
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
  ) async throws -> any FrameProcessorBackend {
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

  /// Cheap synchronous validation of whether this backend can handle the given sizes on
  /// this device. Does not start a session, allocate Metal resources, or download ML models.
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
