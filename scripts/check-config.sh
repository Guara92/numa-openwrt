#!/bin/sh
# Fail if a shipped numa.toml carries a key this numa does not know.
# Usage: check-config.sh <path-to-numa-binary>
#
# numa logs `unknown key \`<path>\` is ignored` via serde_ignored. A renamed or
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

# numa-ctl gen-config writes the config a router actually runs, from a heredoc
# inside the script. Render that heredoc so a key the daemon no longer accepts
# fails here rather than on the router.
awk '/cat > "\$_out" <<EOF/{on=1;next} on&&/^EOF$/{exit} on' \
    "$root/pkg/root/usr/sbin/numa-ctl" > "$work/gen.toml"
if [ ! -s "$work/gen.toml" ]; then
    echo "FAIL: could not extract the gen-config heredoc from numa-ctl" >&2
    fail=1
else
    grep -q '^\[upstream\]' "$work/gen.toml" || {
        echo "FAIL: gen-config heredoc extraction lost its [upstream] section" >&2
        fail=1
    }
    # The heredoc is only valid TOML once its five shell expansions are filled.
    # $_ts_forward holds a whole [[forwarding]] block built by ts_forward_block().
    # That block is extracted verbatim and only its argument is substituted, so a
    # renamed or dropped key inside the real block reaches the parser instead of
    # being papered over by a hand-written copy.
    awk '/^ts_forward_block\(\)/ {infn=1; next}
         infn && /^[[:space:]]*cat <<EOF$/ {on=1; next}
         infn && on && /^EOF$/ {exit}
         on {print}
        ' "$root/pkg/root/usr/sbin/numa-ctl" > "$work/ts.block"
    if [ ! -s "$work/ts.block" ]; then
        echo "FAIL: could not extract ts_forward_block from numa-ctl" >&2
        fail=1
    fi
    # shellcheck disable=SC2016  # the block's $1 is the value placeholder
    sed -e 's#\$1#tailnet.example.ts.net#' "$work/ts.block" > "$work/ts.ready"
    awk -v blk="$work/ts.ready" '
         /^\$_ts_forward$/ { while ((getline l < blk) > 0) print l; close(blk); next }
         { print }' "$work/gen.toml" > "$work/gen.ts.toml"
    # shellcheck disable=SC2016  # matching the literal $_name text, not expanding
    sed -e 's#$_suffix#"lan", "168.192.in-addr.arpa", "d.f.ip6.arpa"#' \
        -e 's#\$CANARY_A#192.0.2.53#' \
        -e 's#\$CANARY#canary.numa-ctl.internal#' \
        -e 's#\$_api#127.0.0.1#' \
        -e "s#/etc/numa/state#$work/state#" \
        -e "s#/etc/numa/canary-block.txt#$work/block.txt#" \
        -e "s#/etc/numa/allow.txt#$work/allow.txt#" \
        -e 's#^bind_addr .*#bind_addr = "127.0.0.1:15455"#' \
        -e 's#^api_port .*#api_port = 15482#' \
        -e 's#^api_bind_addr .*#api_bind_addr = "127.0.0.1"#' \
        -e 's#^address  *= .*#address = ["127.0.0.1:15353"]#' \
        -e 's#^fallback *= .*#fallback = []#' \
        -e 's#^warm .*#warm = []#' \
        -e 's#^upstream = "127.0.0.1:5354"#upstream = "127.0.0.1:15355"#' \
        "$work/gen.ts.toml" > "$work/gen.ready.toml"
    # A config that parses is not a config that routes tailnet names. Collapse
    # each [[forwarding]] block to one "index|suffix|upstream" line so the checks
    # below can require that ONE block carries both the tailnet suffix and the
    # MagicDNS upstream. Text matching cannot: it passes a wrong suffix, and it
    # passes when the suffix and the upstream belong to different blocks.
    awk '
        /^\[\[forwarding\]\]$/ { if (blk) print n "|" suf "|" up
                                 n++; suf = ""; up = ""; blk = 1; next }
        /^\[/ { if (blk) { print n "|" suf "|" up; blk = 0 } ; next }
        blk && /^suffix[[:space:]]*=/ { suf = $0; next }
        blk && /^upstream[[:space:]]*=/ { up = $0; next }
        END { if (blk) print n "|" suf "|" up }
    ' "$work/gen.ready.toml" > "$work/blocks"
    # Each block is "index|suffix-line|upstream-line"; one block must pair the
    # tailnet suffix with the MagicDNS upstream, and it must come after dnsmasq.
    _tsblk=$(awk -F'|' -v s='tailnet[.]example[.]ts[.]net' -v u='100[.]100[.]100[.]100:53' \
        '$2 ~ s && $3 ~ u { print $1; exit }' "$work/blocks")
    if [ -z "$_tsblk" ]; then
        echo "FAIL: no single [[forwarding]] block pairs the tailnet suffix" >&2
        echo "      with the MagicDNS upstream in gen-config's output" >&2
        fail=1
    fi
    _dsblk=$(awk -F'|' -v s='"lan"' -v u='127[.]0[.]0[.]1:15355' \
        '$2 ~ s && $3 ~ u { print $1; exit }' "$work/blocks")
    if [ -z "$_dsblk" ]; then
        echo "FAIL: gen-config's output has no dnsmasq forwarding block" >&2
        fail=1
    elif [ -n "$_tsblk" ] && [ "$_tsblk" -lt "$_dsblk" ]; then
        echo "FAIL: the MagicDNS rule precedes the dnsmasq rule; the latter matches first" >&2
        fail=1
    fi
    check "$work/gen.ready.toml" "numa-ctl gen-config" || fail=1
fi

exit "$fail"
