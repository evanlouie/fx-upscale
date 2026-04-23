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
  static let brightYellow = "\u{1B}[93m"
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

  /// `style` that gates on stderr's TTY-ness — piping stderr strips escapes even when
  /// stdout is still a TTY (and vice versa).
  static func styleForStderr(_ string: String, _ codes: String...) -> String {
    guard Terminal.isStderrTTY else { return string }
    return codes.joined() + string + reset
  }
}

// MARK: - Terminal

enum Terminal {
  static let isTTY: Bool = isatty(fileno(Darwin.stdout)) != 0
  static let isStderrTTY: Bool = isatty(fileno(Darwin.stderr)) != 0

  static func info(_ message: String) {
    print(ANSI.style("i ", ANSI.brightCyan, ANSI.bold) + message)
  }

  static func success(_ message: String) {
    print(ANSI.style("✓ ", ANSI.brightGreen, ANSI.bold) + message)
  }

  /// Writes a red error line to `stderr` so pipes/CI capture failures correctly and callers
  /// can check the process exit code without parsing stdout. stderr is unbuffered by default
  /// on POSIX, but we `fflush` explicitly as cheap defense-in-depth in case a caller (or
  /// future test harness) has reopened stderr with buffering.
  static func error(_ message: String) {
    let styled = ANSI.styleForStderr("✗ ", ANSI.brightRed, ANSI.bold) + message + "\n"
    fputs(styled, Darwin.stderr)
    fflush(Darwin.stderr)
  }

  /// Non-fatal warning: the operation will still complete, but something notable happened
  /// (degraded output, unsupported feature silently ignored, etc.). Writes to stderr with
  /// the same flush discipline as `error` so pipes/CI capture both on the same stream.
  static func warning(_ message: String) {
    let styled = ANSI.styleForStderr("! ", ANSI.brightYellow, ANSI.bold) + message + "\n"
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
  /// `ProgressBar.render()` and `ProgressBar.stop()` (main-actor / render Task), read by
  /// `restoreCursorUnsafe()` from a `DispatchSource` signal queue — wrap the shared state in
  /// an unfair lock to avoid racy reads/writes across threads.
  private static let progressLineCountLock = OSAllocatedUnfairLock<Int>(initialState: 0)
  fileprivate static var progressLineCount: Int {
    get { progressLineCountLock.withLock { $0 } }
    set { progressLineCountLock.withLock { $0 = newValue } }
  }

  /// Emits the cursor-up + clear-to-end-of-screen + show-cursor sequence that tears down an
  /// existing progress block. Uses `fputs`/`fflush` (plus an unfair lock acquisition via
  /// `progressLineCount` when the caller reads it) — safe to call from `DispatchSource`
  /// signal handlers, which run on a dispatch queue rather than in async-signal context.
  /// Does not mutate `progressLineCount` — callers reset it if appropriate.
  ///
  /// `trailingNewline: true` is wanted on the signal-handler path so the shell prompt lands on
  /// its own line after the process dies. On the normal-shutdown path it is `false`: callers
  /// (e.g. `Terminal.success`) follow immediately with their own output, and an extra `\n`
  /// would leave a blank line.
  fileprivate static func tearDownProgressBlock(lineCount: Int, trailingNewline: Bool) {
    if lineCount > 1 {
      fputs(ANSI.cursorUp(lineCount - 1), Darwin.stdout)
    }
    // `\r` moves to column 0; `\e[J` clears from cursor to end of display (all stale lines).
    let tail = trailingNewline ? "\n" : ""
    fputs("\r" + ANSI.clearToEndOfScreen + ANSI.showCursor + tail, Darwin.stdout)
    fflush(Darwin.stdout)
  }

  /// Moves the cursor to the top of the progress block and clears all its lines. Emits a
  /// trailing newline so whatever prints next (often the shell prompt after an abort) starts
  /// on a fresh line. Safe to call from `DispatchSource` signal handlers. No-op when stdout
  /// is not a TTY (otherwise raw ANSI escapes would leak into pipes).
  static func restoreCursorUnsafe() {
    guard isTTY else { return }
    tearDownProgressBlock(lineCount: progressLineCount, trailingNewline: true)
    progressLineCount = 0
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
    // Idempotent: a nil task combined with a zero line count means there's nothing to tear
    // down (either never started, or already stopped). Without this guard, a second call
    // would still emit `\r\e[J\e[?25h\n` and leave a stray blank line.
    if task == nil && Terminal.progressLineCount == 0 { return }
    task?.cancel()
    task = nil
    guard Terminal.isTTY else { return }
    // Move to the top of the progress block, then clear everything below. No trailing newline:
    // the next output (`Terminal.success` + metrics summary, or an error line) prints on its
    // own line already, and an extra `\n` here would leave a visible blank line.
    Terminal.tearDownProgressBlock(lineCount: Terminal.progressLineCount, trailingNewline: false)
    Terminal.progressLineCount = 0
  }

  // MARK: Private

  private static let frameInterval: Duration = .milliseconds(80)
  private static let minBarColumns = 10
  private static let defaultColumns = 80
  // `" " + "%6.2f%%"` → 1 leading space + 7 chars ("  0.00%" … "100.00%") = 8 visible columns.
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
    let fraction = max(0, min(1, progress.fractionCompleted))
    // Locale-fixed formatting: `.formatted(.percent...)` emits `"50,00 %"` in de_DE / fr_FR,
    // breaking the fixed-width assumption below. `%6.2f%%` always produces a 7-char field
    // ("  0.00%", " 50.00%", "100.00%") regardless of locale.
    let percent = String(format: "%6.2f%%", fraction * 100)

    let requiredMinimum =
      bracketsWidth + percentFieldWidth + overallFpsVisibleWidth + minBarColumns

    var lines: [String]
    if terminalWidth < requiredMinimum {
      // Terminal too narrow to fit a meaningful bar — degrade to just the percent so we
      // never emit a line wider than the window (which would corrupt the redraw math).
      lines = [ANSI.style(percent, ANSI.gray) + overallFpsText]
    } else {
      let barCols =
        terminalWidth - bracketsWidth - percentFieldWidth - overallFpsVisibleWidth
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
      bar += ANSI.style(" " + percent, ANSI.gray)
      bar += overallFpsText

      lines = [bar]
    }

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
