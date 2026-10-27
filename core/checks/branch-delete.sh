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

# gag_push_deletes STRIPPED -> prints each branch a `git push` deletes, one per
# line. Reads the push's own words: the first positional is the remote and the
# rest are refspecs, which name deletions under -d/--delete (anywhere, or in a
# short cluster like -fd) or when written :branch. Options that take a separate
# value (-o, --repo, ...) have it skipped so it is not read as the remote.
gag_push_deletes() {
    # shellcheck disable=SC2020  # each of ; & | becomes a newline, one segment per command
    printf '%s\n' "$1" | tr ';&|' '\n\n\n' | while IFS= read -r seg; do
        gag_git_verb "$seg" push || continue
        printf '%s\n' "$seg" | awk '{
            for (i = 1; i <= NF && $i != "push"; i++) ;
            del = 0; npos = 0; endopt = 0
            for (i++; i <= NF; i++) {
                t = $i
                if (!endopt && t == "--") { endopt = 1; continue }
                if (!endopt && t ~ /^-/) {
                    if (t == "--delete" || t ~ /^-[A-Za-z]*d[A-Za-z]*$/) del = 1
                    else if (t == "-o" || t == "--push-option" || t == "--repo" || t == "--receive-pack" || t == "--exec") i++
                    continue
                }
                pos[++npos] = t
            }
            for (k = 2; k <= npos; k++) {
                r = pos[k]; sub(/^\+/, "", r)
                if (del) b = r
                else if (r ~ /^:/) b = substr(r, 2)
                else continue
                sub(/^refs\/heads\//, "", b)
                if (b != "") print b
            }
        }'
    done
}

branches=""
if gag_git_verb "$stripped" branch; then
    # Two expressions, no alternation: \| is a GNU sed extension, absent in BSD sed.
    branches=$(printf '%s' "$stripped" | sed -n 's/.*git[[:space:]].*branch[[:space:]]\{1,\}-[dD][[:space:]]\{1,\}\([^[:space:];&|]\{1,\}\).*/\1/p')
    [ -z "$branches" ] && branches=$(printf '%s' "$stripped" | sed -n 's/.*git[[:space:]].*branch[[:space:]]\{1,\}--delete[[:space:]]\{1,\}\(--force[[:space:]]\{1,\}\)*\([^[:space:];&|]\{1,\}\).*/\2/p')
elif gag_git_verb "$stripped" push; then
    branches=$(gag_push_deletes "$stripped")
fi
[ -n "$branches" ] || exit 0

dir=$(gag_workdir "$cmd")
git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# _no_new_patches <ref> [scratch] -> rc 0 when every commit the ref adds is
# already in the base as a patch. `git cherry` marks patch-equivalent commits
# "-" and genuinely new ones "+", so an absence of "+" means nothing would be
# stranded. With a scratch object dir, git reads it first and the repository's
# own objects ($objdir) as an alternate.
# A failed `git cherry` returns 1 rather than an empty result: an error must
# read as "cannot show this is merged", never as permission to delete.
# The object-dir variables go to git through env, never as assignments in
# front of this function: POSIX leaves it unspecified whether those reach the
# commands inside it and whether they outlive the call. ksh drops them for git
# and keeps them afterwards, and a GIT_OBJECT_DIRECTORY left pointing at the
# deleted scratch dir would make every later git query here fail.
_no_new_patches() {
    if [ -n "${2:-}" ]; then
        _cherry=$(env GIT_OBJECT_DIRECTORY="$2" GIT_ALTERNATE_OBJECT_DIRECTORIES="$objdir" \
                  git -C "$dir" cherry "refs/remotes/$base" "$1" 2>/dev/null) || return 1
    else
        _cherry=$(git -C "$dir" cherry "refs/remotes/$base" "$1" 2>/dev/null) || return 1
    fi
    ! printf '%s\n' "$_cherry" | grep -q '^+'
}

