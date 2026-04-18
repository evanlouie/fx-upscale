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
      By default the video is upscaled by 2×. Pass --scale for a uniform integer factor \
      (e.g. --scale 4 for 4× on both axes), or --width and/or --height for explicit dimensions \
      — --scale cannot be combined with --width or --height. When only one of --width / \
      --height is supplied, the other is computed from the source aspect ratio. Output \
      dimensions are rounded up to the nearest even integer (required by H.264 / HEVC).

      HDR (PQ / HLG) and Rec. 2020 wide-gamut inputs are rejected because the 8-bit BGRA \
      path would silently clip or shift those values.

      Two upscaling algorithms are available via --scaler:
        spatial (default)   MTLFXSpatialScaler — fast, arbitrary ratios.
        super-resolution    VTFrameProcessor ML-based super resolution — higher quality for \
                            recorded video, but requires an integer scale factor, caps input \
                            at 1920×1080 on macOS, and may download an ML model on first use.
      """,
    version: "1.1.0"
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

    let outputSize = calculateOutputDimensions(
      inputSize: inputSize,
      requestedWidth: scale.map { Int(inputSize.width) * $0 } ?? width,
      requestedHeight: scale.map { Int(inputSize.height) * $0 } ?? height
    )

    guard outputSize.width > 0, outputSize.height > 0 else {
      throw ValidationError("Computed output dimensions are invalid.")
    }

    guard Int(outputSize.width) <= UpscalingExportSession.maxOutputSize,
      Int(outputSize.height) <= UpscalingExportSession.maxOutputSize
    else {
      throw ValidationError(
        "Maximum supported width/height: \(UpscalingExportSession.maxOutputSize)")
    }

    do {
      try scaler.preflight(inputSize: inputSize, outputSize: outputSize)
    } catch {
      throw ValidationError(error.localizedDescription)
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

    let exportSession = UpscalingExportSession(
      asset: asset,
      outputCodec: outputCodec,
      preferredOutputURL: outputURL,
      outputSize: outputSize,
      quality: normalizedQuality,
      keyFrameInterval: keyframeInterval > 0 ? keyframeInterval : nil,
      creator: "fx-upscale",
      upscaler: scaler
    )

    let qualityInfo = quality.map { ", quality: \($0)" } ?? ""
    Terminal.info(
      "Upscaling from \(Int(inputSize.width))x\(Int(inputSize.height)) "
        + "to \(Int(outputSize.width))x\(Int(outputSize.height)) "
        + "using \(scaler.displayName), codec: \(outputCodec.rawValue)\(qualityInfo)"
    )

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
