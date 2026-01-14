---
name: delegate
description: Delegate a task to GitHub Copilot CLI as a subagent
arguments:
  - name: task
    description: The task to delegate to Copilot CLI
    required: true
  - name: agent
    description: Optional Copilot agent to use (e.g., swift-expert)
    required: false
  - name: allow_tools
    description: "Tool permissions: 'all' or specific like 'shell(git)', 'write'"
    required: false
---

# Delegate Task to Copilot CLI

Execute the following steps to delegate this task to GitHub Copilot CLI:

## Step 1: Verify Prerequisites

Run the prerequisite check script:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-copilot.sh
```

If Copilot CLI is not installed or authenticated, inform the user and provide installation instructions.

## Step 2: Formulate the Prompt

Take the user's task and enhance it:

1. Add relevant file context using `@<relative-path>` syntax if applicable
2. Be specific about expected output format
3. Include any project-specific conventions

## Step 3: Execute Delegation

Run the task using the invocation wrapper:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/invoke-copilot.sh "<formatted_prompt>" 120 "<agent_if_specified>" "<allow_tools_if_specified>"
```

For tasks requiring file writes or shell commands, include tool permissions to avoid interactive prompts.

## Step 4: Present Results

After receiving Copilot's output:

1. Review the response for correctness
2. Format code blocks appropriately
3. Summarize key findings or generated content
4. Offer to apply changes or iterate on results

## Step 5: Handle Errors

If the command fails:

- **Exit code 124 (timeout)**: Copilot may be waiting for interactive approval. Retry with `--allow-tool` permissions or suggest running the command directly.
- **Exit code 1**: Check error message and suggest fixes.
- **Not installed**: Provide installation command `npm install -g @github/copilot`.
- **Not authenticated**: Suggest setting `GITHUB_TOKEN` or running `copilot` interactively with `/login`.

## Notes

- Copilot CLI uses Claude Sonnet 4.5 by default
- File references must be relative paths from the working directory
- Use `--allow-tool 'write'` for file creation, `--allow-tool 'shell(git)'` for git operations
- Use `--allow-all-tools` for full access (with caution)
