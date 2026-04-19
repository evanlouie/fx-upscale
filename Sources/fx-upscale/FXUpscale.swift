import AVFoundation
import ArgumentParser
import Foundation
import Upscaling

// MARK: - FXUpscale

@main struct FXUpscale: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "fx-upscale",
    abstract: "Upscale a video file using Apple's Metal / VideoToolbox upscalers.",
    discussion: """
      Scaling is opt-in: pass --scale for a uniform integer factor (e.g. --scale 4 for 4× on \
      both axes), or --width and/or --height for explicit dimensions — --scale cannot be \
      combined with --width or --height. When only one of --width / --height is supplied, the \
      other is computed from the source aspect ratio. Output dimensions are rounded up to the \
      nearest even integer (required by H.264 / HEVC). If no scaling flag is passed, the \
      source resolution is preserved and only the requested effects (and codec) are applied.

      HDR (PQ / HLG) and Rec. 2020 wide-gamut inputs are rejected because the 8-bit BGRA \
      path would silently clip or shift those values.

      Two upscaling algorithms are available via --scaler:
        spatial (default)   MTLFXSpatialScaler — fast, arbitrary ratios.
        super-resolution    VTFrameProcessor ML-based super resolution — higher quality for \
                            recorded video, but requires an integer scale factor, caps input \
                            at 1920×1080 on macOS, and may download an ML model on first use.
      """,
    version: "1.2.0"
  )

  // MARK: Arguments

  @Argument(help: "The video file to upscale", transform: URL.init(fileURLWithPath:)) var url: URL

  @Option(name: .shortAndLong, help: "The output file width") var width: Int?

  // Use a custom short name to avoid colliding with ArgumentParser's built-in `-h` for `--help`.
  @Option(
    name: [.customShort("H"), .long],
    help: "The output file height"
  )
  var height: Int?

  @Option(
    name: [.customShort("x"), .long],
    help: ArgumentHelp(
      "Uniform integer scale factor (e.g. 2 for 2×, 4 for 4×).",
      discussion: "Mutually exclusive with --width and --height."
    )
  )
  var scale: Int?

  @Option(
    name: .shortAndLong,
    help: "Output codec (h264 | hevc)"
  )
  var codec: Codec = .h264

  @Option(
    name: .shortAndLong,
    help: "Output quality 1-100 (higher = better, larger file; default: encoder default)"
  )
  var quality: Int?

  @Option(
    name: [.customShort("k"), .customLong("keyframe-interval")],
    help: ArgumentHelp(
      "Max seconds between keyframes (0 = let encoder decide).",
      discussion:
        "Shorter intervals improve scrubbing responsiveness at a small size cost. "
        + "Leaving this up to the encoder can cause HEVC output to contain only a "
        + "single keyframe, which breaks arrow-key seeking in some players (e.g. IINA)."
    )
  )
  var keyframeInterval: Double = 1.0

  @Flag(name: .shortAndLong, help: "Overwrite the output file if it already exists")
  var force: Bool = false

  @Option(
    name: [.customShort("s"), .long],
    help: ArgumentHelp(
      "Upscaling algorithm (spatial | super-resolution)",
      discussion:
        "'spatial' uses MTLFXSpatialScaler (fast, arbitrary ratios). "
        + "'super-resolution' uses VTFrameProcessor's ML-based super resolution — "
        + "higher quality on recorded video, but integer scale factor only, "
        + "input capped at 1920×1080, and a one-time model download on first use."
    )
  )
  var scaler: UpscalerKind = .spatial

  @Option(
    name: [.customShort("d"), .long],
    help: ArgumentHelp(
      "Temporal noise-filter strength, 1-100 (omit for no denoising).",
      discussion:
        "Runs VTFrameProcessor's ML-based temporal noise filter before scaling. "
        + "Denoising before upscaling keeps the scaler from amplifying source noise and "
        + "gives it cleaner inter-frame flow to work with. 1 is subtle, 100 is aggressive."
    )
  )
  var denoise: Int?

  @Option(
    name: [.customShort("m"), .long],
    help: ArgumentHelp(
      "Motion-blur strength, 1-100 (omit for no motion blur).",
      discussion:
        "Runs VTFrameProcessor's ML-based motion-blur synthesis on the scaled output. "
        + "50 matches a standard 180° film shutter; 1 is subtle, 100 is pronounced. "
        + "Input must be ≤ 8192×4320 after scaling."
    )
  )
  var motionBlur: Int?

  @Option(
    name: .long,
    help: ArgumentHelp(
      "Target output frame rate (omit to preserve source rate).",
      discussion:
        "Runs VTFrameProcessor's ML-based frame-rate conversion on the scaled output. "
        + "Must be greater than the source's frame rate — this flag only upsamples; "
        + "downsampling is not supported. Output duration stays the same; only the "
        + "cadence changes. Input must be ≤ 8192×4320 after scaling."
    )
  )
  var fps: Double?

  // MARK: Validation

  func validate() throws {
    guard ["mov", "m4v", "mp4"].contains(url.pathExtension.lowercased()) else {
      throw ValidationError("Unsupported file type. Supported types: mov, m4v, mp4")
    }

    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
      throw ValidationError("File does not exist at \(url.path(percentEncoded: false))")
    }

    if let width, width <= 0 {
      throw ValidationError("--width must be a positive integer")
    }
    if let height, height <= 0 {
      throw ValidationError("--height must be a positive integer")
    }
    if let scale {
      if scale < 2 {
        throw ValidationError("--scale must be an integer ≥ 2")
      }
      if width != nil || height != nil {
        throw ValidationError("--scale cannot be combined with --width or --height")
      }
    }
    if let quality, !(1...100).contains(quality) {
      throw ValidationError("Quality must be between 1 and 100")
    }
    if keyframeInterval < 0 || !keyframeInterval.isFinite {
      throw ValidationError("--keyframe-interval must be a non-negative, finite number")
    }
    if let denoise, !(1...100).contains(denoise) {
      throw ValidationError("--denoise must be between 1 and 100")
    }
    if let motionBlur, !(1...100).contains(motionBlur) {
      throw ValidationError("--motion-blur must be between 1 and 100")
    }
    // `--fps` finiteness / range is validated by `VTFrameRateConverter.preflight` in
    // `run()`, alongside the source-vs-target check once the source track is loaded.
  }

  // MARK: Run

  func run() async throws {
    let asset = AVURLAsset(url: url)
    guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
      throw ValidationError("Failed to get video track from input file")
    }

    let formatDescription = try await videoTrack.load(.formatDescriptions).first
    let dimensions = formatDescription.map {
      CMVideoFormatDescriptionGetDimensions($0)
    }.map {
      CGSize(width: Int($0.width), height: Int($0.height))
    }
    let naturalSize = try await videoTrack.load(.naturalSize)
    let inputSize = dimensions ?? naturalSize

    guard inputSize.width > 0, inputSize.height > 0 else {
      throw ValidationError(
        "Invalid input video dimensions: \(Int(inputSize.width))x\(Int(inputSize.height)). "
          + "The video file may be corrupted."
      )
    }

    let wantsScaling = scale != nil || width != nil || height != nil
    let outputSize: CGSize =
      wantsScaling
      ? calculateOutputDimensions(
        inputSize: inputSize,
        requestedWidth: scale.map { Int(inputSize.width) * $0 } ?? width,
        requestedHeight: scale.map { Int(inputSize.height) * $0 } ?? height)
      : inputSize

    guard outputSize.width > 0, outputSize.height > 0 else {
      throw ValidationError("Computed output dimensions are invalid.")
    }

    guard Int(outputSize.width) <= UpscalingExportSession.maxOutputSize,
      Int(outputSize.height) <= UpscalingExportSession.maxOutputSize
    else {
      throw ValidationError(
        "Maximum supported width/height: \(UpscalingExportSession.maxOutputSize)")
    }

    if wantsScaling {
      try preflight { try scaler.preflight(inputSize: inputSize, outputSize: outputSize) }
    }

    if let denoise {
      try preflight {
        try VTTemporalNoiseProcessor.preflight(frameSize: inputSize, strength: denoise)
      }
    }

    if let motionBlur {
      try preflight {
        try VTMotionBlurProcessor.preflight(frameSize: outputSize, strength: motionBlur)
      }
    }

    if let fps {
      // `nominalFrameRate` is a Float; promote for the comparison so rounding doesn't pass
      // a marginally-higher target like 29.9999 as "greater than" a 30.0 source.
      let sourceFrameRate = try await Double(videoTrack.load(.nominalFrameRate))
      if sourceFrameRate > 0, fps <= sourceFrameRate {
        throw ValidationError(
          "--fps must be greater than the source frame rate "
            + "(source: \(String(format: "%.3f", sourceFrameRate)))."
        )
      }
      try preflight {
        try VTFrameRateConverter.preflight(frameSize: outputSize, targetFrameRate: fps)
      }
    }

    let outputCodec: AVVideoCodecType = codec.avCodec
    let normalizedQuality: Double? = quality.map { Double($0) / 100.0 }
    let outputURL = url.renamed { "\($0) Upscaled" }

    if FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) {
      if force {
        try FileManager.default.removeItem(at: outputURL)
      } else {
        throw ValidationError(
          "Output file already exists at \(outputURL.path(percentEncoded: false)). "
            + "Pass --force to overwrite.")
      }
    }

    let chainFactory: UpscalingExportSession.ChainFactory = {
      [scaler, denoise, fps, motionBlur, wantsScaling] inputSize in
      var stages: [any FrameProcessorBackend] = []
      if let denoise {
        stages.append(
          try await VTTemporalNoiseProcessor(frameSize: inputSize, strength: denoise))
      }
      if wantsScaling {
        stages.append(try await scaler.makeBackend(inputSize: inputSize, outputSize: outputSize))
      }
      if let fps {
        stages.append(
          try await VTFrameRateConverter(frameSize: outputSize, targetFrameRate: fps))
      }
      if let motionBlur {
        stages.append(
          try await VTMotionBlurProcessor(frameSize: outputSize, strength: motionBlur))
      }
      return try FrameProcessorChain(
        inputSize: inputSize, outputSize: outputSize, stages: stages)
    }

    let exportSession = UpscalingExportSession(
      asset: asset,
      outputCodec: outputCodec,
      preferredOutputURL: outputURL,
      outputSize: outputSize,
      quality: normalizedQuality,
      keyFrameInterval: keyframeInterval > 0 ? keyframeInterval : nil,
      creator: "fx-upscale",
      chainFactory: chainFactory
    )

    let qualityInfo = quality.map { ", quality: \($0)" } ?? ""
    let denoiseInfo = denoise.map { ", denoise: \($0)" } ?? ""
    let fpsInfo = fps.map { ", fps: \(String(format: "%g", $0))" } ?? ""
    let motionBlurInfo = motionBlur.map { ", motion-blur: \($0)" } ?? ""
    let summary: String =
      wantsScaling
      ? "Upscaling from \(Int(inputSize.width))x\(Int(inputSize.height)) "
        + "to \(Int(outputSize.width))x\(Int(outputSize.height)) "
        + "using \(scaler.displayName), codec: \(outputCodec.rawValue)\(qualityInfo)"
      : "Processing at \(Int(inputSize.width))x\(Int(inputSize.height)), "
        + "codec: \(outputCodec.rawValue)\(qualityInfo)"
    Terminal.info(summary + denoiseInfo + fpsInfo + motionBlurInfo)

    // Install SIGINT/SIGTERM handlers unconditionally so Ctrl-C during pipe/CI runs still
    // removes the partial output. The progress bar's TTY-only redraw loop is orthogonal.
    SignalHandlers.install { [outputURL] in
      try? FileManager.default.removeItem(at: outputURL)
    }
    defer { SignalHandlers.clearCleanup() }

    ProgressBar.start(progress: exportSession.progress)
    defer { ProgressBar.stop() }

    do {
      try await exportSession.export()
    } catch {
      ProgressBar.stop()
      try? FileManager.default.removeItem(at: outputURL)
      Terminal.error(error.localizedDescription)
      throw ExitCode.failure
    }
    Terminal.success("Video successfully upscaled!")
  }

  /// Runs a preflight check and rewraps any thrown error as a `ValidationError` so
  /// ArgumentParser surfaces it the same way it surfaces its own argument-level errors.
  private func preflight(_ check: () throws -> Void) throws {
    do { try check() } catch { throw ValidationError(error.localizedDescription) }
  }
}

// MARK: - UpscalerKind + ExpressibleByArgument

extension UpscalerKind: ExpressibleByArgument {}

// MARK: - Codec

extension FXUpscale {
  enum Codec: String, ExpressibleByArgument, CaseIterable {
    case h264
    case hevc

    var avCodec: AVVideoCodecType {
      switch self {
      case .h264: .h264
      case .hevc: .hevc
      }
    }
  }
}
