#!/bin/sh
# Agent-layer check: git/gh must run where the guard can see it.
#
# Every other check reads the command as text, at command position. git or gh
# inside sh -c, eval, $( ), backticks, xargs, exec, a grouping, or a script fed
# to a shell runs just the same but is invisible to those matchers, so one
# wrapper would bypass the whole kit. Deny rather than ask: the remedy is to
# run the same command directly. One exception: a read-only query (an
# allowlist in gag_scan_launch) inside $( ), backticks or a ( ) / { } grouping
# passes, since `v=$(git rev-parse HEAD)` cannot change anything the other
# checks guard. Opaque launchers (sh -c, eval, xargs, exec, ...) get none.
#
# Under sudo/doas/su/pkexec/run0 git must not run at all: files it writes turn
# root-owned and repo hooks and config run as root. elevation.sh asks about
# elevation in general; this deny outranks that ask for git/gh.

set -u
. "$(dirname "$0")/../lib.sh"

cmd="${1:-}"
[ -n "$cmd" ] || exit 0
printf '%s' "$cmd" | grep -qE '(git|gh)' || exit 0

found=$(gag_scan_launch "$cmd")

how=$(printf '%s\n' "$found" | sed -n 's/^elevgit //p' | head -1)
if [ -n "$how" ]; then
    echo "This call runs git/gh with elevated privileges (via $how). git must never run elevated: files it writes become root-owned, and the repository's hooks and config run as root. Allowed next: run the git or gh command directly as the user, without $how; if it fails on permissions, show the user the error and let them decide."
    exit 1
fi

where=$(printf '%s\n' "$found" | sed -n 's/^hidden //p' | head -1)
if [ -n "$where" ]; then
    echo "This call runs git/gh inside $where, where the guard cannot inspect it (only read-only queries are allowed in \$( ) and groupings). Allowed next: run the git or gh command directly as its own top-level call so it can be checked; if you need its output, run it first and use the result in a second call."
    exit 1
fi

exit 0
