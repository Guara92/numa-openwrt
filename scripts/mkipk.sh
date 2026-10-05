#!/bin/sh
# Build an opkg 21.02-compatible ipk from pkg/ + a built binary.
# Usage: [IPKG_BUILD=/path/to/ipkg-build] [PUBLISH_VARIANT=v] mkipk.sh
#
# The packaging tool is OpenWrt 21.02 scripts/ipkg-build, pinned; it produces
# the tar.gz-based ipk that opkg 21.02 reads.
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
lock="$root/upstream.lock"
OWRT_COMMIT=78e4cffcd882389cb8f0bf818303f85f8d1e9c8e   # openwrt-21.02

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

variant=${PUBLISH_VARIANT:-$(lock_get build publish)}
rev=$(lock_get build rev)
tag=$(lock_get upstream tag)
up_commit=$(lock_get upstream commit)
mm_head=$(lock_get mimalloc head)
semver=${tag#v}
version=${VERSION:-$semver-$rev}

bin="$root/dist/numa-$variant"
# Artifacts lose the exec bit through upload/download; only existence matters.
[ -f "$bin" ] || { echo "missing $bin (build variant $variant first)" >&2; exit 1; }
chmod 0755 "$bin"

if [ -z "${IPKG_BUILD:-}" ]; then
    clone=$(mktemp -d)
    IPKG_BUILD=$(mktemp -d)/ipkg-build
    git init --quiet "$clone"
    git -C "$clone" remote add origin https://github.com/openwrt/openwrt.git
    git -C "$clone" fetch --quiet --depth 1 origin "$OWRT_COMMIT"
    git -C "$clone" show "FETCH_HEAD:scripts/ipkg-build" > "$IPKG_BUILD"
fi
[ -f "$IPKG_BUILD" ] || { echo "IPKG_BUILD=$IPKG_BUILD is not a file" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

stage="$work/pkg"
mkdir -p "$stage/CONTROL"
cp -a "$root/pkg/root/." "$stage/"
install -m 0755 "$bin" "$stage/usr/sbin/numa"

sed -e "s/@VERSION@/$version/" \
    -e "s/@UPSTREAM_TAG@/$tag/" \
    -e "s/@UPSTREAM_COMMIT@/$up_commit/" \
    -e "s/@MIMALLOC_HEAD@/$mm_head/" \
    "$root/pkg/CONTROL/control.in" > "$stage/CONTROL/control"
cp "$root/pkg/CONTROL/conffiles" "$stage/CONTROL/conffiles"
cp "$root/pkg/CONTROL/postinst" "$root/pkg/CONTROL/prerm" "$stage/CONTROL/"
chmod 0755 "$stage/CONTROL/postinst" "$stage/CONTROL/prerm"

mkdir -p "$root/dist"
sh "$IPKG_BUILD" "$stage" "$root/dist" >/dev/null
ipk="$root/dist/numa_${version}_aarch64_cortex-a53.ipk"
[ -f "$ipk" ] || { echo "ipkg-build produced no ipk in $root/dist" >&2; exit 1; }
sha256sum "$ipk" > "$ipk.sha256"
echo "mkipk: $(basename "$ipk") ($(stat -c %s "$ipk") bytes)"
