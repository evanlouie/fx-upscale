# Code Review Delegation Examples

Examples of delegating code review and debugging tasks to Copilot CLI.

## Review for Memory Leaks

**Task:** Check for memory management issues

**Command:**

```bash
copilot --prompt "Review @Sources/Upscaling/UpscalingExportSession.swift for memory leaks, particularly:
1. CVPixelBuffer retain/release patterns
2. Metal texture lifecycle
3. AVAssetReader/Writer cleanup
4. Closure capture lists"
```

## Review Thread Safety

**Task:** Analyze concurrent code

**Command:**

```bash
copilot --prompt "Analyze @Sources/Upscaling/Upscaler.swift for thread safety issues:
1. Shared mutable state
2. Metal command buffer synchronization
3. Race conditions in async methods
4. Actor isolation correctness"
```

## Debug Performance Issue

**Task:** Investigate slow performance

**Command:**

```bash
copilot --prompt "The upscaling pipeline is slow with 8K video. Analyze @Sources/Upscaling/Upscaler.swift and @Sources/Upscaling/UpscalingExportSession.swift for:
1. Unnecessary texture allocations
2. Synchronous waits on GPU
3. Memory bandwidth bottlenecks
4. Suboptimal command buffer usage"
```

## Review Error Handling

**Task:** Check error handling completeness

**Command:**

```bash
copilot --prompt "Review @Sources/Upscaling/UpscalingExportSession.swift for error handling gaps:
1. Unhandled optional unwrapping
2. Missing error propagation
3. Silent failures
4. Resource cleanup on error paths"
```

## Security Review

**Task:** Check for security issues

**Command:**

```bash
copilot --prompt "Review @Sources/fx-upscale/main.swift for security issues:
1. Path traversal vulnerabilities
2. Unsafe file operations
3. Input validation gaps
4. Temporary file handling"
```

## API Design Review

**Task:** Evaluate public API

**Command:**

```bash
copilot --prompt "Review the public API of @Sources/Upscaling/Upscaler.swift:
1. Naming convention compliance
2. Parameter clarity
3. Documentation completeness
4. Error communication
5. Sendable conformance for concurrency"
```
