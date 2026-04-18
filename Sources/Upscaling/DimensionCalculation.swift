import CoreGraphics

/// Calculates output dimensions for upscaling based on input size and optional requested
/// dimensions.
///
/// Output dimensions are rounded (not truncated) and always rounded up to the nearest even
/// integer to remain compatible with H.264 / HEVC encoders, which require even width and height.
///
/// - Parameters:
///   - inputSize: The original video dimensions. Width and height must both be positive.
///   - requestedWidth: Optional user-requested width. If `nil`, derived from `requestedHeight`
///     preserving aspect ratio, or defaults to 2× the input width. Must be positive when
///     supplied.
///   - requestedHeight: Optional user-requested height. If `nil`, derived from the computed
///     width preserving aspect ratio. Must be positive when supplied.
/// - Returns: Even, positive output dimensions. If both `requestedWidth` and `requestedHeight`
///   are supplied, the requested values are used verbatim (after even-rounding) and the input
///   aspect ratio is not preserved.
public func calculateOutputDimensions(
  inputSize: CGSize,
  requestedWidth: Int?,
  requestedHeight: Int?
) -> CGSize {
  precondition(
    inputSize.width > 0 && inputSize.height > 0,
    "inputSize must have positive width and height")
  if let requestedWidth {
    precondition(requestedWidth > 0, "requestedWidth must be positive")
  }
  if let requestedHeight {
    precondition(requestedHeight > 0, "requestedHeight must be positive")
  }

  let aspect: Double = Double(inputSize.width) / Double(inputSize.height)

  let baseWidth: Int =
    requestedWidth
    ?? requestedHeight.map { Int((Double($0) * aspect).rounded()) }
    ?? Int(inputSize.width) * 2
  let baseHeight: Int =
    requestedHeight
    ?? Int((Double(baseWidth) / aspect).rounded())

  return CGSize(width: evenCeil(baseWidth), height: evenCeil(baseHeight))
}

private func evenCeil(_ value: Int) -> Int {
  precondition(value > 0, "evenCeil requires a positive input")
  return value + (value & 1)
}
