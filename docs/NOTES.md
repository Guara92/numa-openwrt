# numa-openwrt notes

Verification log. `⚠` items from the design notes get a line here once checked
on the device or in CI. Keep it factual: command, result.

## Pins (re-verified 2026-11-18)

- upstream tag `v0.25.2` -> commit `e966c0658eb65211429a29b01d194e7c68d517c1` (latest release).
- mimalloc comes from upstream: v0.25.2 depends on `mimalloc 0.1.52` and
  `libmimalloc-sys 0.1.49` under `cfg(target_env = "musl")`, so this repo applies
  no patch. `cargo tree --target aarch64-unknown-linux-musl` lists both; the gnu
  target lists neither. Both versions are unchanged since v0.25.0.
- rust pinned `1.100.0`. v0.25.2 has no `rust-version` and builds on it: the host
  build (`rustup run 1.100.0 cargo build --release --locked`) succeeds.
- `-C target-cpu=cortex-a73` target features (rustc 1.100.0, `aarch64-unknown-linux-musl`):
  `aes crc neon pmuv3 sha2` (+ `crt-static`). Mapped to cpuinfo: `aes pmull crc32 asimd sha1 sha2`
  - `pmuv3` and `crt-static` are in `scripts/check-features.sh` IGNORE (PMU baseline / linkage, not user-space ISA).
  - Identical to the 1.99.0 set, so raising the pin needs no `targets/flint4.features` change.
- OpenWrt 21.02 `scripts/ipkg-build` pinned at `78e4cffcd882389cb8f0bf818303f85f8d1e9c8e`.
- usign pinned at `c4c72b1b07945ee192361dc751291a7c98d6adcd`.
- mimalloc microbench is the `pipeline_parallel` group inside
  `benches/throughput.rs` (no standalone bench file):
  `cargo bench --bench throughput pipeline_parallel`.

## CI / release results (2026-10-05)

`build.yml` on push to `main` (run `37281061762`), all green. Release
`v0.24.1-r2` published (public, 15 assets); `v0.24.1-r1` is superseded (it
shipped `runner/runner`-owned files).

| check | result |
|---|---|
| built variants | `generic` and `cortex-a73`, both with mimalloc |
| `check-features.sh` (cortex-a73) | pass |
| qemu ISA gate (`qemu-aarch64 -cpu cortex-a72`, `--lib --skip socket`, `--version`) | pass |
| native dual-stack `smoke.sh` (UDP+TCP on 5 addrs, idle RSS) | pass |
| `musl-gcc` native arm64 musl linking | pass (no `cross` fallback needed) |
| `ipkg-build` (21.02) + `mkmanifest` + usign sign | pass |
| ipk files owned `root:root` (fakeroot) | pass |
| `usign -V` on this PC against the repo pubkey | pass (`OK`) |

ipk (`numa_0.24.1-2_aarch64_cortex-a53.ipk`) verified: gzip tar with
`debian-binary` / `data.tar.gz` / `control.tar.gz`; `Architecture:
aarch64_cortex-a53`; `root:root` ownership; ships `/etc/init.d/numa`,
`/etc/numa/*`, `/usr/sbin/numa-ctl`; `conffiles` =
`/etc/numa/canary-block.txt`; no auto-start.

CI gotchas found and fixed (keep in mind when changing these files):

- `strategy.matrix` must resolve to a **mapping**; `fromJson` of a bare array
  fails with "A sequence was not expected". Use `{"include":[...]}`.
- `replace()` is **not** a GitHub Actions expression function.
- GitHub Actions runners have no git identity; a step that creates a commit in
  a fresh clone needs a repo-local `user.name`/`user.email`.
- `upload-artifact` drops the exec bit (files land 0644); do not gate on `-x`.
- `ipkg-build` 21.02 takes only `[-v] [-h] [-m]`; no `-o`/`-g`.

## Known gaps

- ipk `mtime` reproducibility (resolved): `mkipk.sh` exports `SOURCE_DATE_EPOCH`
  (the release commit date), `LC_ALL=C` and `TZ=UTC`, so the pinned `ipkg-build`
  stamps every tar member from a stable value. It reads the epoch back with
  `date --date=@...`, hence the C locale is required or GNU tar rejects the string.

Binary reproducibility (mimalloc banner):

