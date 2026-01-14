---
name: Copilot CLI Delegation
description: This skill should be used when the user asks to "delegate to copilot", "use copilot for this", "have copilot generate", "let copilot handle", "copilot cli", "run copilot", "ask copilot to", or when delegating code generation, debugging, git operations, or complex coding tasks to GitHub Copilot CLI as a subagent. Provides patterns for invoking Copilot CLI non-interactively and parsing results.
version: 0.1.0
---

# Copilot CLI Delegation

Delegate tasks to GitHub Copilot CLI as a subagent mechanism. This enables leveraging Copilot's coding capabilities, GitHub integration, and alternative model perspectives for specific tasks.

## When to Use

Delegate to Copilot CLI when:

- **Code generation** - Generate new functions, classes, or files with Copilot's assistance
- **Code review/debugging** - Get a second opinion on code quality, potential bugs, or performance issues
- **Git/GitHub operations** - Generate commit messages, PR descriptions, or analyze repository state
- **Alternative perspective** - Obtain a different model's approach to a problem

Avoid delegation when:

- The task requires Claude's current context or conversation history
- Immediate file modifications are needed (Copilot may require interactive approval)
- The task is simple enough to handle directly

## Prerequisites

Before delegating, verify Copilot CLI availability:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-copilot.sh
```

Requirements:

- Copilot CLI installed (`npm install -g @github/copilot`)
- GitHub authentication via `GITHUB_TOKEN` environment variable or prior `/login`
- macOS, Linux, or Windows (WSL)

## Core Invocation

### Basic Prompt Execution

Execute a task with a direct prompt:

```bash
copilot --prompt "Generate a Swift function to calculate video aspect ratio"
```

### File Context

Include file references using `@<relative-path>` syntax:

```bash
copilot --prompt "Review @Sources/Upscaling/Upscaler.swift for memory leaks in Metal texture handling"
```

Multiple files can be referenced:

```bash
copilot --prompt "Compare @Sources/Upscaling/Upscaler.swift and @Sources/Upscaling/UpscalingFilter.swift for consistent error handling patterns"
```

### Custom Agents

Invoke a specific Copilot agent:

```bash
copilot --agent=swift-expert --prompt "Optimize the upscaling pipeline for 8K video"
```

Custom agents are defined in:

- `.github/agents/` - Repository-level agents
- `~/.copilot/agents/` - User-level agents

### Tool Permissions

Copilot requires explicit permission for file modifications and shell commands. Without permissions, tasks requiring these operations will hang waiting for interactive approval.

| Flag                        | Use Case                     |
| --------------------------- | ---------------------------- |
| `--allow-tool 'shell(git)'` | Git operations only          |
| `--allow-tool 'write'`      | File modifications           |
| `--allow-tool 'shell'`      | All shell commands           |
| `--allow-all-tools`         | Full access (use cautiously) |

Example with permissions:

```bash
copilot --prompt "Create a new Swift file for video metadata" --allow-tool 'write'
```

## Delegation Workflow

### Step 1: Formulate the Task

Create a clear, specific prompt. Include:

- The exact task to perform
- Relevant file context with `@path` references
- Expected output format if applicable
- Constraints or requirements

### Step 2: Execute Delegation

Use the invocation wrapper for proper error handling:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/invoke-copilot.sh "<prompt>" [timeout] [agent] [allow_tools]
```

Parameters:

- `prompt` - The task description (required)
- `timeout` - Seconds before timeout (default: 120)
- `agent` - Optional custom agent name
- `allow_tools` - Tool permissions: `all` or specific like `shell(git)`

### Step 3: Parse Output

Copilot returns text output with potential code blocks. Extract relevant content:

- Look for fenced code blocks (` ``` `)
- Check for error indicators ("error", "failed", "exception")
- Capture explanatory text for context

### Step 4: Integrate Results

After receiving Copilot's output:

1. Review the generated content for correctness
2. Adapt to project conventions if needed
3. Present to user with analysis
4. Offer to apply or iterate on results

## Handling Interactive Prompts

Copilot CLI may request approval for file modifications. Strategies:

1. **Use tool permissions** - Pre-authorize specific tools to avoid interactive prompts:

   ```bash
   copilot --prompt "Create tests" --allow-tool 'write'
   ```

2. **Focus on read-only tasks** - Code review, analysis, and generation that outputs to stdout don't require approval

3. **Timeout detection** - The invocation wrapper detects hanging prompts (exit code 124)

4. **Manual intervention** - When timeout occurs, inform user that Copilot is waiting for approval and suggest running the command directly or adding tool permissions

## Output Handling

### Successful Output

Copilot returns markdown-formatted text. Common patterns:

- Code blocks with language identifiers
- Explanatory prose
- Numbered steps or bullet points
- File paths for context

### Error Detection

Check output for error indicators:

- "Error:", "Failed:", "Exception:"
- Non-zero exit codes
- Timeout (exit code 124)
- "Permission denied" or authentication failures

### Capturing Output

Use command substitution for processing:

```bash
output=$(copilot --prompt "..." 2>&1)
exit_code=$?
```

## Best Practices

### Task Specificity

Provide detailed, specific prompts:

**Good:**

```
Generate a Swift extension on CVPixelBuffer that adds a method `toCIImage()`
returning CIImage?. Use CVPixelBufferGetBaseAddress and handle
kCVPixelFormatType_32BGRA format. Follow patterns from
@Sources/Upscaling/Extensions/CVPixelBuffer+Extensions.swift
```

**Avoid:**

```
Make a pixel buffer helper
```

### Context Management

- Reference relevant files with `@path` syntax
- Include enough context for standalone execution
- Mention project-specific conventions

### Appropriate Delegation

Delegate when:

- A fresh perspective would help
- GitHub-specific operations are needed
- Code generation is the primary task

Handle directly when:

- Conversation context is essential
- Immediate file edits are required
- The task is trivial

## Quick Reference

| Pattern           | Command                                          |
| ----------------- | ------------------------------------------------ |
| Basic prompt      | `copilot --prompt "<task>"`                      |
| With file context | `copilot --prompt "Review @path/to/file.swift"`  |
| Custom agent      | `copilot --agent=<name> --prompt "<task>"`       |
| Tool permissions  | `copilot --prompt "<task>" --allow-tool 'write'` |
| Full tool access  | `copilot --prompt "<task>" --allow-all-tools`    |
| With timeout      | `timeout 120 copilot --prompt "<task>"`          |
| Capture output    | `output=$(copilot --prompt "..." 2>&1)`          |

## Additional Resources

### Reference Files

For detailed patterns and configuration:

- **`references/invocation-patterns.md`** - Complete CLI flags, environment variables, authentication
- **`references/agent-configuration.md`** - Creating and using custom Copilot agents

### Example Files

Working delegation examples in `examples/`:

- **`examples/code-generation.md`** - Swift code generation patterns
- **`examples/code-review.md`** - Code review and debugging delegation
- **`examples/git-operations.md`** - Git/GitHub operation examples

### Utility Scripts

Available scripts in `scripts/`:

- **`scripts/invoke-copilot.sh`** - Main invocation wrapper with error handling
- **`scripts/check-copilot.sh`** - Verify Copilot CLI installation and auth
