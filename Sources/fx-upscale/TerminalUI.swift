import Darwin
import Foundation
import os

// MARK: - ANSI

private enum ANSI {
  static let reset = "\u{1B}[0m"
  static let bold = "\u{1B}[1m"
  static let brightCyan = "\u{1B}[96m"
  static let brightGreen = "\u{1B}[92m"
  static let brightRed = "\u{1B}[91m"
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

  /// Writes a red error line to `stderr` so pipes/CI capture failures correctly and callers
  /// can check the process exit code without parsing stdout.
  static func error(_ message: String) {
    let styled = ANSI.style("✗ ", ANSI.brightRed, ANSI.bold) + message + "\n"
    fputs(styled, Darwin.stderr)
    fflush(Darwin.stderr)
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

  /// Emits the sequences needed to restore the cursor from a signal handler.
  static func restoreCursorUnsafe() {
    fputs("\r" + ANSI.clearToEndOfLine + ANSI.showCursor + "\n", Darwin.stdout)
    fflush(Darwin.stdout)
  }
}

// MARK: - SignalHandlers

enum SignalHandlers {
  // MARK: Public

  /// Installs SIGINT / SIGTERM handlers that run `cleanup` (on a background queue) before
  /// exiting. The handlers are installed at most once per process — subsequent calls replace
  /// the cleanup closure atomically.
  ///
  /// Install this unconditionally (not gated on `Terminal.isTTY`) so Ctrl-C during a pipe or
  /// CI run still removes partial outputs rather than leaving them on disk.
  static func install(cleanup: @escaping @Sendable () -> Void) {
    let shouldInstallSources = state.withLock { state -> Bool in
      state.cleanup = cleanup
      guard !state.installed else { return false }
      state.installed = true
      return true
    }
    guard shouldInstallSources else { return }
    for sig in [SIGINT, SIGTERM] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
      source.setEventHandler {
        let stored = state.withLock { $0.cleanup }
        stored?()
        Terminal.restoreCursorUnsafe()
        // 128 + signal number is the conventional shell exit code for signal termination.
        exit(128 + sig)
      }
      source.resume()
      state.withLock { $0.sources.append(source) }
    }
  }

  /// Clears any previously-installed cleanup closure without uninstalling the signal source.
  static func clearCleanup() {
    state.withLock { $0.cleanup = nil }
  }

  // MARK: Private

  private struct State {
    var cleanup: (@Sendable () -> Void)?
    var installed: Bool = false
    var sources: [DispatchSourceSignal] = []
  }

  private static let state = OSAllocatedUnfairLock(initialState: State())
}

// MARK: - ProgressBar

enum ProgressBar {
  // MARK: Public

  static func start(progress: Progress) {
    stop()
    // No animated redraw when not attached to a TTY — signal handling is already installed by
    // the caller, so Ctrl-C still cleans up output files.
    guard Terminal.isTTY else { return }
    print(ANSI.hideCursor, terminator: "")
    task = Task {
      while !Task.isCancelled {
        render(progress: progress)
        try? await Task.sleep(for: frameInterval)
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

  private static let frameInterval: Duration = .milliseconds(80)
  private static let minBarColumns = 10
  private static let defaultColumns = 80
  private static let percentFieldWidth = 8
  private static let bracketsWidth = 2

  /// Partial-fill glyphs from empty to nearly full. Index 0 is intentionally empty so that the
  /// bar renders a clean space for sub-column progress rather than the minimum partial glyph.
  private static let partialFrames = [" ", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
  private static let openBracket = ANSI.style("[", ANSI.brightCyan, ANSI.bold)
  private static let closeBracket = ANSI.style("]", ANSI.brightCyan, ANSI.bold)

  /// Single-writer invariant: `task` is only ever mutated from `start()`/`stop()`, which the
  /// CLI invokes from its single `async run()` flow.
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
    let percent = fraction.formatted(.percent.precision(.fractionLength(2)))
    components.append(ANSI.style(" " + percent, ANSI.gray))

    print("\r" + ANSI.clearToEndOfLine + components.joined(), terminator: "")
    fflush(Darwin.stdout)
  }
}
