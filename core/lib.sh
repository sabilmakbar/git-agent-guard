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

# gag_strip_quoted CMD [PH] -> stdout: CMD with quoted spans and heredoc bodies
# removed; with PH, each quoted span becomes PH instead, so a check that counts
# arguments still sees one there. A command that merely NAMES a verb must not
# match: grep patterns, commit-message text, and heredoc payloads (writing a
# script or a test whose CONTENT contains git commands) are all data rather
# than invocations. The
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
    ' | awk -v q="'" -v ph="${2:-}" '
        # Quoted spans are removed across line breaks, not line by line: a
        # multi-line commit message is one span, and its second line is data.
        { s = s (NR > 1 ? "\n" : "") $0 }
        END { gsub(q "[^" q "]*" q, ph, s); gsub(/"[^"]*"/, ph, s); print s }
    '
}

# GAG_CMD_POS: ERE for "a command starts here, and what may precede its name".
# Command position is line start or after ; & | (covers && and ||). Before the
# name: `command`, `env` (and flags such as -i), and VAR=value assignments, in
# any number; the name itself may carry a path (/usr/bin/git, ./bin/git). Each
# of these runs the same binary, so a matcher that skipped them would be a
# one-word bypass.
GAG_CMD_POS='(^|[;&|])[[:space:]]*((command|env)[[:space:]]+|-[^[:space:]]*[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|]*/)?'

