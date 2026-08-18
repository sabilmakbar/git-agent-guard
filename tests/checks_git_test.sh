#!/bin/sh
# Tests for checks that query real git state: new-track, branch-delete,
# push-identity. All git activity happens in sandboxed throwaway repos.

set -u
root=$(cd "$(dirname "$0")/.." && pwd)
pass=0; fail=0

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/gag-gtest.XXXXXX")
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

t() { # <name> <want-rc> <check> <cmd> ; runs from $workdir
    _n=$1; _w=$2; _c=$3; _cmd=$4
    ( cd "$workdir" && "$root/core/checks/$_c" "$_cmd" >/dev/null 2>&1 )
    _g=$?
    if [ "$_g" -eq "$_w" ]; then pass=$((pass+1)); else
        fail=$((fail+1)); echo "FAIL: $_n (want $_w got $_g)"; fi
}

# --- fixture: origin bare repo + clone with history ------------------------
origin="$sandbox/origin.git"; git init -q --bare "$origin"
repo="$sandbox/repo"; git init -q "$repo"; workdir="$repo"
( cd "$repo" && echo a > f.txt && git add f.txt && git commit -qm init \
  && git remote add origin "$origin" && git push -qu origin main ) >/dev/null 2>&1

# --- new-track --------------------------------------------------------------
( cd "$repo" && echo b >> f.txt && git add f.txt )
t "modified tracked file passes"   0 new-track.sh 'git commit -m "edit"'
( cd "$repo" && echo n > brand-new.txt && git add brand-new.txt )
t "newly tracked file asks"        3 new-track.sh 'git commit -m "edit"'
t "non-commit command passes"      0 new-track.sh 'git status'
( cd "$repo" && git commit -qm "seed" )   # clear staged state

# --- branch-delete ----------------------------------------------------------
( cd "$repo" && git checkout -qb merged-branch && echo m > m.txt && git add m.txt \
  && git commit -qm m && git checkout -q main && git merge -q merged-branch \
  && git push -q origin main ) >/dev/null 2>&1
t "fully merged branch passes"     0 branch-delete.sh 'git branch -d merged-branch'
( cd "$repo" && git checkout -qb unmerged-branch && echo u > u.txt && git add u.txt \
  && git commit -qm u && git checkout -q main ) >/dev/null 2>&1
t "unmerged branch denied"         1 branch-delete.sh 'git branch -D unmerged-branch'
t "remote delete unmerged denied"  1 branch-delete.sh 'git push origin --delete unmerged-branch'
( cd "$repo" && git checkout -q merged-branch && echo s > s.txt && git stash -qu \
  && git checkout -q main ) >/dev/null 2>&1
t "stash on branch denied"         1 branch-delete.sh 'git branch -d merged-branch'
( cd "$repo" && git stash drop -q ) >/dev/null 2>&1
t "non-delete branch cmd passes"   0 branch-delete.sh 'git branch --list'
t "plain push passes"              0 branch-delete.sh 'git push origin main'

# --- push-identity ----------------------------------------------------------
t "no identities file: disabled"   0 push-identity.sh 'git push origin main'
mkdir -p "$XDG_CONFIG_HOME/git-agent-guard"
printf '%s\n' "$sandbox test@example.invalid" > "$XDG_CONFIG_HOME/git-agent-guard/identities"
t "matching identity passes"       0 push-identity.sh 'git push origin main'
printf '%s\n' "$sandbox work@corp.invalid" > "$XDG_CONFIG_HOME/git-agent-guard/identities"
t "identity mismatch denied"       1 push-identity.sh 'git push origin main'
printf '%s\n' "no-such-host.invalid x@y.invalid" > "$XDG_CONFIG_HOME/git-agent-guard/identities"
t "unmapped remote asks"           3 push-identity.sh 'git push origin main'
t "non-push passes"                0 push-identity.sh 'git fetch origin'

echo "----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
