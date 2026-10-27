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
| Stage and commit are two separate approvals | a chained `add` and `commit`, `commit -a`, or a commit that names paths is refused, with the fix in the message |
| Agents open PRs, humans merge them | `gh pr merge` and API merge calls are refused |
| A first-time-tracked file needs its own yes | the commit pauses and asks, listing the files |
| No deleting a branch with work still on it | refused unless merged, pushed, and no stash names it |
| The right identity for the right remote | a push with the wrong `user.email` is refused (opt-in, see below) |
| git runs where the guard can see it | git or gh inside `sh -c`, `eval`, `$( )`, backticks, `xargs`, a grouping, or under `sudo` is refused (read-only queries in `$( )` and groupings excepted) |
| Elevated privileges are the user's call, for any command | `sudo`, `doas`, `su`, `pkexec` or `run0` pauses and asks, wherever it runs |
| Each repo decides whether commits disclose AI assistance | the first commit in an undecided repo pauses and asks, once (opt-in) |

Every check runs before the command does, from one hook on the agent's shell tool.
Claude Code is the wired adapter today. The checks themselves are tool-agnostic
scripts with a three-exit-code contract, so adapters for other agent CLIs are small,
and `adapters/generic/` has the rules as plain guidance for tools that cannot run
hooks at all.

Hidden git has one exception. Reading a value is the everyday use of `$( )`,
backticks and `( )` or `{ }` groupings, as in `v=$(git rev-parse HEAD)` or
`(cd ~/x && git status)`, so a read-only query is allowed there: an allowlist of
verbs (`status`, `log`, `diff`, `rev-parse`, listing forms of `branch`, `tag` and
`config`, `gh pr view`, a GET `gh api`, and similar), with anything unrecognized or
able to write, such as `diff --output`, still refused. Opaque launchers get no
exception: `sh -c`, `eval`, `xargs`, `exec`, `nohup`, `find -exec`, a script fed to a
shell, and anything under `sudo` stay refused whatever the verb.

The elevation check is the one rule that is not about git: it applies to every
command the agent runs. A launcher counts wherever it actually executes: after `;`,
`&&` or a pipe, behind `env`, `xargs` or `time`, inside `sh -c`, `eval`, `$( )`,
backticks or a grouping. Elevation is asked about rather than refused, since
installing a package or editing a system file can be legitimate; git itself under
`sudo` is refused outright, and that refusal wins over the question.

A command that merely mentions a forbidden shape passes: quoted spans and heredoc
bodies are stripped before matching, so a commit message, a grep pattern, or a script
you are writing whose contents contain `git add ... && git commit` trips nothing.
The exception is text the shell would execute anyway: `$( )` and backticks inside
double quotes or an unquoted heredoc still run, so they are checked.

## Two modes, and you must pick one

`managed` blocks. `advisory` runs the same checks, prints the same message, and lets
the command through. The installer refuses to run without `--mode`, because whether an
agent gets blocked or warned is a policy about your machine, and a default would be
the kit deciding it for you.

Advisory is the right first week on a new machine: you see what would have been
blocked before anything actually is. It is also the escape hatch if a check misfires
on a command shape the parser gets wrong. Flip the mode in
`~/.config/git-agent-guard/config`, one line, no reinstall.

There is a third value you set by hand rather than at install, `MODE=off`, which
skips every check without uninstalling anything. Use it to get out of the way for a
while; use `--uninstall` when you mean it permanently.

Only the exact lowercase spellings `advisory` and `off` turn blocking down. A typo,
a trailing comment, or a missing config file all read as `managed`, because a guard
you can disable by misspelling its own setting fails open without telling you.
Turning the kit off also leaves the repository's own git hooks alone: whatever husky
or pre-commit installed there keeps running.

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
git clone --branch v0.1.0 https://github.com/sabilmakbar/git-agent-guard.git ~/git-agent-guard
~/git-agent-guard/install.sh --mode managed     # or --mode advisory
```

The kit runs from the clone, so keep the folder where you cloned it. Hooks apply from
your next Claude Code session, not the current one.

The checkout is pinned to a release tag. To upgrade when a newer release is available,
fetch tags and check out that release, replacing `vX.Y.Z` with its tag:

```bash
git -C ~/git-agent-guard fetch --tags
git -C ~/git-agent-guard checkout vX.Y.Z
~/git-agent-guard/install.sh --mode managed  # or advisory, as chosen at install
```

`git pull` does not update a tag-pinned checkout. The [changelog](CHANGELOG.md)
records what each release contains.

The install does not touch Claude Code's `attribution` keys. Whether commits and PR
bodies carry an agent footer is your policy, or your organization's, and some
organizations require one; the kit has no business suppressing it.

### Whether commits say they were AI-assisted is decided per repo

Your global `attribution` setting is the starting position, not necessarily the
answer: the choice can belong to the project. With the check turned on, the first
commit in a repo with no recorded decision pauses and asks, once, and never again for
that repo. It is off by default, since many setups already have the answer decided
for them; turn it on with one line in `~/.config/git-agent-guard/config`:

```
ATTRIBUTION_CHECK=on
```

Only the exact lowercase `on` enables it. Anything else, including a missing line,
reads as off. The helper below works either way.

```bash
bin/gag-attribution include    # commits carry a Co-Authored-By trailer, PRs a footer
bin/gag-attribution exclude    # they do not
bin/gag-attribution default    # defer to the global setting, stop asking
```

Both directions are defensible, which is exactly why it is asked rather than
assumed. A trailer discloses AI involvement to reviewers and makes the history
greppable later, and disclosure is the friendlier default in your own projects. It
is also permanent, and some projects' contribution policies reject AI-attributed
commits outright, so a trailer can get a pull request bounced.

`include` pins a generic trailer, `Co-Authored-By: Claude <noreply@anthropic.com>`,
rather than letting Claude Code use its own default. Its default names the model
("Claude Sonnet 5", "Claude Haiku 4.5"), so a repo left to it accumulates a
different co-author identity per model and per model release, and the history stops
being greppable by one name.

It sets the PR-body footer as well, to
`Generated with [Claude Code](https://claude.com/claude-code)`, so pull requests from
that repo disclose the same way its commits do.

`include` writes `.claude/settings.local.json` in that repo, which overrides the
global setting for that repo only. That file is the per-machine, untracked one, so
the decision never enters the project's history; if it is not gitignored where you
run it, the command says so rather than editing `.gitignore` for you.

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

The asking checks are different, and pausing you is their job. A commit that tracks a
new file for the first time, any command run with `sudo` or another elevation
launcher, the first commit in a repo whose attribution decision has not been made
(when that check is on), and a push to a remote your identities file does not cover
all stop and wait for your answer, because those decisions are yours and not the
agent's. When two checks fire at once, a refusal is what you see: a hard violation
outranks a pending decision.

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
  read-only git queries at hook time and never modify anything. The branch check
  builds a throwaway commit to recognise squashed work, and writes it to a scratch
  directory so the repository it is inspecting is left untouched.
- **A branch merged by rebase or squash can still be deleted.** Those merges put
  the content on the base under a new SHA, so ancestry alone would refuse forever.
  The check compares patches when ancestry fails, and refuses only when something
  on the branch is genuinely absent from the base.
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

Takes the kit's hook entry back out of `~/.claude/settings.json` and deletes the
kit's config and manifest. Older versions of the installer set the `attribution`
keys; if yours did, uninstall says so and leaves them for you to keep or remove.
Hooks it did not write are not touched. A backup of your settings from just before
the removal is left next to the file. Your identities file stays, since you wrote it.

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
