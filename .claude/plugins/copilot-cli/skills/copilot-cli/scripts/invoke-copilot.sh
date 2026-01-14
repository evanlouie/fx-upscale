#!/bin/bash
# Wrapper for invoking Copilot CLI with proper error handling
# Usage: invoke-copilot.sh <prompt> [timeout] [agent] [allow_tools]

set -uo pipefail

PROMPT="${1:-}"
TIMEOUT="${2:-120}"
AGENT="${3:-}"
ALLOW_TOOLS="${4:-}"

if [ -z "$PROMPT" ]; then
    echo "Usage: invoke-copilot.sh <prompt> [timeout] [agent] [allow_tools]" >&2
    echo "  prompt      - The task to send to Copilot (required)" >&2
    echo "  timeout     - Seconds before timeout (default: 120)" >&2
    echo "  agent       - Optional custom agent name" >&2
    echo "  allow_tools - Tool permissions: 'all' or specific like 'shell(git)'" >&2
    exit 1
fi

# Check Copilot availability
if ! command -v copilot &>/dev/null; then
    echo "ERROR: Copilot CLI not installed" >&2
    echo "Install with: npm install -g @github/copilot" >&2
    exit 1
fi

# Build command arguments
ARGS=(--prompt "$PROMPT")
if [ -n "$AGENT" ]; then
    ARGS=(--agent="$AGENT" "${ARGS[@]}")
fi

# Add tool permission flags
if [ "$ALLOW_TOOLS" = "all" ]; then
    ARGS+=(--allow-all-tools)
elif [ -n "$ALLOW_TOOLS" ]; then
    ARGS+=(--allow-tool "$ALLOW_TOOLS")
fi

# Execute with timeout, capturing exit code properly
timeout "$TIMEOUT" copilot "${ARGS[@]}" 2>&1
exit_code=$?

if [ $exit_code -ne 0 ]; then
    if [ $exit_code -eq 124 ]; then
        echo "" >&2
        echo "ERROR: Copilot CLI timed out after ${TIMEOUT}s" >&2
        echo "This may indicate Copilot is waiting for interactive approval." >&2
        echo "Try adding tool permissions with allow_tools parameter." >&2
    fi
    exit $exit_code
fi
