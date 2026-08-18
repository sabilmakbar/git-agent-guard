#!/bin/sh
# git-agent-guard installer. Agent-layer (v1): wires the Claude Code adapter
# as a PreToolUse hook and sets attribution keys. Runs from the clone —
# nothing is copied; update with git pull.
#
#   ./install.sh --mode managed|advisory [--dry-run]
#   ./install.sh --uninstall [--dry-run]
#
# Conventions (shared with sibling kits):
#   - --mode is required, no default: the blocking behavior is a choice.
#   - The settings merge only ever adds, and uninstall removes only what this
#     kit wrote (recorded in a manifest), never another tool's entries.
#   - Backup of settings.json is taken before any write.

set -u

root=$(cd "$(dirname "$0")" && pwd)
settings="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/git-agent-guard"
manifest="$cfg_dir/manifest"
adapter="$root/adapters/claude-code/pretooluse.sh"

mode=""; dry=0; uninstall=0
while [ $# -gt 0 ]; do
    case "$1" in
        --mode) mode="${2:-}"; shift 2 ;;
        --dry-run) dry=1; shift ;;
        --uninstall) uninstall=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

say() { printf '%s\n' "$*"; }
act() { [ "$dry" -eq 1 ] && say "[dry-run] $*" || say "$*"; }

# ---------------------------------------------------------------- uninstall
if [ "$uninstall" -eq 1 ]; then
    if [ ! -f "$manifest" ]; then
        say "No manifest at $manifest — nothing recorded as installed."
        exit 0
    fi
    act "Removing this kit's PreToolUse hook entry from $settings"
    if [ "$dry" -eq 0 ] && [ -f "$settings" ]; then
        cp "$settings" "$settings.gag-uninstall-backup"
        jq --arg cmd "$adapter" '
          if .hooks.PreToolUse then
            .hooks.PreToolUse |= ( map(
                .hooks |= map(select(.command != $cmd))
              ) | map(select((.hooks | length) > 0)) )
          else . end
          | if (.hooks.PreToolUse? // null) == [] then .hooks |= del(.PreToolUse) else . end
          | if (.hooks? // null) == {} then del(.hooks) else . end' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
    fi
    if grep -q '^attribution_set=1$' "$manifest" 2>/dev/null; then
        act "Removing attribution keys (this kit set them)"
        if [ "$dry" -eq 0 ] && [ -f "$settings" ]; then
            jq 'del(.attribution)' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
        fi
    else
        say "attribution keys were not set by this kit; leaving them."
    fi
    act "Removing $cfg_dir/config and manifest"
    [ "$dry" -eq 0 ] && rm -f "$cfg_dir/config" "$manifest"
    say "Uninstalled. Backup at $settings.gag-uninstall-backup"
    exit 0
fi

# ------------------------------------------------------------------ install
case "$mode" in
    managed|advisory) ;;
    *) echo "--mode managed|advisory is required (no default: blocking is a choice you make)." >&2; exit 2 ;;
esac

say "== git-agent-guard install (mode: $mode) =="

# Tests gate the install: a kit that polices commands must itself be proven.
say "-- running test suites"
for t in "$root"/tests/*.sh; do
    "$t" >/dev/null 2>&1 || { echo "FATAL: $(basename "$t") failed; not installing. Run it directly to see why." >&2; exit 1; }
done
say "   all suites pass"

# Settings file sanity before touching it.
if [ -f "$settings" ]; then
    jq empty "$settings" 2>/dev/null || { echo "FATAL: $settings is not valid JSON; fix it first. Nothing installed." >&2; exit 1; }
else
    act "Creating $settings"
    [ "$dry" -eq 0 ] && { mkdir -p "$(dirname "$settings")"; echo '{}' > "$settings"; }
fi

already=$(jq --arg cmd "$adapter" '[.hooks.PreToolUse // [] | .[] | .hooks[]? | select(.command == $cmd)] | length' "$settings" 2>/dev/null || echo 0)

act "Backing up $settings -> $settings.gag-backup"
[ "$dry" -eq 0 ] && cp "$settings" "$settings.gag-backup"

if [ "${already:-0}" -gt 0 ]; then
    say "Hook already wired; skipping (idempotent)."
else
    act "Wiring PreToolUse/Bash hook -> $adapter"
    if [ "$dry" -eq 0 ]; then
        jq --arg cmd "$adapter" '
          .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{
            matcher: "Bash",
            hooks: [{type: "command", command: $cmd}]
          }])' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
    fi
fi

attr_set=0
has_attr=$(jq 'has("attribution")' "$settings" 2>/dev/null || echo false)
if [ "$has_attr" = "true" ]; then
    say "attribution already present in settings; leaving as-is: $(jq -c .attribution "$settings")"
else
    act "Setting attribution keys empty (suppresses agent footers in commits and PRs)"
    if [ "$dry" -eq 0 ]; then
        jq '.attribution = {commit: "", pr: ""}' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
    fi
    attr_set=1
fi

act "Writing mode to $cfg_dir/config"
if [ "$dry" -eq 0 ]; then
    mkdir -p "$cfg_dir"
    printf 'MODE=%s\n' "$mode" > "$cfg_dir/config"
    { printf 'hook_command=%s\n' "$adapter"; printf 'attribution_set=%s\n' "$attr_set"; } > "$manifest"
fi

# Legacy overlap report — never remove what this kit did not write.
legacy=$(jq '[.hooks.PreToolUse // [] | .[] | .hooks[]? | select(.command | test("git-staging-guard"))] | length' "$settings" 2>/dev/null || echo 0)
if [ "${legacy:-0}" -gt 0 ]; then
    say "NOTE: a legacy git-staging-guard hook is also wired; this kit supersedes it. Remove that entry manually to avoid double prompts."
fi

say "Done. Identity checks are opt-in: create $cfg_dir/identities (lines: <remote-url-substring> <expected-email>)."
