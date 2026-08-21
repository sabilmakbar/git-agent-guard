#!/bin/sh
# Agent-layer check (ask): this repository has no recorded AI-attribution
# decision, and a commit is about to be made.
#
# Whether a commit says it was AI-assisted is a disclosure choice, and it is
# per project rather than per machine: some projects want the provenance in
# history, and some contribution policies reject AI-attributed commits
# outright. It is also effectively permanent, since removing a trailer later
# means rewriting history. So it is asked once per repository and remembered.

set -u
. "$(dirname "$0")/../lib.sh"

cmd="${1:-}"
[ -n "$cmd" ] || exit 0

stripped=$(gag_strip_quoted "$cmd")
gag_git_verb "$stripped" commit || exit 0

dir=$(gag_workdir "$cmd")
git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || exit 0

key=$(git -C "$dir" remote get-url origin 2>/dev/null) || key=""
[ -n "$key" ] || key=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || exit 0

decisions="${XDG_CONFIG_HOME:-$HOME/.config}/git-agent-guard/attribution-decisions"
if [ -f "$decisions" ]; then
    while IFS=' ' read -r k _; do
        [ "$k" = "$key" ] && exit 0
    done < "$decisions"
fi

helper=$(cd "$(dirname "$0")/../../bin" 2>/dev/null && pwd)/gag-attribution

echo "This repository has no recorded AI-attribution decision, and it is worth making once: a Co-Authored-By trailer discloses AI involvement to reviewers and is greppable later, but it is permanent in history and some projects' contribution policies reject AI-attributed commits. Allowed next: ask the user which they want here, then run \`$helper include\` (commits carry the trailer) or \`$helper exclude\` (they do not) from the repo root, and commit again. \`$helper default\` defers to the global setting and also stops the asking."
exit 3
