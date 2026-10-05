# numa bench (real aarch64, GL-BE14000)

Data for upstream PR #395. The variant grid and the router vs HA/Pi4 A/B are
filled in below.

## Variants

| variant | note |
|---|---|
| upstream official aarch64 | baseline (= Pi4 build) |
| generic-musl | |
| generic-mimalloc | published (best throughput + CPU/query) |
| cortex-a73-musl | |
| cortex-a73-mimalloc | -6 to -8% vs generic-mimalloc |

Allocator and CPU effects are separable by comparing across the grid.

## Method

Target: `numa-ctl stage --variant V --keep` -> `[::]:5399` on the router (LAN
zone input is allowed). Run off-peak; the router is live.

Load from a wired LAN PC with `dnsperf` 2.x (note: `-q` is max outstanding,
`-Q` is max qps):

```sh
dnsperf -s <lan v4> -p 5399 -d cached.txt -c 8 -l 12
```

`cached.txt` = 52 popular names, warmed once (`-c 1 -l 3`). Grid = 3
round-robin rounds over the 5 variants; the mimalloc pair is re-confirmed with
order A B B A x3. Stop the staged process with
`pgrep -f '^/tmp/numa-stage/numa'` - a bare `pkill -f /tmp/numa-stage/numa`
matches the ssh shell itself and kills nothing.

Metrics: qps; `VmRSS`/`VmSize` from `/proc/<pid>/status`; resolver CPU per
query from the sum over `/proc/<pid>/task/*/stat`
(`sum(utime+stime)/CLK_TCK/queries`).

Microbench: `cargo bench --no-run --bench throughput` with the variant's flags,
copy the binary to the router, run the `pipeline_parallel` group with 1/2/4
threads.

## Results

### End-to-end (dnsperf, cached)

Router, `:5399`, `cached.txt` = 52 names warmed first, `dnsperf` 2.x, `-c 8
-l 12`. Means; mimalloc rows are 6 ABBA runs, the rest 3 round-robin rounds.

| variant | mean qps | VmSize | VmRSS |
|---|---|---|---|
| upstream official aarch64 | 29 273 | 33 MB | ~20 MB |
| generic-musl | 29 629 | 33 MB | ~20 MB |
| cortex-a73-musl | 28 515 | 33 MB | ~20 MB |
| generic-mimalloc | 41 014 | 1072 MB | ~36 MB |
| cortex-a73-mimalloc | 38 512 | 1072 MB | ~36 MB |

Effects (same run):

| comparison | delta | reading |
|---|---|---|
| generic-musl -> generic-mimalloc | +39% | mimalloc |
| cortex-a73-musl -> cortex-a73-mimalloc | +34% | mimalloc |
| generic-musl -> cortex-a73-musl | -3.8% | a73 |
| generic-mimalloc -> cortex-a73-mimalloc | -6.1% | a73 |
| upstream -> generic-musl | +1% | noise |

- mimalloc is the win (+34-39%): the allocator, not the ISA tuning.
- `-C target-cpu=cortex-a73` costs ~4-6% cached throughput vs generic; kept
  anyway (see Decision).
- mem: mimalloc reserves ~1 GB **VmSize** (virtual arenas) but only ~20-36 MB
  RSS; the live numa reports VmSize 1048 MB, VmRSS 24.5 MB, VmHWM 37 MB.
  Address space, not RAM. Requirement: `overcommit_memory != 2` and no
  `ulimit -v` (router: overcommit=0, `ulimit -v` unlimited).
- not measured: the cold/unique path, DNSSEC on.

### Confirmation: generic-mimalloc vs cortex-a73-mimalloc (`-T 4 -c 32`)

Re-run with higher client parallelism to rule out a client-side ceiling, ABBA
x3, CPU/query summed over the staged pid's `/proc/<pid>/task/*/stat`
(`CLK_TCK=100`).

