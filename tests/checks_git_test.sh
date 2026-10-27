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
# remote deletes: the remote name must never be read as the branch
t "push --delete after remote"     1 branch-delete.sh 'git push origin --delete unmerged-branch'
t "push --delete before remote"    1 branch-delete.sh 'git push --delete origin unmerged-branch'
t "push -d before remote"          1 branch-delete.sh 'git push -d origin unmerged-branch'
t "push -d after remote"           1 branch-delete.sh 'git push origin -d unmerged-branch'
t "push clustered -fd"             1 branch-delete.sh 'git push -fd origin unmerged-branch'
t "push :branch"                   1 branch-delete.sh 'git push origin :unmerged-branch'
t "push :refs/heads/branch"        1 branch-delete.sh 'git push origin :refs/heads/unmerged-branch'
t "push -d second of two branches" 1 branch-delete.sh 'git push origin -d merged-branch unmerged-branch'
t "push -d with globals, -o value" 1 branch-delete.sh 'git -c a=b push -o ci.skip origin -d unmerged-branch'
t "push -d merged branch passes"   0 branch-delete.sh 'git push -d origin merged-branch'
t "push :merged branch passes"     0 branch-delete.sh 'git push origin :merged-branch'
t "push -u not a delete"           0 branch-delete.sh 'git push -u origin unmerged-branch'
t "push --dry-run not a delete"    0 branch-delete.sh 'git push --dry-run origin unmerged-branch'
t "push src:dst not a delete"      0 branch-delete.sh 'git push origin unmerged-branch:other'
t "delete only in later cmd"       0 branch-delete.sh 'git push origin unmerged-branch; echo -d'

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

# --- branch-delete: history-rewriting merges --------------------------------
# A rebase, squash or cherry-pick puts the branch's content on the base under a
# new SHA, so ancestry is false even though nothing would be stranded. Each
# scenario gets its own repo with its own bare origin.

mkrw() { # <name> -> $rwrepo, a clone with origin/main and a feat branch off base
    rwrepo="$sandbox/rw-$1"
    git init -q --bare "$rwrepo.origin"
    git init -q "$rwrepo"
    git -C "$rwrepo" remote add origin "$rwrepo.origin"
    printf 'base\n' > "$rwrepo/f.txt"
    git -C "$rwrepo" add f.txt
    git -C "$rwrepo" commit -qm base
    git -C "$rwrepo" push -qu origin main
    git -C "$rwrepo" checkout -qb feat
}

sync_origin() { git -C "$1" push -q origin main; git -C "$1" fetch -q origin; }

rt() { # <name> <want-rc> <repo> ; delete of 'feat' in that repo
    _n=$1; _w=$2; _r=$3
    ( cd "$_r" && "$root/core/checks/branch-delete.sh" 'git branch -d feat' >/dev/null 2>&1 )
    _g=$?
    if [ "$_g" -eq "$_w" ]; then pass=$((pass+1)); else
        fail=$((fail+1)); echo "FAIL: $_n (want $_w got $_g)"; fi
}

# rebase-merge: the contribution is replayed onto main, branch left behind
mkrw rebase
printf 'A\n' >> "$rwrepo/f.txt"; git -C "$rwrepo" add f.txt; git -C "$rwrepo" commit -qm a
git -C "$rwrepo" checkout -q main
printf 'other\n' > "$rwrepo/g.txt"; git -C "$rwrepo" add g.txt; git -C "$rwrepo" commit -qm "main moves on"
git -C "$rwrepo" checkout -q -b tmp feat
git -C "$rwrepo" rebase main >/dev/null 2>&1
git -C "$rwrepo" checkout -q main
git -C "$rwrepo" merge -q --ff-only tmp >/dev/null 2>&1
git -C "$rwrepo" branch -qD tmp
sync_origin "$rwrepo"
rt "rebase-merged branch allowed"      0 "$rwrepo"

# squash-merge of a single commit
mkrw squash1
printf 'A\n' >> "$rwrepo/f.txt"; git -C "$rwrepo" add f.txt; git -C "$rwrepo" commit -qm a
git -C "$rwrepo" checkout -q main
git -C "$rwrepo" merge -q --squash feat >/dev/null 2>&1
git -C "$rwrepo" commit -qm "squashed feat"
sync_origin "$rwrepo"
rt "squash-merged (1 commit) allowed"  0 "$rwrepo"

# squash-merge of several commits: no individual patch matches, only the
# branch taken as a whole does
mkrw squashN
printf 'A\n' >> "$rwrepo/f.txt"; git -C "$rwrepo" add f.txt; git -C "$rwrepo" commit -qm a
printf 'B\n' >> "$rwrepo/f.txt"; git -C "$rwrepo" add f.txt; git -C "$rwrepo" commit -qm b
git -C "$rwrepo" checkout -q main
git -C "$rwrepo" merge -q --squash feat >/dev/null 2>&1
git -C "$rwrepo" commit -qm "squashed feat"
sync_origin "$rwrepo"
rt "squash-merged (N commits) allowed" 0 "$rwrepo"

# the other direction: part of the branch was squashed in, part never left it
mkrw partial
printf 'A\n' >> "$rwrepo/f.txt"; git -C "$rwrepo" add f.txt; git -C "$rwrepo" commit -qm a
git -C "$rwrepo" checkout -q main
git -C "$rwrepo" merge -q --squash feat >/dev/null 2>&1
git -C "$rwrepo" commit -qm "squashed only the first commit"
sync_origin "$rwrepo"
git -C "$rwrepo" checkout -q feat
printf 'NEVER-MERGED\n' >> "$rwrepo/f.txt"; git -C "$rwrepo" add f.txt; git -C "$rwrepo" commit -qm b
git -C "$rwrepo" checkout -q main
rt "partially merged still refused"    1 "$rwrepo"

# and a branch whose work never reached the base at all
mkrw none
printf 'NEVER\n' >> "$rwrepo/f.txt"; git -C "$rwrepo" add f.txt; git -C "$rwrepo" commit -qm a
git -C "$rwrepo" checkout -q main
printf 'other\n' > "$rwrepo/g.txt"; git -C "$rwrepo" add g.txt; git -C "$rwrepo" commit -qm "main moves on"
sync_origin "$rwrepo"
rt "unmerged branch still refused"     1 "$rwrepo"

# the squash probe must not leave anything behind in the repo it inspects
before=$(find "$rwrepo/.git/objects" -type f | wc -l | tr -d ' ')
( cd "$rwrepo" && "$root/core/checks/branch-delete.sh" 'git branch -d feat' >/dev/null 2>&1 )
after=$(find "$rwrepo/.git/objects" -type f | wc -l | tr -d ' ')
if [ "$before" -eq "$after" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "FAIL: check wrote objects into the repo ($before -> $after)"; fi

echo "----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
