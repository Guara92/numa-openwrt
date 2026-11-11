# numa-openwrt notes

Verification log. `⚠` items from the design notes get a line here once checked
on the device or in CI. Keep it factual: command, result.

## Pins (re-verified 2026-11-11)

- upstream tag `v0.25.0` -> commit `91389fe65dfd6e36937b4d96fa95de5ef0239120` (latest release).
- mimalloc comes from upstream: v0.25.0 depends on `mimalloc 0.1.52` and
  `libmimalloc-sys 0.1.49` under `cfg(target_env = "musl")`, so this repo applies
  no patch. `cargo tree --target aarch64-unknown-linux-musl` lists both; the gnu
  target lists neither.
- rust pinned `1.99.0`.
- `-C target-cpu=cortex-a73` target features (rustc 1.99.0, `aarch64-unknown-linux-musl`):
  `aes crc neon pmuv3 sha2` (+ `crt-static`). Mapped to cpuinfo: `aes pmull crc32 asimd sha1 sha2`
  - `pmuv3` and `crt-static` are in `scripts/check-features.sh` IGNORE (PMU baseline / linkage, not user-space ISA).
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
  aarch64 asset embeds `Oct 23 2026` for the same reason.
- `build.sh` exports `SOURCE_DATE_EPOCH` from the source HEAD commit date before
  `cargo build`; the `cc` crate inherits it and gcc derives both macros from it.
  Verified locally: gcc maps `SOURCE_DATE_EPOCH` to `__DATE__`/`__TIME__`.
- `SOURCE_DATE_EPOCH` is not in `cc`'s `rerun-if-env-changed` set (gcc reads it,
  not `cc`), so changing the epoch alone does not force a C rebuild. That is why
  the flag and the `-v25mim` cache-key suffix both stay: the suffix drops objects
  built against a different dependency graph.
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
- `MIMALLOC_ARENA_RESERVE=64M` applies: upstream sets `ARENA_EAGER_COMMIT=0` at
  startup and restores `PURGE_DELAY` after a blocklist reload, neither of which
  touches the arena reserve. Idle VmSize on the x86_64 build: 130 MB with 64M
  vs 1113 MB default.
- Blocklist reload does not copy the domain table and purges eagerly
  (`load_blocklists_purging`). The reload RSS spike in `BENCH-mimalloc.md` is
  from the pre-v0.25.0 reload path.

## Upstream transport (2026-10-05)

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
- ⚠ RDNSS advertises the router after `cutover` deletes the `dns` list.
- ⚠ `localuse` exists in `/etc/init.d/dnsmasq`.
- ⚠ `uclient-fetch` follows the `releases/latest/download` redirect.
- `uclient-fetch` prints a connect/DNS failure as `Failed to send request:
  Operation not permitted`: it passes `UCLIENT_ERROR_CONNECT` (= 1) to
  `strerror`, and `strerror(1)` is "Operation not permitted". It means *cannot
  connect* (DNS or route), never a permission problem.
- ⚠ the current LAN DHCP option-6 host - see RUNBOOK open decisions.
- ⚠ GL UI DNS settings page can rewrite the dnsmasq port back to 53 - see RUNBOOK.

## Workflow notes

- `watch-upstream.yml` mints a GitHub App installation token
  (`vars.APP_CLIENT_ID` + `secrets.APP_PRIVATE_KEY`) so its PRs trigger
  `build.yml`; `GITHUB_TOKEN`-opened PRs would not.
- Releases are signed with `secrets.USIGN_SECRET_KEY`; the matching public key is
  `pkg/root/etc/numa/keys/numa-openwrt.pub` (fingerprint `53ee14af45d2dc89`).
