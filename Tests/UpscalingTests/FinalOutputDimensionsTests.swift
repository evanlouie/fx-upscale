import CoreGraphics
import Foundation
import Testing

@testable import Upscaling

@Suite("Final Output Dimensions")
struct FinalOutputDimensionsTests {
  @Test("Both nil returns scalerOutputSize verbatim")
  func bothNilReturnsScaler() throws {
    let scaler = CGSize(width: 3840, height: 2160)
    let out = try DimensionCalculation.calculateFinalOutputDimensions(
      scalerOutputSize: scaler, requestedWidth: nil, requestedHeight: nil)
    #expect(out == scaler)
  }

  @Test("Width-only derives height from scalerOutputSize's aspect")
  func widthOnlyDerivesHeight() throws {
    let scaler = CGSize(width: 3840, height: 2160)
    let out = try DimensionCalculation.calculateFinalOutputDimensions(
      scalerOutputSize: scaler, requestedWidth: 1920, requestedHeight: nil)
    #expect(out == CGSize(width: 1920, height: 1080))
  }

  @Test("Height-only derives width from scalerOutputSize's aspect")
  func heightOnlyDerivesWidth() throws {
    let scaler = CGSize(width: 3840, height: 2160)
    let out = try DimensionCalculation.calculateFinalOutputDimensions(
      scalerOutputSize: scaler, requestedWidth: nil, requestedHeight: 1080)
    #expect(out == CGSize(width: 1920, height: 1080))
  }

  @Test("Derived zero axes are clamped before even-rounding")
  func derivedZeroAxesAreClamped() throws {
    let wide = try DimensionCalculation.calculateFinalOutputDimensions(
      scalerOutputSize: CGSize(width: 3840, height: 1606),
      requestedWidth: 1, requestedHeight: nil)
    #expect(wide == CGSize(width: 2, height: 2))

    let tall = try DimensionCalculation.calculateFinalOutputDimensions(
      scalerOutputSize: CGSize(width: 1080, height: 2400),
      requestedWidth: nil, requestedHeight: 1)
    #expect(tall == CGSize(width: 2, height: 2))
  }

  @Test("Both given are honored verbatim after even-rounding")
  func bothGivenHonored() throws {
    let scaler = CGSize(width: 3840, height: 2160)
    let out = try DimensionCalculation.calculateFinalOutputDimensions(
      scalerOutputSize: scaler, requestedWidth: 1280, requestedHeight: 720)
    #expect(out == CGSize(width: 1280, height: 720))
  }

  @Test("Non-positive requested width throws")
  func nonPositiveWidthThrows() {
    #expect(throws: DimensionCalculation.Error.self) {
      _ = try DimensionCalculation.calculateFinalOutputDimensions(
        scalerOutputSize: CGSize(width: 3840, height: 2160),
        requestedWidth: 0, requestedHeight: nil)
    }
  }

  @Test("Non-positive requested height throws")
  func nonPositiveHeightThrows() {
    #expect(throws: DimensionCalculation.Error.self) {
      _ = try DimensionCalculation.calculateFinalOutputDimensions(
        scalerOutputSize: CGSize(width: 3840, height: 2160),
        requestedWidth: nil, requestedHeight: -1)
    }
  }

  @Test("Non-positive scalerOutputSize throws")
  func invalidScalerSizeThrows() {
    #expect(throws: DimensionCalculation.Error.self) {
      _ = try DimensionCalculation.calculateFinalOutputDimensions(
        scalerOutputSize: CGSize(width: 0, height: 0),
        requestedWidth: nil, requestedHeight: nil)
    }
  }

  @Test("Odd scalerOutputSize with both-nil returns even dimensions")
  func oddScalerBothNil() throws {
    let scaler = CGSize(width: 3841, height: 2161)
    let out = try DimensionCalculation.calculateFinalOutputDimensions(
      scalerOutputSize: scaler, requestedWidth: nil, requestedHeight: nil)
    #expect(out.width == 3840)
    #expect(out.height == 2160)
    #expect(Int(out.width).isMultiple(of: 2))
    #expect(Int(out.height).isMultiple(of: 2))
    #expect(out.width <= scaler.width)
    #expect(out.height <= scaler.height)
  }

  @Test("Clamps result to scalerOutputSize on the width axis")
  func clampsWidth() throws {
    let scaler = CGSize(width: 1920, height: 1080)
    let out = try DimensionCalculation.calculateFinalOutputDimensions(
      scalerOutputSize: scaler, requestedWidth: 1920, requestedHeight: nil)
    #expect(out.width == 1920)
    #expect(out.width <= scaler.width)
    #expect(out.height <= scaler.height)
  }

  @Test("Final dims smaller than scaler produce even, correct output")
  func downsample() throws {
    let out = try DimensionCalculation.calculateFinalOutputDimensions(
      scalerOutputSize: CGSize(width: 3840, height: 2160),
      requestedWidth: 1920, requestedHeight: 1080)
    #expect(out == CGSize(width: 1920, height: 1080))
  }
}