- mimalloc (C) compiles `__DATE__`/`__TIME__` into its version banner, so the
  binary changes on every rebuild unless the epoch is pinned. The upstream
  aarch64 asset for v0.25.1 embeds `Nov 15 2026` (its build date) for the same
  reason.
- `build.sh` exports `SOURCE_DATE_EPOCH` from the source HEAD commit date before
  `cargo build`; the `cc` crate inherits it and gcc derives both macros from it.
  Verified locally: gcc maps `SOURCE_DATE_EPOCH` to `__DATE__`/`__TIME__`.
- `SOURCE_DATE_EPOCH` is not in `cc`'s `rerun-if-env-changed` set for the `cc`
  version upstream resolves (gcc reads it, not `cc`), so changing the epoch alone
  does not force a C rebuild. The rust-cache `key` carries the CPU axis only, not
  a per-pin suffix: `Cargo.lock` is part of rust-cache's automatic key, so a pin
  that moves mimalloc misses the cache on its own. Residual gap: a pin that moves
  without touching `Cargo.lock` reuses the cached `libmimalloc-sys` object and
  keeps the old date in its banner, which is cosmetic. Closing it properly means
  exporting the epoch before the cache step and adding `SOURCE_DATE_EPOCH` to
  rust-cache's `env-vars`.
- `Cargo.toml` pins `libmimalloc-sys = "=0.1.49"`, so the resolved dependency is
  part of Cargo's build-script fingerprint and a new mimalloc release cannot
  silently reuse a stale object. `cc` emits `rerun-if-env-changed` for everything
  it reads, so `CFLAGS_aarch64_unknown_linux_musl` is honoured deliberately.
- `git describe` reaches the binary (build version), so `[build].describe` in
  `upstream.lock` stays as the drift detector.

## Runtime allocator tuning (2026-10-05)

Matrix executed on the device: `docs/BENCH-mimalloc.md`. Only
`MIMALLOC_ARENA_RESERVE` matters: the default 1 GiB virtual arena drops to
`89696 kB` VmSize at `64M` with cached qps and CPU/query unchanged (n=6 per
side). `PURGE_DELAY`, `PURGE_DECOMMITS`, `MINIMAL_PURGE_SIZE`, `ALLOW_THP` and
`USE_NUMA_NODES` have no net win. `init.d/numa` exports
`MIMALLOC_ARENA_RESERVE=64M` to procd; override in `/etc/numa/numa.env`.

## Upgrade transport and procd startup (2026-11-11)

Found on the Flint 4 running numa 0.24.1-7. Two independent defects made
`numa-ctl upgrade` unusable; the second is fixed here.

- **`pidof`/`pgrep` (already fixed in `main`, `236831e`).** The 0.24.1-7 package
  used `pgrep -x numa`, which on this BusyBox returns exit 1 with no output for
  a running process (`pidof numa` -> 6048). `cmd_upgrade` then called
  `health "" ...`, H1 failed on the empty pid, and the upgrade rolled itself
  back. Any image older than that commit shows the same thing as `pid: none` in
  `numa-ctl status`.
- **`uclient-fetch` cannot download from github.com here.** Measured on the
  router: every GitHub host fails through `uclient-fetch`
  (`github.com`, `raw.githubusercontent.com`, `codeload.github.com`,
  `gist.github.com`) while `api.github.com`, `cdn.jsdelivr.net`,
  `example.com` and `one.one.one.one` succeed, so it is not a general network
  or TLS failure. Not DNS: the A record is returned and observed in a
  `tcpdump -i any port 53` capture. Not TCP: `uclient-fetch https://<ip>/`
  reaches TLS and fails only on `Server hostname does not match SSL
  certificate`. With an SNI hostname no SYN appears on `pppoe-wan` at all,
  while `curl https://github.com/` gets a SYN/SYNACK and HTTP 200 from the same
  source address. `openssl s_client -connect <ip>:443 -servername github.com`
  also connects.
- Fix: `fetch()` prefers `curl -fsSL` and falls back to `uclient-fetch`, and
  `cmd_fetch` writes to a temp file that only replaces the cached ipk after the
  checksum matches — a failed download must not destroy a cached package that
  offline rollback depends on. `http_get()` buffers each attempt so a partial
  body from a failed request is never read as a reply, and H2 retries for 20s
  because the API may not have bound its port yet. `bootstrap.sh` gets the same
  helper: it is the first-install path and hit the identical wall.
