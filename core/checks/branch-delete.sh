#!/bin/sh
# Agent-layer check: gate branch deletion on three mechanical safety checks.
# A merged PR means the PR merged, not that everything on the branch reached
# the base. Deleting early strands commits behind reflog recovery, silently.
#
#   1. branch tip is an ancestor of the base
#   2. nothing unpushed to the branch's own upstream
#   3. no stash reads "WIP on <branch>"

set -u
. "$(dirname "$0")/../lib.sh"

cmd="${1:-}"
[ -n "$cmd" ] || exit 0

stripped=$(gag_strip_quoted "$cmd")

branch=""
if gag_git_verb "$stripped" branch; then
    # Two expressions, no alternation: \| is a GNU sed extension, absent in BSD sed.
    branch=$(printf '%s' "$stripped" | sed -n 's/.*git[[:space:]].*branch[[:space:]]\{1,\}-[dD][[:space:]]\{1,\}\([^[:space:];&|]\{1,\}\).*/\1/p')
    [ -z "$branch" ] && branch=$(printf '%s' "$stripped" | sed -n 's/.*git[[:space:]].*branch[[:space:]]\{1,\}--delete[[:space:]]\{1,\}\(--force[[:space:]]\{1,\}\)*\([^[:space:];&|]\{1,\}\).*/\2/p')
elif gag_git_verb "$stripped" push; then
    branch=$(printf '%s' "$stripped" | sed -n 's/.*git.*push[[:space:]].*--delete[[:space:]]\{1,\}\([^[:space:];&|]\{1,\}\).*/\1/p')
    [ -z "$branch" ] && branch=$(printf '%s' "$stripped" | sed -n 's/.*git.*push[[:space:]]\{1,\}[^[:space:]]\{1,\}[[:space:]]\{1,\}:\([^[:space:];&|]\{1,\}\).*/\1/p')
fi
[ -n "$branch" ] || exit 0

dir=$(gag_workdir "$cmd")
git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || exit 0
git -C "$dir" show-ref --verify --quiet "refs/heads/$branch" || exit 0  # remote-only ref: local checks n/a

base=$(git -C "$dir" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||')
if [ -z "$base" ]; then
    for b in origin/main origin/master; do
        git -C "$dir" show-ref --verify --quiet "refs/remotes/$b" && { base="$b"; break; }
    done
fi
if [ -z "$base" ]; then
    echo "Cannot determine the base branch to verify '$branch' is fully merged. Allowed next: run \`git fetch origin\` and retry, or ask the user which branch is the base."
    exit 3
fi

if ! git -C "$dir" merge-base --is-ancestor "refs/heads/$branch" "refs/remotes/$base" 2>/dev/null; then
    echo "Branch '$branch' has commits not reached $base — deleting would strand them. Allowed next: run \`git log $base..$branch\` to show the user what would be lost, and let them decide; deletion stays blocked until the branch is fully merged."
    exit 1
fi

if git -C "$dir" rev-parse --verify --quiet "$branch@{upstream}" >/dev/null 2>&1; then
    ahead=$(git -C "$dir" rev-list --count "$branch@{upstream}..refs/heads/$branch" 2>/dev/null || echo 0)
    if [ "${ahead:-0}" -gt 0 ]; then
        echo "Branch '$branch' has $ahead commit(s) not pushed to its upstream. Allowed next: run \`git push\` for '$branch' first, then retry the delete; it will pass once nothing is unpushed."
        exit 1
    fi
fi

if git -C "$dir" stash list 2>/dev/null | grep -q "WIP on $branch:"; then
    echo "A stash entry reads 'WIP on $branch' — stashes survive branch deletion but get much harder to find once the name is gone. Allowed next: show the user \`git stash list\` output and let them decide; apply or drop the stash, then retry the delete."
    exit 1
fi

exit 0
