# numa mimalloc tuning matrix (GL-BE14000)

Test plan and results for the runtime options of the mimalloc build shipped in
the ipk. All knobs are environment variables: no rebuild, no rev bump.

Executed 2026-10-05 on the live router (`192.168.1.1`, off-peak), load from the
wired client `192.168.1.106`. Staged binary: `generic-mimalloc` extracted from
the cached `numa_0.24.1-9_aarch64_cortex-a53.ipk`.

## Scope and invariants

- Binary: `generic-mimalloc` (the published variant). No rebuild; every cell
  changes only the process environment at exec time.
- Allocator: mimalloc **v3.3.2** (`libmimalloc-sys 0.1.49`, v3 is the default;
  `mimalloc` is pulled with `default-features = false`). Option names, defaults
  and env parsing below are taken from that exact source (`v3/src/options.c`).
- One factor per cell against the default cell (OFAT screen), then a confirm
  pass on the winner.
- The router is live: off-peak, stage on `:5399` only, never touch `:53`.

## Injection (env, not a file yet)

`cmd_stage` runs `HOME=/root "$_stage/numa" run ...`, i.e. it only adds `HOME`;
every other exported variable in the `numa-ctl` environment is inherited by the
staged process. So:

```sh
MIMALLOC_ARENA_RESERVE=64M numa-ctl stage --ipk <ipk> --keep
```

The child was verified to receive it before every run:

```sh
pid=$(pgrep -f '^/tmp/numa-stage/numa')
tr '\0' '\n' < "/proc/$pid/environ" | grep '^MIMALLOC_'
```

Stop the staged process with `pgrep -f '^/tmp/numa-stage/numa'` (a bare
`pkill -f /tmp/numa-stage/numa` matches the ssh shell and kills nothing).

## Excluded factors (with reason)

| env | why not tested |
|---|---|
| `MIMALLOC_ARENA_EAGER_COMMIT` | hardcoded to `0` in `src/main.rs` (`mi_option_set(4,0)`), so it wins over the env; already off |
| `MIMALLOC_RESERVE_HUGE_OS_PAGES`, `MIMALLOC_ALLOW_LARGE_OS_PAGES` | require OS-provisioned huge/large pages; absent on OpenWrt 21.02 |
| `MIMALLOC_SHOW_STATS`, `MIMALLOC_VERBOSE` | diagnostics only; `VERBOSE` prints options before `main.rs` overrides, so it is not a reliable check for `arena_eager_commit` |
| `MIMALLOC_USE_NUMA_NODES` | single-node SoC; run only as a negative control (F) |

## Factors and levels

Defaults are the v3.3.2 compiled defaults.

### Tier 1 - memory / CPU, plausible impact

| id | env | default | levels run | expected | primary metric |
|---|---|---|---|---|---|
| A | `MIMALLOC_ARENA_RESERVE` | 1 GiB (1048576 KiB) | `32M`, `64M`, `128M`, `256M` | VmSize drops to the reserve; RSS and qps unchanged | VmSize, qps |
| B | `MIMALLOC_PURGE_DELAY` | `1000` ms | `-1`, `0`, `100`, `10000` | `-1` less purge CPU, higher RSS; `0` more CPU, lower RSS | CPU/query, RSS |
| C | `MIMALLOC_PURGE_DECOMMITS` | `1` | `0` | `0` uses `MADV_FREE`: fewer syscalls, RSS not returned immediately | CPU/query, RSS |
| D | `MIMALLOC_MINIMAL_PURGE_SIZE` | `0` (resolves to 64 KiB) | `512`, `2048` | larger granularity, fewer `madvise` calls, higher RSS | CPU/query, RSS |
| E | `MIMALLOC_ALLOW_THP` | `1` | `0` | no THP; on kernel 5.4 likely a no-op unless THP=always | RSS, qps |

### Tier 2 - exploratory

Not run. Tier 1 left no CPU/query opening to chase (see Results).

### Control

| id | env | levels | expected |
|---|---|---|---|
| F | `MIMALLOC_USE_NUMA_NODES` | `1` | no-op; if it moves qps, the harness has a confound |

## Method

Per run:

1. Stage (with or without the env prefix) from the cached r9 ipk, `--keep`.
2. Verify the env in `/proc/<pid>/environ`.
3. Warm the cache once: `dnsperf -d cached.txt -c 1 -l 3`.
4. Snapshot `VmSize`/`VmRSS`/`VmHWM` from `/proc/<pid>/status`.
5. Throughput: `dnsperf -d cached.txt -c 8 -l 12`.
6. CPU/query: `(ticks_after - ticks_before)/CLK_TCK/queries`, ticks summed over
   `/proc/<pid>/task/*/stat` (`utime+stime`), `CLK_TCK=100`.

Screen = ABBA (`default, cell, cell, default`) x1 per level. Confirm = ABBA x3
on the winner. All runs from `192.168.1.106`, `dnsperf 2.16.0`, wired.

Inputs (generated, not shipped; regenerate identically for comparability):

```sh
printf '%s\n' google.com www.google.com youtube.com www.youtube.com \
  facebook.com www.facebook.com instagram.com www.instagram.com \
  whatsapp.com www.whatsapp.com amazon.com www.amazon.com \
  wikipedia.org www.wikipedia.org twitter.com x.com reddit.com www.reddit.com \
  netflix.com www.netflix.com microsoft.com www.microsoft.com office.com \
  live.com apple.com www.apple.com icloud.com linkedin.com www.linkedin.com \
  tiktok.com www.tiktok.com github.com www.github.com stackoverflow.com \
  cloudflare.com www.cloudflare.com mozilla.org www.mozilla.org dropbox.com \
  spotify.com www.spotify.com paypal.com www.paypal.com ebay.com www.ebay.com \
  bing.com www.bing.com yahoo.com www.yahoo.com duckduckgo.com \
  www.duckduckgo.com booking.com www.booking.com | sed 's/$/ A/' > cached.txt

awk 'BEGIN{for(i=1;i<=5000;i++) printf "u%05d.example.com A\n", i}' > unique.txt
```

