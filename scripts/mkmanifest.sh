#!/bin/sh
# Emit dist/manifest.json from the built artifacts and, when a key is present,
# dist/manifest.json.sig.
#
# Signing env:
#   USIGN        path to the usign binary (required to sign)
#   USIGN_KEY    path to the usign secret key, or
#   USIGN_SECRET_KEY  base64-encoded secret key (decoded to a temp file)
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
lock="$root/upstream.lock"
dist="$root/dist"

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

rev=$(lock_get build rev)
tag=$(lock_get upstream tag)
up_commit=$(lock_get upstream commit)
mm_source=$(lock_get mimalloc source)
mm_pr=$(lock_get mimalloc pr)
mm_head=$(lock_get mimalloc head)
publish=$(lock_get build publish)
version=${VERSION:-${tag#v}-$rev}
rustc_ver=$(rustc --version 2>/dev/null | awk '{print $2}')

ipk="$dist/numa_${version}_aarch64_cortex-a53.ipk"
[ -f "$ipk" ] || { echo "missing $ipk (run scripts/mkipk.sh)" >&2; exit 1; }
ipk_sha=$(sha256sum "$ipk" | cut -d' ' -f1)

binaries=""
for f in "$dist"/numa-*.sha256; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .sha256)
    variant=${name#numa-}
    sha=$(cut -d' ' -f1 "$f")
    info="$dist/$name.info"
    describe=unknown
    [ -f "$info" ] && describe=$(sed -n 's/^DESCRIBE=//p' "$info")
    item=$(printf '{"variant":"%s","name":"%s","sha256":"%s","describe":"%s"}' \
        "$variant" "$name" "$sha" "$describe")
    if [ -z "$binaries" ]; then binaries=$item; else binaries="$binaries,$item"; fi
done
[ -n "$binaries" ] || { echo "no dist/numa-* binaries to manifest" >&2; exit 1; }

mkdir -p "$dist"
cat > "$dist/manifest.json" <<EOF
{"version":"$version",
 "upstream":{"tag":"$tag","commit":"$up_commit"},
 "mimalloc":{"source":"$mm_source","pr":$mm_pr,"head":"$mm_head"},
 "rustc":"$rustc_ver","published_variant":"$publish",
 "ipk":{"name":"numa_${version}_aarch64_cortex-a53.ipk","sha256":"$ipk_sha"},
 "binaries":[$binaries]}
EOF

if [ -n "${USIGN:-}" ]; then
    key=${USIGN_KEY:-}
    if [ -z "$key" ] && [ -n "${USIGN_SECRET_KEY:-}" ]; then
        key=$(mktemp)
        printf '%s' "$USIGN_SECRET_KEY" | base64 -d > "$key"
    fi
    [ -n "$key" ] || { echo "USIGN set but no USIGN_KEY/USIGN_SECRET_KEY" >&2; exit 1; }
    "$USIGN" -S -m "$dist/manifest.json" -s "$key" -x "$dist/manifest.json.sig"
    echo "mkmanifest: dist/manifest.json + dist/manifest.json.sig"
else
    echo "mkmanifest: dist/manifest.json (unsigned: USIGN unset)"
fi
