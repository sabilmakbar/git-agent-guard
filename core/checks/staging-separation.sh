#!/bin/sh
# Agent-layer check: refuse one command that both stages and commits.
#
# Staging and committing are approved independently; chaining skips the staging
# review. A transcript audit over 38 sessions found 286 of 488 staging calls
# chained the two (41% adherence). Guidance text could not hold the rule; a
# gate can. Deny rather than ask: the remedy is running the same two commands
# as two calls, so there is nothing to adjudicate.

set -u
. "$(dirname "$0")/../lib.sh"

cmd="${1:-}"
[ -n "$cmd" ] || exit 0

stripped=$(gag_strip_quoted "$cmd")

# `git commit -a` is the same chain in one command: it stages every tracked
# change and commits it. Short flags may be clustered (-am, -va); the cluster
# is only read up to the first flag that takes a value (-m, -F, -C, -c, -t,
# -S, -u), so a value like -mall is not mistaken for -a.
if gag_git_verb "$stripped" commit '-[^-[:space:];&|mFCctSu]*a[^[:space:];&|]*|--all'; then
    echo "This commit uses -a/--all, which stages and commits in one step. Run them as two separate calls so staging can be reviewed on its own: send \`git add ...\` with the paths first, then \`git commit ...\` without -a once it returns."
    exit 1
fi

gag_git_verb "$stripped" add    || exit 0
gag_git_verb "$stripped" commit || exit 0

echo "This call stages and commits together. Run them as two separate calls so staging can be reviewed on its own: send \`git add ...\` first, then \`git commit ...\` once it returns."
exit 1
