# numa-openwrt notes

Verification log. `⚠` items from PLAN.md get a line here once checked on the
device or in CI. Keep it factual: command, result.

## Pins (re-verified 2026-10-04)

- upstream tag `v0.24.1` -> commit `c7385c78512b81ee096d41e4b27dab8ebe5b8e7e` (latest release).
- PR #395 head -> `a892fbadaa65fdb85697be194afd4092b13c4017`, **open, not merged** (`mimalloc.source=pr`).
- rust pinned `1.99.0`.
- `-C target-cpu=cortex-a73` target features (rustc 1.99.0, `aarch64-unknown-linux-musl`):
  `aes crc neon pmuv3 sha2` (+ `crt-static`). Mapped to cpuinfo: `aes pmull crc32 asimd sha1 sha2`
  - `pmuv3` and `crt-static` are in `scripts/check-features.sh` IGNORE (PMU baseline / linkage, not user-space ISA).
- OpenWrt 21.02 `scripts/ipkg-build` pinned at `78e4cffcd882389cb8f0bf818303f85f8d1e9c8e`.
- usign pinned at `c4c72b1b07945ee192361dc751291a7c98d6adcd`.
- PR #395 microbench is the `pipeline_parallel` group inside `benches/throughput.rs`
  (no standalone bench file): `cargo bench --bench throughput pipeline_parallel`.

## Open / to verify on device

- ⚠ native arm64 musl linking with `musl-gcc`; fall back to `cross build` if it fails.
- ⚠ ipk inner member names: `data.tar.gz` / `./usr/sbin/numa` for `--ipk` extraction.
- ⚠ opkg 21.02 sets `PKG_UPGRADE=1` in prerm on upgrade.
- ⚠ BusyBox `nslookup -port=` support (else `bind-dig` is required).
- ⚠ `[blocking].lists` sinkhole form for `blocked.numa-ctl.internal` (0.0.0.0 vs NXDOMAIN) - pin after first smoke.
- ⚠ RDNSS advertises the router after `cutover` deletes the `dns` list.
- ⚠ `localuse` exists in `/etc/init.d/dnsmasq`.
- ⚠ `uclient-fetch` follows the `releases/latest/download` redirect.
- ⚠ the current LAN DHCP option-6 host - see RUNBOOK open decisions.
- ⚠ GL UI DNS settings page can rewrite the dnsmasq port back to 53 - see RUNBOOK.

## Tooling note

- `memory-mcp-1file` (`memory-proxy_*`) returned `invalid_union` on every query
  this session (2026-10-04); memories not updated. Recheck the MCP server.
