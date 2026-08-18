#!/bin/sh
# Agent-layer check (ask): a commit is about to track files for the first time.
#
# Editing an untracked file is not approval to put it in the repo — what enters
# version control is the user's call. When the staged set contains newly-added
# paths, ask instead of committing straight through.

set -u
. "$(dirname "$0")/../lib.sh"

cmd="${1:-}"
[ -n "$cmd" ] || exit 0

stripped=$(gag_strip_quoted "$cmd")
gag_git_verb "$stripped" commit || exit 0

dir=$(gag_workdir "$cmd")
git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || exit 0

new_files=$(git -C "$dir" diff --cached --name-only --diff-filter=A 2>/dev/null)
[ -n "$new_files" ] || exit 0

echo "This commit tracks file(s) for the first time: $(printf '%s' "$new_files" | tr '\n' ' '). Newly-tracked files need their own explicit approval — confirm with the user that these belong in the repo (vs staying local-only) before committing."
exit 3
