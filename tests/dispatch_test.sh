#!/bin/sh
# Dispatcher integration tests: symlinked hook entry, registered checks,
# chaining to repo .git/hooks, stdin replay, advisory mode. Sandboxed HOME.

set -u
root=$(cd "$(dirname "$0")/.." && pwd)
pass=0; fail=0

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/gag-dtest.XXXXXX")
trap 'rm -rf "$sandbox"' EXIT
export HOME="$sandbox/home"
export XDG_CONFIG_HOME="$sandbox/home/.config"
export GIT_CONFIG_GLOBAL="$sandbox/home/.gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="$sandbox"
mkdir -p "$HOME"
git config --global user.email test@example.invalid
git config --global user.name gag-test
git config --global init.defaultBranch main

# Simulated install layout: <inst>/{hooks,core,dispatcher}
inst="$sandbox/inst"
mkdir -p "$inst/hooks/pre-commit.d"
cp -R "$root/core" "$inst/core"
cp -R "$root/dispatcher" "$inst/dispatcher"
ln -s ../dispatcher/dispatch.sh "$inst/hooks/pre-commit"
ln -s ../dispatcher/dispatch.sh "$inst/hooks/pre-push"
mkdir -p "$inst/hooks/pre-push.d"

# A registered check that records its stdin, and a repo hook that records both.
cat > "$inst/hooks/pre-push.d/10-record" <<'SH'
#!/bin/sh
cat > "$GAG_TEST_OUT/check-stdin"
exit "${GAG_TEST_CHECK_RC:-0}"
SH
chmod +x "$inst/hooks/pre-push.d/10-record"

repo="$sandbox/repo"
git init -q "$repo"
cat > "$repo/.git/hooks/pre-push" <<'SH'
#!/bin/sh
cat > "$GAG_TEST_OUT/repohook-stdin"
echo ran > "$GAG_TEST_OUT/repohook-ran"
exit 0
SH
chmod +x "$repo/.git/hooks/pre-push"

export GAG_TEST_OUT="$sandbox/out"

check() { # <name> <cond...>
    if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $name"; fi
}

run_hook() { # <hookname> ... ; runs inside repo with stdin "refline"
    ( cd "$repo" && printf 'refs/heads/main abc refs/heads/main def\n' | "$inst/hooks/$1" origin git@example.invalid:o/r.git )
}

# 1. pass-through: check rc=0 -> hook exits 0, repo hook chained, stdin replayed to both
rm -rf "$GAG_TEST_OUT"; mkdir -p "$GAG_TEST_OUT"
GAG_TEST_CHECK_RC=0 run_hook pre-push; rc=$?
name="pass-through exits 0";        check [ "$rc" -eq 0 ]
name="repo hook chained";           check [ -f "$GAG_TEST_OUT/repohook-ran" ]
name="stdin replayed to check";     check grep -q refs/heads "$GAG_TEST_OUT/check-stdin"
name="stdin replayed to repo hook"; check grep -q refs/heads "$GAG_TEST_OUT/repohook-stdin"

# 2. managed: check rc=1 -> hook exits 1, repo hook NOT run
rm -rf "$GAG_TEST_OUT"; mkdir -p "$GAG_TEST_OUT"
GAG_TEST_CHECK_RC=1 run_hook pre-push 2>/dev/null; rc=$?
name="managed violation exits 1";   check [ "$rc" -eq 1 ]
name="repo hook not run on block";  check [ ! -f "$GAG_TEST_OUT/repohook-ran" ]

# 3. advisory: check rc=1 -> hook exits 0, repo hook still runs
mkdir -p "$XDG_CONFIG_HOME/git-agent-guard"
echo MODE=advisory > "$XDG_CONFIG_HOME/git-agent-guard/config"
rm -rf "$GAG_TEST_OUT"; mkdir -p "$GAG_TEST_OUT"
GAG_TEST_CHECK_RC=1 run_hook pre-push 2>/dev/null; rc=$?
name="advisory violation exits 0";  check [ "$rc" -eq 0 ]
name="repo hook runs in advisory";  check [ -f "$GAG_TEST_OUT/repohook-ran" ]
rm -f "$XDG_CONFIG_HOME/git-agent-guard/config"

# 4. check bug (rc=2) never blocks
rm -rf "$GAG_TEST_OUT"; mkdir -p "$GAG_TEST_OUT"
GAG_TEST_CHECK_RC=2 run_hook pre-push 2>/dev/null; rc=$?
name="check error never blocks";    check [ "$rc" -eq 0 ]

# 5. hook with empty .d dir and no repo hook: exits 0
rm -f "$repo/.git/hooks/pre-push"
rm -rf "$GAG_TEST_OUT"; mkdir -p "$GAG_TEST_OUT"
GAG_TEST_CHECK_RC=0 run_hook pre-commit; rc=$?
name="no checks no repo hook ok";   check [ "$rc" -eq 0 ]

echo "----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