| variant | mean qps | CPU ms/query | dropped/run |
|---|---|---|---|
| generic-mimalloc | 38 958 | 0.0697 | 54 |
| cortex-a73-mimalloc | 35 760 | 0.0758 | 71 |

- More client parallelism did not raise qps: the earlier ~41k was the
  resolver/host limit, not the client, so the grid stands.
- a73 is -8.2% qps here (reproduces the -6.1% grid figure) and +8% CPU/query:
  no efficiency upside. The only unmeasured a73 upside is its ISA on
  TLS/DNSSEC paths (off).

### Microbench (`pipeline_parallel`)

| variant | threads | q/s |
|---|---|---|
| | | |

## Decision

`build.publish = generic-mimalloc` (switched 2026-10-05).

mimalloc is the win and ships either way. On top, generic beats a73 on cached
throughput (a73 -6 to -8%) and on CPU/query (a73 +8% CPU per query), so there
is no efficiency upside. The only a73 upside is its ISA (aes/sha2/crc) on
TLS/DNSSEC paths, which are off. Revisit only if DNSSEC/TLS-heavy server paths
are enabled and re-measured.

## A/B: router vs HA add-on (Pi4), 2026-10-05

Load client wired (`enp11s0`, `<client v4>/24`), same /24 as both targets.
`dnsperf` 2.x, `cached.txt` = 52 popular names, warmed once per target first.

| target | build | host |
|---|---|---|
| A `<router v4>` | `cortex-a73-mimalloc` (published then) | GL-BE14000, MT7988A, 4x Cortex-A73 |
| B `<ha-host v4>` | upstream `numa-linux-aarch64` (generic) | Raspberry Pi 4 (BCM2711, 4x Cortex-A72), HA add-on, `host_network` |

### Throughput (cached, 8 clients, 15s, order A B B A x3)

```
dnsperf -s <ip> -p 53 -d cached.txt -c 8 -l 15
```

| round | A qps (a/b) | B qps (a/b) |
|---|---|---|
| 1 | 28371 / 28848 | 19980 / 19885 |
| 2 | 29140 / 28538 | 20245 / 20202 |
| 3 | 28726 / 28695 | 20186 / 20135 |

| target | mean qps | avg latency under load | dropped/run |
|---|---|---|---|
| A router | 28 720 | 2.77 ms | 66 |
| B Pi4 | 20 105 | 2.97 ms | 122 |

Router is **1.43x** the Pi4 in qps; drops <0.05% both.

### Low load (1 client, 500 qps cap, 15s)

```
dnsperf -s <ip> -p 53 -d cached.txt -c 1 -Q 500 -l 15
```

| target | dig avg latency | ping RTT (30x) | ping TTL | resolver cost (dig - RTT) |
|---|---|---|---|---|
| A router | 0.46 ms | 0.45 ms | 64 | ~0.01 ms |
| B Pi4 | 0.27 ms | 0.23 ms | 64 | ~0.04 ms |

### Reading

- Throughput tracks hardware + allocator: the variant grid above shows
  mimalloc is the win (+34-39%) and the a73 ISA tuning is neutral-to-negative,
  so the 1.43x vs the Pi4 comes from mimalloc plus A73-vs-A72, not the flags.
- The low-load gap is **network, not numa**: TTL is 64 for both (same subnet,
  zero L3 hops), so the ~0.2 ms difference is the router's software packet
  path, not an extra hop. Net of RTT the resolver adds ~0.01 ms (router) vs
  ~0.04 ms (Pi4) - sub-tenth-of-ms on both.
- Router-side diagnostics (2026-10-05): no `cpufreq` (no DVFS); `tc` only the
  default `fq_codel` (no SQM); nftables empty (the router uses iptables-legacy);
  Ethernet IRQs pinned to CPU0 (`/proc/interrupts`, 0 on CPUs 1-3), so network
  processing is single-core there. `ethtool -c` exposes no coalescing params.
- For a home LAN (tens to hundreds of qps) both are far beyond the need. The
  router's measurable win is throughput headroom and removing the HA host from
  the DNS path, not low-load latency.
