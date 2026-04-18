import AVFoundation
import CoreImage
import CoreVideo
import Foundation

#if canImport(MetalFX)
  import MetalFX
#endif

// MARK: - Upscaler

/// Performs MetalFX spatial upscaling of `CVPixelBuffer`s.
///
/// The upscaler is created with a fixed input/output size and can be reused across many frames.
/// Call `upscale(_:)` from any task; the actor serializes access to the shared Metal state
/// (command queue, texture cache, pixel-buffer pool) while allowing GPU work to run in parallel
/// via MetalFX command buffers.
///
/// - Important: Input buffers must be `kCVPixelFormatType_32BGRA`. HDR / 10-bit buffers are not
///   supported by this 8-bit path and will throw `Error.unsupportedPixelFormat`.
public actor Upscaler: UpscalerBackend {
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
      guard let device = MTLCreateSystemDefaultDevice(),
        let commandQueue = device.makeCommandQueue(),
        let spatialScaler = spatialScalerDescriptor.makeSpatialScaler(device: device)
      else { return nil }
      self.device = device
      self.commandQueue = commandQueue
      self.spatialScaler = spatialScaler

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

  /// Upscales a pixel buffer asynchronously.
  ///
  /// - Parameters:
  ///   - pixelBuffer: Input buffer in `kCVPixelFormatType_32BGRA` at `inputSize`.
  ///   - pixelBufferPool: Pool to allocate the output buffer from. Falls back to the upscaler's
  ///     internal pool if `nil`.
  ///   - outputPixelBuffer: Pre-allocated output buffer to write into. If provided it must match
  ///     `outputSize`.
  /// - Returns: The upscaled pixel buffer.
  /// - Throws: `Upscaler.Error` on failure; the original input buffer is *not* silently returned.
  @discardableResult public func upscale(
    _ pixelBuffer: sending CVPixelBuffer,
    pixelBufferPool: sending CVPixelBufferPool? = nil,
    outputPixelBuffer: sending CVPixelBuffer? = nil
  ) async throws -> sending CVPixelBuffer {
    #if canImport(MetalFX)
      let (commandBuffer, output, cvColor, cvUpscaled) = try upscaleCommandBuffer(
        pixelBuffer,
        pixelBufferPool: pixelBufferPool,
        outputPixelBuffer: outputPixelBuffer
      )
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
      nonisolated(unsafe) let transferred = output
      return transferred
    #else
      throw Error.metalFXUnavailable
    #endif
  }

  // MARK: Private

  #if canImport(MetalFX)
    /// Minimum buffers kept in the output `CVPixelBufferPool`. Chosen to allow ~3 frames
    /// in-flight (reader → GPU → writer) without allocating per frame.
    private static let minimumPoolBufferCount = 3

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let spatialScaler: MTLFXSpatialScaler
    private let textureCache: CVMetalTextureCache
    private let pixelBufferPool: CVPixelBufferPool

    private func upscaleCommandBuffer(
      _ pixelBuffer: sending CVPixelBuffer,
      pixelBufferPool: sending CVPixelBufferPool? = nil,
      outputPixelBuffer: sending CVPixelBuffer? = nil
    ) throws -> (MTLCommandBuffer, CVPixelBuffer, CVMetalTexture, CVMetalTexture) {
      let output = try resolveUpscalerOutputBuffer(
        input: pixelBuffer,
        expectedInputSize: inputSize,
        expectedOutputSize: outputSize,
        externalPool: pixelBufferPool,
        internalPool: self.pixelBufferPool,
        providedOutput: outputPixelBuffer
      )

      // Input texture
      var cvColorTextureOpt: CVMetalTexture?
      let colorStatus = CVMetalTextureCacheCreateTextureFromImage(
        nil,
        textureCache,
        pixelBuffer,
        [:] as CFDictionary,
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

      // Output texture
      var cvUpscaledTextureOpt: CVMetalTexture?
      let upscaledStatus = CVMetalTextureCacheCreateTextureFromImage(
        nil,
        textureCache,
        output,
        [:] as CFDictionary,
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

      // Per-call intermediate texture — ensures concurrent in-flight command buffers don't
      // share the same GPU memory.
      let textureDescriptor = MTLTextureDescriptor()
      textureDescriptor.width = Int(outputSize.width)
      textureDescriptor.height = Int(outputSize.height)
      textureDescriptor.pixelFormat = .bgra8Unorm
      textureDescriptor.storageMode = .private
      textureDescriptor.usage = [.renderTarget, .shaderRead]
      guard let intermediateOutputTexture = device.makeTexture(descriptor: textureDescriptor) else {
        throw Error.couldNotCreateMetalTexture
      }

      guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw Error.couldNotMakeCommandBuffer
      }

      spatialScaler.colorTexture = colorTexture
      spatialScaler.outputTexture = intermediateOutputTexture
      spatialScaler.encode(commandBuffer: commandBuffer)

      guard let blitCommandEncoder = commandBuffer.makeBlitCommandEncoder() else {
        throw Error.couldNotMakeBlitCommandEncoder
      }
      blitCommandEncoder.copy(from: intermediateOutputTexture, to: upscaledTexture)
      blitCommandEncoder.endEncoding()

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
