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
