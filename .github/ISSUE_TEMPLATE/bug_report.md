---
name: Bug report
about: Something in the plugin isn't working as documented
title: "bug: "
labels: bug
---

**Describe the bug**
A clear, concise description of what's wrong.

**To reproduce**
Steps to reproduce, ideally against a minimal example repo:
1. `.claude/pipeline.config.json` (redact anything sensitive):
   ```json

   ```
2. Command run (e.g. `/lgtmgate:feature 42 "..."`):
3. What happened:
4. What you expected instead:

**Versions**
- Plugin version (`.claude-plugin/plugin.json`'s `version`, or the `buildStamp` from a run):
- Claude Code version:
- OS:

**Logs**
Paste the relevant `logs[]` entries or `buildStamp` from the run's output, and any hook stderr
(`PreToolUse`/`Stop` hook output), if available. Redact secrets and unrelated file contents.

**Additional context**
Anything else that might be relevant (recent config changes, custom hooks, etc).
