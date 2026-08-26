#!/bin/sh
# git-agent-guard hook dispatcher.
#
# Installed as the target of global core.hooksPath. For hook <name> it runs,
# in order:
#   1. every executable in <dispatch-dir>/<name>.d/  (this kit's and any other
#      kit's registered checks — the public registration contract)
#   2. the repository's own .git/hooks/<name>, if present and executable —
#      global hooksPath makes git ignore .git/hooks entirely, so without this
#      chain step we would silently disable pre-commit-framework/husky-style
#      hooks installed there. Never clobber other tooling.
#
# stdin is captured once and replayed to every child (pre-push and others
# receive ref lines on stdin); hook args ($@) are passed through unchanged.
#
# Exit: first failing script wins in managed mode. In advisory mode failures
# are reported but the hook exits 0. A script exiting >=2 is a check bug:
# reported, never blocking.

set -u

hook_name=$(basename "$0")
dispatch_dir=$(cd "$(dirname "$0")" && pwd)
lib="$dispatch_dir/../core/lib.sh"
[ -f "$lib" ] && . "$lib"

mode=$(gag_mode 2>/dev/null || printf 'managed')

stdin_file=""
if [ ! -t 0 ]; then
    stdin_file=$(mktemp "${TMPDIR:-/tmp}/gag-stdin.XXXXXX") || stdin_file=""
    [ -n "$stdin_file" ] && cat > "$stdin_file"
fi

run_child() { # <script> [args...]
    if [ -n "$stdin_file" ]; then
        "$@" < "$stdin_file"
    else
        "$@" < /dev/null
    fi
}

cleanup() { [ -n "$stdin_file" ] && rm -f "$stdin_file"; }
trap cleanup EXIT

# "off" silences this kit's own checks, and only those: the chain to the
# repository's own hook below still runs, so disabling this guard never
# disables husky, pre-commit, or whatever else the repo installed.
fail=0
if [ "$mode" = off ]; then
    :
elif [ -d "$dispatch_dir/$hook_name.d" ]; then
    for script in "$dispatch_dir/$hook_name.d"/*; do
        [ -x "$script" ] || continue
        GAG_HOOK="$hook_name" run_child "$script" "$@"
        rc=$?
        if [ "$rc" -eq 1 ]; then
            fail=1
        elif [ "$rc" -ge 2 ]; then
            echo "git-agent-guard: check $(basename "$script") errored (rc=$rc); not blocking." >&2
        fi
    done
fi

if [ "$fail" -eq 1 ]; then
    if [ "$mode" = "advisory" ]; then
        echo "git-agent-guard (advisory): $hook_name checks reported violations above; not blocking." >&2
    else
        exit 1
    fi
fi

# Chain to the repository's own hook, which global hooksPath would otherwise hide.
repo_hook=$(git rev-parse --git-path "hooks/$hook_name" 2>/dev/null || true)
if [ -n "$repo_hook" ] && [ -x "$repo_hook" ]; then
    run_child "$repo_hook" "$@"
    exit $?
fi

exit 0
