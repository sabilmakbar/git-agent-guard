#!/bin/sh
# attribution-decision check + gag-attribution helper. Sandboxed HOME and repo.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
pass=0; fail=0
sandbox=$(mktemp -d "${TMPDIR:-/tmp}/gag-attr.XXXXXX")
trap 'rm -rf "$sandbox"' EXIT
export HOME="$sandbox/home"
export XDG_CONFIG_HOME="$sandbox/home/.config"
export GIT_CONFIG_GLOBAL="$sandbox/home/.gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="$sandbox"
mkdir -p "$HOME"
git config --global user.email t@example.invalid
git config --global user.name t
git config --global init.defaultBranch main

seed() { # <dir> <file>
    git init -q "$1"
    printf 'a\n' > "$1/$2"
    git -C "$1" add "$2"
    git -C "$1" commit -qm init
}

repo="$sandbox/repo"; seed "$repo" f.txt
check="$root/core/checks/attribution-decision.sh"
helper="$root/bin/gag-attribution"

t() { # <name> <want-rc> <cmd>
    ( cd "$repo" && "$check" "$3" >/dev/null 2>&1 )
    g=$?
    if [ "$g" -eq "$2" ]; then pass=$((pass+1)); else
        fail=$((fail+1)); echo "FAIL: $1 (want $2 got $g)"; fi
}

ok() { # <name> <cond-rc>
    if [ "$2" -eq 0 ]; then pass=$((pass+1)); else
        fail=$((fail+1)); echo "FAIL: $1"; fi
}

t "undecided repo asks on commit"  3 'git commit -m "x"'
t "non-commit command passes"      0 'git status'

( cd "$repo" && "$helper" exclude >/dev/null 2>&1 )
t "after exclude, silent"          0 'git commit -m "x"'
[ ! -f "$repo/.claude/settings.local.json" ]; ok "exclude wrote no repo settings" $?

( cd "$repo" && "$helper" include >/dev/null 2>&1 )
t "after include, silent"          0 'git commit -m "x"'
grep -q 'Co-Authored-By' "$repo/.claude/settings.local.json" 2>/dev/null
ok "include wrote the trailer setting" $?
[ "$(jq -r .attribution.pr "$repo/.claude/settings.local.json" 2>/dev/null)" = 'Generated with [Claude Code](https://claude.com/claude-code)' ]
ok "include wrote the PR footer setting" $?

# include merges into an existing local settings file, keeping other keys
printf '{"permissions": {"allow": ["Bash(ls)"]}}\n' > "$repo/.claude/settings.local.json"
( cd "$repo" && "$helper" include >/dev/null 2>&1 )
jq -e '.permissions.allow[0] == "Bash(ls)" and (.attribution.commit | test("Co-Authored-By")) and (.attribution.pr | test("Claude Code"))' \
  "$repo/.claude/settings.local.json" >/dev/null 2>&1
ok "include merges, keeping other keys" $?

# a decision is replaced, never accumulated
n=$(grep -c . "$XDG_CONFIG_HOME/git-agent-guard/attribution-decisions")
[ "$n" -eq 1 ]; ok "decisions file holds one line, not two" $?

# an unrelated repo is still asked
repo2="$sandbox/repo2"; seed "$repo2" g.txt
( cd "$repo2" && "$check" 'git commit -m "x"' >/dev/null 2>&1 )
[ $? -eq 3 ]; ok "second repo still asked" $?

# the helper refuses outside a repository
( cd "$sandbox" && "$helper" include >/dev/null 2>&1 )
[ $? -eq 2 ]; ok "helper refuses outside a repo" $?

echo "----"; echo "pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
