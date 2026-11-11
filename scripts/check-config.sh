#!/bin/sh
# Fail if a shipped numa.toml carries a key this numa does not know.
# Usage: check-config.sh <path-to-numa-binary>
#
# v0.25.0 logs `unknown key \`<path>\` is ignored` via serde_ignored. A renamed or
# moved key is otherwise silent: the daemon starts on defaults for that block.
set -eu

[ $# -eq 1 ] || { echo "usage: $0 <numa-binary>" >&2; exit 2; }
bin=$1
[ -x "$bin" ] || { echo "$bin is not executable" >&2; exit 1; }

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

mkdir -p "$work/state"
# Every placeholder in the examples must resolve to something local, so the run
# reaches config parsing instead of failing on a network fetch.
printf '# allowlist fixture\n' > "$work/allow.txt"
printf 'canary.invalid\n' > "$work/block.txt"

check() { # check <config-file> <name>
    _log="$work/$(printf '%s' "$2" | tr '/.' '__').log"
    # --version-style probes do not exist; a short serve is the only real parse.
    timeout 20 "$bin" run "$1" >"$_log" 2>&1 || true
    if grep -q 'unknown key' "$_log"; then
        echo "FAIL: $2 has unknown keys:" >&2
        grep 'unknown key' "$_log" >&2
        return 1
    fi
    # Absence of the warning is only meaningful if the config parsed at all.
    if ! grep -qiE 'numa listening|config not found' "$_log"; then
        echo "FAIL: $2 did not start on this config; cannot judge it:" >&2
        tail -20 "$_log" >&2
        return 1
    fi
    echo "check-config: $2 clean"
}

fail=0
sed -e "s#<lan v4>#127.0.0.1#" \
    -e "s#<dnsmasq domain>#lan#" \
    -e "s#/etc/numa/state#$work/state#" \
    -e "s#/etc/numa/canary-block.txt#$work/block.txt#" \
    -e "s#/etc/numa/allow.txt#$work/allow.txt#" \
    -e 's#^bind_addr .*#bind_addr = "127.0.0.1:15453"#' \
    -e 's#^api_port .*#api_port = 15480#' \
    -e 's#^api_bind_addr .*#api_bind_addr = "127.0.0.1"#' \
    -e 's#^address  *= .*#address = ["127.0.0.1:15353"]#' \
    -e 's#^fallback *= .*#fallback = []#' \
    -e 's#^warm .*#warm = []#' \
    -e 's#^upstream = "127.0.0.1:5354"#upstream = "127.0.0.1:15354"#' \
    "$root/pkg/root/etc/numa/numa.toml.example" > "$work/example.toml"
# `lists` spans two lines in the example: replace the whole array, including
# continuation lines, or the leftover line breaks the TOML.
awk -v file="file://$work/block.txt" '
    inlists { if ($0 ~ /\]/) inlists = 0; next }
    /^[[:space:]]*lists[[:space:]]*=/ {
        print "lists = [\"" file "\"]"
        if ($0 !~ /\]/) inlists = 1
        next
    }
    { print }
' "$work/example.toml" > "$work/example.flat"
mv "$work/example.flat" "$work/example.toml"
check "$work/example.toml" numa.toml.example || fail=1

sed -e "s#@DATA_DIR@#$work/state#" \
    -e "s#@CANARY@#$work/block.txt#" \
    -e "s#@BLOCKED2@#$work/block.txt#" \
    -e "s#@ALLOWED@#$work/allow.txt#" \
    -e 's#^bind_addr .*#bind_addr = "127.0.0.1:15454"#' \
    -e 's#^api_port .*#api_port = 15481#' \
    -e 's#^address  *= .*#address = ["127.0.0.1:15353"]#' \
    -e 's#^fallback *= .*#fallback = []#' \
    "$root/tests/smoke.toml" > "$work/smoke.toml"
check "$work/smoke.toml" tests/smoke.toml || fail=1

exit "$fail"
