import Foundation
import os

// MARK: - StageMetrics

/// Immutable snapshot of one pipeline stage's accumulated timing.
///
/// Created by ``PipelineMetricsCollector/snapshot()`` — not constructed directly.
public struct StageMetrics: Sendable {
  /// Human-readable stage name (e.g. "MetalFX spatial", "Denoise").
  public let name: String

  /// Number of `process(...)` calls completed by this stage.
  public let framesProcessed: Int

  /// Sum of wall-clock time spent inside this stage's `process(...)` calls.
  public let totalDuration: Duration

  /// Average wall-clock time per `process(...)` call, or `.zero` when no frames have been
  /// processed.
  public var averageDuration: Duration {
    framesProcessed > 0 ? totalDuration / framesProcessed : .zero
  }

  /// Throughput of this stage in isolation: frames processed per second of time spent *in
  /// this stage*. Returns `0` when no frames have been processed or the total duration is
  /// zero.
  public var framesPerSecond: Double {
    guard framesProcessed > 0 else { return 0 }
    let seconds = totalDuration.timeInterval
    return seconds > 0 ? Double(framesProcessed) / seconds : 0
  }
}

// MARK: - PipelineMetrics

/// Immutable snapshot of pipeline-wide metrics at a point in time.
///
/// Created by ``PipelineMetricsCollector/snapshot()`` — not constructed directly.
public struct PipelineMetrics: Sendable {
  /// Per-stage breakdown, in pipeline order.
  public let stages: [StageMetrics]

  /// Number of source frames fed into the chain (each `process(...)` call on the chain
  /// counts as one).
  public let framesProcessed: Int

  /// Number of output frames produced by the chain. Equal to `framesProcessed` for purely
  /// 1:1 pipelines; larger when the chain contains a frame-rate conversion stage.
  public let framesEmitted: Int

  /// Wall-clock time elapsed since the first frame entered the chain.
  public let elapsed: Duration

  /// End-to-end throughput: source frames consumed per second of wall-clock time.
  /// Returns `0` before any frames have been processed.
  public var framesPerSecond: Double {
    guard framesProcessed > 0 else { return 0 }
    let seconds = elapsed.timeInterval
    return seconds > 0 ? Double(framesProcessed) / seconds : 0
  }
}

// MARK: - PipelineMetricsCollector

/// Thread-safe accumulator for per-stage timing and overall pipeline throughput.
///
/// Create a collector and pass it to ``FrameProcessorChain/init(inputSize:outputSize:stages:metricsCollector:)``.
/// The chain records timing automatically on each `process(...)` and `finish(...)` call.
/// Consumers (CLI, GUI) poll ``snapshot()`` at their own cadence for the current state.
///
/// The collector uses `OSAllocatedUnfairLock` for internal synchronisation, so ``snapshot()``
/// is safe to call from any thread or task without `await`.
public final class PipelineMetricsCollector: Sendable {

  // MARK: Lifecycle

  public init() {
    state = OSAllocatedUnfairLock(initialState: State())
  }

  // MARK: Public

  /// Registers a named stage and returns its index for subsequent ``record(stageIndex:duration:)``
  /// calls. Call once per stage at chain construction time; the returned indices are stable for
  /// the lifetime of the collector.
  package func addStage(name: String) -> Int {
    state.withLock { state in
      let index = state.stages.count
      state.stages.append(StageState(name: name))
      return index
    }
  }

  /// Records the wall-clock duration of a single `process(...)` call on the stage at
  /// `stageIndex`.
  package func record(stageIndex: Int, duration: Duration) {
    state.withLock { state in
      state.stages[stageIndex].framesProcessed += 1
      state.stages[stageIndex].totalDuration += duration
    }
  }

  /// Records that the chain completed processing one source frame, producing `outputCount`
  /// output frames. The first call also anchors the wall-clock start time.
  package func recordChainCompletion(outputCount: Int) {
    state.withLock { state in
      if state.startInstant == nil {
        state.startInstant = .now
      }
      state.framesProcessed += 1
      state.framesEmitted += outputCount
    }
  }

  /// Returns an immutable snapshot of the current metrics. Cheap to call (single lock
  /// acquisition, no heap allocation beyond the returned arrays).
  public func snapshot() -> PipelineMetrics {
    state.withLock { state in
      let elapsed: Duration =
        if let start = state.startInstant {
          ContinuousClock.now - start
        } else {
          .zero
        }
      return PipelineMetrics(
        stages: state.stages.map { stage in
          StageMetrics(
            name: stage.name,
            framesProcessed: stage.framesProcessed,
            totalDuration: stage.totalDuration
          )
        },
        framesProcessed: state.framesProcessed,
        framesEmitted: state.framesEmitted,
        elapsed: elapsed
      )
    }
  }

  // MARK: Private

  private struct StageState {
    var name: String
    var framesProcessed: Int = 0
    var totalDuration: Duration = .zero
  }

  private struct State {
    var stages: [StageState] = []
    var framesProcessed: Int = 0
    var framesEmitted: Int = 0
    var startInstant: ContinuousClock.Instant?
  }

  private let state: OSAllocatedUnfairLock<State>
}

// MARK: - Duration helpers

extension Duration {
  /// Converts this `Duration` to a `TimeInterval` (seconds as `Double`).
  package var timeInterval: Double {
    let (seconds, attoseconds) = components
    return Double(seconds) + Double(attoseconds) / 1e18
  }
}
