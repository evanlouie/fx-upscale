import AVFoundation
import ArgumentParser
import Foundation
import SwiftTUI
import Upscaling

// MARK: - MetalFXUpscale

@main struct FXUpscale: AsyncParsableCommand {
  @Argument(help: "The video file to upscale", transform: URL.init(fileURLWithPath:)) var url: URL

  @Option(name: .shortAndLong, help: "The output file width") var width: Int?
  @Option(name: .shortAndLong, help: "The output file height") var height: Int?
  @Option(name: .shortAndLong, help: "Output codec: 'hevc' or 'h264' (default: h264)")
  var codec: String = "h264"
  @Option(name: .shortAndLong, help: "Output quality: 1-100 (default: encoder default)")
  var quality: Int?

  mutating func run() async throws {
    guard ["mov", "m4v", "mp4"].contains(url.pathExtension.lowercased()) else {
      throw ValidationError("Unsupported file type. Supported types: mov, m4v, mp4")
    }

    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ValidationError("File does not exist at \(url.path(percentEncoded: false))")
    }

    if let quality, !(1...100).contains(quality) {
      throw ValidationError("Quality must be between 1 and 100")
    }

    let asset = AVAsset(url: url)
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
        "Invalid input video dimensions: \(Int(inputSize.width))x\(Int(inputSize.height)). The video file may be corrupted."
      )
    }

    // 1. Use passed in width/height
    // 2. Use proportional width/height if only one is specified
    // 3. Default to 2x upscale

    let width =
      width ?? height.map { Int(inputSize.width * (CGFloat($0) / inputSize.height)) } ?? Int(
        inputSize.width) * 2
    let height = height ?? Int(inputSize.height * (CGFloat(width) / inputSize.width))

    guard width > 0, height > 0 else {
      throw ValidationError("Width and height must be positive integers")
    }

    guard width <= UpscalingExportSession.maxOutputSize,
      height <= UpscalingExportSession.maxOutputSize
    else {
      throw ValidationError("Maximum supported width/height: 16384")
    }

    let outputSize = CGSize(width: width, height: height)
    let outputCodec: AVVideoCodecType? =
      switch codec.lowercased() {
      case "hevc": .hevc
      case "h264": .h264
      default:
        throw ValidationError("Invalid codec '\(codec)'. Supported codecs: hevc, h264")
      }

    let normalizedQuality: Double? = quality.map { Double($0) / 100.0 }

    let exportSession = UpscalingExportSession(
      asset: asset,
      outputCodec: outputCodec,
      preferredOutputURL: url.renamed { "\($0) Upscaled" },
      outputSize: outputSize,
      quality: normalizedQuality,
      creator: ProcessInfo.processInfo.processName
    )

    let qualityInfo = quality.map { ", quality: \($0)" } ?? ""
    CommandLine.info(
      [
        "Upscaling from \(Int(inputSize.width))x\(Int(inputSize.height)) ",
        "to \(Int(outputSize.width))x\(Int(outputSize.height)) ",
        "using codec: \(outputCodec?.rawValue ?? "hevc")\(qualityInfo)",
      ].joined())
    ProgressBar.start(progress: exportSession.progress)
    defer { ProgressBar.stop() }
    try await exportSession.export()
    CommandLine.success("Video successfully upscaled!")
  }
}
