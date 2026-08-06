# Troubleshooting

Organised by what you actually see, not by what is actually wrong.

---

## The client connects to nothing. No error, no server log line — and the real website loads instead.

This is the worst failure in the whole ecosystem, because everything looks
healthy. The server starts clean, the port listens, and every rejected
connection falls through to the genuine site your server impersonates, so a
browser pointed at your server shows you `www.microsoft.com`.

First, settle it in one command:

```
transtation verify
```

That does a real REALITY handshake against the server's own inbound. If it
fails, the problem is the server, not your client — and note that the
healthcheck cannot tell you this, because it goes through a loopback inbound
that never touches REALITY.

Causes, in order of likelihood:

1. **The dest's certificate chain is too big.** Above roughly 5200 bytes the
   handshake dies partway through the borrowed certificate. `www.microsoft.com`
   (5879 bytes) is the notable trap — it looks like the safest possible choice
   and does not work. Check and replace:
   ```
   docker compose exec proxy xray tls ping www.microsoft.com   # look at the chain length
   echo 'SNI=dl.google.com' >> /opt/transtation/.env
   cd /opt/transtation && docker compose up -d && transtation verify
   ```
   Known-good: `dl.google.com` (895), `www.cloudflare.com` (2493),
   `addons.mozilla.org` (2843), `www.nicovideo.jp` (3822).
2. **Wrong `pbk`, `sid` or `sni` in the link.** Regenerate it — never hand-edit
   it, and never reuse a link from an older install:
   ```
   transtation show
   ```
3. **`minClientVer`.** Newer Xray versions default the Reality server to a
   client-version floor, and a client below it gets exactly this behaviour.
   transtation pins `minClientVer=0.0.0` so this cannot happen; if you set
   `MIN_CLIENT_VER` yourself, unset it.
4. **Missing `fp` in a hand-built link.** sing-box, NekoBox and Hiddify hard-fail
   with `uTLS is required by reality client`; Xray-based clients tolerate it.
   The generated link always carries `fp=chrome`.
5. **Your SNI stopped supporting TLS 1.3 or X25519.** Check it and pick another:
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

It should print `Using gVisor TUN. NoKernelTun is set to true.` — that is the
normal, expected path and it holds even if the container was given extra
capabilities. So if you see it, the WireGuard stack is fine and the problem is
UDP egress: set `WARP=0` in `.env` and `docker compose up -d`.

If instead it prints `Using kernel TUN`, or the container dies with a
`read-only file system` error mentioning `rp_filter`, then something removed
the `noKernelTun` pin from the generated config. That is a transtation bug —
please report it.

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
# several rules can share one priority, so delete until each one is empty
for p in $(seq 9000 9010); do
  while sudo ip rule del priority $p 2>/dev/null; do :; done
done
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
cd /opt/transtation && docker compose down
transtation restore /root/transtation-backup.tgz
docker compose up -d && transtation verify
```

This started life as a documented `tar` one-liner and failed twice in testing,
so it is a command now. Getting it right by hand means knowing that Docker
seeds a fresh named volume with the ownership of the image directory it is
first mounted into — so unpacking with a generic image leaves `/data` owned by
root and the server refuses to start — *and* that the backup is mode 0600, so
the unpacking container has to run as root to read it at all. `restore` also
refuses to run while the server is up, and refuses a file that is not a
transtation backup.

If you do not, there is nothing to recover: a new install generates a new
keypair, and every previously issued link is dead. Run `transtation backup` now
on the install you still have.
