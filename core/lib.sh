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

# gag_git_verb STRIPPED VERB -> rc 0 when `git VERB` is actually invoked.
# Command position only: line start or after ; & | (covers && and ||).
# Tolerates a leading `git -C <path>` and other single-token global flags.
gag_git_verb() {
    printf '%s' "$1" \
      | grep -qE "(^|[;&|])[[:space:]]*git([[:space:]]+(-C|--git-dir|--work-tree)[[:space:]]*=?[[:space:]]*[^[:space:]]+|[[:space:]]+--no-pager)*[[:space:]]+$2([[:space:]]|$)"
}

# gag_gh_words STRIPPED W1 W2 -> rc 0 when `gh W1 W2` is actually invoked.
gag_gh_words() {
    printf '%s' "$1" \
      | grep -qE "(^|[;&|])[[:space:]]*gh[[:space:]]+$2[[:space:]]+$3([[:space:]]|$)"
}

# gag_mode -> prints managed|advisory (default managed when config missing: fail safe).
gag_mode() {
    _cfg="${XDG_CONFIG_HOME:-$HOME/.config}/git-agent-guard/config"
    _m=""
    [ -f "$_cfg" ] && _m=$(sed -n 's/^MODE=//p' "$_cfg" | head -1)
    case "$_m" in
        advisory) printf 'advisory' ;;
        *)        printf 'managed'  ;;
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
