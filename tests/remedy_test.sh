#!/bin/sh
# Remedy admissibility: every command a deny message recommends must itself
# pass every check in the kit. A remedy that trips another check bounces the
# agent into a deny loop instead of steering it out of one.
#
# Two layers:
#  1. static corpus: the canonical remedy shapes named in check messages
#  2. live extraction: backtick-quoted commands inside each check's message
#     strings, run through the full suite

set -u
root=$(cd "$(dirname "$0")/.." && pwd)
pass=0; fail=0

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/gag-rtest.XXXXXX")
trap 'rm -rf "$sandbox"' EXIT
export HOME="$sandbox/home"
export XDG_CONFIG_HOME="$sandbox/home/.config"
export GIT_CONFIG_GLOBAL="$sandbox/home/.gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="$sandbox"
mkdir -p "$HOME"

git config --global user.email t@example.invalid 2>/dev/null
git config --global user.name t 2>/dev/null
git config --global init.defaultBranch main 2>/dev/null
git init -q "$sandbox/repo" 2>/dev/null
mkdir -p "$XDG_CONFIG_HOME/git-agent-guard"
# Record the key exactly as git reports it: on macOS mktemp hands back /var/...
# while git resolves the physical /private/var/... path.
printf '%s exclude\n' "$(git -C "$sandbox/repo" rev-parse --show-toplevel)" \
  > "$XDG_CONFIG_HOME/git-agent-guard/attribution-decisions"
cd "$sandbox/repo" || exit 1

admissible() { # <cmd> : rc 0 when no check denies it (ask=3 also fails it:
               # a remedy must be run-through-clean, not another pause)
    for check in "$root"/core/checks/*.sh; do
        "$check" "$1" >/dev/null 2>&1
        rc=$?
        [ "$rc" -eq 1 ] || [ "$rc" -eq 3 ] && return 1
    done
    return 0
}

t() { # <label> <cmd>
    if admissible "$2"; then pass=$((pass+1)); else
        fail=$((fail+1)); echo "FAIL: remedy trips a check: [$1] $2"; fi
}

# 1. canonical remedies, one per deny path
t staging-1      'git add path/to/file'
t staging-2      'git commit -m "message"'
t pr-merge       'gh pr view 42 --json state'
t branch-fetch   'git fetch origin'
t branch-show    'git log origin/main..feature-branch'
t branch-push    'git push'
t stash-list     'git stash list'
t untrack        'git restore --staged newfile.md'
t identity       'git config user.email right@example.invalid'

# 2. extract backticked commands from the checks' own message strings
tmp="$sandbox/extracted"
grep -oh '\\`[^`]*\\`' "$root"/core/checks/*.sh 2>/dev/null \
  | sed 's/^\\`//; s/\\`$//' | sort -u > "$tmp"
while IFS= read -r c; do
    [ -n "$c" ] || continue
    case "$c" in git\ *|gh\ *) t "extracted" "$c" ;; esac
done < "$tmp"

echo "----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
