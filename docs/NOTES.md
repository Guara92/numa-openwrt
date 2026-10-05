# numa-openwrt notes

Verification log. `⚠` items from the design notes get a line here once checked
on the device or in CI. Keep it factual: command, result.

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

## CI / release results (2026-10-05)

`build.yml` on push to `main` (run `37281061762`), all green. Release
`v0.24.1-r2` published (public, 15 assets); `v0.24.1-r1` is superseded (it
shipped `runner/runner`-owned files).

| check | result |
|---|---|
| 4 variants built (`generic`/`cortex-a73` x `musl`/`mimalloc`) | pass |
| `check-features.sh` (cortex-a73) | pass |
| qemu ISA gate (`qemu-aarch64 -cpu cortex-a72`, `--lib --skip socket`, `--version`) | pass |
| native dual-stack `smoke.sh` (UDP+TCP on 5 addrs, idle RSS) | pass |
| `musl-gcc` native arm64 musl linking | pass (no `cross` fallback needed) |
| `ipkg-build` (21.02) + `mkmanifest` + usign sign | pass |
| ipk files owned `root:root` (fakeroot) | pass |
| overlay `describe` identical across mimalloc legs (`v0.24.1-5-g373db8a`) | pass |
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
- GitHub Actions runners have no git identity; `cherry-pick --continue` aborts
  with "empty ident name" unless the clone sets `user.name`/`user.email`.
- `upload-artifact` drops the exec bit (files land 0644); do not gate on `-x`.
- `ipkg-build` 21.02 takes only `[-v] [-h] [-m]`; no `-o`/`-g`.

## Known gaps

- The ipk `mtime` comes from `ipkg-build`'s `TIMESTAMP=$(date)`. Set
  `SOURCE_DATE_EPOCH` (ipkg-build honours it) for a byte-reproducible ipk; note
  the value is locale-formatted, so a non-C locale makes GNU tar reject it.

Overlay hash reproducibility (resolved):

- `git describe` reaches the binary (build version), so a different overlay
  commit hash yields a different binary `sha256` and blocks byte comparison with
  a release artifact.
- Cause of the drift: developer-global git config and env leak into commit
  creation. `commit.gpgsign` embeds a `gpgsig`; `core.hooksPath` can run
  `prepare-commit-msg`; `commit.cleanup`/`core.commentChar` alter the message
  rewritten by `cherry-pick --continue`; `GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL`
  override the clone's `user.*`. `cargo fetch` also regenerated `Cargo.lock`
  against the live registry.
- Fix: `prepare-src.sh` isolates the throwaway clone (`GIT_CONFIG_GLOBAL=/dev/null`,
  `GIT_CONFIG_NOSYSTEM=1`, unsets the committer env, local `commit.gpgsign=false`)
  and applies a frozen `targets/overlay-Cargo.lock.diff` instead of `cargo fetch`.
  The expected `git describe` is pinned as `[build].describe` in `upstream.lock`;
  a mismatch warns. Verified: local and CI both give `v0.24.1-5-g373db8a`.

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
- ⚠ the current LAN DHCP option-6 host - see RUNBOOK open decisions.
- ⚠ GL UI DNS settings page can rewrite the dnsmasq port back to 53 - see RUNBOOK.

## Workflow notes

- `watch-upstream.yml` mints a GitHub App installation token
  (`vars.APP_CLIENT_ID` + `secrets.APP_PRIVATE_KEY`) so its PRs trigger
  `build.yml`; `GITHUB_TOKEN`-opened PRs would not.
- Releases are signed with `secrets.USIGN_SECRET_KEY`; the matching public key is
  `pkg/root/etc/numa/keys/numa-openwrt.pub` (fingerprint `53ee14af45d2dc89`).
