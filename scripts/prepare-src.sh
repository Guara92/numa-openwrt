#!/bin/sh
# Clone the pinned upstream tag into src/ and verify it against upstream.lock.
# Usage: prepare-src.sh
set -eu

[ $# -eq 0 ] || { echo "usage: $0" >&2; exit 2; }

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
lock="$root/upstream.lock"

lock_get() {
    awk -v sec="$1" -v key="$2" '
        /^[[:space:]]*\[/ { s=$0; gsub(/[][[:space:]]/, "", s); next }
        s == sec {
            line=$0; sub(/#.*/, "", line)
            n=split(line, kv, "=")
            if (n < 2) next
            k=kv[1]; gsub(/[[:space:]]/, "", k)
            if (k != key) next
            v=kv[2]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); gsub(/"/, "", v)
            print v; exit
        }
    ' "$lock"
}

repo=$(lock_get upstream repo)
tag=$(lock_get upstream tag)
commit=$(lock_get upstream commit)
mm_source=$(lock_get mimalloc source)

case "$mm_source" in
    upstream) ;;
    *) echo "mimalloc.source=$mm_source (want upstream)" >&2; exit 1 ;;
esac

src_dir="$root/src"
rm -rf "$src_dir"
git clone --quiet "https://github.com/$repo.git" "$src_dir"
git -C "$src_dir" checkout --quiet --detach "$tag"

got=$(git -C "$src_dir" rev-parse HEAD)
[ "$got" = "$commit" ] || { echo "tag $tag is $got, lock pins $commit" >&2; exit 1; }

describe=$(git -C "$src_dir" describe --tags --long)

# Drift detector: the expected describe is pinned in upstream.lock and changes
# only when the tag moves. Warn, not fail, so a legitimate pin bump is not
# blocked by an un-updated lock.
want=$(lock_get build describe)
if [ -n "$want" ] && [ "$describe" != "$want" ]; then
    echo "WARN: describe=$describe, upstream.lock pins $want" >&2
fi

mkdir -p "$root/dist"
{
    echo "TAG=$tag"
    echo "COMMIT=$commit"
    echo "DESCRIBE=$describe"
} > "$root/dist/build-info.env"

echo "prepare-src: $describe"
