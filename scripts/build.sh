#!/bin/sh
# Build one variant and drop it in dist/.
# Usage: VARIANT={generic|cortex-a73}-{musl|mimalloc} build.sh
#
# Native arm64 musl linking uses musl-gcc. If that fails on the runner, fall
# back to `cross build` exactly as upstream does (same target, generic CPU).
set -eu

: "${VARIANT:?set VARIANT=generic-musl|generic-mimalloc|cortex-a73-musl|cortex-a73-mimalloc}"
cpu=${VARIANT%-*}
alloc=${VARIANT##*-}
case "$cpu" in generic|cortex-a73) ;; *) echo "bad cpu '$cpu' in VARIANT" >&2; exit 2 ;; esac
case "$alloc" in musl|mimalloc) ;; *) echo "bad alloc '$alloc' in VARIANT" >&2; exit 2 ;; esac

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

if [ "$alloc" = mimalloc ]; then
    strings "$out" | grep -qi mimalloc || { echo "numa-$VARIANT: mimalloc not linked" >&2; exit 1; }
else
    if strings "$out" | grep -qi mimalloc; then
        echo "numa-$VARIANT: unexpected mimalloc allocator" >&2
        exit 1
    fi
fi

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
