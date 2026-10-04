#!/bin/sh
# First install of numa on the router. Run as root.
# Usage: [NUMA_OPENWRT_REPO=owner/repo] bootstrap.sh [pubkey-file]
#
# The public key is trusted out-of-band: pass it here (scp'd from the repo) or
# install it to /etc/numa/keys/numa-openwrt.pub beforehand. Everything else is
# verified against it.
set -eu

PUBKEY=/etc/numa/keys/numa-openwrt.pub
STATE_DIR=/etc/numa/state
REPO=${NUMA_OPENWRT_REPO:-Guara92/numa-openwrt}
BASE="https://github.com/$REPO/releases/latest/download"

log() { logger -t numa-bootstrap "$*" 2>/dev/null || true; echo "bootstrap: $*"; }
die() { echo "bootstrap: ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"

if [ -n "${1:-}" ]; then
    mkdir -p "$(dirname "$PUBKEY")"
    cp "$1" "$PUBKEY"
    chmod 0644 "$PUBKEY"
fi
[ -f "$PUBKEY" ] || die "no public key at $PUBKEY (pass the file as \$1)"

for t in usign uclient-fetch jsonfilter opkg; do
    command -v "$t" >/dev/null 2>&1 || die "missing $t"
done

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

uclient-fetch -q -O "$work/manifest.json" "$BASE/manifest.json"
uclient-fetch -q -O "$work/manifest.json.sig" "$BASE/manifest.json.sig"
usign -V -m "$work/manifest.json" -s "$work/manifest.json.sig" -p "$PUBKEY" \
    || die "manifest signature verification failed"

ver=$(jsonfilter -i "$work/manifest.json" -e '$.version')
sha=$(jsonfilter -i "$work/manifest.json" -e '$.ipk.sha256')
ipk="numa_${ver}_aarch64_cortex-a53.ipk"
uclient-fetch -q -O "$work/$ipk" "$BASE/$ipk"
got=$(sha256sum "$work/$ipk" | cut -d' ' -f1)
[ "$got" = "$sha" ] || die "ipk sha256 mismatch"

opkg install "$work/$ipk" || die "opkg install failed"
opkg install bind-dig || log "WARN: bind-dig install failed; probe needs it"

log "installed numa $ver (no service started)"
cat <<'EOF'
Next steps:
  1. numa-ctl gen-config --apply
  2. numa-ctl stage --ipk /etc/numa/pkgcache/<ipk>   (or --variant)
  3. numa-ctl enable
  4. test one client: set its DNS to the router
  5. numa-ctl cutover lan
EOF
