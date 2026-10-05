# numa bench (real aarch64, GL-BE14000)

Data for upstream PR #395. Nothing here is filled in yet.

## Variants

| variant | note |
|---|---|
| upstream official aarch64 | verify upstream sha256 |
| generic-musl | |
| generic-mimalloc | |
| cortex-a73-musl | |
| cortex-a73-mimalloc | |

Allocator and CPU effects are separable by comparing across the grid.

## Method

Target: `numa-ctl stage --variant V --keep` -> `[::]:5399` on the router (LAN
zone input is allowed). Run off-peak; the router is live.

Load from a wired LAN PC with `dnsperf`:

```sh
dnsperf -s <lan v4> -p 5399 -d cached.txt -c {1,8} -q 16 -l 30
```

`cached.txt` holds about 100 names, warmed once first. Order A B B A per pair,
3 rounds.

Metrics: qps; resolver CPU per query from `/proc/<pid>/stat`
(`(utime+stime)/CLK_TCK/queries`); `VmRSS` idle and under load.

Microbench: `cargo bench --no-run --bench throughput` with the variant's flags,
copy the binary to the router, run the `pipeline_parallel` group with 1/2/4
threads.

## Results

### End-to-end (dnsperf, cached)

| variant | clients | qps | CPU/query | VmRSS idle | VmRSS load |
|---|---|---|---|---|---|
| | | | | | |

### Microbench (`pipeline_parallel`)

| variant | threads | q/s |
|---|---|---|
| | | |

## Decision

`build.publish` in `upstream.lock` records the packaged variant. [TBD]

## A/B: router vs HA add-on (Pi4), 2026-10-05

Load client wired (`enp11s0`, `192.168.1.106/24`), same /24 as both targets.
`dnsperf` 2.x, `cached.txt` = 52 popular names, warmed once per target first.

| target | build | host |
|---|---|---|
| A `192.168.1.1` | `cortex-a73-mimalloc` (this repo) | GL-BE14000, MT7988A, 4x Cortex-A73 |
| B `192.168.1.247` | upstream `numa-linux-aarch64` (generic) | Raspberry Pi 4 (BCM2711, 4x Cortex-A72), HA add-on, `host_network` |

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

- Throughput tracks CPU: the A73 build is ~1.4x the generic A72 build; the
  `target-cpu` tuning and mimalloc sit in that delta.
- The low-load gap is **network, not numa**: TTL is 64 for both (same subnet,
  zero L3 hops), so the ~0.2 ms difference is the router's slower idle
  response, not an extra hop. Net of RTT the resolver adds ~0.01 ms (router)
  vs ~0.04 ms (Pi4) - sub-tenth-of-ms on both.
- For a home LAN (tens to hundreds of qps) both are far beyond the need. The
  router's measurable win is throughput headroom and removing the HA host from
  the DNS path, not low-load latency.
