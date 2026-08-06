# Troubleshooting

Organised by what you actually see, not by what is actually wrong.

---

## The client connects to nothing. No error, no server log line — and the real website loads instead.

This is the worst failure in the whole ecosystem, because everything looks
healthy. The server starts clean, the port listens, and every rejected
connection falls through to the genuine site your server impersonates, so a
browser pointed at your server shows you `www.microsoft.com`.

It means the handshake was rejected before Xray logged anything. Causes, in
order of likelihood:

1. **Wrong `pbk`, `sid` or `sni` in the link.** Regenerate it — never hand-edit
   it, and never reuse a link from an older install:
   ```
   transtation show
   ```
2. **`minClientVer`.** Newer Xray versions default the Reality server to a
   client-version floor, and a client below it gets exactly this behaviour.
   transtation pins `minClientVer=0.0.0` so this cannot happen; if you set
   `MIN_CLIENT_VER` yourself, unset it.
3. **Missing `fp` in a hand-built link.** sing-box, NekoBox and Hiddify hard-fail
   with `uTLS is required by reality client`; Xray-based clients tolerate it.
   The generated link always carries `fp=chrome`.
4. **Your SNI stopped supporting TLS 1.3 or X25519.** Check it and pick another:
   ```
   docker compose exec proxy xray tls ping www.microsoft.com
   ```

---

## `transtation status` says `egress DIRECT — WARP requested but NOT registered`

Registration failed, and the server started anyway rather than crash-looping.
This is not cosmetic: **every packet is leaving from your VPS's own IP**, which
is the address tied to your name and payment method.

```
transtation warp register
```

Cloudflare rate-limits registration per source IP for about fifteen minutes, so
if you have just retried a few times, wait. If it keeps failing, either accept
direct egress and silence the warning with `WARP=0` in `/opt/transtation/.env`,
or check that this host has working outbound HTTPS.

---

## The container is `unhealthy`, but Reality itself works

Almost always: **your provider blocks outbound UDP/2408**. WARP registration is
TCP and succeeds; the data plane is UDP and never comes up.

```
docker compose logs proxy | grep -o 'Using .* TUN'
```

- prints `Using gVisor TUN` → good, the userspace path is live; the problem is
  UDP egress. Set `WARP=0` in `.env` and `docker compose up -d`.
- prints `Using kernel TUN`, or the container dies with a `read-only file
  system` error mentioning `rp_filter` → **you added `--cap-add NET_ADMIN`.
  Remove it.** With that capability Xray tries kernel TUN, writes to
  `/proc/sys` before opening the device, hits Docker's read-only `/proc/sys`,
  and fails with no fallback.

Docker does not restart unhealthy containers by itself. `unhealthy` is a report,
not a self-heal.

---

## Clients time out and the server log is completely silent

Nothing is reaching Xray. The healthcheck cannot detect this — it only proves
*outbound* traffic works, and inbound cannot be verified from the server at all.

1. Open TCP 443 in your **provider's** firewall or security group. This is the
   answer roughly nine times out of ten.
2. Oracle Cloud also needs it opened in the instance's own iptables.
3. Docker's published ports **bypass `ufw`** in both directions, so a ufw rule
   neither helps nor hurts. Do not go looking there.
4. Confirm something is actually listening:
   ```
   docker compose ps
   ss -tlnp | grep :443
   ```

---

## Tun mode: the container starts and exits, or the host's traffic is untouched

Read the startup message — each impossible situation gets its own sentence.

| Message | Meaning |
|---|---|
| `no /dev/net/tun in this container` | add `--device /dev/net/tun`. If the *host* has none: `sudo modprobe tun && echo tun \| sudo tee /etc/modules-load.d/tun.conf` |
| `cannot manage host routing` | either `--cap-add NET_ADMIN` is missing, or this is rootless Docker/Podman, where tun mode cannot work at all. Use proxy mode. On Fedora/RHEL also try `sudo setsebool -P container_use_devices=true` |
| `docker0 is not visible` | you are on bridge networking. Add `--network host`, or the tunnel comes up in the container's own namespace and your host never uses it |

---

## The network is completely dead

```
sudo transtation-panic
```

It removes the killswitch table, sweeps sing-box's leftover ip rules at
priority 9000–9010, flushes routing table 2022 and deletes `tt0`. It needs
neither Docker nor a working network.

If `transtation-panic` is not installed, the same thing by hand:

```
sudo nft delete table inet transtation
for p in $(seq 9000 9010); do sudo ip rule del priority $p 2>/dev/null; done
sudo ip link del tt0
```

Note that a SIGKILLed sing-box leaves those ip rules behind even though the tun
device is gone — including `strict_route`'s unreachable rule, which is not bound
to the interface. That is why the loop above matters and deleting the interface
alone is not enough.

---

## Everything works except one site, which blocks you

That is WARP's shared exit pool, not a bug. Either route that site around the
tunnel:

```
docker run ... -e DIRECT_SUFFIXES=thatsite.com,othersite.net ...
```

or turn WARP off entirely (`WARP=0`) so you egress from your own VPS address.

---

## I lost the volume / moved to a new host

If you have a backup, it is one command into a fresh volume:

```
docker run --rm -v transtation-data:/data -v /root:/b alpine \
  tar xzf /b/transtation-backup.tgz -C /data
```

If you do not, there is nothing to recover: a new install generates a new
keypair, and every previously issued link is dead. Run `transtation backup` now
on the install you still have.