# gag_git_verb STRIPPED VERB [ARG] -> rc 0 when `git VERB` is actually invoked;
# with ARG (an ERE for one whole argument token), only when that same
# invocation carries such an argument before the next ; & | or line end.
# Any global options may sit between git and the verb: every dash token
# (--no-pager, -P, -c<k=v>, --git-dir=<p>, --namespace=<n>, ...), plus the
# separate argument of the options that take one (-C <p>, -c <k=v>, ...). The
# argument is optional in the pattern because a quoted one has already been
# stripped away, and `git -c "k=v" commit` must still read as a commit.
gag_git_verb() {
    _arg=""
    [ -n "${3:-}" ] && _arg="([[:space:]]+[^;&|[:space:]]*)*[[:space:]]+($3)"
    printf '%s' "$1" \
      | grep -qE "${GAG_CMD_POS}git([[:space:]]+(-C|-c|--git-dir|--work-tree|--namespace|--config-env)([[:space:]]+[^-[:space:]][^[:space:]]*)?|[[:space:]]+-[^[:space:]]*)*[[:space:]]+$2${_arg}([[:space:]]|$|[;&|])"
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

# gag_scan_launch CMD -> stdout: one finding per line, reading the RAW command
# (quotes intact, unlike every matcher above):
#   hidden <where>    git/gh runs somewhere the verb matchers cannot see it:
#                     sh -c strings, eval, $( ), backticks, xargs, exec, nohup,
#                     time, nice, find -exec, ( ) and { } groupings, a heredoc,
#                     here-string or pipe fed to a shell. A read-only query
#                     (see readonly below) in $( ), backticks or a grouping
#                     is not reported.
#   elevgit <how>     git/gh runs under sudo, doas, su, pkexec or run0
#   elevated <how>    any command runs under one of those launchers
# A small shell lexer: single quotes and quoted-delimiter heredoc bodies are
# literal text; double quotes and unquoted heredoc bodies are text in which
# $( ) and backticks still execute; strings handed to a shell (-c, eval, a
# heredoc on its stdin) are code and are scanned again as commands. Elevation
# counts at command position only, so `grep sudo f` and `echo 'use sudo'` are
# not elevation. Best-effort like the rest: `case` patterns and other rarer
# syntax can confuse it.
gag_scan_launch() {
    printf '%s' "$1" | awk '
    function emit(kind, what,   key) { key = kind " " what; if (!(key in SEEN)) { SEEN[key] = 1; print key } }
    function base(t) { sub(/.*\//, "", t); return t }
    function gitword(t) { return t ~ /(^|[^A-Za-z0-9_.-])(git|gh)([^A-Za-z0-9_.-]|$)/ }
    function elevword(t) { return t ~ /(^|[^A-Za-z0-9_.-])(sudo|doas|su|pkexec|run0)([^A-Za-z0-9_.-]|$)/ }
    function isshell(b) { return b ~ /^(sh|bash|zsh|dash|ksh)$/ }
    function isassign(t) { return t ~ /^[A-Za-z_][A-Za-z0-9_]*=/ }

    # resolve CS CE DOEMIT: walk past launch prefixes to the real command word.
    # Sets R_K (its index), R_ELEV (launcher, if any) and R_WRAP (hiding wrapper).
    function resolve(cs, ce, doemit,   k, b) {
        R_ELEV = ""; R_WRAP = ""; k = cs
        while (k <= ce) {
            b = base(W[k])
            if (isassign(W[k]) || b ~ /^(!|if|then|else|elif|while|until|do)$/) { k++; continue }
            if (b == "env") {
                for (k++; k <= ce && (W[k] ~ /^-/ || isassign(W[k])); k++) if (W[k] ~ /^-[uCS]$/) k++
                continue
            }
            if (b == "command") { for (k++; k <= ce && W[k] ~ /^-/; k++) ; continue }
            if (b ~ /^(exec|nohup|time|nice)$/) {
                R_WRAP = b
                for (k++; k <= ce && W[k] ~ /^-/; k++) if (W[k] == "-n" || W[k] == "-a") k++
                continue
            }
            if (b == "xargs") {
                R_WRAP = b
                for (k++; k <= ce && W[k] ~ /^-/; k++) if (W[k] ~ /^-[InPLdEsa]$/) k++
                continue
            }
            if (b ~ /^(sudo|doas|pkexec|run0)$/) {
                R_ELEV = b; if (doemit) emit("elevated", b)
                for (k++; k <= ce && W[k] ~ /^-/; k++) if (W[k] ~ /^(-[ugCDhprtUTR]|--user|--group|--chdir)$/) k++
                continue
            }
            break
        }
        R_K = k
    }

    # readonly C M CE: is `C W[M..CE]` (C = git or gh) a query that cannot
    # write? Used only for $( ), backticks and groupings, where reading a value
    # (v=$(git rev-parse HEAD), (cd d && git status)) is the everyday shape.
    # An allowlist, and anything it does not recognise reads as a write.
    function readonly(c, m, ce,   v, a, j, list, want, n) {
        if (c == "gh") {
            v = W[m] " " W[m + 1]
            if (v ~ /^pr (view|list|status|diff|checks)$/ || v ~ /^issue (view|list|status)$/ || v == "repo view") return 1
            if (W[m] != "api") return 0
            for (j = m + 1; j <= ce; j++) {
                a = W[j]
                if (a ~ /^(-f|-F|--field|--raw-field|--input)/) return 0
                if (a == "-X" || a == "--method") { if (toupper(W[j + 1]) != "GET") return 0; j++; continue }
                if (a ~ /^(-X|--method=)/) { sub(/^(-X|--method=)/, "", a); if (toupper(a) != "GET") return 0 }
            }
            return 1
        }
        while (m <= ce && W[m] ~ /^-/) { if (W[m] ~ /^(-C|-c|--git-dir|--work-tree|--namespace|--config-env)$/) m++; m++ }
        if (m > ce) return 0
        v = W[m]; n = ce - m
        for (j = m + 1; j <= ce; j++) if (W[j] ~ /^(--output(=|$)|-O|--open-files-in-pager)/) return 0
        if (v ~ /^(status|log|diff|show|rev-parse|rev-list|describe|ls-files|ls-tree|cat-file|merge-base|show-ref|blame|grep|shortlog|for-each-ref)$/) return 1
        if (v == "symbolic-ref") {    # a second positional would set the ref
            n = 0; for (j = m + 1; j <= ce; j++) if (W[j] !~ /^-/) n++
            return n <= 1
        }
        if (v == "stash" || v == "worktree") return W[m + 1] == "list"
        if (v == "remote") return (n == 1 && W[m + 1] ~ /^(-v|--verbose)$/) || W[m + 1] == "get-url"
        if (v == "config") {
            want = 0
            for (j = m + 1; j <= ce; j++) {
                if (W[j] ~ /^(--get|--get-all|--get-regexp|--list|-l)$/) want = 1
                else if (W[j] ~ /^-/ && W[j] !~ /^(--global|--system|--local|--worktree|--show-origin|--show-scope|--null|-z|--name-only|--includes|--no-includes|--type=.*|--bool|--int|--path|--default=.*)$/) return 0
            }
            return want
        }
        if (v == "branch" || v == "tag") {
            # Listing only: a bare name would create, and -d/-m/-f... would
            # delete, rename or force, so any other flag or name reads as a write.
            list = 0; want = 0
            for (j = m + 1; j <= ce; j++) if (W[j] == "-l" || W[j] == "--list") list = 1
            for (j = m + 1; j <= ce; j++) {
                a = W[j]
                if (a ~ /^(--contains|--merged|--no-merged|--points-at)$/) { want = 1; if (j < ce && W[j + 1] !~ /^-/) j++; continue }
                if (a ~ /^(--contains|--merged|--no-merged|--points-at)=/ || a == "-l" || a == "--list") { want = 1; continue }
                if (v == "branch" && a ~ /^(--show-current|-a|--all|-r|--remotes|-v|-vv|--verbose)$/) { want = 1; continue }
                if (a ~ /^(--format|--sort|--colou?r)(=|$)/ || a == "--no-color") continue
                if (a ~ /^-/ || !list) return 0
            }
            return want
        }
        return 0
    }

    # finish CS HIDDEN ISPIPE: judge the simple command in W[CS..WN].
    function finish(cs, hidden, ispipe,   ce, k, c, m, sawc, str, has) {
        ce = WN
        if (ce >= cs) {
            resolve(cs, ce, 1); k = R_K
            c = (k <= ce) ? base(W[k]) : ""
            if (c == "git" || c == "gh") {
                if (R_ELEV != "") emit("elevgit", R_ELEV)
                else if (R_WRAP != "") emit("hidden", R_WRAP)
                else if (hidden != "" && !(hidden ~ /^(command substitution|backticks|a \( \) grouping|a \{ \} grouping)$/ && readonly(c, k + 1, ce))) emit("hidden", hidden)
            } else if (isshell(c) || c == "su") {
                if (c == "su") emit("elevated", "su")
                sawc = 0; has = 0
                for (m = k + 1; m <= ce; m++) {
                    if (W[m] ~ /^-[A-Za-z]*c[A-Za-z]*$/ || W[m] == "--command") { sawc = 1; continue }
                    if (W[m] ~ /^--command=/) { sawc = 1; str = W[m]; sub(/^--command=/, "", str); has = 1; break }
                    if (W[m] ~ /^[-+]/ || (c == "su" && !sawc)) continue
                    if (sawc) { str = W[m]; has = 1 }
                    break
                }
                el = (c == "su") ? "su" : R_ELEV
                if (has) {
                    if (gitword(str)) emit(el != "" ? "elevgit" : "hidden", el != "" ? el : c " -c")
                    sub_parse(str, c " -c")
                } else if (!sawc) {
                    if (PGIT) emit(el != "" ? "elevgit" : "hidden", el != "" ? el : "a pipe into " c)
                    if (PELEV) emit("elevated", "a pipe into " c)
                }
            } else if (c == "eval") {
                str = ""; for (m = k + 1; m <= ce; m++) str = str " " W[m]
                if (gitword(str)) emit(R_ELEV != "" ? "elevgit" : "hidden", R_ELEV != "" ? R_ELEV : "eval")
                sub_parse(str, "eval")
            } else if (c == "find") {
                for (m = k + 1; m < ce; m++) if (W[m] ~ /^-(exec|execdir|ok|okdir)$/) {
                    if (base(W[m + 1]) ~ /^(git|gh)$/) emit("hidden", "find " W[m])
                    if (base(W[m + 1]) ~ /^(sudo|doas|su|pkexec|run0)$/) emit("elevated", base(W[m + 1]))
                }
            }
            if (ispipe) {
                for (m = cs; m <= ce; m++) { if (gitword(W[m])) PGIT = 1; if (elevword(W[m])) PELEV = 1 }
            }
        }
        if (!ispipe) { PGIT = 0; PELEV = 0 }
        WN = cs - 1
    }

    function endword() {
        if (!INW) return
        if (SKIPNEXT) SKIPNEXT = 0
        else if (HS) {
            HS = 0
            if (HS_SH) {
                if (gitword(CUR)) emit(HS_EL != "" ? "elevgit" : "hidden", HS_EL != "" ? HS_EL : "a here-string fed to a shell")
                sub_parse(CUR, "a here-string fed to a shell")
            }
        } else W[++WN] = CUR
        CUR = ""; INW = 0
    }

    # nested I STOP LABEL: parse a substitution or grouping in place.
    function nested(i, stop, label,   sC, sI, sW, sSK, sPG, sPE) {
        sC = CUR; sI = INW; sW = WN; sSK = SKIPNEXT; sPG = PGIT; sPE = PELEV
        SKIPNEXT = 0; PGIT = 0; PELEV = 0
        i = parse(i, stop, label)
        CUR = sC "_"; INW = 1; WN = sW; SKIPNEXT = sSK; PGIT = sPG; PELEV = sPE
        return i
    }

    # sub_parse TEXT LABEL: scan TEXT, handed to a shell, as commands.
    function sub_parse(text, label,   sS, sL, sC, sI, sW, sB, sN) {
        sS = S; sL = L; sC = CUR; sI = INW; sW = WN; sB = HDB; sN = HDN
        S = text; L = length(text); HDB = HDN
        parse(1, "", label)
        S = sS; L = sL; CUR = sC; INW = sI; WN = sW; HDB = sB; HDN = sN
    }

    # escan TEXT: text in which only $( ) and backticks execute.
    function escan(text,   sS, sL, sC, sI, i, c) {
        sS = S; sL = L; sC = CUR; sI = INW
        S = text; L = length(text); i = 1
        while (i <= L) {
            c = substr(S, i, 1)
            if (c == "\\") { i += 2; continue }
            if (c == "`") { i = nested(i + 1, "`", "backticks"); continue }
            if (c == "$" && substr(S, i + 1, 1) == "(") { i = nested(i + 2, ")", "command substitution"); continue }
            i++
        }
        S = sS; L = sL; CUR = sC; INW = sI
    }

    function dq(i,   c) {
        while (i <= L) {
            c = substr(S, i, 1)
            if (c == "\"") return i + 1
            if (c == "\\") { CUR = CUR substr(S, i + 1, 1); i += 2; continue }
            if (c == "`") { i = nested(i + 1, "`", "backticks"); continue }
            if (c == "$" && substr(S, i + 1, 1) == "(") { i = nested(i + 2, ")", "command substitution"); continue }
            CUR = CUR c; i++
        }
        return i
    }

    # bodies I: consume the pending heredoc bodies that start at I.
    function bodies(i,   h, n, nl, line, t, body) {
        n = HDN
        for (h = HDB + 1; h <= n; h++) {
            body = ""
            while (i <= L) {
                nl = index(substr(S, i), "\n")
                line = nl ? substr(S, i, nl - 1) : substr(S, i)
                i = nl ? i + nl : L + 1
                t = line; sub(/^[ \t]*/, "", t)
                if (t == HD_D[h]) break
                body = body line "\n"
            }
            if (HD_SH[h]) {
                if (gitword(body)) emit(HD_EL[h] != "" ? "elevgit" : "hidden", HD_EL[h] != "" ? HD_EL[h] : "a heredoc fed to a shell")
                sub_parse(body, "a heredoc fed to a shell")
            } else if (!HD_Q[h]) escan(body)
        }
        HDN = HDB
        return i
    }

    function parse(i, stop, hidden,   c, cs, j, d, q, ow, ispipe) {
        cs = WN + 1; CUR = ""; INW = 0
        while (i <= L) {
            c = substr(S, i, 1)
            if (stop != "" && c == stop && (stop != "}" || (!INW && WN < cs))) {
                endword(); finish(cs, hidden, 0); return i + 1
            }
            if (c == "\\") {
                if (substr(S, i + 1, 1) != "\n") { CUR = CUR substr(S, i + 1, 1); INW = 1 }
                i += 2; continue
            }
            if (c == "\047") {
                j = index(substr(S, i + 1), "\047"); if (!j) j = L - i + 1
                CUR = CUR substr(S, i + 1, j - 1); INW = 1; i += j + 1; continue
            }
            if (c == "\"") { INW = 1; i = dq(i + 1); continue }
            if (c == "`") { i = nested(i + 1, "`", "backticks"); continue }
            if (c == "$" && substr(S, i + 1, 1) == "(") { i = nested(i + 2, ")", "command substitution"); continue }
            if ((c == "<" || c == ">") && substr(S, i + 1, 1) == "(") { i = nested(i + 2, ")", "process substitution"); continue }
            if (c == "#" && !INW) { while (i <= L && substr(S, i, 1) != "\n") i++; continue }
            if (substr(S, i, 2) == "<<") {
                endword()
                resolve(cs, WN, 0); ow = (R_K <= WN) ? base(W[R_K]) : ""
                if (substr(S, i, 3) == "<<<") {
                    HS = 1; HS_SH = isshell(ow) || ow == "su"; HS_EL = (ow == "su") ? "su" : R_ELEV
                    i += 3; continue
                }
                i += 2; if (substr(S, i, 1) == "-") i++
                while (substr(S, i, 1) ~ /[ \t]/) i++
                d = ""; q = 0
                while (i <= L) {
                    c = substr(S, i, 1)
                    if (c ~ /[ \t\n;&|<>()]/) break
                    if (c == "\047" || c == "\"") {
                        q = 1; j = index(substr(S, i + 1), c); if (!j) j = L - i + 1
                        d = d substr(S, i + 1, j - 1); i += j + 1; continue
                    }
                    if (c == "\\") { q = 1; d = d substr(S, i + 1, 1); i += 2; continue }
                    d = d c; i++
                }
                HDN++; HD_D[HDN] = d; HD_Q[HDN] = q
                HD_SH[HDN] = isshell(ow) || ow == "su"; HD_EL[HDN] = (ow == "su") ? "su" : R_ELEV
                continue
            }
            if (c == "&" && substr(S, i + 1, 1) == ">") { endword(); i++; continue }
            if (c == "<" || c == ">") {
                if (INW && CUR ~ /^[0-9]+$/) { CUR = ""; INW = 0 } else endword()
                for (i++; substr(S, i, 1) ~ /[<>|]/; i++) ;
                if (substr(S, i, 1) == "&") { for (i++; substr(S, i, 1) ~ /[0-9-]/; i++) ; continue }
                SKIPNEXT = 1; continue
            }
            if (c == " " || c == "\t") { endword(); i++; continue }
            if (c == "\n") { endword(); finish(cs, hidden, 0); i = bodies(i + 1); cs = WN + 1; continue }
            if (c == ";" || c == "&" || c == "|") {
                endword(); ispipe = (c == "|" && substr(S, i + 1, 1) != "|")
                finish(cs, hidden, ispipe)
                for (i++; substr(S, i, 1) ~ /[;&|]/; i++) ;
                cs = WN + 1; continue
            }
            if (c == "(" && !INW) { i = nested(i + 1, ")", hidden != "" ? hidden : "a ( ) grouping"); continue }
            if (c == "{" && !INW && WN < cs && substr(S, i + 1, 1) ~ /[ \t\n]/) {
                i = nested(i + 1, "}", hidden != "" ? hidden : "a { } grouping"); continue
            }
            if (c == ")") { endword(); i++; continue }
            CUR = CUR c; INW = 1; i++
        }
        endword(); finish(cs, hidden, 0)
        return i
    }

    { S = S (NR > 1 ? "\n" : "") $0 }
    END { L = length(S); HDN = 0; HDB = 0; WN = 0; parse(1, "", "") }
    '
}
