# git-agent-guard

AI coding agents are decent at writing code and careless with git. Not
destructive, careless: they chain staging and committing so you never review
what got staged, quietly track files you meant to keep local, merge PRs that
were only supposed to be opened, and sign commits with whichever identity the
machine had lying around.

Destruction guards exist ([dcg](https://github.com/Dicklesworthstone/destructive_command_guard),
[agent-guardrails](https://github.com/roboticforce/agent-guardrails)) and stop
`rm -rf` and force-pushes. This kit governs the workflow instead: how work is
allowed to enter history. The two compose; run both.

The motivation is measured, not felt: across 38 real agent sessions, 286 of
488 staging commands chained straight into a commit — a written rule the
agent "knew" and followed 41% of the time. Rules in a prompt fade; a hook
fires every time.

## What it enforces

| Rule | Behavior |
|---|---|
| Stage and commit are two separate approvals | deny chained `add`+`commit` |
| Agents open PRs, humans merge them | deny `gh pr merge` and API merge calls |
| A first-time-tracked file needs its own yes | ask, listing the files |
| No branch deletion with work still on it | deny unless merged, pushed, no stash |
| The right identity for the right remote | deny mismatched `user.email` on push (opt-in map) |
| No agent-attribution footers in commits/PRs | native `attribution` setting, set at install |

Two modes, chosen at install, never defaulted: **managed** blocks, **advisory**
warns and lets the command through.

## How it works

One PreToolUse hook on the Bash tool (Claude Code, v1). The adapter extracts
the command, exits fast when it isn't git/gh-shaped, and runs each check in
`core/checks/`. Checks are plain POSIX sh taking the command string as `$1`:
exit 0 pass, 1 deny, 3 ask-the-user. Quoted spans are stripped before verb
matching, so a commit message that *mentions* forbidden commands passes.

Checks that need repo state (staged files, ancestry, stashes) run read-only
git queries at hook time.

The core is tool-agnostic on purpose. Other agent CLIs can get thin adapters
(see `adapters/`), and a git-hook layer for non-agent coverage is written but
deliberately not wired in v1 (`dispatcher/README.md`).

## Install

Requires `jq`. The installer edits `~/.claude/settings.json`: it backs the
file up first, refuses to run if the JSON is invalid, only ever adds its own
entries, and uninstall removes exactly what the manifest says it wrote.
The test suites run first; a failing suite aborts the install.

```sh
git clone https://github.com/sabilmakbar/git-agent-guard
cd git-agent-guard
./install.sh --mode managed --dry-run   # see the plan
./install.sh --mode managed
```

Uninstall: `./install.sh --uninstall`.

Identity checking is opt-in. Create
`~/.config/git-agent-guard/identities` with one mapping per line:

```
github.com/your-org  you@work.example
github.com/yourname  you@personal.example
```

An unmapped remote asks; no file at all disables the check.

## Known limits

- Agent-layer only (v1): commands typed by a human in a terminal are not
  checked. The git-hook layer exists in-tree for later promotion.
- Command parsing is textual. Exotic shapes (scripts that call git, aliases,
  heredoc bodies containing git commands) can produce false positives or
  negatives; every check ships a test corpus and fails open on its own bugs.
- Claude Code is the only wired adapter today. The check contract is three
  exit codes and a string — adapters for other tools are small.

## Tests

```sh
for t in tests/*.sh; do "$t"; done
```

Every suite runs in a throwaway `HOME` with git config pinned to sandbox
files (`GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`, `GIT_CEILING_DIRECTORIES`).
Tests never touch real repositories or real settings.

## License

MIT
