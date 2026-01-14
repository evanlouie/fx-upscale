#!/bin/bash
# Verify Copilot CLI installation and authentication
# Usage: check-copilot.sh

set -euo pipefail

echo "Checking Copilot CLI prerequisites..."
echo ""

# Check installation
if ! command -v copilot &>/dev/null; then
    echo "STATUS: NOT_INSTALLED"
    echo ""
    echo "Copilot CLI is not installed."
    echo "Install with: npm install -g @github/copilot"
    exit 1
fi

# Check version
version=$(copilot --version 2>/dev/null || echo "unknown")
echo "VERSION: $version"

# Check authentication tokens
AUTH_OK=false
if [ -n "${COPILOT_GITHUB_TOKEN:-}" ]; then
    echo "AUTH: COPILOT_GITHUB_TOKEN configured"
    AUTH_OK=true
elif [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "AUTH: GITHUB_TOKEN configured"
    AUTH_OK=true
elif [ -n "${GH_TOKEN:-}" ]; then
    echo "AUTH: GH_TOKEN configured"
    AUTH_OK=true
else
    echo "AUTH: No token found"
    echo ""
    echo "Warning: No authentication token detected."
    echo "Set GITHUB_TOKEN or run 'copilot' interactively and use /login"
fi

echo ""
if [ "$AUTH_OK" = true ]; then
    echo "STATUS: READY"
else
    echo "STATUS: NOT_AUTHENTICATED"
    exit 1
fi
