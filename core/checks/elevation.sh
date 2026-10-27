#!/bin/sh
# Agent-layer check (ask): any command that runs with elevated privileges.
#
# sudo, doas, su, pkexec and run0 lift a command past every permission the
# agent was given, whatever the command is. That is the user's call each time,
# so ask. Only a launcher at command position counts (after ; && || |, inside
# sh -c, eval, $( ), backticks, groupings, or behind env, xargs, time, ...);
# the word as data (`grep sudo f`, a quoted message) is not elevation.

set -u
. "$(dirname "$0")/../lib.sh"

cmd="${1:-}"
[ -n "$cmd" ] || exit 0
printf '%s' "$cmd" | grep -qE '(sudo|doas|su|pkexec|run0)' || exit 0

how=$(gag_scan_launch "$cmd" | sed -n 's/^elevated //p' | head -1)
[ -n "$how" ] || exit 0

echo "This command runs with elevated privileges (via $how) and needs the user's explicit approval. Allowed next: show the user the exact command and why it needs elevation, and run it only once they approve."
exit 3
