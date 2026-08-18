# git-agent-guard

[![tests](https://github.com/sabilmakbar/git-agent-guard/actions/workflows/tests.yml/badge.svg)](https://github.com/sabilmakbar/git-agent-guard/actions/workflows/tests.yml)

An AI coding agent that writes good code can still be careless with git. It chains
staging into committing, so you never review what got staged. It quietly tracks files
you meant to keep local. It merges a PR it was only asked to open. It pushes with
whichever identity the machine had lying around. This kit stops each of those at the
moment it is attempted, before the command runs.

It is plain POSIX shell plus `jq`. No server, no telemetry, nothing to build.

The reason it exists is measured rather than felt. Across 38 real agent sessions, 286
of 488 staging commands chained straight into a commit: a written rule the agent knew,
followed 41% of the time. A rule in a prompt fades as the session grows. A hook fires
every time.

Guards against destructive commands already exist and are good:
[dcg](https://github.com/Dicklesworthstone/destructive_command_guard) and
[agent-guardrails](https://github.com/roboticforce/agent-guardrails) stop `rm -rf` and
force-pushes. This kit governs the workflow instead: how work is allowed to enter
history. The two kinds compose, and running both is sensible.

## What you get

| Rule | What happens |
|---|---|
| Stage and commit are two separate approvals | a chained `add` and `commit` is refused, with the fix in the message |
| Agents open PRs, humans merge them | `gh pr merge` and API merge calls are refused |
| A first-time-tracked file needs its own yes | the commit pauses and asks, listing the files |
| No deleting a branch with work still on it | refused unless merged, pushed, and no stash names it |
| The right identity for the right remote | a push with the wrong `user.email` is refused (opt-in, see below) |
| No agent-attribution footers | covered by a native setting, written at install |

Every check runs before the command does, from one hook on the agent's shell tool.
Claude Code is the wired adapter today. The checks themselves are tool-agnostic
scripts with a three-exit-code contract, so adapters for other agent CLIs are small,
and `adapters/generic/` has the rules as plain guidance for tools that cannot run
hooks at all.

A command that merely mentions a forbidden shape passes: quoted spans are stripped
before matching, so a commit message or grep pattern containing the words `git add`
trips nothing.

## Two modes, and you must pick one

`managed` blocks. `advisory` runs the same checks, prints the same message, and lets
the command through. The installer refuses to run without `--mode`, because whether an
agent gets blocked or warned is a policy about your machine, and a default would be
the kit deciding it for you.

Advisory is the right first week on a new machine: you see what would have been
blocked before anything actually is. It is also the escape hatch if a check misfires
on a command shape the parser gets wrong. Flip the mode in
`~/.config/git-agent-guard/config`, one line, no reinstall.

## Install

**Read this first: the installer edits `~/.claude/settings.json`.** That file is your
global Claude Code config, shared with every other tool you have installed. The kit
writes to it because a hook entry there is the only way to run before every command.

Three things make that safe, and none of them is good intentions. The test suites run
first and a failing suite aborts the install with nothing written. Your settings file
is then checked: invalid JSON stops the run and your file is untouched. Past that, the
merge only ever adds its own entry, a backup is taken first, and uninstall removes
exactly what a manifest says the kit wrote, never another tool's entries. `--dry-run`
shows the plan without doing any of it.

You need `jq`.

```bash
git clone https://github.com/sabilmakbar/git-agent-guard.git ~/git-agent-guard
~/git-agent-guard/install.sh --mode managed     # or --mode advisory
```

The kit runs from the clone, so keep the folder where you cloned it. Hooks apply from
your next Claude Code session, not the current one.

The install also sets Claude Code's `attribution` keys empty, which is the native way
to keep agent footers out of commit messages and PR bodies. If you already have
`attribution` set to something, the installer reports it and leaves yours alone.

### Identity checking is opt-in

The identity check needs to know which email belongs to which remote, and only you
know that. Create `~/.config/git-agent-guard/identities` with one mapping per line:

```
github.com/your-org   you@work.example
github.com/yourname   you@personal.example
```

The left column is any substring of the remote URL. With the file in place, a push
from a repo whose `user.email` does not match its remote's line is refused, and a push
to a remote no line covers pauses and asks. No file at all means the check is off.

## What you will notice day to day

Mostly nothing. The checks are silent on every command that follows the rules.

When the agent breaks a rule in managed mode, it is not you who gets interrupted: the
agent receives the refusal and its message, corrects itself, and carries on. A chained
stage-and-commit becomes two separate calls a few seconds later, without you touching
anything.

The two asking checks are different, and pausing you is their job. A commit that
tracks a new file for the first time, and a push to a remote your identities file does
not cover, both stop and wait for your answer, because those decisions are yours and
not the agent's.

## Is it working?

Pipe a rule-breaking command at the adapter and watch it refuse:

```bash
printf '{"tool_input":{"command":"git add -A && git commit -m x"}}' \
  | ~/git-agent-guard/adapters/claude-code/pretooluse.sh | jq -r .hookSpecificOutput.permissionDecision
```

`deny` is the answer you want (`ask` and empty output are what compliant commands
get). The same one-liner with `"ls"` as the command should print nothing at all.

## Good to know

- **Agent-layer only, on purpose.** Commands a human types in a terminal are not
  checked. A git-hook layer that would cover those exists in the tree, written and
  tested, but is deliberately not wired in v1; `dispatcher/README.md` says what would
  justify promoting it.
- **Parsing is textual and honest about it.** Exotic shapes (scripts that call git,
  aliases, heredoc bodies containing git commands) can produce false positives or
  negatives. Every check ships a test corpus, and a check that errors on its own bug
  is treated as a pass rather than locking you out.
- **Checks that need repo state read only.** The new-file and branch checks run
  read-only git queries at hook time and never modify anything.
- Works on macOS (bash 3.2, BSD tools) and Linux. CI runs the suites on both.

## FAQ

**Doesn't blocking things ruin fully automatic runs?** The refusing checks do not: the
agent gets the message, fixes the shape, and continues without a human in the loop.
The asking checks genuinely pause the run, and that is what they are for, since they
guard decisions that belong to you. If an unattended run must not pause, switch to
advisory mode for its duration.

**Does it work with agents other than Claude Code?** The checks are plain scripts that
take a command string and answer with an exit code, so any tool with a pre-execution
hook can drive them; only the thin adapter is Claude-specific. Tools with no hook
support get `adapters/generic/AGENTS-snippet.md`, the same rules as standing
guidance, with none of the enforcement.

**Why not git hooks instead?** Git hooks would also catch commands from humans and
other tools, but git only reads hooks from one place, and on real machines that place
is often already claimed by husky or pre-commit. v1 avoids the conflict entirely by
staying at the agent layer. The git-layer dispatcher in the tree chains to a repo's
existing hooks rather than replacing them, and is ready if the need is ever
demonstrated.

**What if a check is wrong about my command?** Flip to advisory mode in
`~/.config/git-agent-guard/config` and the same check becomes a warning. Then please
open an issue with the command shape; every check's test corpus grows from exactly
these reports.

**Does anything leave my machine?** No. There is no network code anywhere in the kit.

## Uninstall

```bash
~/git-agent-guard/install.sh --uninstall
```

Takes the kit's hook entry back out of `~/.claude/settings.json`, removes the
`attribution` keys only if the kit was the one that set them, and deletes the kit's
config and manifest. Hooks it did not write are not touched. A backup of your
settings from just before the removal is left next to the file. Your identities file
stays, since you wrote it.

## Working on the kit

```bash
for t in tests/*.sh; do "$t"; done
```

Every suite runs in a throwaway `HOME` with git configuration pinned to sandbox files,
so the tests never touch your real repositories or settings, and refuse to run if the
sandbox does not hold. The same suites gate every install.

## Related projects

- **[claude-memory-kit](https://github.com/sabilmakbar/claude-memory-kit)**: keeps the
  preferences you teach Claude across sessions and machines. This kit's install
  conventions come from it.
- **[claude-session-kit](https://github.com/sabilmakbar/claude-session-kit)**: gives
  sessions real names, notes and clean handoffs.
- **[dcg](https://github.com/Dicklesworthstone/destructive_command_guard)** and
  **[agent-guardrails](https://github.com/roboticforce/agent-guardrails)**: the
  destruction-prevention side of the same problem. Run one of them alongside this.

MIT licensed, see [LICENSE](LICENSE).
