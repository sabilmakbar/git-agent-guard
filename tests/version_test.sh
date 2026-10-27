#!/bin/sh
# A release tag must name the version in the changelog and install instructions.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
version=$(sed -n 's/^## \([0-9][0-9.]*\)$/\1/p' "$root/CHANGELOG.md" | head -n 1)
[ -n "$version" ] || { echo 'No release version in CHANGELOG.md' >&2; exit 1; }
grep -F "git clone --branch v$version https://github.com/sabilmakbar/git-agent-guard.git" "$root/README.md" >/dev/null || {
    echo "README install tag does not match changelog v$version" >&2; exit 1;
}
# An untagged checkout is normal development. On a release tag, check the tag too.
tag=$(git -C "$root" describe --tags --exact-match HEAD 2>/dev/null || true)
case "$tag" in
    '') ;;
    "v$version") ;;
    *) echo "Tag $tag does not match changelog v$version" >&2; exit 1 ;;
esac
echo "release version v$version matches README${tag:+ and tag}"
