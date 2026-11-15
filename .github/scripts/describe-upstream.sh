#!/bin/sh
# Print the `git describe --tags --long` string for an upstream tag, which is
# what upstream.lock's [build].describe pins and what prepare-src.sh compares
# against.
# Usage: describe-upstream.sh <owner/repo> <tag> <commit>
set -eu

[ $# -eq 3 ] || { echo "usage: $0 <owner/repo> <tag> <commit>" >&2; exit 2; }
repo=$1; tag=$2; commit=$3

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

# Shallow-fetch only the tag: describe needs the commit and its tag, nothing
# else in the history.
git init --quiet "$work"
git -C "$work" remote add origin "https://github.com/$repo.git"
git -C "$work" fetch --quiet --depth 1 origin "refs/tags/$tag:refs/tags/$tag"

got=$(git -C "$work" rev-parse "$tag^{commit}")
[ "$got" = "$commit" ] || { echo "tag $tag is $got, expected $commit" >&2; exit 1; }

git -C "$work" describe --tags --long "$tag"
