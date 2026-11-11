#!/bin/sh
# Build one variant and drop it in dist/.
# Usage: VARIANT={generic|cortex-a73}
#
# Native arm64 musl linking uses musl-gcc. Upstream links mimalloc on every
# musl target, so there is no allocator axis.
set -eu

: "${VARIANT:?set VARIANT=generic|cortex-a73}"
cpu=$VARIANT
case "$cpu" in
    generic|cortex-a73) ;;
    *) echo "bad cpu '$cpu' in VARIANT (want generic|cortex-a73)" >&2; exit 2 ;;
esac

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
src="$root/src"
[ -f "$src/Cargo.toml" ] || { echo "run scripts/prepare-src.sh first" >&2; exit 1; }

target=aarch64-unknown-linux-musl
rustflags=""
cflags=""
if [ "$cpu" = cortex-a73 ]; then
    rustflags="-C target-cpu=cortex-a73"
    cflags="-O3 -mcpu=cortex-a73"
fi

# mimalloc (C) bakes __DATE__/__TIME__ into its version banner, which made the
# published binary change on every rebuild. Pin it to the source revision; the
# cc crate inherits the env and gcc derives both macros from it.
SOURCE_DATE_EPOCH="$(git -C "$src" log -1 --format=%ct)"
export SOURCE_DATE_EPOCH

export CC_aarch64_unknown_linux_musl=musl-gcc
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="$rustflags"
export CFLAGS_aarch64_unknown_linux_musl="$cflags"

cargo build --release --locked --target "$target" --manifest-path "$src/Cargo.toml"

mkdir -p "$root/dist"
out="$root/dist/numa-$VARIANT"
cp "$src/target/$target/release/numa" "$out"
chmod 0755 "$out"

if ! file "$out" | grep -q 'statically linked'; then
    echo "numa-$VARIANT is not statically linked" >&2
    file "$out" >&2
    exit 1
fi

# Upstream gates the allocator on cfg(target_env = "musl"), so a musl build
# without it means the dependency was dropped upstream: catch that here rather
# than ship a binary 30% slower than expected.
strings "$out" | grep -qi mimalloc || { echo "numa-$VARIANT: mimalloc not linked" >&2; exit 1; }

sha=$(sha256sum "$out" | cut -d' ' -f1)
size=$(stat -c %s "$out")
printf '%s  %s\n' "$sha" "numa-$VARIANT" > "$out.sha256"

if [ -f "$root/dist/build-info.env" ]; then
    describe=$(sed -n 's/^DESCRIBE=//p' "$root/dist/build-info.env")
else
    describe=$(git -C "$src" describe --tags --long 2>/dev/null || echo unknown)
fi
printf 'VARIANT=%s\nSHA256=%s\nSIZE=%s\nDESCRIBE=%s\n' \
    "$VARIANT" "$sha" "$size" "$describe" > "$out.info"

echo "build: numa-$VARIANT $size bytes sha256=$sha"
