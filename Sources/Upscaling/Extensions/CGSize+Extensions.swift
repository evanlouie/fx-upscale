import CoreGraphics

extension CGSize {
  /// Width and height rounded to the nearest integer (banker's rounding via the default
  /// `FloatingPointRoundingRule`), for APIs that take `Int` dimensions (MetalFX, VT, CI).
  /// Sites that need a different rounding mode (e.g. `.up` for stride-alignment) should
  /// spell the rounding out explicitly instead of using this accessor.
  var intDimensions: (width: Int, height: Int) {
    (Int(width.rounded()), Int(height.rounded()))
  }
}
