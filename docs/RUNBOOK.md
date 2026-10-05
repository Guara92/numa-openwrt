# numa-openwrt runbook

Operational procedures for the Flint 4. Facts and pin values live in
`docs/NOTES.md`; the build inputs live in `upstream.lock`.

## Model

numa owns `:53` (dual-stack, `bind_addr = "[::]:53"`). dnsmasq moves to `:5354`
and keeps DHCP plus local names; numa forwards `lan`, the dnsmasq domain and the
reverse zones to it. Cutover is per DHCP pool, so clients keep their current DNS
until they renew.

`numa-ctl` is the only supported way to enable, disable, upgrade and roll back.
Nothing starts numa at install time.

## First install

```sh
# on a PC: copy the trusted pubkey and bootstrap.sh to the router out-of-band.
# -O forces the legacy SCP protocol: OpenWrt ships no sftp-server and OpenSSH >= 9
# defaults scp to SFTP, which fails with "sftp-server: not found".
scp -O bootstrap.sh pkg/root/etc/numa/keys/numa-openwrt.pub root@router:/tmp/

ssh root@router 'NUMA_OPENWRT_REPO=<owner>/numa-openwrt sh /tmp/bootstrap.sh /tmp/numa-openwrt.pub'
numa-ctl gen-config --apply
numa-ctl stage --ipk "$(ls -1t /etc/numa/pkgcache/*.ipk | head -1)"
numa-ctl enable
# test one client: set its DNS to the router, confirm it resolves and is filtered
numa-ctl cutover lan
```

## Hard rules

- **Never touch the GL UI DNS settings, AdGuard Home, or VPN-client DNS pages.**
  If GL rewrites the dnsmasq port back to 53 while numa holds `:53`, dnsmasq
  fails to start and **DHCP goes down**. `numa-ctl status` reports the drift.
- **Never touch a protected pool**: pools listed one per line in
  `/etc/numa/state/protected_pools` are refused by `cutover`. Add any site pool
  that must keep bypassing to its own DNS.
- GL dynamic DNS rules written into dnsmasq are bypassed once numa is primary.
  Re-express them as `[[forwarding]]` in `numa.toml`.
- `allow_from` is left empty on purpose (numa default: allow all peers). Client
  source prefixes churn (SLAAC ULA from a LAN router advertisement, rotating ISP
  GUA) and cannot be enumerated, so a prefix allowlist silently drops LAN
  clients. Reachability is contained by the firewall instead: the `wan` zone
  must keep `input='DROP'` and **nothing may forward or expose `:53`**
  (`[dot]`/`[proxy]` stay disabled). Do not reintroduce a prefix list.

## Firmware upgrade

`keep.d` preserves `/etc/numa/` only. A settings-keeping flash removes
`/usr/sbin/numa`, `/usr/sbin/numa-ctl` and `/etc/init.d/numa`; `numa.toml`, the
keys and `pkgcache/` survive, so no `gen-config` is needed after the reinstall.

1. `numa-ctl disable` **before** flashing (restores dnsmasq on `:53`).
2. Flash.
3. Restore the package from the kept cache:

   ```sh
   ls -l /etc/numa/pkgcache/
   opkg install /etc/numa/pkgcache/numa_*.ipk
   ```

   If `pkgcache/` is empty (the bootstrap that installed it predates the cache
   copy, or the flash dropped the overlay), download `numa_*.ipk` on a PC,
   `scp -O` it to `/tmp`, then `opkg install /tmp/numa_*.ipk`.
4. `numa-ctl enable`.

Do **not** reach for `bootstrap.sh` as the first fallback: with dnsmasq left on
`:5354` the router has no resolver on `:53`, and the fetch dies with the
misleading `Failed to send request: Operation not permitted`
(`strerror(UCLIENT_ERROR_CONNECT)`, i.e. *cannot connect* — DNS or route, not a
permission error). Restore `:53` first:
`uci -q delete dhcp.@dnsmasq[0].port && uci commit dhcp && /etc/init.d/dnsmasq restart`.

## Upgrade and rollback (no firmware change)

```sh
numa-ctl upgrade        # fetch + stage on :5399 + install + health, auto-rollback on failure
numa-ctl rollback       # install the previous cached ipk
```

`stage` runs the candidate on `:5399` with a copy of the live state, so a bad
binary never touches `:53`.

## Watchdog

`enable` installs `* * * * * /usr/sbin/numa-ctl watchdog`. It probes the canary
on `127.0.0.1:53`; after 3 consecutive misses it runs `disable`, leaves
`/etc/numa/state/FAILED_OPEN`, and logs `daemon.crit`. This is **fail-open**: the
router falls back to dnsmasq rather than losing DNS. `enable` clears the flag.

Test it without breaking DNS: `kill -STOP $(pgrep -x numa)` and watch the next
three cron ticks; then `kill -CONT`.

## Open decisions

Until answered, defaults hold:
1. the current LAN DHCP option-6 host keeps serving; decide whether numa
   replaces it after cutover.
2. the iot pool and any protected pool keep bypassing to their own DNS.
3. Upstream provider: Quad9 DoH.
4. Watchdog is fail-open.
