#!/bin/sh
# Agent-layer check (ask): a commit command whose text carries an email address,
# a home-directory path, or a term from the user's own list.
#
# A commit message is permanent and is usually pushed. Personal details in it
# (an author email, /Users/<name>/...) or an employer's name in a personal repo
# cannot be removed later without rewriting history. A guidance rule could not
# hold this; a gate can. Ask rather than deny: the match may be intended, and
# only the user can say so.
#
# Opt-in: silent unless the config sets COMMIT_MSG_CHECK=on. The term list is
# optional: ~/.config/git-agent-guard/commit-message-terms, one ERE per line,
# blank lines and #-comments ignored, matched case-insensitively.
#
# Reads only the text after the `commit` word, so a `git -C <path>` or
# `cd <path> &&` prefix is not mistaken for message text. A message read from a
# file (-F <file>, --file=<file>) is read too, when the file exists now; -F -
# takes its text from a heredoc in the command, which is already scanned. A file
# that an earlier command will create cannot be seen.

set -u
. "$(dirname "$0")/../lib.sh"

[ "$(gag_commit_msg_check)" = on ] || exit 0

cmd="${1:-}"
[ -n "$cmd" ] || exit 0

gag_git_verb "$(gag_strip_quoted "$cmd")" commit || exit 0

# The text after the first ` commit`. The attribution trailer's noreply address
# and git@host remotes (a push chained after the commit) are not personal.
rest=${cmd#* commit}

# The message file, when there is one. Capped, since it is only scanned.
mf=$(printf '%s' "$rest" | sed -nE "s/.*[[:space:]](-F|--file)[= ]?[\"']?([^[:space:];&|\"']+).*/\2/p" | head -1)
case "$mf" in
    ""|-) ;;
    "~/"*) mf="$HOME/${mf#\~/}" ;;
    /*) ;;
    *) mf="$(gag_workdir "$cmd")/$mf" ;;
esac
case "$mf" in
    ""|-) ;;
    *) [ -f "$mf" ] && rest="$rest $(head -c 65536 "$mf" 2>/dev/null)" ;;
esac

rest=$(printf '%s' "$rest" | sed -E 's/<?noreply@[A-Za-z0-9.-]+>?//g; s/git@[A-Za-z0-9.-]+//g')

found=""
printf '%s' "$rest" | grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}' \
    && found="an email address"
printf '%s' "$rest" | grep -qE '/(Users|home)/[A-Za-z0-9._-]+' \
    && found="${found:+$found, }a home-directory path"

terms="${XDG_CONFIG_HOME:-$HOME/.config}/git-agent-guard/commit-message-terms"
if [ -f "$terms" ]; then
    # An empty alternation would match everything, so skip it when no term is set.
    pat=$(grep -vE '^[[:space:]]*(#|$)' "$terms" | paste -sd'|' -)
    if [ -n "$pat" ] && printf '%s' "$rest" | grep -qEi -e "$pat"; then
        found="${found:+$found, }a term from your commit-message-terms list"
    fi
fi

[ -n "$found" ] || exit 0

echo "This commit command contains $found. Commit messages are permanent and usually pushed, and personal details cannot be removed later without rewriting history. Allowed next: reword the message without it and commit again. If it is intended, tell the user what matched and wait for their yes before committing."
exit 3