- Also: `wait_pid()` waits for procd to report a pid before any
  restart-then-health check. `restart` returns before the new process exists, so
  the previous code could read an empty pid on a perfectly healthy daemon. An
  upgrade whose daemon never appears rolls back like any other health failure
  instead of exiting with the new package installed.

## Config and behaviour on v0.25.0 (2026-11-11)

Checked against the tag source and the published `numa-linux-aarch64.tar.gz`
(4700861 B, sha256 `2d25f89…571b2`, inner binary 9608488 B, static, stripped).

- The generated `numa.toml` and `tests/smoke.toml` load with **zero** unknown-key
  warnings, enforced by `scripts/check-config.sh` in CI. The only key added in
  this range is `[proxy] authoritative` (default `true`); a field-level diff of
  `src/config.rs` shows nothing else, so `gen-config` needs no change.
- A named config file that does not exist is fatal: `numa run /nonexistent.toml`
  -> `Error: config file not found`, rc 1. `init.d/numa` checks for the file
  before starting, so the log says why instead of procd respawning on exit.
- `-c/--config FILE` works before or after the subcommand. The positional form
  still works, so `PROG run "$CONFIG_FILE"` is unchanged.
- `names_this_host` exempts loopback only for an exact `numa.<tld>`, not every
  `*.numa` name. `/health` stays unauthenticated, so the `numa-ctl` probe is
  unaffected.
- DNSSEC validation only runs in recursive mode, and the dashboard/`/health`
  report it off otherwise. This deployment uses `forward`, so `[dnssec] enabled`
  is a no-op here.
- `bootstrap_resolver` accepts `upstream.fallback` entries as IP literals only.
  A DoH entry is skipped even when written as `https://1.1.1.1/dns-query` (it is
  parsed as an address, not unwrapped), and the hardcoded `9.9.9.9, 1.1.1.1`
  list is used instead.
- `upstream.fallback` feeds two independent consumers, so its entries are not
  free-form: (1) `bootstrap_resolver`, which keeps only IP-literal entries, and
  (2) the failover chain, where a bare IP becomes a **plaintext UDP** upstream.
  A bare `"1.1.1.1"` added to narrow (1) therefore silently adds a plaintext
  resolver to (2); verified with a local UDP stub, which answered a query after
  both DoH upstreams were pointed at dead ports.
- `MIMALLOC_ARENA_RESERVE=64M` applies: upstream sets `ARENA_EAGER_COMMIT=0` at
  startup and restores `PURGE_DELAY` after a blocklist reload, neither of which
  touches the arena reserve. Idle VmSize on the x86_64 build: 130 MB with 64M
  vs 1113 MB default.
- Blocklist reload does not copy the domain table and purges eagerly
  (`load_blocklists_purging`). The reload RSS spike in `BENCH-mimalloc.md` is
  from the pre-v0.25.0 reload path.

## Config and behaviour on v0.25.1 (2026-11-15)

Checked against the tag source and the published `numa-linux-aarch64.tar.gz`
(4731144 B, sha256 `be835c90…8b3129`, inner binary 9669936 B, static, `numa 0.25.1`).

- `src/config.rs` is byte-identical to v0.25.0, so the tag itself needs no config
  change. `scripts/check-config.sh` runs both shipped configs against a v0.25.1
  binary: zero unknown keys.
- Upstream endpoints switched from hostname to IP-literal DoH
  (`https://9.9.9.9/dns-query`, `https://1.1.1.1/dns-query`) for both `address`
  and `fallback`, in `numa.toml.example` and `numa-ctl gen-config`. Reason: an IP
  literal gives reqwest no hostname to resolve, so `bootstrap_resolver` never
  sends the upstream name to `9.9.9.9`/`1.1.1.1` in plaintext. Verified with
  `RUST_LOG=debug`: the hostname form logs `bootstrap_resolver: resolved
  dns.quad9.net → 4 addr(s)`, the IP-literal form logs no bootstrap line at all.
  `NumaResolver` has no cache, so the hostname form paid that lookup on every new
  connection. Encryption is unchanged (still TLS with certificate validation, as
  the earlier `curl https://9.9.9.9/dns-query` -> 200 confirms), and both
  endpoints answered 120/120 unique names with zero 403s, so the IP-literal DoH
  failure recorded above does not reproduce against these endpoints today.
