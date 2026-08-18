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

emit() { jq -n --arg c "$1" '{tool_input: {command: $c}}'; }

t() { # <name> <expect: deny|allow|advisory> <command>
    _name=$1; _want=$2; _cmd=$3
    _out=$(emit "$_cmd" | "$adapter")
    _dec=$(printf '%s' "$_out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    _ctx=$(printf '%s' "$_out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
    _got=allow
    [ "$_dec" = "deny" ] && _got=deny
    [ -n "$_ctx" ] && _got=advisory
    if [ "$_got" = "$_want" ]; then pass=$((pass+1)); else
        fail=$((fail+1)); echo "FAIL: $_name (want $_want got $_got)"; fi
}

t "chained add+commit denied"   deny  'git add -A && git commit -m "x"'
t "gh pr merge denied"          deny  'gh pr merge 7'
t "plain add allowed"           allow 'git add -A'
t "non-git command allowed"     allow 'ls -la'
t "gh pr view allowed"          allow 'gh pr view 7 --json state'

mkdir -p "$XDG_CONFIG_HOME/git-agent-guard"
echo MODE=advisory > "$XDG_CONFIG_HOME/git-agent-guard/config"
t "advisory mode warns not denies" advisory 'git add -A && git commit -m "x"'

echo "----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
