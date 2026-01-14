# Copilot CLI Invocation Patterns

Complete reference for GitHub Copilot CLI command-line options and invocation patterns.

## Command-Line Flags

### Core Flags

| Flag                | Description                                    |
| ------------------- | ---------------------------------------------- |
| `--prompt "<text>"` | Execute a prompt non-interactively             |
| `--agent=<name>`    | Use a specific custom agent                    |
| `--resume`          | Return to previous session with selection list |
| `--continue`        | Resume most recently closed session            |

### Permission Flags

| Flag                   | Description                 |
| ---------------------- | --------------------------- |
| `--allow-all-paths`    | Disable path verification   |
| `--allow-all-urls`     | Disable URL verification    |
| `--allow-url <domain>` | Pre-approve specific domain |

## Environment Variables

| Variable               | Description                                       |
| ---------------------- | ------------------------------------------------- |
| `GITHUB_TOKEN`         | Primary authentication token                      |
| `GH_TOKEN`             | Alternative authentication token                  |
| `COPILOT_GITHUB_TOKEN` | Copilot-specific token (takes precedence)         |
| `XDG_CONFIG_HOME`      | Override config directory (default: `~/.copilot`) |

## File Context Syntax

Reference files in prompts using `@<relative-path>`:

```bash
# Single file
copilot --prompt "Explain @src/main.swift"

# Multiple files
copilot --prompt "Compare @src/foo.swift and @src/bar.swift"
```

## Non-Interactive Patterns

### Basic Execution

```bash
copilot --prompt "Generate a Swift struct for video metadata"
```

### With Custom Agent

```bash
copilot --agent=swift-expert --prompt "Review this Metal shader"
```

### With Timeout

```bash
timeout 120 copilot --prompt "Analyze codebase architecture"
```

### Capturing Output

```bash
output=$(copilot --prompt "Generate unit tests" 2>&1)
```

## Exit Codes

| Code | Meaning                                |
| ---- | -------------------------------------- |
| 0    | Success                                |
| 1    | General error                          |
| 124  | Timeout (when using `timeout` command) |

## Interactive Session Commands

| Command              | Purpose                         |
| -------------------- | ------------------------------- |
| `/login`             | Authenticate to GitHub          |
| `/model`             | Select AI model                 |
| `/agent`             | Select custom agent             |
| `/delegate <prompt>` | Hand off to GitHub coding agent |
| `/cwd <path>`        | Switch working directory        |
| `/usage`             | View token usage                |
