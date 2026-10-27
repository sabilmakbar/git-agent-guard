#!/bin/sh
# Claude Code adapter tests: JSON in -> deny/allow/advisory JSON out. Sandboxed.

set -u
root=$(cd "$(dirname "$0")/.." && pwd)
pass=0; fail=0

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/gag-atest.XXXXXX")
trap 'rm -rf "$sandbox"' EXIT
export HOME="$sandbox/home"
export XDG_CONFIG_HOME="$sandbox/home/.config"
mkdir -p "$HOME"

adapter="$root/adapters/claude-code/pretooluse.sh"

# Work inside a sandbox repo whose attribution decision is already recorded, so
# the one-time attribution ask does not confound every commit-shaped case.
export GIT_CONFIG_GLOBAL="$sandbox/home/.gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="$sandbox"
git config --global user.email t@example.invalid
git config --global user.name t
git config --global init.defaultBranch main
git init -q "$sandbox/repo"
mkdir -p "$XDG_CONFIG_HOME/git-agent-guard"
printf '%s exclude\n' "$(git -C "$sandbox/repo" rev-parse --show-toplevel)" \
  > "$XDG_CONFIG_HOME/git-agent-guard/attribution-decisions"
cd "$sandbox/repo" || exit 1

emit() { jq -n --arg c "$1" '{tool_input: {command: $c}}'; }

t() { # <name> <expect: deny|allow|advisory> <command>
    _name=$1; _want=$2; _cmd=$3
    _out=$(emit "$_cmd" | "$adapter")
    _dec=$(printf '%s' "$_out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    _ctx=$(printf '%s' "$_out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
    _got=allow
    [ "$_dec" = "deny" ] && _got=deny
    [ "$_dec" = "ask" ] && _got=ask
    [ -n "$_ctx" ] && _got=advisory
    if [ "$_got" = "$_want" ]; then pass=$((pass+1)); else
        fail=$((fail+1)); echo "FAIL: $_name (want $_want got $_got)"; fi
}

t "chained add+commit denied"   deny  'git add -A && git commit -m "x"'
t "gh pr merge denied"          deny  'gh pr merge 7'
t "plain add allowed"           allow 'git add -A'
t "non-git command allowed"     allow 'ls -la'
t "gh pr view allowed"          allow 'gh pr view 7 --json state'
t "path-qualified git reaches checks" deny '/usr/bin/git add -A && /usr/bin/git commit -m "x"'
t "git in \$( ) reaches checks"    deny 'echo $(git rev-parse HEAD)'
t "git in sh -c reaches checks"    deny "sh -c 'git status'"
t "sudo on any command asks"       ask   'sudo make install'
t "sudo git: deny outranks ask"    deny  'sudo git pull'
t "sudo sh -c git: deny wins"      deny  "sudo sh -c 'git status'"
t "word sudo as data allowed"      allow "grep -r 'sudo' docs/"

# deny must outrank a co-firing ask: undecided repo (ask) + chained call (deny)
git init -q "$sandbox/undecided"
( cd "$sandbox/undecided" && printf 'a\n' > f.txt && git add f.txt && git commit -qm init ) >/dev/null 2>&1
cd "$sandbox/undecided" || exit 1
echo ATTRIBUTION_CHECK=on > "$XDG_CONFIG_HOME/git-agent-guard/config"
t "deny outranks ask"           deny  'git add -A && git commit -m "x"'
t "lone ask still asks"         ask   'git commit -m "x"'
rm -f "$XDG_CONFIG_HOME/git-agent-guard/config"
t "attribution ask is opt-in"   allow 'git commit -m "x"'
cd "$sandbox/repo" || exit 1

mkdir -p "$XDG_CONFIG_HOME/git-agent-guard"
echo MODE=advisory > "$XDG_CONFIG_HOME/git-agent-guard/config"
t "advisory mode warns not denies" advisory 'git add -A && git commit -m "x"'
t "advisory mode hints on sudo"   advisory 'sudo make install'

echo MODE=off > "$XDG_CONFIG_HOME/git-agent-guard/config"
t "off lets a violation through"   allow 'git add -A && git commit -m "x"'

# Fail safe: only the exact spellings turn blocking down, so a typo in this
# file cannot silently disable the guard.
echo MODE=of > "$XDG_CONFIG_HOME/git-agent-guard/config"
t "typo in MODE still denies"      deny  'git add -A && git commit -m "x"'
echo MODE=OFF > "$XDG_CONFIG_HOME/git-agent-guard/config"
t "wrong case still denies"        deny  'git add -A && git commit -m "x"'
echo "MODE=advisory # note" > "$XDG_CONFIG_HOME/git-agent-guard/config"
t "trailing text is not advisory"  deny  'git add -A && git commit -m "x"'
rm -f "$XDG_CONFIG_HOME/git-agent-guard/config"
t "missing config denies"          deny  'git add -A && git commit -m "x"'

echo "----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
