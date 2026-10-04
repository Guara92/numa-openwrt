#!/bin/sh
# Verify the rustc feature set for -C target-cpu=cortex-a73 is a subset of the
# features the Flint 4 reports. Run after `rustup target add`.
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
target=aarch64-unknown-linux-musl
features=$(tr ' ' '\n' < "$root/targets/flint4.features" | grep -v '^$')

# Non-ISA rustc flags. pmuv3 is architectural baseline on every AArch64 core
# (no user-space instruction is gated on it); crt-static is a linkage choice.
IGNORE="crt-static pmuv3"

mapped=$(rustc --print cfg --target "$target" -C target-cpu=cortex-a73 \
    | sed -n 's/^target_feature="\(.*\)"$/\1/p')

fail=0
for f in $mapped; do
    case " $IGNORE " in *" $f "*) continue ;; esac
    case "$f" in
        neon)     names="asimd" ;;
        fp-armv8) names="fp" ;;
        aes)      names="aes pmull" ;;
        sha2)     names="sha1 sha2" ;;
        crc)      names="crc32" ;;
        *)
            echo "unknown rustc feature '$f': review and add to IGNORE if not ISA" >&2
            fail=1
            continue
            ;;
    esac
    for n in $names; do
        if ! echo "$features" | grep -qx "$n"; then
            echo "device lacks cpuinfo feature '$n' (implied by rustc '$f')" >&2
            fail=1
        fi
    done
done

[ "$fail" = 0 ] || exit 1
echo "check-features: cortex-a73 feature set is a subset of targets/flint4.features"
