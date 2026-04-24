/// Drains a throwing task group and cancels still-running siblings as soon as the first child
/// throws. This is important for bounded producer/consumer pipelines: a downstream failure must
/// wake upstream tasks that may be suspended in `PipelineChannel.send`.
extension ThrowingTaskGroup where Failure == any Error {
  mutating func waitForAllCancellingOnFirstError() async throws {
    do {
      while try await next() != nil {}
    } catch {
      cancelAll()
      throw error
    }
  }
}
