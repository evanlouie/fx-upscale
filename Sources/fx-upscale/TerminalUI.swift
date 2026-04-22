import Darwin
import Foundation
import Upscaling
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
  static let clearToEndOfScreen = "\u{1B}[J"
  static let hideCursor = "\u{1B}[?25l"
  static let showCursor = "\u{1B}[?25h"

  /// Moves the cursor up `n` lines. No-op when `n <= 0`.
  static func cursorUp(_ n: Int) -> String {
    n > 0 ? "\u{1B}[\(n)A" : ""
  }

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

  /// Number of lines currently occupied by the progress display. Written by
  /// `ProgressBar.render()`, read by `restoreCursorUnsafe()` for signal-handler cleanup.
  fileprivate nonisolated(unsafe) static var progressLineCount = 0

  /// Moves the cursor to the top of the progress block and clears all its lines.
  /// Safe to call from `DispatchSource` signal handlers — uses only `fputs` and `fflush`.
  static func restoreCursorUnsafe() {
    let n = progressLineCount
    if n > 1 {
      fputs(ANSI.cursorUp(n - 1), Darwin.stdout)
    }
    // `\r` moves to column 0; `\e[J` clears from cursor to end of display (all stale lines).
    fputs("\r" + ANSI.clearToEndOfScreen + ANSI.showCursor + "\n", Darwin.stdout)
    fflush(Darwin.stdout)
  }

  // MARK: Metrics Summary

  /// Prints a per-stage timing breakdown table after export completes.
  ///
  /// Skips output when there are no stages (identity/re-encode-only chain) or when not attached
  /// to a TTY (piped/CI output stays machine-parseable).
  static func metricsSummary(_ metrics: PipelineMetrics) {
    guard isTTY, !metrics.stages.isEmpty, metrics.framesProcessed > 0 else { return }

    // Column widths — sized so realistic values align without excess padding.
    let nameWidth = max(21, metrics.stages.map(\.name.count).max() ?? 0)
    let framesWidth = 8
    let avgWidth = 10
    let totalWidth = 11
    let fpsWidth = 9

    let header =
      "  " + "Stage".padding(toLength: nameWidth, withPad: " ", startingAt: 0)
      + "Frames".leftPad(framesWidth)
      + "Avg (ms)".leftPad(avgWidth)
      + "Total (s)".leftPad(totalWidth)
      + "FPS".leftPad(fpsWidth)
    let divider =
      "  " + String(repeating: "\u{2500}", count: nameWidth)
      + "  " + String(repeating: "\u{2500}", count: framesWidth)
      + "  " + String(repeating: "\u{2500}", count: avgWidth)
      + "  " + String(repeating: "\u{2500}", count: totalWidth)
      + "  " + String(repeating: "\u{2500}", count: fpsWidth)

    print(ANSI.style(header, ANSI.gray))
    print(ANSI.style(divider, ANSI.gray))

    for stage in metrics.stages {
      let avgMs = stage.averageDuration.timeInterval * 1000.0
      let totalS = stage.totalDuration.timeInterval
      let row =
        "  " + stage.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
        + String(stage.framesProcessed).leftPad(framesWidth)
        + String(format: "%.2f", avgMs).leftPad(avgWidth)
        + String(format: "%.2f", totalS).leftPad(totalWidth)
        + String(format: "%.1f", stage.framesPerSecond).leftPad(fpsWidth)
      print(row)
    }

    print(ANSI.style(divider, ANSI.gray))

    let pipelineRow =
      "  " + "Pipeline".padding(toLength: nameWidth, withPad: " ", startingAt: 0)
      + String(metrics.framesProcessed).leftPad(framesWidth)
      + "".leftPad(avgWidth)
      + String(format: "%.2f", metrics.elapsed.timeInterval).leftPad(totalWidth)
      + String(format: "%.1f", metrics.framesPerSecond).leftPad(fpsWidth)
    print(ANSI.style(pipelineRow, ANSI.bold))
  }
}

// MARK: - String + leftPad

