#!/bin/sh
# Clone the pinned upstream tag and apply the mimalloc overlay (PR #395).
# Usage: prepare-src.sh <musl|mimalloc>
set -eu

usage() { echo "usage: $0 {musl|mimalloc}" >&2; exit 2; }
[ $# -eq 1 ] || usage
alloc=$1
case "$alloc" in musl|mimalloc) ;; *) usage ;; esac

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
pr=$(lock_get mimalloc pr)
head=$(lock_get mimalloc head)

src_dir="$root/src"
rm -rf "$src_dir"
# Full clone: a blob:none partial clone cannot lazy-fetch blobs from the PR's
# ref (the promisor remote rejects "not our ref"), which breaks the cherry-pick.
git clone --quiet "https://github.com/$repo.git" "$src_dir"
git -C "$src_dir" checkout --quiet --detach "$tag"
# CI runners have no git identity; cherry-pick --continue needs one.
git -C "$src_dir" config user.name "numa-openwrt build"
git -C "$src_dir" config user.email "numa-openwrt@users.noreply.github.com"

got=$(git -C "$src_dir" rev-parse HEAD)
[ "$got" = "$commit" ] || { echo "tag $tag is $got, lock pins $commit" >&2; exit 1; }

overlay=0
if [ "$alloc" = mimalloc ]; then
    [ "$mm_source" = pr ] || { echo "mimalloc.source=$mm_source but alloc=mimalloc" >&2; exit 1; }
    git -C "$src_dir" fetch --quiet origin "pull/$pr/head"
    got=$(git -C "$src_dir" rev-parse FETCH_HEAD)
    [ "$got" = "$head" ] || { echo "PR $pr head is $got, lock pins $head" >&2; exit 1; }

    base=$(git -C "$src_dir" merge-base FETCH_HEAD origin/main)
    for c in $(git -C "$src_dir" rev-list --reverse "$base..FETCH_HEAD"); do
        # Reuse the original committer date so the overlay commit hashes (and
        # `git describe`) are identical across machines and builds.
        cdate=$(git -C "$src_dir" show -s --format=%cI "$c")
        if GIT_COMMITTER_DATE="$cdate" git -C "$src_dir" cherry-pick "$c" >/dev/null 2>&1; then
            continue
        fi
        # Only a Cargo.lock conflict is expected (the tag's lock vs the PR's).
        # Anything else means the PR no longer applies cleanly: stop.
        if git -C "$src_dir" diff --name-only --diff-filter=U | grep -qv '^Cargo.lock$'; then
            echo "conflict outside Cargo.lock while applying $c" >&2
            git -C "$src_dir" status --short >&2
            exit 1
        fi
        git -C "$src_dir" checkout HEAD -- Cargo.lock
        # Apply the frozen lock overlay instead of `cargo fetch`: regenerating
        # resolves against the live registry, so the lock (and every commit hash
        # built on it) would differ between machines. The patch is the minimal
        # tag-lock + mimalloc addition; regenerate it when the tag moves.
        git -C "$src_dir" apply "$root/targets/overlay-Cargo.lock.diff" \
            || { echo "pinned Cargo.lock overlay did not apply; regenerate targets/overlay-Cargo.lock.diff" >&2; exit 1; }
        git -C "$src_dir" add Cargo.lock
        if ! GIT_COMMITTER_DATE="$cdate" git -C "$src_dir" -c core.editor=true cherry-pick --continue; then
            echo "cherry-pick --continue failed for $c" >&2
            git -C "$src_dir" status --short >&2
            exit 1
        fi
    done
    overlay=1
fi

describe=$(git -C "$src_dir" describe --tags --long)

mkdir -p "$root/dist"
{
    echo "ALLOC=$alloc"
    echo "TAG=$tag"
    echo "COMMIT=$commit"
    echo "PR=$pr"
    echo "PR_HEAD=$head"
    echo "OVERLAY=$overlay"
    echo "DESCRIBE=$describe"
} > "$root/dist/build-info.env"

if [ "$overlay" = 1 ]; then
    git -C "$src_dir" diff "$tag" -- Cargo.lock > "$root/dist/Cargo.lock.diff" 2>/dev/null || true
fi

echo "prepare-src: $describe (alloc=$alloc, overlay=$overlay)"
