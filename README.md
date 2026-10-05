# numa-openwrt

Reproducible builds of [numa][numa] for the GL.iNet Flint 4 (GL-BE14000,
OpenWrt 21.02, `aarch64`), packaged as an ipk and published as signed GitHub
Releases. The router-side tooling stages a candidate on `:5399`, health-checks
it, then moves `:53` over with an automatic rollback path.

numa becomes the primary resolver on `:53`; dnsmasq stays for DHCP and local
names on `:5354`. Cutover is per DHCP pool, so clients are unaffected until
they renew. Deployment is manual via `numa-ctl` - nothing auto-deploys to the
router and no opkg feed is used.

The verified facts and phases are recorded in [docs/NOTES.md](docs/NOTES.md);
operations are in [docs/RUNBOOK.md](docs/RUNBOOK.md); bench data for upstream
PR #395 in [docs/BENCH.md](docs/BENCH.md); runtime allocator tuning in
[docs/BENCH-mimalloc.md](docs/BENCH-mimalloc.md).

## Layout

```text
numa-openwrt/
├── upstream.lock                    pinned upstream tag, PR #395 head, rust
├── targets/flint4.features          cpuinfo features of the target
├── targets/overlay-Cargo.lock.diff  frozen tag-lock + mimalloc lock overlay
├── scripts/
│   ├── prepare-src.sh               clone tag, verify sha, apply overlay
│   ├── build.sh                     VARIANT=<cpu>-<alloc> -> dist/numa-<variant>
│   ├── check-features.sh            rustc features subset of targets/flint4.features
│   ├── smoke.sh                     native dual-stack network smoke test
│   ├── mkipk.sh                     wraps OpenWrt 21.02 scripts/ipkg-build
│   └── mkmanifest.sh                manifest.json + usign signature
├── pkg/
│   ├── CONTROL/{control.in,conffiles,postinst,prerm}
│   └── root/
│       ├── etc/init.d/numa          procd service
│       ├── etc/numa/numa.toml.example
│       ├── etc/numa/canary-block.txt
│       ├── etc/numa/keys/numa-openwrt.pub
│       ├── lib/upgrade/keep.d/numa  "/etc/numa/"
│       └── usr/sbin/numa-ctl
├── tests/smoke.toml
├── bootstrap.sh                     first install on the router
├── docs/{RUNBOOK.md,BENCH.md,BENCH-mimalloc.md,NOTES.md}
└── .github/workflows/{watch-upstream.yml,build.yml}
```

## Build

CI (`build.yml`, `ubuntu-24.04-arm`) is the reference build. Locally:

```sh
rustup target add aarch64-unknown-linux-musl
sh scripts/prepare-src.sh mimalloc            # or musl
sh scripts/check-features.sh                  # cortex-a73 variants
VARIANT=cortex-a73-mimalloc sh scripts/build.sh
sudo VARIANT=cortex-a73-mimalloc sh scripts/smoke.sh
```

Then package and sign:

```sh
sh scripts/mkipk.sh
USIGN=/path/to/usign USIGN_SECRET_KEY=<base64> sh scripts/mkmanifest.sh
```

## Router

All commands run on the router as `root`. The public key must be trusted
out-of-band (see `bootstrap.sh`).

```sh
# on a PC: copy the trusted pubkey and bootstrap.sh to the router.
# -O: OpenWrt has no sftp-server and OpenSSH >= 9 defaults scp to SFTP.
scp -O bootstrap.sh pkg/root/etc/numa/keys/numa-openwrt.pub root@router:/tmp/

ssh root@router 'NUMA_OPENWRT_REPO=<owner>/numa-openwrt sh /tmp/bootstrap.sh /tmp/numa-openwrt.pub'
numa-ctl gen-config --apply
numa-ctl stage --ipk "$(ls -1t /etc/numa/pkgcache/*.ipk | head -1)"
numa-ctl enable                         # hand :53 to numa, health-check, watchdog
numa-ctl cutover lan                    # point one pool's DNS at the router
```

### Dashboard / API

numa serves its dashboard and API from `numa.toml` on `api_bind_addr` (the
pool's v4, set by `gen-config`, e.g. `192.168.1.1`) and `api_port` (default
`5380`). This is separate from the DNS listener on `:53`. It is plain HTTP, so
the token is a gate, not transport encryption.

```text
http://<api_bind_addr>:<api_port>       # e.g. http://192.168.1.1:5380
```

Loopback is unauthenticated and `/health` is always open. Every other client,
including the LAN address, must present the API token:

- browser: the HTTP Basic prompt - any username, the token as the password
- API clients: `Authorization: Bearer <token>`, or Basic

The 64-hex token is minted on first start, stored owner-only at
`<data_dir>/api_token` (here `/etc/numa/state/api_token`), and printed on the
router with `numa token`. Pin it with `[server] api_token` in `numa.toml` or
`NUMA_API_TOKEN` (env wins).

Hard rules and the firmware-upgrade procedure are in the runbook. Anything
touching DHCP or the GL web UI can take DNS and DHCP down; read it first.

## Conventions

- Router scripts are POSIX `sh` for BusyBox ash (`shellcheck -s sh`).
- On the router: `jsonfilter`, `uclient-fetch`, `ubus`, `uci` - not jq/curl.
- The repo contains no site data; the config is generated on the router.
- Every GitHub Action is pinned by commit SHA.

[numa]: https://github.com/razvandimescu/numa
