#!/bin/sh
# Claude Code adapter: PreToolUse hook on Bash.
#
# Reads the tool-call JSON on stdin, extracts the command, runs every
# agent-layer check, and emits Claude Code's permission JSON for the first
# violation. Managed mode denies; advisory mode attaches a warning as context
# and lets the call through. No violation -> no output (allow).

set -u

command -v jq >/dev/null 2>&1 || exit 0

adapter_dir=$(cd "$(dirname "$0")" && pwd)
root="$adapter_dir/../.."
checks_dir="$root/core/checks"
. "$root/core/lib.sh"

# Checked before anything is parsed, so "off" costs one config read rather than
# a full pass that ends in silence.
[ "$(gag_mode)" = off ] && exit 0

cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# Fast exit: nothing git/gh-shaped in the command. A path-qualified name
# (/usr/bin/git) counts too.
printf '%s' "$cmd" | grep -qE '(^|[;&|[:space:]/])(git|gh)([[:space:]]|$)' || exit 0

# Every check runs, and a deny outranks an ask. Otherwise a pending decision
# (ask) reported by an early check would shadow a hard violation found by a
# later one, and file order would decide what the user sees.
deny_msg=""; ask_msg=""
for check in "$checks_dir"/*.sh; do
    [ -x "$check" ] || continue
    # Git-layer-only checks declare themselves by marker and are skipped here.
    grep -q '^# layer: git-only' "$check" && continue
    msg=$("$check" "$cmd")
    rc=$?
    # Contract: 0 pass, 1 deny, 3 ask; anything else is a check bug — never block on it.
    case "$rc" in
        1) [ -n "$deny_msg" ] || deny_msg="$msg" ;;
        3) [ -n "$ask_msg" ]  || ask_msg="$msg" ;;
    esac
done

if [ -n "$deny_msg" ]; then
    decision=deny; msg="$deny_msg"
elif [ -n "$ask_msg" ]; then
    decision=ask; msg="$ask_msg"
else
    exit 0
fi

if [ "$(gag_mode)" = "advisory" ]; then
    jq -n --arg m "git-agent-guard (advisory): $msg" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $m}}'
else
    jq -n --arg m "$msg" --arg d "$decision" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $m}}'
fi
exit 0
