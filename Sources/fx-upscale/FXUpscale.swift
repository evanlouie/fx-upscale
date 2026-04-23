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
      --scale controls the scaler stage (how much MetalFX / VT super-resolution magnifies). \
      --width / --height control the final encoded resolution. Pass together to supersample \
      (upscale then Lanczos-downsample back down). Pass --width / --height alone to \
      downsample only. Pass --scale alone for a pure upscale. Pass none for an identity \
      re-encode.

      Supersampled downscaling — --scale N with a smaller --width / --height — renders at \
      the higher resolution first, then Lanczos-downsamples. Detail retained at the final \
      size exceeds what a direct encode of the source would preserve.

      Dimensions are rounded up to the nearest even integer (required by H.264 / HEVC). \
      --width / --height larger than the source require --scale — they cannot upscale on \
      their own.

      Effects (--denoise, --fps, --motion-blur) run between the scaler and any terminal \
      downsample, so their input caps (8192×4320 for --fps and --motion-blur) apply at the \
      scaler output size, not the final encoded size.

      HDR / Rec. 2020 inputs require `--scaler super-resolution` (without `--width` / \
      `--height`) so the chain can round-trip 10-bit 420 YUV end-to-end. The spatial path \
      remains 8-bit sRGB-only; other chains that mix sRGB-only stages (Lanczos, denoise, \
      motion blur, frame-rate conversion) also reject HDR for now.

      Two upscaling algorithms are available via --scaler:
        spatial (default)   MTLFXSpatialScaler — fast, arbitrary ratios.
        super-resolution    VTFrameProcessor ML-based super resolution — higher quality for \
                            recorded video, but requires an integer scale factor, caps input \
                            at 1920×1080 on macOS, and may download an ML model on first use.
      """,
    version: "1.3.0"
  )

  // MARK: Arguments

  @Argument(help: "The video file to upscale", transform: URL.init(fileURLWithPath:)) var url: URL

  @Option(
    name: .shortAndLong,
    help: ArgumentHelp(
      "Final encoded width.",
      discussion:
        "Sets the final encoded resolution, not the scaler output. Alone, can only "
        + "downsample — use --scale to enable upscaling. Combined with --scale, enables "
        + "supersampled downscaling."
    )
  )
  var width: Int?

  // Use a custom short name to avoid colliding with ArgumentParser's built-in `-h` for `--help`.
  @Option(
    name: [.customShort("H"), .long],
    help: ArgumentHelp(
      "Final encoded height.",
      discussion:
        "Sets the final encoded resolution, not the scaler output. Alone, can only "
        + "downsample — use --scale to enable upscaling. Combined with --scale, enables "
        + "supersampled downscaling."
    )
  )
  var height: Int?

  @Option(
    name: [.customShort("x"), .long],
    help: ArgumentHelp(
      "Uniform integer scale factor applied by the scaler stage (e.g. 2 for 2×).",
      discussion:
        "Separate from --width / --height, which set the final encoded resolution. "
        + "Combined use enables supersampled downscaling: --scale 2 --height 1080 on a "
        + "1080p source renders at 2160p, then Lanczos-downsamples to 1080p."
    )
  )
  var scale: Int?

  @Option(
    name: .shortAndLong,
    help: "Output codec (\(Codec.helpList))"
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
      "Upscaling algorithm (\(UpscalerKind.helpList), default: spatial)",
      discussion:
        "Only meaningful with --scale. 'spatial' uses MTLFXSpatialScaler (fast, arbitrary "
        + "ratios). 'super-resolution' uses VTFrameProcessor's ML-based super resolution — "
        + "higher quality on recorded video, but integer scale factor only, input capped "
        + "at 1920×1080, and a one-time model download on first use."
    )
  )
  var scaler: UpscalerKind?

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
        "Runs VTFrameProcessor's ML-based motion-blur synthesis on the scaler output. "
        + "50 matches a standard 180° film shutter; 1 is subtle, 100 is pronounced. "
        + "Input must be ≤ 8192×4320 at the scaler output size (before any terminal "
        + "downsample)."
    )
  )
  var motionBlur: Int?

  @Option(
    name: .long,
    help: ArgumentHelp(
      "Target output frame rate (omit to preserve source rate).",
      discussion:
        "Runs VTFrameProcessor's ML-based frame-rate conversion on the scaler output. "
        + "Must be greater than the source's frame rate — this flag only upsamples; "
        + "downsampling is not supported. Output duration stays the same; only the "
        + "cadence changes. Input must be ≤ 8192×4320 at the scaler output size (before "
        + "any terminal downsample)."
    )
  )
  var fps: Double?

  // MARK: Derived paths

  /// Single source of truth for the output path — a pure transform of `url`. Shared by
  /// `validate()` (pre-existing-file check) and `run()` (write destination).
  private var outputURL: URL { url.renamed { "\($0) Upscaled" } }

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
    if let scale, scale < 2 {
      throw ValidationError("--scale must be an integer ≥ 2")
    }
    if scaler != nil, scale == nil {
      throw ValidationError(
        "--scaler \(scaler!.rawValue) selects a scaling algorithm, but no scaling was requested.\n"
          + "Pass --scale N to enable the scaler, or drop --scaler to do a pure downsample.")
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

    // Fail fast on a pre-existing output file — the output path is a pure transform of
    // the input URL and CLI flags, so we can compute it here without loading the asset.
    // This avoids running the (potentially slow) preflight and model download before
    // discovering the output would be rejected anyway.
    if FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)), !force {
      throw ValidationError(
        "Output file already exists at \(outputURL.path(percentEncoded: false)). "
          + "Pass --force to overwrite.")
    }
  }

  // MARK: Run

  /// Exit codes:
  /// - `0` on success.
  /// - `1` (`ExitCode.failure`) on runtime export errors — see the `catch` around
  ///   `exportSession.export()`.
  /// - `2` (`ExitCode.validationFailure`) on `ValidationError`s from `validate()` or the
  ///   `--fps` source-rate check. ArgumentParser applies this exit code automatically.
  /// - `3` on preflight failures (device/config incompatibility surfaced before any I/O),
  ///   routed through the `preflight(_:)` helper below.
  func run() async throws {
    let asset = AVURLAsset(url: url)
    guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
      throw ValidationError("Failed to get video track from input file")
    }

    let formatDescription = try await videoTrack.load(.formatDescriptions).first
    let dimensions = formatDescription.map {
      CMVideoFormatDescriptionGetDimensions($0).cgSize
    }
    let naturalSize = try await videoTrack.load(.naturalSize)
    let inputSize = dimensions ?? naturalSize

    guard inputSize.width > 0, inputSize.height > 0 else {
      throw ValidationError(
        "Invalid input video dimensions: \(Int(inputSize.width))x\(Int(inputSize.height)). "
          + "The video file may be corrupted."
      )
    }

    let effectiveScaler: UpscalerKind = scaler ?? .spatial

    let scalerOutputSize: CGSize =
      if let scale {
        CGSize(
          width: evenCeil(Int(inputSize.width) * scale),
          height: evenCeil(Int(inputSize.height) * scale))
      } else {
        inputSize
      }

    // Reject requests that would silently clamp inside `calculateFinalOutputDimensions`:
    // without `--scale`, a request > source is an implicit-upscale attempt; with `--scale`, a
    // request > scaler output asks the downsample-only Lanczos stage to upscale.
    if scale == nil {
      let rejectImplicitUpscale = { (axis: String, requested: Int?, sourceDim: Int) throws in
        guard let requested, requested > sourceDim else { return }
        throw ValidationError(
          "--\(axis) \(requested) exceeds the source "
            + "(\(Int(inputSize.width))x\(Int(inputSize.height))), but no scaler was selected.\n"
            + "Pass --scale N (e.g. --scale 2) to enable the scaler stage.\n"
            + "--width/--height alone can only downsample.")
      }
      try rejectImplicitUpscale("width", width, Int(inputSize.width))
      try rejectImplicitUpscale("height", height, Int(inputSize.height))
    } else if let scale {
      let widthExceeds = (width ?? 0) > Int(scalerOutputSize.width)
      let heightExceeds = (height ?? 0) > Int(scalerOutputSize.height)
      if widthExceeds || heightExceeds {
        let axes: String =
          switch (widthExceeds, heightExceeds) {
          case (true, true): "both"
          case (true, false): "width"
          case (false, true): "height"
          case (false, false): ""
          }
        let requestedWidth = width ?? Int(scalerOutputSize.width)
        let requestedHeight = height ?? Int(scalerOutputSize.height)
        let ratio = max(
          Double(requestedWidth) / Double(inputSize.width),
          Double(requestedHeight) / Double(inputSize.height))
        let nextScale = Int(ratio.rounded(.up))
        throw ValidationError(
          "--width/--height (\(requestedWidth)x\(requestedHeight)) exceeds the scaler output "
            + "(\(Int(scalerOutputSize.width))x\(Int(scalerOutputSize.height)) at --scale \(scale)).\n"
            + "The Lanczos stage only downsamples.\n"
            + "  • Axis(es) exceeded: \(axes)\n"
            + "  • Tip: --scale \(nextScale) would produce the scaler output "
            + "(\(nextScale * Int(inputSize.width))x\(nextScale * Int(inputSize.height))).\n"
            + "Lower --width/--height to fit within the scaler output, or raise --scale.")
      }
    }

    let finalOutputSize: CGSize
    do {
      finalOutputSize = try DimensionCalculation.calculateFinalOutputDimensions(
        scalerOutputSize: scalerOutputSize,
        requestedWidth: width,
        requestedHeight: height)
    } catch {
      throw ValidationError(error.localizedDescription)
    }

    guard finalOutputSize.width > 0, finalOutputSize.height > 0,
      scalerOutputSize.width > 0, scalerOutputSize.height > 0
    else {
      throw ValidationError("Computed output dimensions are invalid.")
    }

    guard Int(scalerOutputSize.width) <= UpscalingExportSession.maxOutputSize,
      Int(scalerOutputSize.height) <= UpscalingExportSession.maxOutputSize,
      Int(finalOutputSize.width) <= UpscalingExportSession.maxOutputSize,
      Int(finalOutputSize.height) <= UpscalingExportSession.maxOutputSize
    else {
      throw ValidationError(
        "Maximum supported width/height: \(UpscalingExportSession.maxOutputSize)")
    }

    if scale != nil {
      try preflight {
        try effectiveScaler.preflight(inputSize: inputSize, outputSize: scalerOutputSize)
      }
    }

    if let denoise {
      try preflight {
        try VTTemporalNoiseProcessor.preflight(frameSize: inputSize, strength: denoise)
      }
    }

    if let motionBlur {
      try preflight {
        try VTMotionBlurProcessor.preflight(frameSize: scalerOutputSize, strength: motionBlur)
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
        try VTFrameRateConverter.preflight(frameSize: scalerOutputSize, targetFrameRate: fps)
      }
    }

    let needsDownsample = finalOutputSize != scalerOutputSize
    if needsDownsample {
      try preflight {
        try CILanczosDownsampler.preflight(
          inputSize: scalerOutputSize, outputSize: finalOutputSize)
      }
    }

    let outputCodec: AVVideoCodecType = codec.avCodec
    let normalizedQuality: Double? = quality.map { Double($0) / 100.0 }

    if formatDescription?.isHDR == true, codec == .h264 {
      throw ValidationError(
        "HDR sources require `--codec hevc` to preserve HDR metadata; H.264 cannot carry "
          + "it cleanly. Omit `--codec` to preserve the source codec, or pass `--codec hevc`.")
    }
    if formatDescription?.hasDolbyVision == true {
      Terminal.warning(
        "Source carries Dolby Vision metadata. This tool preserves HDR10 static metadata "
          + "(ST 2086 + MaxCLL/MaxFALL) but not Dolby Vision RPU side-data — the output "
          + "will play as HDR10.")
    }

    // `validate()` already rejected a pre-existing output unless --force was given.
    // In the --force case, remove the stale file now that we're committed to running.
    // `try?` both swallows a benign "file not found" (avoiding the TOCTOU existence check)
    // and any other removal failure — the asset writer will surface a clear error shortly
    // if the path is actually unusable.
    if force {
      try? FileManager.default.removeItem(at: outputURL)
    }

    let metricsCollector = PipelineMetricsCollector()

    let wantsScaler = scale != nil

    // First sRGB-only stage in the pipeline, if any. Derived from the CLI flags rather than
    // by inspecting a constructed chain so the session can consult it before any ML model
    // downloads. A non-nil value means the chain can't accept HDR / 10-bit input.
    let srgbOnlyStageName: String? = {
      if needsDownsample { return CILanczosDownsampler.displayName }
      if denoise != nil { return VTTemporalNoiseProcessor.displayName }
      if motionBlur != nil { return VTMotionBlurProcessor.displayName }
      if fps != nil { return VTFrameRateConverter.displayName }
      if wantsScaler, effectiveScaler == .spatial { return Upscaler.displayName }
      return nil
    }()
    let chainIsHDRCapable =
      wantsScaler && effectiveScaler == .superResolution && srgbOnlyStageName == nil

    let chainFactory: UpscalingExportSession.ChainFactory = {
      [
        effectiveScaler, wantsScaler, denoise, fps, motionBlur,
        scalerOutputSize, finalOutputSize, needsDownsample, chainIsHDRCapable,
        metricsCollector
      ] inputSize in
      var stages: [any FrameProcessorBackend] = []
      if let denoise {
        stages.append(
          try await VTTemporalNoiseProcessor(frameSize: inputSize, strength: denoise))
      }
      if wantsScaler {
        if effectiveScaler == .superResolution, chainIsHDRCapable {
          stages.append(
            try await VTSuperResolutionUpscaler(
              inputSize: inputSize, outputSize: scalerOutputSize,
              pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange))
        } else {
          stages.append(
            try await effectiveScaler.makeBackend(
              inputSize: inputSize, outputSize: scalerOutputSize))
        }
      }
      if let fps {
        stages.append(
          try await VTFrameRateConverter(frameSize: scalerOutputSize, targetFrameRate: fps))
      }
      if let motionBlur {
        stages.append(
          try await VTMotionBlurProcessor(frameSize: scalerOutputSize, strength: motionBlur))
      }
      if needsDownsample {
        stages.append(
          try CILanczosDownsampler(
            inputSize: scalerOutputSize, outputSize: finalOutputSize))
      }
      return try FrameProcessorChain(
        inputSize: inputSize, outputSize: finalOutputSize, stages: stages,
        metricsCollector: metricsCollector)
    }

    let chainCapabilities: UpscalingExportSession.ChainCapabilities =
      chainIsHDRCapable
        ? UpscalingExportSession.ChainCapabilities(
            supportedSourceInputFormats: [
              kCVPixelFormatType_32BGRA,
              kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            ],
            producedOutputFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        : UpscalingExportSession.ChainCapabilities(
            supportedSourceInputFormats: [kCVPixelFormatType_32BGRA],
            producedOutputFormat: kCVPixelFormatType_32BGRA,
            srgbRejectingStageName: srgbOnlyStageName)

    let exportSession = UpscalingExportSession(
      asset: asset,
      outputCodec: outputCodec,
      preferredOutputURL: outputURL,
      outputSize: finalOutputSize,
      quality: normalizedQuality,
      keyFrameInterval: keyframeInterval > 0 ? keyframeInterval : nil,
      creator: "fx-upscale",
      chainFactory: chainFactory,
      chainCapabilities: chainCapabilities
    )

    let qualityInfo = quality.map { ", quality: \($0)" } ?? ""
    let denoiseInfo = denoise.map { ", denoise: \($0)" } ?? ""
    let fpsInfo = fps.map { ", fps: \(String(format: "%g", $0))" } ?? ""
    let motionBlurInfo = motionBlur.map { ", motion-blur: \($0)" } ?? ""
    let source = "\(Int(inputSize.width))x\(Int(inputSize.height))"
    let scalerOut = "\(Int(scalerOutputSize.width))x\(Int(scalerOutputSize.height))"
    let final = "\(Int(finalOutputSize.width))x\(Int(finalOutputSize.height))"
    let summary: String
    switch (wantsScaler, needsDownsample) {
    case (false, false):
      summary =
        "Processing at \(source), codec: \(outputCodec.rawValue)\(qualityInfo)"
    case (true, false):
      summary =
        "Upscaling from \(source) to \(scalerOut) using \(effectiveScaler.displayName), "
        + "codec: \(outputCodec.rawValue)\(qualityInfo)"
    case (false, true):
      summary =
        "Downsampling from \(source) to \(final), codec: \(outputCodec.rawValue)\(qualityInfo)"
    case (true, true):
      summary =
        "Upscaling from \(source) to \(scalerOut) using \(effectiveScaler.displayName), "
        + "then downsampling to \(final), codec: \(outputCodec.rawValue)\(qualityInfo)"
    }
    Terminal.info(summary + denoiseInfo + fpsInfo + motionBlurInfo)

    // Install SIGINT/SIGTERM handlers unconditionally so Ctrl-C during pipe/CI runs still
    // removes the partial output. The progress bar's TTY-only redraw loop is orthogonal.
    SignalHandlers.install { [outputURL] in
      try? FileManager.default.removeItem(at: outputURL)
    }

    ProgressBar.start(progress: exportSession.progress, metricsCollector: metricsCollector)
    defer { ProgressBar.stop() }

    do {
      try await exportSession.export()
      // Disarm the cleanup closure BEFORE we acknowledge success (or let the deferred
      // `ProgressBar.stop()` run). A `defer` here would fire after `Terminal.success`,
      // leaving a window in which a SIGINT would delete the very file we just announced
      // we wrote.
      SignalHandlers.clearCleanup()
    } catch {
      // Tear down the progress block immediately so the red error line on stderr doesn't
      // interleave with the still-visible bar on a TTY. The deferred `ProgressBar.stop()`
      // above still runs, but `stop()` is idempotent.
      ProgressBar.stop()
      try? FileManager.default.removeItem(at: outputURL)
      Terminal.error(error.localizedDescription)
      throw ExitCode.failure
    }
    Terminal.success("Wrote \(outputURL.path(percentEncoded: false))")
    Terminal.metricsSummary(metricsCollector.snapshot())
  }

  /// Runs a preflight check and, on failure, prints the error and exits with code 3 so
  /// preflight failures are distinguishable from both validation errors (exit 2) and
  /// mid-export runtime failures (exit 1). Preflight errors are not usage errors, so we
  /// don't wrap them as `ValidationError` (which would trigger ArgumentParser to print
  /// command usage alongside the message).
  private func preflight(_ check: () throws -> Void) throws {
    do { try check() } catch {
      Terminal.error(error.localizedDescription)
      throw ExitCode(rawValue: 3)
    }
  }
}

// MARK: - CLI argument helpers

/// Pipe-separated rendering of a string-backed enum's cases, used for dynamic
/// `ArgumentHelp` strings (e.g. "h264 | hevc").
protocol ArgumentHelpListing: CaseIterable, RawRepresentable where RawValue == String {}

extension ArgumentHelpListing {
  static var helpList: String { allCases.map(\.rawValue).joined(separator: " | ") }
}

// MARK: - UpscalerKind + ExpressibleByArgument

extension UpscalerKind: ExpressibleByArgument, ArgumentHelpListing {}

// MARK: - Codec

extension FXUpscale {
  enum Codec: String, ExpressibleByArgument, CaseIterable, ArgumentHelpListing {
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