## Decision rules

Noise floor: +-2% run-to-run. Accept only if cached qps is within 2% of the
paired default and the targeted metric improves; RSS cap 64 MB `VmRSS` /
128 MB `VmHWM`.

## Results

### Tier 1 screen (cached, cell mean n=2 vs paired default mean n=2)

| id | value | cell qps | default qps | cell CPU ms/q | cell VmSize | cell VmRSS | verdict |
|---|---|---|---|---|---|---|---|
| A | 32M | 41230 | 40187 | 0.0684 | 89696 | 28536 | accept |
| A | 64M | 42567 | 41564 | 0.0680 | 89696 | 28794 | accept |
| A | 128M | 40798 | 37154* | 0.0678 | 155232 | 28764 | accept |
| A | 256M | 41167 | 41196 | 0.0690 | 286336 | 27960 | accept |
| B | -1 | 41325 | 42667 | 0.0690 | 1072736 | 38624 | reject (+RSS) |
| B | 0 | 39531 | 41401 | 0.0734 | 1072736 | 24406 | reject (qps -4.5%, CPU +7%) |
| B | 100 | 40849 | 40563 | 0.0694 | 1072736 | 28174 | neutral |
| B | 10000 | 41209 | 40678 | 0.0687 | 1072736 | 43588 | reject (+RSS) |
| C | 0 | 41935 | 41658 | 0.0685 | 1072736 | 44410 | reject (+RSS) |
| D | 512 | 41183 | 41260 | 0.0685 | 1072736 | 28904 | neutral |
| D | 2048 | 41936 | 41834 | 0.0685 | 1072736 | 28622 | neutral |
| E | 0 | 42030 | 41190 | 0.0679 | 1072736 | 29380 | neutral |
| F | 1 | 41007 | 41392 | 0.0692 | 1072736 | 29442 | no-op (expected) |

`*` the A-128M default pair includes one 35026 qps outlier (unexplained, seen
once in the whole session); the A-128M cell itself is within noise.

Read:

- **A is the only real lever.** Any reserve <= 128M cuts VmSize proportionally;
  qps and CPU/query do not move. 32M and 64M are empirically identical
  (both 89696 kB), so the effective floor is 64 MiB.
- B-0 (immediate purge) trades RSS for CPU and loses qps: purge cost is real on
  this SoC.
- B-10000 / B--1 / C-0 remove or defer purging: RSS +40-50% (38-44 MB), no qps
  or CPU gain.
- D and E are flat; THP is effectively a no-op on kernel 5.4 here.

### Confirm A-64M (cached, ABBA x3 = 6 cell + 6 default runs)

| set | mean qps | mean CPU ms/q | mean VmSize | mean VmRSS |
|---|---|---|---|---|
| default | 41454 | 0.0689 | 1072736 | 28966 |
| `ARENA_RESERVE=64M` | 41422 | 0.0688 | 89704 | 28450 |

qps delta -0.08% (noise); VmSize 1048 MB -> 87.6 MB (12x); RSS unchanged.

### Cold / unique path (5000 names)

| id | value | qps | VmSize | VmRSS |
|---|---|---|---|---|
| default | - | 154-11576 | 1072736 | 32.9-36.0 MB |
| A | 64M | 201-609 | 89696, 155296 | 35.5-38.7 MB |

Cold qps is upstream-bound (DoH forwarding of unique names) and not comparable;
the useful signal is memory: the 64M arena grew by exactly one step
(89696 -> 155296 kB) under cold load and stayed there. No OOM, no failure to
resolve. One default run in the cold set failed to stage (health flake); the
cell runs were unaffected.

### Microbench (`pipeline_parallel`)

Not run: the release ipk ships no bench binary, and building `cargo bench`
locally (prepare-src + cherry-pick PR #395 + musl toolchain) is out of scope for
an env-only matrix. Remains TBD in `BENCH.md`.

## Decision

Ship exactly one runtime option:

```
MIMALLOC_ARENA_RESERVE=64M
```

- VmSize 1048 MB -> 87.6 MB, deterministic across 6 confirm runs.
- Cached qps and CPU/query unchanged (within 0.1%).
- Removes the `overcommit_memory != 2` / `ulimit -v` caveat recorded in
  `BENCH.md`: an 88 MB virtual reservation is safe under any overcommit policy.
- Keep every other option at the compiled default (`PURGE_DELAY=1000`,
  `PURGE_DECOMMITS=1`, `ALLOW_THP=1`, `USE_NUMA_NODES=0`).

Caveats: cold comparison is upstream-bound, not a controlled qps measurement;
Tier 2 and the microbench were not run.

## Next step (not done)

To apply the decision on the device, the variable must reach every launch path,
not only procd:

- `procd_set_param env` in `pkg/root/etc/init.d/numa` (currently passes only
  `HOME` and `RUST_LOG`), and
- the same value in `/etc/numa/numa.env` so `numa-ctl stage` / manual runs match
  production (this matrix injected it ad hoc on the `ssh numa-ctl stage` line).
