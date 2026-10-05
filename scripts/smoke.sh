#!/bin/sh
# Native dual-stack smoke test for one built variant.
# Usage: sudo VARIANT=generic-musl scripts/smoke.sh
#
# Exits non-zero on any hard failure. The upstream `example.com` check is a
# warning only (network flake).
set -eu

: "${VARIANT:?set VARIANT=...}"
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
bin="$root/dist/numa-$VARIANT"
[ -x "$bin" ] || { echo "missing $bin (run scripts/build.sh)" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
command -v dig >/dev/null 2>&1 || { echo "dig not found: apt-get install dnsutils" >&2; exit 1; }

work=$(mktemp -d)
pid=
cleanup() {
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    ip link del numa0 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

ip link del numa0 2>/dev/null || true
ip link add numa0 type dummy
ip link set numa0 up
ip addr add 10.99.0.1/24 dev numa0
ip addr add 10.99.1.1/24 dev numa0
ip -6 addr add fd99::1/64 dev numa0 nodad

cp "$root/pkg/root/etc/numa/canary-block.txt" "$work/canary-block.txt"
sed -e "s#@DATA_DIR@#$work/state#" -e "s#@CANARY@#$work/canary-block.txt#" \
    "$root/tests/smoke.toml" > "$work/numa.toml"
mkdir -p "$work/state"

"$bin" run "$work/numa.toml" >"$work/numa.log" 2>&1 &
pid=$!

dig_short() { dig +short +time=2 +tries=1 -p 15353 "$@" 2>/dev/null; }
dig_warn()  { dig +time=2 +tries=1 -p 15353 "$@" 2>&1 | grep -qi 'unexpected source'; }

i=0
while [ "$i" -lt 25 ]; do
    [ "$(dig_short "@127.0.0.1" canary.numa-ctl.internal A)" = "192.0.2.53" ] && break
    i=$((i + 1))
    sleep 0.4
done
if [ "$i" -ge 25 ]; then
    echo "FAIL: numa never answered the canary" >&2
    cat "$work/numa.log" >&2
    exit 1
fi

fail=0
for addr in 127.0.0.1 ::1 10.99.0.1 10.99.1.1 fd99::1; do
    for proto in udp tcp; do
        extra=
        [ "$proto" = tcp ] && extra=+tcp
        ans=$(dig_short $extra "@$addr" canary.numa-ctl.internal A)
        if [ "$ans" != "192.0.2.53" ]; then
            echo "FAIL canary @$addr/$proto -> '$ans'" >&2
            fail=1
        fi
        if dig_warn $extra "@$addr" canary.numa-ctl.internal A; then
            echo "FAIL @$addr/$proto: reply from unexpected source" >&2
            fail=1
        fi
    done
done

# Blocklist load is async: retry up to 60 s. The sinkhole form is pinned to
# A -> 0.0.0.0 (NOERROR) in docs/NOTES.md; an empty reply (NXDOMAIN forwarded
# upstream before the list loads) must not pass.
blocked=0
i=0
while [ "$i" -lt 30 ]; do
    ans=$(dig_short "@127.0.0.1" blocked.numa-ctl.internal A)
    [ "$ans" = "0.0.0.0" ] && { blocked=1; break; }
    i=$((i + 1))
    sleep 2
done
[ "$blocked" = 1 ] || { echo "FAIL: blocked.numa-ctl.internal not sinkholed to 0.0.0.0" >&2; fail=1; }

tag=$(sed -n 's/^TAG=v//p' "$root/dist/build-info.env" 2>/dev/null || true)
ver=$("$bin" --version 2>&1 || true)
if [ -n "$tag" ]; then
    case "$ver" in
        "numa $tag"*) ;;
        *) echo "FAIL: --version '$ver' does not start with 'numa $tag'" >&2; fail=1 ;;
    esac
fi

# Idle RSS must stay low: catches a mimalloc arena_eager_commit regression.
sleep 5
rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)
if [ "$rss" -ge 20480 ]; then
    echo "FAIL: idle VmRSS ${rss} kB >= 20480 kB" >&2
    fail=1
fi

i=0
ok=0
while [ "$i" -lt 10 ]; do
    ans=$(dig_short "@127.0.0.1" example.com A)
    [ -n "$ans" ] && { ok=1; break; }
    i=$((i + 1))
    sleep 1
done
[ "$ok" = 1 ] || echo "WARN: example.com did not resolve (upstream network?)" >&2

if [ "$fail" != 0 ]; then
    echo "--- numa log ---" >&2
    cat "$work/numa.log" >&2
    exit 1
fi
echo "smoke: numa-$VARIANT OK (idle VmRSS ${rss} kB)"
