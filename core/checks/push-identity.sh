#!/bin/sh
# Agent-layer check: verify the commit identity matches the remote before push.
# The author email decides which account a commit maps to; a work identity in a
# personal repo (or the reverse) is public and hard to scrub.
#
# Opt-in: reads <config-dir>/git-agent-guard/identities, lines of
#   <remote-url-substring> <expected-email>
# No file -> check disabled. File present but remote unmapped -> ask.

set -u
. "$(dirname "$0")/../lib.sh"

cmd="${1:-}"
[ -n "$cmd" ] || exit 0

stripped=$(gag_strip_quoted "$cmd")
gag_git_verb "$stripped" push || exit 0

id_file="${XDG_CONFIG_HOME:-$HOME/.config}/git-agent-guard/identities"
[ -f "$id_file" ] || exit 0

dir=$(gag_workdir "$cmd")
git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || exit 0

remote=$(printf '%s' "$stripped" | sed -n 's/.*git[[:space:]]\{1,\}push[[:space:]]\{1,\}\(-[^[:space:]]\{1,\}[[:space:]]\{1,\}\)*\([^-:[:space:]][^[:space:];&|]*\).*/\2/p')
[ -n "$remote" ] || remote=origin
url=$(git -C "$dir" remote get-url "$remote" 2>/dev/null) || exit 0

email=$(git -C "$dir" config user.email 2>/dev/null)

expected=""
while IFS=' ' read -r pat exp; do
    case "$pat" in ''|'#'*) continue ;; esac
    case "$url" in *"$pat"*) expected="$exp"; break ;; esac
done < "$id_file"

if [ -z "$expected" ]; then
    echo "Remote '$url' matches no entry in your identities map ($id_file). Confirm with the user that '$email' is the right identity for this push, or add a mapping."
    exit 3
fi

if [ "$email" != "$expected" ]; then
    echo "Identity mismatch: this repo's user.email is '$email' but pushes to '$url' expect '$expected' (identities map). Fix with \`git config user.email $expected\` before pushing — a wrong identity in public history is hard to scrub."
    exit 1
fi

exit 0
