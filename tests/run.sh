#!/bin/sh
# git-agent-guard test runner.
#
# HARD RULE: tests never touch real state. Every test runs inside a throwaway
# HOME with git configuration pinned to sandbox files. Nothing is seeded from
# the real HOME — a sandbox holding a copy of real settings is how a sibling
# kit once modified the real store through an absolute path (memory-kit PR #42).

set -u

root=$(cd "$(dirname "$0")/.." && pwd)
pass=0; fail=0

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/gag-test.XXXXXX")
trap 'rm -rf "$sandbox"' EXIT
export HOME="$sandbox/home"
export XDG_CONFIG_HOME="$sandbox/home/.config"
export GIT_CONFIG_GLOBAL="$sandbox/home/.gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="$sandbox"
mkdir -p "$HOME"
git config --global user.email test@example.invalid
git config --global user.name gag-test
git config --global init.defaultBranch main

# Containment assertion: the sandbox HOME must not be the real one.
case "$HOME" in "$sandbox"/*) : ;; *) echo "FATAL: sandbox HOME escaped"; exit 99 ;; esac

t() { # t <name> <expected-rc> <check> <command-string>
    _name=$1; _want=$2; _check=$3; _cmd=$4
    "$root/core/checks/$_check" "$_cmd" > /dev/null 2>&1
    _got=$?
    if [ "$_got" -eq "$_want" ]; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); echo "FAIL: $_name (want rc=$_want got rc=$_got)"
    fi
}

# --- staging-separation ---------------------------------------------------
t "chained add+commit denied"        1 staging-separation.sh 'git add -A && git commit -m "x"'
t "semicolon chain denied"           1 staging-separation.sh 'git add .; git commit -m "x"'
t "git -C chain denied"              1 staging-separation.sh 'git -C /tmp/repo add -A && git -C /tmp/repo commit -m "x"'
t "add alone allowed"                0 staging-separation.sh 'git add -A'
t "commit alone allowed"             0 staging-separation.sh 'git commit -m "msg"'
t "verbs only in message allowed"    0 staging-separation.sh 'git commit -m "git add and git commit docs"'
t "verbs only in grep allowed"       0 staging-separation.sh 'grep -r "git add && git commit" docs/'
t "path containing add allowed"      0 staging-separation.sh 'git status && cat notes/add-commit.md'
t "heredoc body with verbs allowed" 0 staging-separation.sh 'cat > t.sh <<EOF
git add f.txt && git commit -qm init
EOF'
t "heredoc quoted tag allowed"      0 staging-separation.sh 'cat > t.sh <<'"'"'SH'"'"'
git add . && git commit -m x
SH'
t "real chain after heredoc denied"  1 staging-separation.sh 'cat > t.sh <<EOF
hello
EOF
git add -A && git commit -m "x"'
t "empty command allowed"            0 staging-separation.sh ''

# --- pr-merge ---------------------------------------------------------------
t "gh pr merge denied"               1 pr-merge.sh 'gh pr merge 42 --squash'
t "chained gh pr merge denied"       1 pr-merge.sh 'git push && gh pr merge 42'
t "gh api merge endpoint denied"     1 pr-merge.sh 'gh api -X PUT repos/o/r/pulls/42/merge'
t "gh pr view allowed"               0 pr-merge.sh 'gh pr view 42 --json state'
t "gh pr create allowed"             0 pr-merge.sh 'gh pr create --title t --body b'
t "merge only in message allowed"    0 pr-merge.sh 'git commit -m "gh pr merge is forbidden"'
t "git merge allowed (local)"        0 pr-merge.sh 'git merge feature-branch'

echo "----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
