# Changelog

Notable changes, newest first. Versions identify tagged states of this repository;
the guard runs from its checkout and does not depend on the sibling kits' versions.

## 0.1.0

First release of git-agent-guard. It provides a Claude Code PreToolUse adapter and
portable shell checks for Git workflow decisions, with managed and advisory modes.
The generic `AGENTS.md` snippet supplies guidance for other agents but does not
enforce the checks.

- Separates staging from committing, asks about newly tracked files, and prevents
  agent-initiated pull request merges.
- Checks branch deletion for unmerged or unpushed work and WIP stashes, including
  branches whose changes reached the base through rebase or squash ([#1](https://github.com/sabilmakbar/git-agent-guard/pull/1)).
- Detects hidden Git invocations and asks before privilege escalation; optional
  checks cover remote-specific identity and repository attribution policy ([#2](https://github.com/sabilmakbar/git-agent-guard/pull/2)).
- Installs the Claude Code hook without replacing unrelated settings, runs its test
  suites before installation, and provides a documented uninstall path.