- Scope of the fix: it removes the *upstream* hostname lookup only. The blocklist
  download (`cdn.jsdelivr.net` by default) still resolves through
  `bootstrap_resolver`, so that name remains visible to the bootstrap resolvers.
- Upstream failover is now list-ordered instead of SRTT-ordered: a failed
  upstream is asked last, and about 1 query in 20 re-tests it in the background.
  `[upstream] srtt = false` disables that state. The shipped config lists one
  primary plus one `fallback`, so the ordering axis changes nothing here.
- REFUSED is retried on the next upstream and only returned when every upstream
  refuses. `9.9.9.9` and Cloudflare do not refuse by design, so this is a no-op
  for the shipped pair; it matters only if a filtering resolver is listed first.
- On Linux, a `search local` in `/etc/resolv.conf` no longer becomes a
  forwarding rule (v0.25.0 created one and every mDNS name waited out a SERVFAIL).
  The `[[forwarding]]` block from `gen-config` for `lan`, the dnsmasq domain and
  the reverse zones is unaffected; an explicit `suffix = "local"` rule still wins.
- Builds on the pinned rust 1.100.0: `rustup run 1.100.0 cargo build --release
  --locked` and `--version` both pass on the host.
- Packaging dry run with the published aarch64 binary (`VERSION=0.25.1-1 sh
  scripts/mkipk.sh`): `numa_0.25.1-1_aarch64_cortex-a53.ipk`, `Architecture`
  and `conffiles` unchanged, data tar `root:root`. CI produces the real one.

## Config and behaviour on v0.25.2 (2026-11-18)

Checked against the tag source and the published `numa-linux-aarch64.tar.gz`
(4763043 B, sha256 `dac50032…1116c37`, inner binary 9731376 B, static, `numa 0.25.2`). `Cargo.lock` changes only the
crate version, so mimalloc and every dependency are as in v0.25.1.

- Config keys: no key added or removed. `scripts/check-config.sh` against a v0.25.2
  host build (rust 1.100.0): zero unknown keys for `numa.toml.example`,
  `tests/smoke.toml` and the `gen-config` heredoc.