# check_branch NAME -> 0 safe to delete; otherwise prints why and returns the rc.
check_branch() {
    branch=$1
    git -C "$dir" show-ref --verify --quiet "refs/heads/$branch" || return 0  # remote-only ref: local checks n/a

    base=$(git -C "$dir" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||')
    if [ -z "$base" ]; then
        for b in origin/main origin/master; do
            git -C "$dir" show-ref --verify --quiet "refs/remotes/$b" && { base="$b"; break; }
        done
    fi
    if [ -z "$base" ]; then
        echo "Cannot determine the base branch to verify '$branch' is fully merged. Allowed next: run \`git fetch origin\` and retry, or ask the user which branch is the base."
        return 3
    fi

    if ! git -C "$dir" merge-base --is-ancestor "refs/heads/$branch" "refs/remotes/$base" 2>/dev/null; then
        # Ancestry is the cheap test and it is only correct for a plain merge. Every
        # history-rewriting merge (rebase, squash, cherry-pick) lands the same content
        # under new SHAs, leaving ancestry false forever and the branch permanently
        # undeletable through this check. So compare patches before refusing.
        merged_anyway=no

        if _no_new_patches "refs/heads/$branch"; then
            merged_anyway=yes
        else
            # A squash of several commits matches none of them individually, so
            # rebuild the branch as the single commit a squash would have produced
            # and ask about that instead. New objects are written to a scratch
            # directory, never into the repository being inspected: these checks
            # read, they do not write.
            mb=$(git -C "$dir" merge-base "refs/remotes/$base" "refs/heads/$branch" 2>/dev/null)
            tree=$(git -C "$dir" rev-parse "refs/heads/$branch^{tree}" 2>/dev/null)
            # --git-path is relative to $dir when run from a subdirectory
            # (../.git/objects); resolve it, so the alternate is found
            # wherever git resolves relative paths from.
            objdir=$(git -C "$dir" rev-parse --git-path objects 2>/dev/null)
            if [ -n "$objdir" ]; then
                objdir=$(cd "$dir" 2>/dev/null && cd "$objdir" 2>/dev/null && pwd) || objdir=""
            fi
            scratch=$(mktemp -d "${TMPDIR:-/tmp}/gag-squash.XXXXXX" 2>/dev/null)
            if [ -n "$mb" ] && [ -n "$tree" ] && [ -n "$objdir" ] && [ -n "$scratch" ]; then
                synth=$(env GIT_OBJECT_DIRECTORY="$scratch" GIT_ALTERNATE_OBJECT_DIRECTORIES="$objdir" \
                        git -C "$dir" commit-tree "$tree" -p "$mb" -m gag-squash-probe 2>/dev/null)
                if [ -n "$synth" ] && _no_new_patches "$synth" "$scratch"; then
                    merged_anyway=yes
                fi
            fi
            [ -n "$scratch" ] && rm -rf "$scratch"
        fi

        if [ "$merged_anyway" = no ]; then
            echo "Branch '$branch' has commits not reached $base, by SHA or by patch, so deleting would strand them. Allowed next: run \`git log $base..$branch\` to show the user what would be lost, and let them decide; deletion stays blocked until the branch is fully merged."
            return 1
        fi
    fi

    if git -C "$dir" rev-parse --verify --quiet "$branch@{upstream}" >/dev/null 2>&1; then
        ahead=$(git -C "$dir" rev-list --count "$branch@{upstream}..refs/heads/$branch" 2>/dev/null || echo 0)
        if [ "${ahead:-0}" -gt 0 ]; then
            echo "Branch '$branch' has $ahead commit(s) not pushed to its upstream. Allowed next: run \`git push\` for '$branch' first, then retry the delete; it will pass once nothing is unpushed."
            return 1
        fi
    fi

    if git -C "$dir" stash list 2>/dev/null | grep -q "WIP on $branch:"; then
        echo "A stash entry reads 'WIP on $branch' — stashes survive branch deletion but get much harder to find once the name is gone. Allowed next: show the user \`git stash list\` output and let them decide; apply or drop the stash, then retry the delete."
        return 1
    fi
    return 0
}

for br in $branches; do
    check_branch "$br"
    rc=$?
    [ "$rc" -eq 0 ] || exit "$rc"
done

exit 0
