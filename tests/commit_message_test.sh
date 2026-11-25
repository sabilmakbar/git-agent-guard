#!/bin/sh
# commit-message check. Sandboxed HOME; only generic example terms.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
pass=0; fail=0
sandbox=$(mktemp -d "${TMPDIR:-/tmp}/gag-cmsg.XXXXXX")
trap 'rm -rf "$sandbox"' EXIT
export HOME="$sandbox/home"
export XDG_CONFIG_HOME="$sandbox/home/.config"
export GIT_CONFIG_GLOBAL="$sandbox/home/.gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="$sandbox"
mkdir -p "$HOME"

check="$root/core/checks/commit-message.sh"
t() { # <name> <want-rc> <cmd>
    "$check" "$3" >/dev/null 2>&1
    g=$?
    if [ "$g" -eq "$2" ]; then pass=$((pass+1)); else
        fail=$((fail+1)); echo "FAIL: $1 (want $2 got $g)"; fi
}

cfgd="$XDG_CONFIG_HOME/git-agent-guard"; mkdir -p "$cfgd"
cfgf="$cfgd/config"; terms="$cfgd/commit-message-terms"

# Opt-in: no config, or anything but the exact `on`, keeps the check silent.
t "no config: check off"        0 'git commit -m "mail a@b.example"'
echo COMMIT_MSG_CHECK=On > "$cfgf"
t "wrong case: check off"       0 'git commit -m "mail a@b.example"'
echo COMMIT_MSG_CHECK=on > "$cfgf"

# Built-in rules
t "plain message passes"        0 'git commit -m "fix parser"'
t "email in message asks"       3 'git commit -m "from a.b@corp.example"'
t "home path in message asks"   3 'git commit -m "moved /Users/someone/notes"'
t "linux home path asks"        3 'git commit -m "see /home/someone/x"'
t "author email asks"           3 'git commit --author="N <n@corp.example>" -m "x"'
t "noreply trailer passes"      0 'git commit -m "x" -m "Co-Authored-By: Claude <noreply@anthropic.com>"'
t "git@host chained push passes" 0 'git commit -m "x" && git push git@github.com:o/r.git main'
t "non-commit command passes"   0 'echo a@b.example'
t "-C path before commit ok"    0 'git -C /Users/someone/repo commit -m "fix"'
t "cd path before commit ok"    0 'cd /Users/someone/repo && git commit -m "fix"'
t "word commit inside message"  3 'git commit -m "commit a@b.example"'
t "empty command passes"        0 ''

# Term list
printf '# comment\n\nacme-corp\n\\bPRJ-[0-9]+\n' > "$terms"
t "term in message asks"        3 'git commit -m "notes for Acme-Corp"'
t "regex term asks"             3 'git commit -m "closes PRJ-42"'
t "unlisted word passes"        0 'git commit -m "notes for someone else"'
printf '# only a comment\n\n' > "$terms"
t "comment-only list passes"    0 'git commit -m "anything at all"'
: > "$terms"
t "empty list passes"           0 'git commit -m "anything at all"'
rm -f "$terms"
t "missing list passes"         0 'git commit -m "anything at all"'

# Message from a file
mdir="$sandbox/m"; mkdir -p "$mdir" "$mdir/sub dir"
printf 'fix parser\n\nreported by a@b.example\n' > "$mdir/bad.txt"
printf 'fix parser\n\nno personal details\n' > "$mdir/ok.txt"
printf 'see /Users/someone/x\n' > "$mdir/sub dir/path.txt"
t "-F file with email asks"       3 "git commit -F $mdir/bad.txt"
t "--file= with email asks"       3 "git commit --file=$mdir/bad.txt"
t "--file path with email asks"   3 "git commit --file $mdir/bad.txt"
t "-F quoted path asks"           3 "git commit -F \"$mdir/bad.txt\""
t "-F path with a space: not read" 0 "git commit -F \"$mdir/sub dir/path.txt\""
t "-F clean file passes"          0 "git commit -F $mdir/ok.txt"
t "-F missing file passes"        0 "git commit -F $mdir/none.txt"
t "-F relative via cd asks"       3 "cd $mdir && git commit -F bad.txt"
t "-F relative via -C asks"       3 "git -C $mdir commit -F bad.txt"
t "-F - heredoc email asks"       3 "git commit -F - <<'EOF'
mail a@b.example
EOF"
t "-F - heredoc clean passes"     0 "git commit -F - <<'EOF'
fix parser
EOF"
printf 'notes for acme-corp\n' > "$mdir/term.txt"
printf 'acme-corp\n' > "$terms"
t "-F file with term asks"        3 "git commit -F $mdir/term.txt"
rm -f "$terms"

echo "commit_message: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
