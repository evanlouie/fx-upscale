import CoreGraphics

/// Calculates output dimensions for upscaling based on input size and optional requested dimensions.
/// - Parameters:
///   - inputSize: The original video dimensions
///   - requestedWidth: Optional user-requested width (if nil, calculated from height or defaults to 2x)
///   - requestedHeight: Optional user-requested height (if nil, calculated proportionally from width)
/// - Returns: The calculated output dimensions maintaining aspect ratio
public func calculateOutputDimensions(
  inputSize: CGSize,
  requestedWidth: Int?,
  requestedHeight: Int?
) -> CGSize {
  let width = requestedWidth
    ?? requestedHeight.map { Int(inputSize.width * (CGFloat($0) / inputSize.height)) }
    ?? Int(inputSize.width) * 2
  let height = requestedHeight ?? Int(inputSize.height * (CGFloat(width) / inputSize.width))
  return CGSize(width: width, height: height)
}