extension String {
  /// Right-aligns this string within a field of `width` characters plus a two-space left gutter.
  fileprivate func leftPad(_ width: Int) -> String {
    let padded = count < width ? String(repeating: " ", count: width - count) + self : self
    return "  " + padded
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

  static func start(progress: Progress, metricsCollector: PipelineMetricsCollector? = nil) {
    stop()
    // No animated redraw when not attached to a TTY — signal handling is already installed by
    // the caller, so Ctrl-C still cleans up output files.
    guard Terminal.isTTY else { return }
    print(ANSI.hideCursor, terminator: "")
    task = Task {
      while !Task.isCancelled {
        render(progress: progress, metricsCollector: metricsCollector)
        try? await Task.sleep(for: frameInterval)
      }
    }
  }

  static func stop() {
    task?.cancel()
    task = nil
    guard Terminal.isTTY else { return }
    // Move to the top of the progress block, then clear everything below.
    let n = Terminal.progressLineCount
    if n > 1 {
      print(ANSI.cursorUp(n - 1), terminator: "")
    }
    print("\r" + ANSI.clearToEndOfScreen + ANSI.showCursor, terminator: "")
    Terminal.progressLineCount = 0
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

  private static func render(
    progress: Progress,
    metricsCollector: PipelineMetricsCollector?
  ) {
    let snapshot = metricsCollector?.snapshot()

    // ── Line 1: progress bar with overall fps ──────────────────────────

    let overallFpsText: String
    var overallFpsVisibleWidth = 0
    if let snapshot, snapshot.framesProcessed > 0, snapshot.framesPerSecond > 0 {
      let text = String(format: "  %.1f fps", snapshot.framesPerSecond)
      overallFpsText = ANSI.style(text, ANSI.gray)
      overallFpsVisibleWidth = text.count
    } else {
      overallFpsText = ""
    }

    let terminalWidth = Terminal.columns ?? defaultColumns
    let barCols = max(
      minBarColumns,
      terminalWidth - bracketsWidth - percentFieldWidth - overallFpsVisibleWidth
    )
    let fraction = max(0, min(1, progress.fractionCompleted))
    let scaled = fraction * Double(barCols)
    let completed = Int(scaled)
    let partial = scaled - Double(completed)

    var bar = openBracket
    bar += String(repeating: "█", count: completed)
    if barCols - completed - 1 > 0 {
      let frameIndex = min(
        partialFrames.count - 1,
        Int(partial * Double(partialFrames.count))
      )
      bar += partialFrames[frameIndex]
      bar += String(repeating: " ", count: barCols - completed - 1)
    }
    bar += closeBracket
    let percent = fraction.formatted(.percent.precision(.fractionLength(2)))
    bar += ANSI.style(" " + percent, ANSI.gray)
    bar += overallFpsText

    var lines = [bar]

    // ── Lines 2+: per-stage fps ────────────────────────────────────────

    if let snapshot, snapshot.framesProcessed > 0 {
      let active = snapshot.stages.filter { $0.framesProcessed > 0 && $0.framesPerSecond > 0 }
      if let nameWidth = active.map(\.name.count).max() {
        for stage in active {
          let stageText =
            "  "
            + stage.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            + String(format: "  %7.1f fps", stage.framesPerSecond)
          lines.append(ANSI.style(stageText, ANSI.gray))
        }
      }
    }

    // ── Emit with cursor management ────────────────────────────────────

    let prev = Terminal.progressLineCount

    // Move cursor back to the top of the previously rendered block.
    if prev > 1 {
      print(ANSI.cursorUp(prev - 1), terminator: "")
    }

    // Write each line, clearing any stale content to the right.
    for (index, line) in lines.enumerated() {
      print("\r" + ANSI.clearToEndOfLine + line, terminator: "")
      if index < lines.count - 1 {
        print("", terminator: "\n")
      }
    }

    // If the previous render had more lines, clear the stale rows below.
    if prev > lines.count {
      print("", terminator: "\n")
      print(ANSI.clearToEndOfScreen, terminator: "")
      // Move back up to the last content line so the next render cycle starts
      // from the right position.
      print(ANSI.cursorUp(1), terminator: "")
    }

    Terminal.progressLineCount = lines.count
    fflush(Darwin.stdout)
  }
}
