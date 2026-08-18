#!/bin/sh
# Agent-layer check: never merge PRs. Opening PRs is the agent's job; merging
# is always the human's. Checking merge state (gh pr view --json state) stays
# allowed — only the merge action is refused.

set -u
. "$(dirname "$0")/../lib.sh"

cmd="${1:-}"
[ -n "$cmd" ] || exit 0

stripped=$(gag_strip_quoted "$cmd")

if gag_gh_words "$stripped" pr merge; then
    echo "Merging PRs is reserved for the user — the agent only opens them. Ask the user to merge, or use \`gh pr view --json state\` if you only need to check merge status."
    exit 1
fi

# gh api merge endpoint: PUT /repos/.../pulls/N/merge (quoted URLs already
# stripped, so match bare tokens).
if printf '%s' "$stripped" | grep -qE "(^|[;&|])[[:space:]]*gh[[:space:]]+api[[:space:]]" \
   && printf '%s' "$cmd" | grep -qE "/pulls/[^/[:space:]]+/merge"; then
    echo "This gh api call hits a PR merge endpoint. Merging PRs is reserved for the user — the agent only opens them."
    exit 1
fi

exit 0
