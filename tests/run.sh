#!/bin/sh
# git-agent-guard test runner.
#
# HARD RULE: tests never touch real state. Every test runs inside a throwaway
# HOME with git configuration pinned to sandbox files. Nothing is seeded from
# the real HOME — a sandbox holding a copy of real settings is how a sibling
# kit once modified the real store through an absolute path (memory-kit PR #42).

set -u

root=$(cd "$(dirname "$0")/.." && pwd)
pass=0; fail=0

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/gag-test.XXXXXX")
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

# Containment assertion: the sandbox HOME must not be the real one.
case "$HOME" in "$sandbox"/*) : ;; *) echo "FATAL: sandbox HOME escaped"; exit 99 ;; esac

t() { # t <name> <expected-rc> <check> <command-string>
    _name=$1; _want=$2; _check=$3; _cmd=$4
    "$root/core/checks/$_check" "$_cmd" > /dev/null 2>&1
    _got=$?
    if [ "$_got" -eq "$_want" ]; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); echo "FAIL: $_name (want rc=$_want got rc=$_got)"
    fi
}

# --- staging-separation ---------------------------------------------------
t "chained add+commit denied"        1 staging-separation.sh 'git add -A && git commit -m "x"'
t "semicolon chain denied"           1 staging-separation.sh 'git add .; git commit -m "x"'
t "git -C chain denied"              1 staging-separation.sh 'git -C /tmp/repo add -A && git -C /tmp/repo commit -m "x"'
t "add alone allowed"                0 staging-separation.sh 'git add -A'
t "commit alone allowed"             0 staging-separation.sh 'git commit -m "msg"'
t "verbs only in message allowed"    0 staging-separation.sh 'git commit -m "git add and git commit docs"'
t "verbs only in grep allowed"       0 staging-separation.sh 'grep -r "git add && git commit" docs/'
t "path containing add allowed"      0 staging-separation.sh 'git status && cat notes/add-commit.md'
t "heredoc body with verbs allowed" 0 staging-separation.sh 'cat > t.sh <<EOF
git add f.txt && git commit -qm init
EOF'
t "heredoc quoted tag allowed"      0 staging-separation.sh 'cat > t.sh <<'"'"'SH'"'"'
git add . && git commit -m x
SH'
t "real chain after heredoc denied"  1 staging-separation.sh 'cat > t.sh <<EOF
hello
EOF
git add -A && git commit -m "x"'
t "empty command allowed"            0 staging-separation.sh ''
t "verbs on a message's 2nd line ok" 0 staging-separation.sh 'git commit -m "subject

git add x && git commit -m y"'
t "commit -a denied"                 1 staging-separation.sh 'git commit -a -m "x"'
t "commit --all denied"              1 staging-separation.sh 'git commit --all -m "x"'
t "commit -am denied"                1 staging-separation.sh 'git commit -am "x"'
t "commit -qam denied"               1 staging-separation.sh 'git commit -qam "x"'
t "commit -a after message denied"   1 staging-separation.sh 'git commit -m "x" -a'
t "commit -a with globals denied"    1 staging-separation.sh 'git -C /tmp/r commit -va'
t "commit -a in a chain denied"      1 staging-separation.sh 'git status && git commit -a -m "x" && git push'
t "commit; then -a elsewhere ok"     0 staging-separation.sh 'git commit -m "x"; ls -a'
t "commit --amend allowed"           0 staging-separation.sh 'git commit --amend --no-edit'
t "commit --allow-empty allowed"     0 staging-separation.sh 'git commit --allow-empty -m "x"'
t "commit -m value with a allowed"   0 staging-separation.sh 'git commit -mall'
t "commit message a allowed"         0 staging-separation.sh 'git commit -m a'
t "-a only in message allowed"       0 staging-separation.sh 'git commit -m "use git commit -a"'
t "add+commit no-space chain denied" 1 staging-separation.sh 'git add -A && git commit&& true'

# commit naming paths stages and commits them in one step
t "commit <path> denied"             1 staging-separation.sh 'git commit f.txt'
t "commit -m x <path> denied"        1 staging-separation.sh 'git commit -m "x" f.txt'
t "commit -mx <path> denied"         1 staging-separation.sh 'git commit -mx f.txt'
t "commit after -- denied"           1 staging-separation.sh 'git commit -m "x" -- f.txt'
t "commit quoted path denied"        1 staging-separation.sh 'git commit -m "x" "my file.txt"'
t "commit -i denied"                 1 staging-separation.sh 'git commit -i -m "x"'
t "commit --include denied"          1 staging-separation.sh 'git commit --include -m "x"'
t "commit -o denied"                 1 staging-separation.sh 'git commit -o -m "x"'
t "commit --only denied"             1 staging-separation.sh 'git commit --only -m "x"'
t "commit clustered -vi denied"      1 staging-separation.sh 'git commit -vi -m "x"'
t "commit --pathspec-from-file denied" 1 staging-separation.sh 'git commit --pathspec-from-file=list.txt -m "x"'
t "commit with globals, path denied" 1 staging-separation.sh 'git -C /tmp/r commit -m "x" .'
t "second commit names path denied"  1 staging-separation.sh 'git commit -m "x"; git commit f.txt'
t "plain commit allowed"             0 staging-separation.sh 'git commit'
t "commit -mvalue allowed"           0 staging-separation.sh 'git commit -mfix'
t "commit -F file allowed"           0 staging-separation.sh 'git commit -F msg.txt'
t "commit -F - heredoc allowed"      0 staging-separation.sh 'git commit -F - <<EOF
subject words here
EOF'
t "commit -C/-c commit allowed"      0 staging-separation.sh 'git commit -C HEAD && git commit -c HEAD~1'
t "commit -t template allowed"       0 staging-separation.sh 'git commit -t tpl.txt'
t "commit long values allowed"       0 staging-separation.sh 'git commit --author "A <a@x>" --date now --trailer "k: v" --cleanup strip -m "x"'
t "commit long = values allowed"     0 staging-separation.sh 'git commit --author=a --date=now --message=x'
t "commit --fixup/--squash allowed"  0 staging-separation.sh 'git commit --fixup HEAD && git commit --squash=HEAD'
t "commit -S / -Skey allowed"        0 staging-separation.sh 'git commit -S -m "x" && git commit -SABCD -m "x"'
t "commit --no-verify allowed"       0 staging-separation.sh 'git commit --no-verify -m "x"'
t "commit redirections allowed"      0 staging-separation.sh 'git commit -m "x" 2>&1 >/dev/null > out.txt | tail -1'
t "commit trailing comment allowed"  0 staging-separation.sh 'git commit -m x # done'
t "commit multi-line message ok"     0 staging-separation.sh 'git commit -m "subject

body line with words"'
t "commit message via heredoc ok"    0 staging-separation.sh 'git commit -m "$(cat <<'"'"'EOF'"'"'
subject (with parens
body words
EOF
)"'

# --- verb matching through global options and launch prefixes --------------
t "-c key=val chain denied"          1 staging-separation.sh 'git -c core.x=1 add -A && git commit -m "x"'
t "-ckey=val chain denied"           1 staging-separation.sh 'git -ccore.x=1 add -A && git -ccore.x=1 commit -m "x"'
t "-c quoted value chain denied"     1 staging-separation.sh 'git -c "user.name=a b" add -A && git commit -m "x"'
t "--namespace= chain denied"        1 staging-separation.sh 'git --namespace=ns add -A && git commit -m "x"'
t "-P / --paginate chain denied"     1 staging-separation.sh 'git -P add -A && git --paginate commit -m "x"'
t "--no-replace-objects denied"      1 staging-separation.sh 'git --no-replace-objects add -A && git --literal-pathspecs commit -m "x"'
t "stacked global options denied"    1 staging-separation.sh 'git --no-pager -C /tmp/r -c a=b --git-dir=/tmp/r/.git add -A && git commit -m "x"'
t "absolute git path denied"         1 staging-separation.sh '/usr/bin/git add -A && /usr/bin/git commit -m "x"'
t "relative git path denied"         1 staging-separation.sh './bin/git add -A && git commit -m "x"'
t "command git denied"               1 staging-separation.sh 'command git add -A && command git commit -m "x"'
t "env git denied"                   1 staging-separation.sh 'env git add -A && env -i git commit -m "x"'
t "VAR=val git denied"               1 staging-separation.sh 'GIT_AUTHOR_NAME=x git add -A && A=1 B=2 git commit -m "x"'
t "env VAR=val git denied"           1 staging-separation.sh 'env GIT_DIR=.git git add -A && git commit -m "x"'
t "-c alone with commit allowed"     0 staging-separation.sh 'git -c core.x=1 commit -m "x"'
t "/usr/bin/git add alone allowed"   0 staging-separation.sh '/usr/bin/git add -A'
t "git-like names not matched"       0 staging-separation.sh 'mygit add -A && legit commit -m "x"'
t "echoed verbs not matched"         0 staging-separation.sh 'echo env git add; echo command git commit'
t "path to non-git not matched"      0 staging-separation.sh '/usr/bin/gitx add -A && git commit -m "x"'

# --- pr-merge ---------------------------------------------------------------
t "gh pr merge denied"               1 pr-merge.sh 'gh pr merge 42 --squash'
t "chained gh pr merge denied"       1 pr-merge.sh 'git push && gh pr merge 42'
t "gh api merge endpoint denied"     1 pr-merge.sh 'gh api -X PUT repos/o/r/pulls/42/merge'
t "gh pr view allowed"               0 pr-merge.sh 'gh pr view 42 --json state'
t "gh pr create allowed"             0 pr-merge.sh 'gh pr create --title t --body b'
t "merge only in message allowed"    0 pr-merge.sh 'git commit -m "gh pr merge is forbidden"'
t "git merge allowed (local)"        0 pr-merge.sh 'git merge feature-branch'
t "VAR=val gh pr merge denied"       1 pr-merge.sh 'GH_REPO=o/r gh pr merge 42'
t "absolute gh path merge denied"    1 pr-merge.sh '/opt/homebrew/bin/gh pr merge 42'
t "command gh pr merge denied"       1 pr-merge.sh 'command gh pr merge 42'

# --- hidden-invocation (raw command: quotes intact) -------------------------
t "sh -c git denied"                 1 hidden-invocation.sh "sh -c 'git add -A && git commit -m x'"
t "bash -lc git denied"              1 hidden-invocation.sh 'bash -lc "git status"'
t "eval git denied"                  1 hidden-invocation.sh 'eval "git add ."'
t "\$( ) git denied"                 1 hidden-invocation.sh 'echo $(git rev-parse HEAD)'
t "\$( ) in assignment denied"       1 hidden-invocation.sh 'v=$(git rev-parse HEAD)'
t "\$( ) in dq message denied"       1 hidden-invocation.sh 'git commit -m "at $(git rev-parse HEAD)"'
t "backticks git denied"             1 hidden-invocation.sh 'echo `git log -1`'
t "process substitution denied"      1 hidden-invocation.sh 'diff <(git show HEAD:f) f'
t "xargs git denied"                 1 hidden-invocation.sh 'ls | xargs git add'
t "xargs -I git denied"              1 hidden-invocation.sh 'xargs -I{} git add {}'
t "exec git denied"                  1 hidden-invocation.sh 'exec git status'
t "nohup git denied"                 1 hidden-invocation.sh 'nohup git fetch &'
t "time git denied"                  1 hidden-invocation.sh 'time git status'
t "( ) grouping denied"              1 hidden-invocation.sh '(cd /tmp && git status)'
t "{ } grouping denied"              1 hidden-invocation.sh '{ git status; }'
t "find -exec git denied"            1 hidden-invocation.sh 'find . -exec git add {} \;'
t "pipe into a shell denied"         1 hidden-invocation.sh "echo 'git add -A' | sh"
t "heredoc into a shell denied"      1 hidden-invocation.sh "bash <<'EOF'
git add -A
EOF"
t "here-string into a shell denied"  1 hidden-invocation.sh "bash <<< 'git status'"
t "\$( ) in unquoted heredoc denied" 1 hidden-invocation.sh 'cat > f.txt <<EOF
at $(git rev-parse HEAD)
EOF'
t "sudo git denied"                  1 hidden-invocation.sh 'sudo git pull'
t "sudo -u git denied"               1 hidden-invocation.sh 'sudo -u root git status'
t "doas/pkexec/run0 git denied"      1 hidden-invocation.sh 'doas git push; pkexec git log; run0 git log'
t "su -c git denied"                 1 hidden-invocation.sh "su -c 'git log' root"
t "sudo sh -c git denied"            1 hidden-invocation.sh "sudo sh -c 'git pull'"
t "plain git allowed"                0 hidden-invocation.sh 'git status && git log -1 | head'
t "env/command git allowed"          0 hidden-invocation.sh 'env GIT_DIR=.git git status; command git log'
t "single-quoted \$( ) allowed"      0 hidden-invocation.sh "git commit -m 'use \$(git rev-parse HEAD)'"
t "escaped \$( ) in dq allowed"      0 hidden-invocation.sh 'git commit -m "use \$(git rev-parse HEAD)"'
t "single-quoted backticks allowed"  0 hidden-invocation.sh "git commit -m 'run \`git add\` first'"
t "quoted heredoc literal allowed"   0 hidden-invocation.sh "cat > f.sh <<'EOF'
git add -A
\$(git status) and \`git log\`
EOF"
t "unquoted heredoc plain git ok"    0 hidden-invocation.sh 'cat > f.sh <<EOF
git add -A && git commit -m x
EOF'
t "commit message via heredoc ok"    0 hidden-invocation.sh "git commit -m \"\$(cat <<'EOF'
subject (git words, sudo, and \$(git x)
EOF
)\""
t "\$( ) without git allowed"        0 hidden-invocation.sh 'git -C "$(pwd)" status'
t "sudo without git allowed"         0 hidden-invocation.sh 'sudo apt install git'
t "git-like words allowed"           0 hidden-invocation.sh 'cat .gitignore; ls ./ghost; echo github'

# --- elevation (ask, any command) -------------------------------------------
t "sudo asks"                        3 elevation.sh 'sudo rm -rf /tmp/x'
t "doas/pkexec/run0 ask"             3 elevation.sh 'doas ls; pkexec ls; run0 ls'
t "su asks"                          3 elevation.sh 'su - root'
t "su -c asks"                       3 elevation.sh "su -c 'ls' root"
t "sudo after && asks"               3 elevation.sh 'ls && sudo make install'
t "sudo after | asks"                3 elevation.sh 'ls | sudo tee /etc/x'
t "sudo after || and ; asks"         3 elevation.sh 'false || sudo ls; true'
t "sudo in sh -c asks"               3 elevation.sh "bash -c 'sudo ls'"
t "sudo in eval asks"                3 elevation.sh 'eval "sudo ls"'
t "sudo in \$( ) asks"               3 elevation.sh 'echo $(sudo whoami)'
t "sudo in dq \$( ) asks"            3 elevation.sh 'echo "$(sudo whoami)"'
t "sudo in backticks asks"           3 elevation.sh 'echo `sudo whoami`'
t "sudo behind xargs asks"           3 elevation.sh 'ls | xargs sudo rm'
t "sudo behind env/command asks"     3 elevation.sh 'env A=1 sudo ls'
t "sudo behind exec/nohup/time asks" 3 elevation.sh 'time sudo ls'
t "sudo in ( ) asks"                 3 elevation.sh '(sudo ls)'
t "sudo in { } asks"                 3 elevation.sh '{ sudo ls; }'
t "sudo in heredoc to shell asks"    3 elevation.sh "sh <<'EOF'
sudo ls
EOF"
t "path-qualified sudo asks"         3 elevation.sh '/usr/bin/sudo ls'
t "grep sudo allowed"                0 elevation.sh 'grep -r sudo docs/'
t "single-quoted sudo allowed"       0 elevation.sh "echo 'use sudo'"
t "sudo in commit message allowed"   0 elevation.sh "git commit -m 'mention sudo'"
t "sudo in dq text allowed"          0 elevation.sh 'git commit -m "mention sudo"'
t "single-quoted \$(sudo) allowed"   0 elevation.sh "echo '\$(sudo whoami)'"
t "sudo in sh -c text allowed"       0 elevation.sh "bash -c 'echo sudo'"
t "literal heredoc sudo allowed"     0 elevation.sh "cat > f.sh <<'EOF'
sudo apt install x
EOF"
t "unquoted heredoc sudo allowed"    0 elevation.sh 'cat > f.sh <<EOF
sudo apt install x
EOF'
t "sudo as a filename allowed"       0 elevation.sh 'echo hi > /tmp/sudo; ls sudoers.d'

echo "----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
