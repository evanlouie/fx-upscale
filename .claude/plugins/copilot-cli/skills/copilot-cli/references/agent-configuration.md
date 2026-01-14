# Copilot Agent Configuration

Guide for creating and using custom Copilot agents.

## Agent Locations

| Location                  | Scope                              |
| ------------------------- | ---------------------------------- |
| `.github/agents/`         | Repository-level (current project) |
| `~/.copilot/agents/`      | User-level (all projects)          |
| `.github-private/agents/` | Organization/enterprise-level      |

## Agent File Format

Create a markdown file in the agents directory:

```markdown
# Agent Name

Description of what this agent specializes in.

## Instructions

Specific instructions for how this agent should behave.

## Capabilities

- Capability 1
- Capability 2
```

## Example Agents

### Swift Expert Agent

**File:** `.github/agents/swift-expert.md`

```markdown
# Swift Expert

Specialized in Swift development for Apple platforms.

## Instructions

- Follow Swift API Design Guidelines
- Use modern Swift features (async/await, actors)
- Prefer value types over reference types
- Include documentation comments for public APIs

## Focus Areas

- Metal and GPU programming
- AVFoundation for media
- Swift concurrency patterns
```

### Code Reviewer Agent

**File:** `.github/agents/code-reviewer.md`

```markdown
# Code Reviewer

Specialized in code review and quality analysis.

## Instructions

- Check for memory leaks and retain cycles
- Identify thread safety issues
- Suggest performance improvements
- Verify error handling completeness

## Output Format

Provide findings as:

1. Severity (Critical/High/Medium/Low)
2. Location (file:line)
3. Issue description
4. Suggested fix
```

## Invoking Agents

### Via CLI Flag

```bash
copilot --agent=swift-expert --prompt "Review this code"
```

### Via Slash Command

In interactive mode:

```
/agent swift-expert
```

### Via Prompt Mention

Reference agent name in prompt:

```bash
copilot --prompt "As swift-expert, review @Sources/Upscaler.swift"
```

## Agent Discovery

Copilot automatically discovers agents from configured locations. Use `/agent` in interactive mode to see available agents.

## Best Practices

1. **Focused scope** - Each agent should have a clear specialty
2. **Clear instructions** - Be explicit about behavior expectations
3. **Output format** - Define expected response structure when relevant
4. **Project context** - Repository agents can reference project-specific conventions
