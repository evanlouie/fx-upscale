import CoreGraphics

/// Calculates output dimensions for upscaling based on input size and optional requested
/// dimensions.
///
/// Output dimensions are rounded (not truncated) and always rounded up to the nearest even integer
/// to remain compatible with H.264/HEVC encoders, which require even width and height.
///
/// - Parameters:
///   - inputSize: The original video dimensions.
///   - requestedWidth: Optional user-requested width. If `nil`, derived from `requestedHeight`
///     preserving aspect ratio, or defaults to 2× the input width.
///   - requestedHeight: Optional user-requested height. If `nil`, derived from the computed
///     width preserving aspect ratio.
/// - Returns: Even, positive output dimensions maintaining the input aspect ratio.
public func calculateOutputDimensions(
  inputSize: CGSize,
  requestedWidth: Int?,
  requestedHeight: Int?
) -> CGSize {
  let aspect: Double =
    (inputSize.height > 0) ? Double(inputSize.width) / Double(inputSize.height) : 1

  let baseWidth: Int =
    requestedWidth
    ?? requestedHeight.map { Int((Double($0) * aspect).rounded()) }
    ?? Int(inputSize.width) * 2
  let baseHeight: Int =
    requestedHeight
    ?? (aspect > 0 ? Int((Double(baseWidth) / aspect).rounded()) : Int(inputSize.height) * 2)

  // Enforce even dimensions (required by most video codecs).
  let width = evenCeil(baseWidth)
  let height = evenCeil(baseHeight)
  return CGSize(width: width, height: height)
}

private func evenCeil(_ value: Int) -> Int {
  guard value > 0 else { return 0 }
  return value + (value & 1)
}
