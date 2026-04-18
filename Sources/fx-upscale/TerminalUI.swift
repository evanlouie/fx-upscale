import Darwin
import Foundation

// MARK: - ANSI

private enum ANSI {
  static let reset = "\u{1B}[0m"
  static let bold = "\u{1B}[1m"
  static let brightCyan = "\u{1B}[96m"
  static let brightGreen = "\u{1B}[92m"
  static let gray = "\u{1B}[90m"
  static let clearToEndOfLine = "\u{1B}[0K"
  static let hideCursor = "\u{1B}[?25l"
  static let showCursor = "\u{1B}[?25h"

  static func style(_ string: String, _ codes: String...) -> String {
    guard Terminal.isTTY else { return string }
    return codes.joined() + string + reset
  }
}

// MARK: - Terminal

enum Terminal {
  static let isTTY: Bool = isatty(fileno(Darwin.stdout)) != 0

  static func info(_ message: String) {
    print(ANSI.style("i ", ANSI.brightCyan, ANSI.bold) + message)
  }

  static func success(_ message: String) {
    print(ANSI.style("✓ ", ANSI.brightGreen, ANSI.bold) + message)
  }

  /// Width of the terminal window in columns, or `nil` when not attached to a TTY.
  static var columns: Int? {
    var size = winsize()
    guard ioctl(fileno(Darwin.stdout), TIOCGWINSZ, &size) == 0, size.ws_col > 0 else {
      return nil
    }
    return Int(size.ws_col)
  }

  fileprivate static func clearLine() {
    print("\r" + ANSI.clearToEndOfLine, terminator: "")
    fflush(Darwin.stdout)
  }
}

// MARK: - ProgressBar

enum ProgressBar {
  // MARK: Public

  static func start(progress: Progress) {
    stop()
    // When not attached to a TTY, a continuously redrawing bar becomes log
    // spam in pipes/CI. A single completion line is emitted by the caller
    // via `Terminal.success`, so we simply no-op here.
    guard Terminal.isTTY else { return }
    print(ANSI.hideCursor, terminator: "")
    task = Task {
      while !Task.isCancelled {
        render(progress: progress)
        try? await Task.sleep(nanoseconds: frameIntervalNanoseconds)
      }
    }
  }

  static func stop() {
    task?.cancel()
    task = nil
    guard Terminal.isTTY else { return }
    Terminal.clearLine()
    print(ANSI.showCursor, terminator: "")
    fflush(Darwin.stdout)
  }

  // MARK: Private

  private static let frameIntervalNanoseconds: UInt64 = 80_000_000
  private static let minBarColumns = 10
  private static let defaultColumns = 80
  private static let percentFieldWidth = 8
  private static let bracketsWidth = 2

  /// Partial-fill glyphs from empty to nearly full. The fractional column
  /// width is mapped to an index in `0..<partialFrames.count`.
  private static let partialFrames = [" ", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
  private static let openBracket = ANSI.style("[", ANSI.brightCyan, ANSI.bold)
  private static let closeBracket = ANSI.style("]", ANSI.brightCyan, ANSI.bold)

  private nonisolated(unsafe) static var task: Task<Void, Never>?

  private static func render(progress: Progress) {
    let cols = max(
      minBarColumns,
      (Terminal.columns ?? defaultColumns) - bracketsWidth - percentFieldWidth
    )
    let fraction = max(0, min(1, progress.fractionCompleted))
    let scaled = fraction * Double(cols)
    let completed = Int(scaled)
    let partial = scaled - Double(completed)

    var components = [openBracket]
    components.append(String(repeating: "█", count: completed))
    if cols - completed - 1 > 0 {
      let frameIndex = min(
        partialFrames.count - 1,
        Int(partial * Double(partialFrames.count))
      )
      components.append(partialFrames[frameIndex])
      components.append(String(repeating: " ", count: cols - completed - 1))
    }
    components.append(closeBracket)
    components.append(ANSI.style(String(format: " %.2f%%", fraction * 100), ANSI.gray))

    print("\r" + ANSI.clearToEndOfLine + components.joined(), terminator: "")
    fflush(Darwin.stdout)
  }
}
