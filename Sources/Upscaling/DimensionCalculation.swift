import CoreGraphics
import Foundation

/// Namespace for output-dimension calculation.
public enum DimensionCalculation {
  /// Errors thrown by `calculateOutputDimensions` when its inputs are invalid.
  public enum Error: Swift.Error, LocalizedError {
    /// The input video size was non-positive.
    case invalidInputSize(CGSize)
    /// A user-requested width or height was non-positive.
    case invalidRequestedDimension(name: String, value: Int)

    public var errorDescription: String? {
      switch self {
      case let .invalidInputSize(size):
        return
          "Invalid input video dimensions: \(Int(size.width))x\(Int(size.height)). "
          + "Width and height must both be positive."
      case let .invalidRequestedDimension(name, value):
        return "--\(name) must be a positive integer (got \(value))."
      }
    }
  }

  /// Calculates output dimensions for upscaling based on input size and optional requested
  /// dimensions.
  ///
  /// Output dimensions are rounded (not truncated) and always rounded up to the nearest even
  /// integer to remain compatible with H.264 / HEVC encoders, which require even width and
  /// height.
  ///
  /// - Parameters:
  ///   - inputSize: The original video dimensions. Width and height must both be positive.
  ///   - requestedWidth: Optional user-requested width. If `nil`, derived from
  ///     `requestedHeight` preserving aspect ratio, or defaults to 2× the input width. Must be
  ///     positive when supplied.
  ///   - requestedHeight: Optional user-requested height. If `nil`, derived from the computed
  ///     width preserving aspect ratio. Must be positive when supplied.
  /// - Returns: Even, positive output dimensions. If both `requestedWidth` and
  ///   `requestedHeight` are supplied, the requested values are used verbatim (after
  ///   even-rounding) and the input aspect ratio is not preserved.
  /// - Throws: ``Error`` if `inputSize` is non-positive or a requested dimension is
  ///   non-positive.
  public static func calculateOutputDimensions(
    inputSize: CGSize,
    requestedWidth: Int?,
    requestedHeight: Int?
  ) throws -> CGSize {
    guard inputSize.width > 0, inputSize.height > 0 else {
      throw Error.invalidInputSize(inputSize)
    }
    if let requestedWidth, requestedWidth <= 0 {
      throw Error.invalidRequestedDimension(name: "width", value: requestedWidth)
    }
    if let requestedHeight, requestedHeight <= 0 {
      throw Error.invalidRequestedDimension(name: "height", value: requestedHeight)
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
}

private func evenCeil(_ value: Int) -> Int {
  precondition(value > 0, "evenCeil requires a positive input")
  return value + (value & 1)
}
