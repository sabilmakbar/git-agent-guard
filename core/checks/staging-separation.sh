#!/bin/sh
# Agent-layer check: refuse one command that both stages and commits.
#
# Staging and committing are approved independently; chaining skips the staging
# review. A transcript audit over 38 sessions found 286 of 488 staging calls
# chained the two (41% adherence). Guidance text could not hold the rule; a
# gate can. Deny rather than ask: the remedy is running the same two commands
# as two calls, so there is nothing to adjudicate.

set -u
. "$(dirname "$0")/../lib.sh"

cmd="${1:-}"
[ -n "$cmd" ] || exit 0

stripped=$(gag_strip_quoted "$cmd")

# `git commit -a` is the same chain in one command: it stages every tracked
# change and commits it. Short flags may be clustered (-am, -va); the cluster
# is only read up to the first flag that takes a value (-m, -F, -C, -c, -t,
# -S, -u), so a value like -mall is not mistaken for -a.
if gag_git_verb "$stripped" commit '-[^-[:space:];&|mFCctSu]*a[^[:space:];&|]*|--all'; then
    echo "This commit uses -a/--all, which stages and commits in one step. Run them as two separate calls so staging can be reviewed on its own: send \`git add ...\` with the paths first, then \`git commit -m ...\` without -a once it returns."
    exit 1
fi

# `git commit <paths>`, -i/--include, -o/--only and --pathspec-from-file stage
# the named paths and commit them in one step too. Read each commit's own
# words, skipping the values of options that take one (-m msg, -mmsg,
# --author=x, --author x, ...), so a value is never mistaken for a path.
# Quoted spans become one placeholder word: `git commit -m "x" file` still has
# a path, and `git commit "my file"` is one.
commit_paths() {
    # shellcheck disable=SC2020  # each of ; & | becomes a newline, one segment per command
    gag_strip_quoted "$cmd" _Q_ \
      | sed 's/[0-9]*[<>]&[0-9-]*/ /g; s/&>/>/g' \
      | tr ';&|' '\n\n\n' | while IFS= read -r seg; do
        gag_git_verb "$seg" commit || continue
        printf '%s\n' "$seg" | awk '{
            for (i = 1; i <= NF && $i != "commit"; i++) ;
            endopt = 0
            for (i++; i <= NF; i++) {
                t = $i
                if (t ~ /^#/) break
                if (t ~ /^[0-9]*[<>]/) { if (t ~ /^[0-9]*[<>]+$/) i++; continue }
                if (endopt) { print "paths"; exit }
                if (t == "--") { endopt = 1; continue }
                if (t ~ /^--/) {
                    n = t; sub(/=.*/, "", n)
                    if ((length(n) >= 5 && index("--include", n) == 1) || (length(n) >= 4 && index("--only", n) == 1)) { print "include/only"; exit }
                    if (length(n) >= 12 && index("--pathspec-from-file", n) == 1) { print "pathspec-from-file"; exit }
                    if (t !~ /=/ && n ~ /^--(message|file|reuse-message|reedit-message|author|date|fixup|squash|trailer|template|cleanup)$/) i++
                    continue
                }
                if (t ~ /^-./) {
                    for (j = 2; j <= length(t); j++) {
                        ch = substr(t, j, 1)
                        if (ch == "i" || ch == "o") { print "include/only"; exit }
                        if (index("mFCct", ch)) { if (j == length(t)) i++; break }
                        if (ch == "S" || ch == "u") break
                    }
                    continue
                }
                print "paths"; exit
            }
        }'
    done | head -1
}
why=$(commit_paths)
if [ -n "$why" ]; then
    echo "This commit names paths (or uses -i/--include, -o/--only, or --pathspec-from-file), which stages them and commits in one step. Run them as two separate calls so staging can be reviewed on its own: send \`git add ...\` with those paths first, then \`git commit -m ...\` without them once it returns."
    exit 1
fi

gag_git_verb "$stripped" add    || exit 0
gag_git_verb "$stripped" commit || exit 0

echo "This call stages and commits together. Run them as two separate calls so staging can be reviewed on its own: send \`git add ...\` first, then \`git commit -m ...\` once it returns."
exit 1
