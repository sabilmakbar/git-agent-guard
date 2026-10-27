#!/bin/sh
# git-agent-guard core library. POSIX sh; must run on macOS bash 3.2 and BSD tools.
#
# Check contract (core/checks/*.sh):
#   agent-layer checks : $1 = full shell command the agent wants to run
#   git-layer checks   : standard git hook args/stdin, plus GAG_HOOK set to the hook name
#   exit 0 = pass
#   exit 1 = violation, deny; one human message on stdout
#   exit 3 = needs the user's judgment, ask; one human message on stdout
#   other  = check error; adapters treat as pass and report (never lock the user out on a bug)

# gag_strip_quoted CMD -> stdout: CMD with quoted spans and heredoc bodies
# removed. A command that merely NAMES a verb must not match: grep patterns,
# commit-message text, and heredoc payloads (writing a script or a test whose
# CONTENT contains git commands) are all data rather than invocations. The
# heredoc case is not hypothetical — it blocked two real edits to this repo
# before being handled here.
gag_strip_quoted() {
    printf '%s' "$1" | awk '
        # Drop everything between a heredoc opener and its terminator line.
        # Handles <<WORD, <<-WORD, <<"WORD" and <<\x27WORD\x27.
        !inhd && match($0, /<<-?[[:space:]]*[\"\x27]?[A-Za-z_][A-Za-z0-9_]*[\"\x27]?/) {
            tag = substr($0, RSTART, RLENGTH)
            sub(/^<<-?[[:space:]]*/, "", tag)
            gsub(/[\"\x27]/, "", tag)
            inhd = 1; hdtag = tag
            print substr($0, 1, RSTART - 1)
            next
        }
        inhd {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            if (line == hdtag) { inhd = 0 }
            next
        }
        { print }
    ' | sed "s/'[^']*'//g; s/\"[^\"]*\"//g"
}

# GAG_CMD_POS: ERE for "a command starts here, and what may precede its name".
# Command position is line start or after ; & | (covers && and ||). Before the
# name: `command`, `env` (and flags such as -i), and VAR=value assignments, in
# any number; the name itself may carry a path (/usr/bin/git, ./bin/git). Each
# of these runs the same binary, so a matcher that skipped them would be a
# one-word bypass.
GAG_CMD_POS='(^|[;&|])[[:space:]]*((command|env)[[:space:]]+|-[^[:space:]]*[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|]*/)?'

# gag_git_verb STRIPPED VERB -> rc 0 when `git VERB` is actually invoked.
# Any global options may sit between git and the verb: every dash token
# (--no-pager, -P, -c<k=v>, --git-dir=<p>, --namespace=<n>, ...), plus the
# separate argument of the options that take one (-C <p>, -c <k=v>, ...). The
# argument is optional in the pattern because a quoted one has already been
# stripped away, and `git -c "k=v" commit` must still read as a commit.
gag_git_verb() {
    printf '%s' "$1" \
      | grep -qE "${GAG_CMD_POS}git([[:space:]]+(-C|-c|--git-dir|--work-tree|--namespace|--config-env)([[:space:]]+[^-[:space:]][^[:space:]]*)?|[[:space:]]+-[^[:space:]]*)*[[:space:]]+$2([[:space:]]|$)"
}

# gag_gh_words STRIPPED W1 W2 -> rc 0 when `gh W1 W2` is actually invoked.
gag_gh_words() {
    printf '%s' "$1" \
      | grep -qE "${GAG_CMD_POS}gh[[:space:]]+$2[[:space:]]+$3([[:space:]]|$)"
}

# gag_mode -> prints managed|advisory|off.
# Only the two exact spellings turn blocking down; anything else, including a
# typo and a missing config, reads as managed. A guard that could be disabled
# by misspelling its own setting would fail open silently.
gag_mode() {
    _cfg="${XDG_CONFIG_HOME:-$HOME/.config}/git-agent-guard/config"
    _m=""
    [ -f "$_cfg" ] && _m=$(sed -n 's/^MODE=//p' "$_cfg" | head -1)
    case "$_m" in
        advisory) printf 'advisory' ;;
        off)      printf 'off'      ;;
        *)        printf 'managed'  ;;
    esac
}

# gag_attribution_check -> prints on|off.
# The per-repo attribution ask is opt-in: many setups have the footer decided
# for them (by the user's global setting, or an organization's policy), and
# asking there only adds a pause. Strict like MODE, but in the other direction:
# only the exact spelling `on` enables it, and anything else reads as off.
gag_attribution_check() {
    _cfg="${XDG_CONFIG_HOME:-$HOME/.config}/git-agent-guard/config"
    _a=""
    [ -f "$_cfg" ] && _a=$(sed -n 's/^ATTRIBUTION_CHECK=//p' "$_cfg" | head -1)
    case "$_a" in
        on) printf 'on'  ;;
        *)  printf 'off' ;;
    esac
}

# gag_workdir CMD -> prints the directory git will run in, resolving the two
# common prefixes: `cd <path> && git ...` and `git -C <path> ...`. Falls back
# to the current directory. Best-effort; unresolvable paths print nothing.
gag_workdir() {
    _d=$(printf '%s' "$1" | sed -n 's/^[[:space:]]*cd[[:space:]]\{1,\}\([^;&|[:space:]]\{1,\}\).*/\1/p')
    [ -z "$_d" ] && _d=$(printf '%s' "$1" | sed -n 's/.*git[[:space:]]\{1,\}-C[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p')
    case "$_d" in
        "~") _d="$HOME" ;;
        "~/"*) _d="$HOME/${_d#\~/}" ;;
    esac
    if [ -n "$_d" ] && [ -d "$_d" ]; then printf '%s' "$_d"; else pwd; fi
}
