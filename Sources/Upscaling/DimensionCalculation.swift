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
    try validateRequestedDimensions(width: requestedWidth, height: requestedHeight)
    return deriveDimensions(
      reference: inputSize,
      requestedWidth: requestedWidth,
      requestedHeight: requestedHeight,
      defaultWidth: Int(inputSize.width) * 2,
      clampToReference: false)
  }

  /// Calculates the *final encoded* output size from a scaler-stage output size and optional
  /// requested dimensions.
  ///
  /// This is the downsample companion to ``calculateOutputDimensions(inputSize:requestedWidth:requestedHeight:)``:
  ///
  /// - ``calculateOutputDimensions`` computes the scaler-stage output from the source, doubling
  ///   by default.
  /// - ``calculateFinalOutputDimensions`` computes the *final* encoded size relative to the
  ///   scaler output, defaulting to the scaler output itself (pass-through, no terminal
  ///   downsample).
  ///
  /// The result is always ≤ `scalerOutputSize` on both axes, even after even-rounding. A
  /// Lanczos stage appended when `result != scalerOutputSize` downsample-converts scaler
  /// output to this size.
  ///
  /// - Parameters:
  ///   - scalerOutputSize: Size produced by the upstream scaler (or the source size if no
  ///     scaler stage is active). Must be positive on both axes.
  ///   - requestedWidth: Optional user-requested final width. If `nil`, derived from
  ///     `requestedHeight` preserving `scalerOutputSize`'s aspect, or defaults to
  ///     `scalerOutputSize.width`.
  ///   - requestedHeight: Optional user-requested final height. If `nil`, derived from the
  ///     computed width preserving `scalerOutputSize`'s aspect.
  /// - Returns: Even, positive final dimensions, clamped to `scalerOutputSize` on both axes.
  /// - Throws: ``Error`` if `scalerOutputSize` is non-positive or a requested dimension is
  ///   non-positive.
  public static func calculateFinalOutputDimensions(
    scalerOutputSize: CGSize,
    requestedWidth: Int?,
    requestedHeight: Int?
  ) throws -> CGSize {
    guard scalerOutputSize.width > 0, scalerOutputSize.height > 0 else {
      throw Error.invalidInputSize(scalerOutputSize)
    }
    try validateRequestedDimensions(width: requestedWidth, height: requestedHeight)
    return deriveDimensions(
      reference: scalerOutputSize,
      requestedWidth: requestedWidth,
      requestedHeight: requestedHeight,
      defaultWidth: Int(scalerOutputSize.width),
      clampToReference: true)
  }

  private static func validateRequestedDimensions(width: Int?, height: Int?) throws {
    if let width, width <= 0 {
      throw Error.invalidRequestedDimension(name: "width", value: width)
    }
    if let height, height <= 0 {
      throw Error.invalidRequestedDimension(name: "height", value: height)
    }
  }

  private static func deriveDimensions(
    reference: CGSize,
    requestedWidth: Int?,
    requestedHeight: Int?,
    defaultWidth: Int,
    clampToReference: Bool
  ) -> CGSize {
    let aspect = Double(reference.width) / Double(reference.height)
    let baseWidth =
      requestedWidth
      ?? requestedHeight.map { Int((Double($0) * aspect).rounded()) }
      ?? defaultWidth
    let baseHeight = requestedHeight ?? Int((Double(baseWidth) / aspect).rounded())

    let evenWidth = evenCeil(baseWidth)
    let evenHeight = evenCeil(baseHeight)
    if clampToReference {
      return CGSize(
        width: min(evenWidth, Int(reference.width)),
        height: min(evenHeight, Int(reference.height)))
    }
    return CGSize(width: evenWidth, height: evenHeight)
  }
}

/// Rounds a positive integer up to the nearest even integer.
///
/// Public so the CLI (a separate target) can share this with `DimensionCalculation` when
/// deriving scaler-stage sizes from `--scale`.
public func evenCeil(_ value: Int) -> Int {
  precondition(value > 0, "evenCeil requires a positive input")
  return value + (value & 1)
}
