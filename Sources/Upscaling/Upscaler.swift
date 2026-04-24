import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

#if canImport(MetalFX)
  import MetalFX
#endif

// MARK: - Upscaler

/// Performs MetalFX spatial upscaling of `CVPixelBuffer`s.
///
/// The upscaler is created with a fixed input/output size and can be reused across many frames.
/// Call `process(_:presentationTimeStamp:outputPool:)` from any task; the actor serializes
/// access to the shared Metal state (command queue, texture cache, pixel-buffer pool) while
/// allowing GPU work to run in parallel via MetalFX command buffers.
///
/// Stateless across frames: MetalFX spatial scaling treats each frame independently, so one
/// `Upscaler` instance can safely serve multiple streams (e.g. both eyes of a stereo pair).
///
/// - Important: Input buffers must be `kCVPixelFormatType_32BGRA`. HDR / 10-bit buffers are not
///   supported by this 8-bit path and will throw `Error.unsupportedPixelFormat`.
public actor Upscaler: FrameProcessorBackend {
  // MARK: Lifecycle

  /// Creates an `Upscaler`.
  ///
  /// Returns `nil` if the current device cannot create a Metal device, command queue, MetalFX
  /// spatial scaler, texture cache, or pixel buffer pool at the requested sizes.
  public init?(inputSize: CGSize, outputSize: CGSize) {
    self.inputSize = inputSize
    self.outputSize = outputSize
    #if canImport(MetalFX)
      let spatialScalerDescriptor = MTLFXSpatialScalerDescriptor.bgra8Perceptual(
        inputSize: inputSize, outputSize: outputSize)
      // Probe: ensure a scaler can actually be created for this (device, descriptor) pair
      // before we commit to returning a usable `Upscaler`. The per-call scaler is created
      // inside `process(_:presentationTimeStamp:outputPool:)`.
      guard let device = MTLCreateSystemDefaultDevice(),
        let commandQueue = device.makeCommandQueue(),
        spatialScalerDescriptor.makeSpatialScaler(device: device) != nil
      else { return nil }
      self.device = device
      self.commandQueue = commandQueue
      self.spatialScalerDescriptor = spatialScalerDescriptor

      var textureCache: CVMetalTextureCache?
      CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
      guard let textureCache else { return nil }
      self.textureCache = textureCache

      guard
        let pixelBufferPool = makeBGRAPixelBufferPool(
          size: outputSize, minimumBufferCount: Self.minimumPoolBufferCount)
      else { return nil }
      self.pixelBufferPool = pixelBufferPool
    #endif
  }

  // MARK: Public

  public nonisolated let inputSize: CGSize
  public nonisolated let outputSize: CGSize
  public static let displayName = "MetalFX spatial"
  public nonisolated var displayName: String { Self.displayName }
  public nonisolated var maxConcurrentFrames: Int { 3 }

  /// Upscales a pixel buffer asynchronously.
  ///
  /// MetalFX spatial scaling is a 1:1 stage: this returns a single-element array carrying the
  /// source frame's PTS verbatim. The `outputPool` is honoured for the output allocation
  /// (typically the writer adaptor's pool when this is the terminal chain stage).
  ///
  /// - Throws: `Upscaler.Error` on GPU failure; `PixelBufferIOError` on size / format mismatch.
  public func process(
    _ pixelBuffer: sending CVPixelBuffer,
    presentationTimeStamp: CMTime,
    outputPool: sending CVPixelBufferPool?
  ) async throws -> [FrameProcessorOutput] {
    #if canImport(MetalFX)
      let (commandBuffer, output, cvColor, cvUpscaled) = try upscaleCommandBuffer(
        pixelBuffer,
        pixelBufferPool: outputPool,
        outputPixelBuffer: nil
      )

      // Bound the CVMetalTextureCache across long exports. The pool recycles IOSurfaces so
      // stale cache entries accumulate; flushing periodically releases them without perturbing
      // in-flight command buffers (the CVMetalTexture retains the referenced MTLTexture).
      frameCounter &+= 1
      if frameCounter % Self.textureCacheFlushInterval == 0 {
        CVMetalTextureCacheFlush(textureCache, 0)
      }

      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Swift.Error>) in
        nonisolated(unsafe) let retainedColor = cvColor
        nonisolated(unsafe) let retainedUpscaled = cvUpscaled
        commandBuffer.addCompletedHandler { commandBuffer in
          _ = retainedColor
          _ = retainedUpscaled
          if let error = commandBuffer.error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        }
        commandBuffer.commit()
      }
      return [
        FrameProcessorOutput(pixelBuffer: output, presentationTimeStamp: presentationTimeStamp)
      ]
    #else
      throw Error.metalFXUnavailable
    #endif
  }

  // MARK: Private

  #if canImport(MetalFX)
    /// Minimum buffers kept in the output `CVPixelBufferPool`. Metal allows multiple command
    /// buffers to run concurrently, plus the pipeline can hold one in-flight output downstream
    /// while the scaler starts the next frame. Avoids fall-through to
    /// `CVPixelBufferPoolCreatePixelBuffer` at 4K frame sizes (~24 MiB each).
    private static let minimumPoolBufferCount = 5

    /// Flush the `CVMetalTextureCache` every N frames. The pool recycles IOSurfaces across
    /// frames and stale cache entries otherwise accumulate over the course of a long export.
    /// 256 ≈ 8–10s of 30fps footage — large enough that the flush cost is negligible, small
    /// enough that cache growth stays bounded.
    private static let textureCacheFlushInterval: UInt64 = 256

    /// Usage flags for the CVMetalTexture cache. Hoisted to `static let` so we don't
    /// allocate a dictionary + `NSNumber` per frame on the hot path. `CFDictionary` isn't
    /// `Sendable`, but these are immutable after initialization — `nonisolated(unsafe)`.
    nonisolated(unsafe) private static let inputTextureAttributes: CFDictionary = [
      kCVMetalTextureUsage as String: NSNumber(
        value: MTLTextureUsage([.shaderRead]).rawValue)
    ] as CFDictionary
    /// MetalFX requires `.renderTarget`; `.shaderWrite` is required on some paths. With
    /// both flags set, the cache-vended MTLTexture is usable as the MetalFX output target,
    /// letting us write the upscaled result directly into the IOSurface-backed pool buffer
    /// and skip the per-frame intermediate + blit.
    nonisolated(unsafe) private static let outputTextureAttributes: CFDictionary = [
      kCVMetalTextureUsage as String: NSNumber(
        value: MTLTextureUsage([.renderTarget, .shaderWrite, .shaderRead]).rawValue)
    ] as CFDictionary

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    /// Descriptor kept so we can build a fresh `MTLFXSpatialScaler` per `process` call.
    /// Sharing a single scaler across concurrent / reentrant calls was a data race: the actor
    /// suspends at `withCheckedThrowingContinuation` (committing the command buffer), and a
    /// second entry into `process` would then mutate the shared scaler's `colorTexture` /
    /// `outputTexture` before the first frame's `encode(commandBuffer:)` had actually been
    /// captured by the command buffer. macOS 26 caches MetalFX shaders, so per-call scaler
    /// construction is cheap after the first use.
    private let spatialScalerDescriptor: MTLFXSpatialScalerDescriptor
    private let textureCache: CVMetalTextureCache
    private let pixelBufferPool: CVPixelBufferPool
    private var frameCounter: UInt64 = 0

    private func upscaleCommandBuffer(
      _ pixelBuffer: sending CVPixelBuffer,
      pixelBufferPool: sending CVPixelBufferPool? = nil,
      outputPixelBuffer: sending CVPixelBuffer? = nil
    ) throws -> (MTLCommandBuffer, CVPixelBuffer, CVMetalTexture, CVMetalTexture) {
      let output = try resolveProcessorOutputBuffer(
        input: pixelBuffer,
        expectedInputSize: inputSize,
        expectedOutputSize: outputSize,
        externalPool: pixelBufferPool,
        internalPool: self.pixelBufferPool,
        providedOutput: outputPixelBuffer
      )

      var cvColorTextureOpt: CVMetalTexture?
      let colorStatus = CVMetalTextureCacheCreateTextureFromImage(
        nil,
        textureCache,
        pixelBuffer,
        Self.inputTextureAttributes,
        .bgra8Unorm,
        pixelBuffer.width,
        pixelBuffer.height,
        0,
        &cvColorTextureOpt
      )
      guard colorStatus == kCVReturnSuccess,
        let cvColorTexture = cvColorTextureOpt,
        let colorTexture = CVMetalTextureGetTexture(cvColorTexture)
      else {
        throw Error.couldNotCreateMetalTexture
      }

      var cvUpscaledTextureOpt: CVMetalTexture?
      let upscaledStatus = CVMetalTextureCacheCreateTextureFromImage(
        nil,
        textureCache,
        output,
        Self.outputTextureAttributes,
        .bgra8Unorm,
        output.width,
        output.height,
        0,
        &cvUpscaledTextureOpt
      )
      guard upscaledStatus == kCVReturnSuccess,
        let cvUpscaledTexture = cvUpscaledTextureOpt,
        let upscaledTexture = CVMetalTextureGetTexture(cvUpscaledTexture)
      else {
        throw Error.couldNotCreateMetalTexture
      }

      // Fresh scaler per call — see comment on `spatialScalerDescriptor`.
      guard let spatialScaler = spatialScalerDescriptor.makeSpatialScaler(device: device) else {
        throw Error.couldNotCreateMetalTexture
      }

      guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw Error.couldNotMakeCommandBuffer
      }

      spatialScaler.colorTexture = colorTexture
      spatialScaler.outputTexture = upscaledTexture
      spatialScaler.encode(commandBuffer: commandBuffer)

      return (commandBuffer, output, cvColorTexture, cvUpscaledTexture)
    }
  #endif
}

// MARK: Upscaler.Error

extension Upscaler {
  public enum Error: Swift.Error, LocalizedError {
    case couldNotCreateMetalTexture
    case couldNotMakeCommandBuffer
    case couldNotMakeBlitCommandEncoder
    case metalFXUnavailable

    public var errorDescription: String? {
      switch self {
      case .couldNotCreateMetalTexture: "Failed to create Metal texture for upscaling."
      case .couldNotMakeCommandBuffer: "Failed to create Metal command buffer."
      case .couldNotMakeBlitCommandEncoder: "Failed to create Metal blit command encoder."
      case .metalFXUnavailable: "MetalFX is not available on this platform."
      }
    }
  }
}