- Blocklist downloads now resolve through numa's own pipeline (configured
  upstream, cache), not `bootstrap_resolver` (upstream #507, reported from this
  repo). Observed on a v0.25.2 host build with the shipped DoH pair:
  `cdn.jsdelivr.net` loaded 252576 domains, and the bootstrap resolver logged
  only its start-up line. This lifts the limit recorded under v0.25.1 ("the
  blocklist download still resolves through `bootstrap_resolver`"): with
  IP-literal DoH, no name leaves in plaintext any more. A list host that is
  itself blocked does not stop its own refresh.
- `hedge_ms` changed meaning and default. It was a duplicate query to the same
  upstream, default 0. It is now the delay before numa also asks the *next*
  upstream, default 200, and a single upstream gets no second query. With the
  shipped primary + `fallback`, each hedge shows that name to Cloudflare as well.
  The earlier `hedge_ms = 50` (copied from the HA add-on) would do that for a
  large share of cache misses: Quad9 DoH p50 was 30 ms in `/stats` (3 answers) from a
  workstation. Both shipped configs now set `hedge_ms = 200`. Upstream's own
  figure at 200 ms is +7% upstream queries for p99 869 -> 476 ms. [TBD: router
  measurement of the hedge rate and the p99 there.]
- Primary racing needs two or more primaries of the same kind. The shipped config
  has one primary and the second operator in `fallback`, so no racing happens and
  list order is fixed. Moving Cloudflare into `address` would turn on the 1-in-20
  race (`srtt = false` disables it).
- `/stats` has an `upstreams` list (`addr`, `kind`, `asked_first`, `failed`,
  `answers`, `p50_ms`); the dashboard Outbound Wire panel shows it. `numa-ctl status`
  prints it (answers, median time, which upstream is asked first, failed flag).
- `/blocking/pause` and overrides answer 400 for a duration the clock cannot
  represent. `numa-ctl` does not call either.
- The x86_64 AVX2 crash of v0.25.1 does not touch this repo: the ipk is built from
  source on arm64 for the Flint 4 only. Upstream now runs each release binary
  under qemu on a baseline CPU; no equivalent gate is added here, since the
  target hardware is fixed.

## Tailscale MagicDNS (2026-11-15)

`gen-config` reads the tailnet suffix from `tailscale status --json`
(`CurrentTailnet.MagicDNSSuffix`, only when `MagicDNSEnabled`) and gives it its
own `[[forwarding]]` block pointing at `100.100.100.100:53`. The suffix is never
hardcoded: the repo holds no site data, so a device without tailscale, or with
MagicDNS off, generates exactly the same file as before.

Why it is a separate rule: on the router this was measured on, the dnsmasq rule
already carried the suffix, because `dhcp.@dnsmasq[0].domain` was set to the
tailnet domain (see "LAN and tailnet share one namespace" below). dnsmasq answers
those names from its static leases, which shadow the tailnet address, and REFUSES
names it does not know. Measured on the Flint 4 before the change:

| query | result |
|---|---|
| a known `<host>.<tailnet>.ts.net` via numa | the router's LAN addresses, from its static leases |
| the same name via MagicDNS | the real `100.x` tailnet address |
| an unknown `*.<tailnet>.ts.net` via numa | `SERVFAIL` in 1 ms (dnsmasq REFUSED) |

The MagicDNS rule is emitted **after** the dnsmasq rule because
`match_forwarding_rule` returns the first match; listed above, it would never be
consulted. `gen-config` also drops the suffix from the dnsmasq rule so the two
do not overlap. One case is not "equal": a dnsmasq suffix that is a **parent** of
the tailnet suffix (`ts.net`) also matches first, so `gen-config` drops that too.
Both checks normalize first — lowercase, no trailing dot, no leading dot — because
that is what `system_dns::ForwardingRule::new` does before comparing. Comparing
raw strings let `TS.NET` or `tailnet.ts.net.` from UCI slip through and shadow
MagicDNS again.

Two dependencies that fail without an error:

- `rebind_protect` must stay `false`, which is what `gen-config` emits. Every
  MagicDNS answer is private — `100.64/10` for A, ULA for AAAA — and it arrives
  over `QueryPath::Forwarded`, which `returns_trusted_local_data()` reports as
  untrusted, so `rebind.rs` strips it. The default ranges include
  `100.64.0.0/10` for exactly this reason. Turning `rebind_protect` on makes the
  whole tailnet rule return NODATA with no error anywhere.
- `timeout` must exist. Without it the `tailscale status` call cannot be bounded,
  so `gen-config` logs `WARN: timeout not installed; MagicDNS rule omitted` and
  emits no rule rather than risking a hang. BusyBox builds `timeout` only when
  `CONFIG_BUSYBOX_CONFIG_TIMEOUT` is set; 21.02 defaults it to `n`.

Verified off-device with stubbed `uci`/`ubus`/`jsonfilter`/`tailscale`: with
MagicDNS on, the tailnet suffix leaves the dnsmasq rule and the
`100.100.100.100:53` rule appears; with MagicDNS off, or tailscale absent, the
output is byte-identical to the previous version; with the dnsmasq domain set to
`lan`, `lan` stays and the MagicDNS rule is still added. The rendered config parses
on a v0.25.1 binary in all four cases, and `scripts/check-config.sh` covers the
generated heredoc — including a byte-level check that the MagicDNS rule exists and
follows the dnsmasq rule, which a config that merely parses does not prove.

## LAN and tailnet share one namespace (2026-11-16)

`dhcp.@dnsmasq[0].domain` is the tailnet suffix on the Flint 4, and `numa-ctl`
never writes it. The vendor script `/usr/bin/gl_tailscale` (firmware 4.9.2) does:
while `tailscale.settings.enabled=1`, `/etc/hotplug.d/iface/19-tailscale-iface`
runs `gl_tailscale restart` on every `ifup`, and that sets `domain` to
`tailscale status`'s `MagicDNSSuffix` (also from `start_dns_poller`, up to 15
tries). The stock value is saved once in `tailscale.settings.original_domain` and
restored only when Tailscale is disabled. So a hand-set `domain=lan` reverts on
the next `ifup` or reboot. With the suffix set, two things go wrong for clients
that do not run Tailscale:

- DHCP option 15 and the RA search list carry the tailnet suffix, so a bare
  `host` becomes `host.<tailnet>.ts.net`.
- dnsmasq registers leases as `<host>.<tailnet>.ts.net`. A host that is also a
  tailnet node resolves to its `100.x` address through the MagicDNS rule.

