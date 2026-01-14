# Git/GitHub Operations Examples

Examples of delegating Git and GitHub operations to Copilot CLI.

## Generate Commit Message

**Task:** Create conventional commit message

**Command:**

```bash
copilot --prompt "Generate a conventional commit message for the staged changes. The changes are visible via 'git diff --cached'. Follow the pattern: type(scope): description"
```

## Generate PR Description

**Task:** Create pull request description

**Command:**

```bash
copilot --prompt "Create a PR description for merging the current branch into main. Include:
1. Summary of changes (bullet points)
2. Test plan
3. Any breaking changes

Use 'git log main..HEAD' and 'git diff main...HEAD' for context."
```

## Analyze Commit History

**Task:** Understand recent changes

**Command:**

```bash
copilot --prompt "Analyze the last 10 commits and summarize:
1. Main areas of change
2. Patterns in commit messages
3. Any concerning trends (large commits, unclear messages)"
```

## Generate Release Notes

**Task:** Create changelog entries

**Command:**

```bash
copilot --prompt "Generate release notes for changes since the last tag. Group by:
- Features
- Bug fixes
- Breaking changes

Use 'git log $(git describe --tags --abbrev=0)..HEAD' for commits."
```

## Review Branch Diff

**Task:** Summarize branch changes

**Command:**

```bash
copilot --prompt "Summarize the differences between main and current branch:
1. Files changed
2. Key modifications
3. Potential merge conflicts

Use 'git diff main...HEAD --stat' for overview."
```

## Fix Merge Conflict

**Task:** Resolve conflict guidance

**Command:**

```bash
copilot --prompt "Help resolve the merge conflict in @Sources/Upscaling/Upscaler.swift. Show the conflict markers and suggest the correct resolution considering both changes."
```
