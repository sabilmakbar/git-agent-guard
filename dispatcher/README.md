# Dispatcher (not installed in v1)

v1 of git-agent-guard is agent-layer only: every check fires from the
Claude Code PreToolUse adapter, before a command runs.

This directory holds the future git-layer: a `core.hooksPath` dispatcher that
runs registered checks and then chains to the repository's own `.git/hooks/`
so it never disables other tooling (husky, pre-commit). It is written and
covered by `tests/dispatch_test.sh`, but the installer does not wire it.

Promotion criteria: a rule demonstrably violated from outside the agent
(a human terminal, another tool) that a git hook would have caught.