A LAN-only client cannot use that `100.x`. Measured with `tcpdump -ni tailscale0`
on the router: the echo requests leave with the client's `192.168.1.x` source and
no reply returns. `NetfilterMode=2` inserts tailscaled's `ts-forward` chain first
in `FORWARD`; it ends in `-o tailscale0 -j ACCEPT`, and its SNAT only applies to
packets that arrived from `tailscale0`. LAN traffic therefore skips fw3 and keeps
its source.

Fix: stop `gl_tailscale` writing `domain`, then set it once. The four
`uci set dhcp.@dnsmasq[0].domain=...` lines (119, 155, 171, 175 on 4.9.2) become
a no-op `:`, so no `if`/`else` block ends up empty:

```sh
cp -a /usr/bin/gl_tailscale /root/gl_tailscale.orig
sed -i 's|uci set dhcp\.@dnsmasq\[0\]\.domain=|: |' /usr/bin/gl_tailscale
sh -n /usr/bin/gl_tailscale && echo syntax ok
uci set dhcp.@dnsmasq[0].domain=lan && uci commit dhcp
/etc/init.d/dnsmasq restart
```

Verified on the device: `domain` stayed `lan` after
`ACTION=ifup INTERFACE=lan sh /etc/hotplug.d/iface/19-tailscale-iface` and after a
reboot. From a LAN client, `nslookup <host>` returns `<host>.lan` with the LAN
address and `resolvectl` shows `DNS Domain: lan`; clients keep the old search
suffix until they renew their lease.

Costs:

- A firmware upgrade restores the stock script and the suffix returns. Reapply the
  patch. `numa-ctl status` prints `dnsmasq domain:` and warns when it is the
  tailnet suffix (or a parent of it), so run it after an upgrade.
- LAN clients lose the vendor's bare tailnet names. Those resolved to `100.x`
  addresses they could not reach, so nothing usable is lost.
- The vendor's `server=/ts.net/100.100.100.100` line in `/etc/dnsmasq.conf` stays,
  and is harmless once leases are registered under `.lan`.

`domain=lan` needs no numa restart only if the active `numa.toml` already lists
`lan` in its dnsmasq `[[forwarding]]` suffix list, which a config generated with
`local=/lan/` does. Check it as the RUNBOOK describes; any other LAN-only name
has to be added to that list.

What this does not fix: a non-Tailscale client that queries
`<host>.<tailnet>.ts.net` explicitly still gets the `100.x` address, and it
still cannot reach it. The firewall has no useful lever here:

| Change | Result |
|---|---|
| `uci delete firewall.<lan→tailscale0 forwarding>` | None. `ts-forward` accepts the packet before fw3 sees it. |
| `firewall.tailscale0.masq=1` | LAN clients reach online peers as the router. Gives the whole `lan` pool the router's tailnet access and drops per-device ACLs. Not applied. |
| tailscale `--netfilter-mode=off` | Not tested. The router is an exit node and a subnet router, which rely on `ts-forward`. |

The LAN-to-tailnet forwarding entry is created by the vendor UI, not by this repo.

## Upstream transport (2026-10-05)

> Superseded by the IP-literal DoH decision in "Config and behaviour on v0.25.1"
> above: both endpoints answer normally today, and the plaintext `fallback` this
> entry describes is gone. Kept for the diagnostic history.

`/stats` showed ~64% of upstream queries leaving on plaintext UDP. Cause: the
DoH primary used IP-literal endpoints (`https://9.9.9.9/dns-query`) that failed
with `error sending request` and Quad9 `HTTP 403 Forbidden`, so queries fell to
the plaintext `fallback`. Shipped config is now DoH-only:
`address = ["https://dns.quad9.net/dns-query"]`,
`fallback = ["https://cloudflare-dns.com/dns-query"]`. Hostname resolution for
numa-originated HTTPS uses `bootstrap_resolver`'s default IP-literal list
(`9.9.9.9`, `1.1.1.1`, UDP), because a fallback without IP literals is skipped
  there by design.

## Dashboard "resolver elsewhere" advisory (2026-10-05)

The dashboard shows `This host's DNS points at 127.0.0.1, not this Numa
instance`. False positive. `GET /health` returns
`system_resolver.matches_listener=false` because
`src/system_dns.rs::matches_numa_listener()` only treats a wildcard listener as
claiming loopback when the address family matches the nameserver
(`l.is_ipv4() == ns.is_ipv4()`), and gen-config binds a single dual-stack
`[::]:53` (`numa-ctl` `bind_addr`). With Linux `bindv6only=0` that socket answers
IPv4 too (`dig @127.0.0.1` works; numa logs `[::ffff:127.0.0.1]`), but the check
does not treat the IPv6 wildcard as claiming the IPv4 loopback. Not fixable from
`bind_addr`: `["0.0.0.0:53","[::]:53"]` collides (`UdpListener` never sets
`IPV6_V6ONLY`) and `0.0.0.0:53` alone drops IPv6. Cosmetic; fix belongs upstream.
Side finding: `/health.lan_ip` reports the WAN address (`detect_lan_ip()`
mis-detects on OpenWrt).

## allow_from = [] and the LAN ULA (2026-10-05)

LAN clients were silently dropped over IPv6. `allow_from` listed the router's
*configured* ULA, but the LAN's live ULA is a different prefix advertised by the
Thread Border Routers on the LAN (the HA OpenThread Border Router and a Samsung
SmartThings device), each sending a prefix-only RA with a route-info option for
its Thread mesh prefix. This is normal Thread/Matter behaviour and must not be
disabled. `gen-config` derived `allow_from` from `ubus network.interface.*
status`, which cannot expose that SLAAC ULA, so it never matched. Fix shipped:
`allow_from = []` (numa default = all peers, same as numa-haos) with the WAN kept
closed by the firewall; the prefix enumeration is removed from `gen-config`.

## Open / to verify on device

- ⚠ opkg 21.02 sets `PKG_UPGRADE=1` in prerm on upgrade.
- ⚠ BusyBox `nslookup -port=` support (else `bind-dig` is required).
- `blocked.numa-ctl.internal` sinkhole pinned to `A -> 0.0.0.0` NOERROR (upstream
  issue #400); the health suite and `smoke.sh` require exactly `0.0.0.0`.
- Device checks from the review fixes: BusyBox `sleep` (the loops use integer
  `sleep 1`), `flock` availability (command locking is best-effort), `uci del_list`
  support in `cutover`/`disable`, and the router ULA read from ubus
  `ipv6-prefix-assignment[*].local-address`.
- `gen-config` dependencies: `timeout` (else the MagicDNS rule is skipped with a
  WARN) and `jsonfilter` reading a JSON document from **stdin**, which is how the
  `tailscale status` output is parsed. `jsonfilter` is `jsonpath` from
  `openwrt/jsonpath@c7e938d` in 21.02; `main.c` defaults `input = stdin`, so the
  form is supported, but only this one call site relies on it.
- ⚠ RDNSS advertises the router after `cutover` deletes the `dns` list.
- ⚠ `localuse` exists in `/etc/init.d/dnsmasq`.
- ⚠ `uclient-fetch` follows the `releases/latest/download` redirect.
- `uclient-fetch` prints a connect/DNS failure as `Failed to send request:
  Operation not permitted`: it passes `UCLIENT_ERROR_CONNECT` (= 1) to
  `strerror`, and `strerror(1)` is "Operation not permitted". It means *cannot
  connect* (DNS or route), never a permission problem.
- ⚠ the current LAN DHCP option-6 host - see RUNBOOK open decisions.
- ⚠ GL UI DNS settings page can rewrite the dnsmasq port back to 53 - see RUNBOOK.
- ⚠ After a firmware upgrade `gl_tailscale` is stock again and rewrites
  `dhcp.@dnsmasq[0].domain` to the tailnet suffix; reapply the patch from
  "LAN and tailnet share one namespace".
- `console.gl-inet.com` is a `dhcp.@domain` entry (static override to the router).
  numa forwards only the suffix list to dnsmasq, so it probably goes upstream
  instead. Check with `dig console.gl-inet.com @<router>`.

## Workflow notes

- `watch-upstream.yml` mints a GitHub App installation token
  (`vars.APP_CLIENT_ID` + `secrets.APP_PRIVATE_KEY`) so its PRs trigger
  `build.yml`; `GITHUB_TOKEN`-opened PRs would not.
- Releases are signed with `secrets.USIGN_SECRET_KEY`; the matching public key is
  `pkg/root/etc/numa/keys/numa-openwrt.pub` (fingerprint `53ee14af45d2dc89`).
