# transtation

Your own VLESS + REALITY proxy, with optional Cloudflare WARP egress, in one
container on any Linux box that has Docker.

```
curl -fsSLO https://raw.githubusercontent.com/sqzer-x/transtation/v1.0.14/install.sh
sha256sum install.sh      # compare against the hash in the v1.0.14 release notes
less install.sh           # please actually read it
sudo sh install.sh
```

That is the whole server install. It generates its own Reality keypair and its
first user, registers a WARP identity, and prints the connection details as a
`vless://` link with a QR of the same link.

---

## This is not a new idea, and you should know the alternatives

[`reality-ezpz`](https://github.com/aleskxyz/reality-ezpz) already does Reality
+ WARP + share link + QR over Docker Compose. [`3x-ui`](https://github.com/MHSanaei/3x-ui)
owns the web-panel end of this space with 44k stars and does far more than this
does. If you want a panel, multiple users with quotas, subscription links or a
Telegram bot, **use 3x-ui and stop reading here.**

transtation exists because of a narrower set of preferences:

- **A published, digest-pinned image**, not a 2,700-line bash generator you run
  on your host.
- **Zero capabilities.** The container holds no `NET_ADMIN`, mounts no
  `/dev/net/tun`, and does not use host networking. WARP runs in Xray's
  in-process userspace network stack.
- **Tracking upstream.** Xray ships roughly monthly and its config schema moves.
  If this project stops keeping up within a year it is worse than what it
  replaced, and the right thing to do then is archive it and point at
  reality-ezpz. That is a promise, not a disclaimer.

---

## Server

Two ways to run it. They are the same software with the same config; pick on
how you feel about a container runtime on your VPS.

### In a container (default)

```
curl -fsSLO https://raw.githubusercontent.com/sqzer-x/transtation/v1.0.14/install.sh
sha256sum install.sh      # compare against the hash in the v1.0.14 release notes
less install.sh           # please actually read it
sudo sh install.sh
```

Installs Docker if it is missing, writes `/opt/transtation/{docker-compose.yml,.env}`,
resolves the image tag to a digest and pins the compose file to it, then waits
for the container to be healthy and proves the handshake works. Re-running it is
how you upgrade.

### Natively

```
sudo sh install.sh server --native
```

No container runtime. It downloads Xray and wgcf, verifies both against
upstream checksums, installs `/usr/local/bin/transtation`, keeps state in
`/var/lib/transtation` owned by a dedicated `transtation` user, and runs under
`transtation.service`.

### Which one

Measured on the same host, same binary:

| | container | native |
|---|---|---|
| capabilities held | **none** — `CapEff 0000000000000000` | `CAP_NET_BIND_SERVICE`, and only that |
| root filesystem | read-only | `ProtectSystem=strict` |
| runs as | uid 10001 | `transtation` user |
| costs | Docker daemon, ~250 MB, `ip_forward=1`, published ports bypass `ufw` | needs systemd |
| upgrades | pull a new digest | re-run the installer |

The container needs no capability at all because dockerd performs the
privileged bind on 443 and the container listens high; natively there is
nothing in front, so it keeps exactly one capability and nothing else is even
reachable. Both pin and verify the same Xray release.

If you have no strong feeling, use the container: one artifact, dependencies
verified and frozen inside it, and rollback is a digest. If you would rather not
run a container runtime on a proxy server, the native path is not a lesser
option — it is the same program with a systemd unit instead of a compose file.

Either way `transtation` is the command:

### Day to day

```
transtation show              # share link + QR for every user
transtation status            # address, SNI, egress IP, WARP state, users
transtation user add alice    # new UUID + shortId, applied immediately
transtation user rm alice     # revokes both
transtation backup            # tar.gz of everything irreplaceable, mode 0600
transtation restore <file>    # put one back (server must be stopped)
transtation verify            # prove a client can actually complete the handshake
transtation logs -f
```

`transtation user add` and `user rm` restart Xray to apply. Existing connections
drop and clients reconnect on their own; Xray has no config reload signal.

### Open the port

The healthcheck only proves **outbound** traffic works. Nothing on the server
can prove inbound does. If clients time out and the server log shows nothing at
all, open TCP 443 in your provider's firewall or security group. Note that
Docker's published ports **bypass `ufw`** in both directions, so a ufw rule is
neither necessary nor sufficient; Oracle Cloud additionally needs the port
opened in the instance's own iptables.

---

## Client

You may well not need this project's client. The server prints a `vless://`
link, and every platform already has a good client that takes one:

| Platform | Use |
|---|---|
| Android | v2rayNG, Hiddify |
| iOS | sing-box, Streisand, Shadowrocket |
| Windows / macOS | v2rayN, Hiddify, sing-box |

What those do not cover well is a Linux machine you want *entirely* behind the
proxy, with a fail-closed killswitch, managed by the init system. That is what
this client is for, and it installs natively — a verified static `sing-box`
binary, a generated config and a systemd unit. **No Docker on the client.**

Capturing a machine's traffic means owning its routing table. A container
handed `--network host` and `CAP_NET_ADMIN` to do that isolates nothing; it is
a packaging format with extra failure modes, and it excludes every phone and
desktop anyway.

### Whole-host tunnel (default)

```
sudo sh install.sh client
```

It asks for the link, verifies and installs sing-box, writes
`transtation-client.service`, starts it, and then checks that this machine's
public address actually **changed** — a reply on its own only proves the network
works, which it did before you installed anything. If the address did not move,
the installer says so and exits non-zero.

```
stop:    sudo systemctl stop transtation-client
logs:    journalctl -u transtation-client -f
panic:   sudo transtation-panic        # undo everything, needs no network
```

Everything the machine sends goes through the tunnel with no per-program
configuration — including traffic from containers running on it.

`DIRECT_SUFFIXES` is a comma-separated list of domain suffixes that bypass the
tunnel entirely — for sites that block proxy IPs, or a bank that objects to a
foreign exit. Those domains also resolve locally rather than through the tunnel,
so you get the geographically correct answer before connecting.

```
DIRECT_SUFFIXES=example.com,example.net sudo sh install.sh client --killswitch
```

Needs Linux, root and systemd. The tunnel interface is created directly on the
host, so there is no rootless story to get wrong and nothing to be confused
about on macOS or Windows — use one of the apps above there.

### Proxy mode — a local SOCKS5 + HTTP proxy

```
sudo sh install.sh client --proxy
```

**This does not put your machine behind the proxy.** It opens a proxy on
`127.0.0.1:1080` and nothing else. Every program that should use it has to be
pointed at it, one at a time. Your browser keeps using your own address until
you configure it; so does everything started from your desktop, and every
systemd service.

```
export ALL_PROXY=socks5h://127.0.0.1:1080
export HTTPS_PROXY=http://127.0.0.1:1080 HTTP_PROXY=http://127.0.0.1:1080
```

Those two lines apply to **that shell and the programs it starts**, and nothing
else. Measured on a host with the client running:

```
curl https://api.ipify.org                 198.51.100.23   your own address
curl https://api.ipify.org   (after the exports)
                                           192.0.2.7    through the proxy
env -i curl https://api.ipify.org          198.51.100.23   your own address
   … and the same from any other terminal, and from anything your desktop starts
```

The **`h`** in `socks5h` is load-bearing: plain `socks5://` makes curl resolve
DNS locally and leaks every hostname you visit. In Firefox, set the SOCKS host
in the connection settings and tick "Proxy DNS when using SOCKS v5" — the
environment variables above will not reach it.

Two more things this mode will not do even for a program you *have* pointed at
it: QUIC (browsers do not send UDP over SOCKS, so it silently falls back to
TCP), and anything that reads no proxy setting at all.

Settings, all optional:

| Variable | Default | What it does |
|---|---|---|
| `DIRECT_SUFFIXES` | *(empty)* | comma-separated domain suffixes that bypass the tunnel |
| `SOCKS_PORT` | `1080` | proxy mode's listening port |
| `TT_URI_FILE` | `/etc/transtation/uri` | where the share link is read from |

### Killswitch and recovery

`--killswitch` installs a host-owned nftables table with a `policy drop` output
chain. It permits loopback, established connections, the tun interface, the
split-tunnel fwmark, RFC1918/CGNAT/link-local/multicast, DHCP, and your server's
address and port. Everything else is dropped, so nothing leaks when the tunnel
is down.

It is **additive** — a separate `table inet transtation` — and removing it is
one command. Nothing in this project ever runs `nft flush ruleset`, which on a
modern host would also wipe the iptables-nft tables Docker installs and silently
break every container on the box.

```
sudo transtation-killswitch on [--persist]
sudo transtation-killswitch off
sudo transtation-killswitch status
```

Persistence is opt-in. By default the killswitch dies at reboot, because reboot
is the first thing everyone tries when the network stops working.

**Two limits, stated plainly.** It is an output-hook chain: it covers this host's
own processes, and traffic *forwarded* from your other containers does not
traverse it. And if you test it by SIGKILLing the client, note that sing-box's
own ip rules at priority 9000–9010 survive — they are not bound to the
interface.

If your network ever dies:

```
sudo transtation-panic
```

Small, and it needs neither a network nor Docker. The same commands are printed
in the client's startup banner every boot, so they are in
`journalctl -u transtation-client` and in your scrollback.

---

## Configuration

Nothing is required. Copy `.env.example` to `/opt/transtation/.env` and set only
what you want to change; every value is read fresh on each boot.

| Variable | Default | What it does |
|---|---|---|
| `PORT` | `443` | public port |
| `HOST` | auto-detected | address that goes into the share link |
| `SNI` | *auto-selected* | the site your server impersonates — leave unset |
| `CLIENT_REGION` | server's country | two-letter code for where your clients connect from |
| `DEST` | `$SNI:443` | where the handshake is forwarded |
| `WARP` | `1` | `0` to egress from the VPS IP instead |
| `WARP_ENDPOINT` | `162.159.192.1:2408` | override if this anycast address does not handshake |
| `USER_NAME` | `main` | name of the user created on first boot |
| `MIN_CLIENT_VER` | `0.0.0` | Reality client version floor |
| `SKIP_DEST_CHECK` | `0` | skip the startup TLS probe of `$SNI` |

### The dest picks itself

The single most important setting is which real site your server impersonates,
so transtation chooses it on first boot — the way a commercial VPN picks your
nearest exit rather than making you read a server list.

**The thing that gets you blocked is not a slow dest, it is an implausible
one.** Your clients' ISP sees their traffic labelled with this name and judges
the volume and shape of it against what the name implies. Hours of sustained
multi-gigabyte download addressed to a corporate brochure page is not something
a human does, and a DPI box that has already taken an interest in your server's
address starts dropping the connection. The same bytes pulled from a video
service are what everyone does all evening.

So candidates carry a curated class, and it dominates the score:

| class | what it is | weight |
|---|---|---|
| `bulk` | video, streaming, real download and CDN hosts. Sustained multi-GB transfer and hours-long connections are unremarkable. | 0 |
| `mixed` | media-heavy portals. Moderate sustained traffic is fine; a torrent of it is a bit odd. | +800 |
| `light` | corporate sites, marketing pages, DNS endpoints. Bulk transfer here looks exactly as wrong as it is. | +2500 |

The weights are in milliseconds so they compare directly against measured
latency, and they are deliberately lopsided: being dropped is fatal, a slower
dest merely adds to connection setup.

This class is a judgement about the internet, not something a probe can
measure — `accept-ranges` was tested for the job and does not discriminate
(`dl.google.com` answers `none` on its root path; `addons.mozilla.org` answers
`bytes`). Everything else *is* measured, from the server, in parallel:

- **hard filter** — the handshake must succeed, it must be TLS 1.3, and the
  certificate chain must have headroom under the size where REALITY breaks.
  Both halves earn their keep: `abema.tv` is an otherwise ideal Japanese video
  dest that serves only TLS 1.2, and `www.hulu.com` has a 4717-byte chain.
- **latency** — the measured TLS handshake time, because your server re-dials
  this site on every single client connection.
- **region** — worth 150 ms. The region that matters is where your *clients*
  are, not where your server is: the ISP judging the traffic is theirs.
  Defaults to the server's country; set `CLIENT_REGION` when they differ.

```
$ transtation sni
  sni     tv.naver.com
  why     sustained heavy traffic is unremarkable here; same region as your
          clients; 54ms TLS handshake, 3480-byte chain
  since   2026-08-06
```

From a Korean VPS it picks a Korean streaming service; with `CLIENT_REGION=JP`
it picks `www.nicovideo.jp`; with no region it can determine at all, a global
streaming brand.

**The choice is sticky.** It lives in the data volume, is included in backups,
and is never re-picked on its own — every share link carries `sni=`, so
silently changing it would break every client you have already handed out.
Re-picking is explicit, and says what it invalidates:

```
transtation sni auto        # probe again and re-pick   (invalidates links)
transtation sni <domain>    # set by hand               (invalidates links)
```

Setting `SNI=` in `.env` overrides all of it, permanently.

### Why the size of a certificate matters

**Above roughly 5200 bytes of certificate chain the REALITY handshake does not
complete**, and the failure is silent in the worst way: the container reports
healthy, the port listens, and every client is quietly handed the real website
instead of your proxy. Measured end to end against Xray 26.3.27:

| dest | chain | | dest | chain |
|---|---|---|---|---|
| `dl.google.com` | 895 ✓ | | `www.ibm.com` | 4331 ✓ |
| `one.one.one.one` | 2307 ✓ | | `www.paypal.com` | 4883 ✓ |
| `www.cloudflare.com` | 2493 ✓ | | `www.linkedin.com` | 5046 ✓ |
| `addons.mozilla.org` | 2843 ✓ | | `www.microsoft.com` | 5879 ✗ |
| `www.nicovideo.jp` | 3822 ✓ | | | |

The auto-selection filters on this, so you only meet it if you override `SNI`
yourself. When you do:

```
transtation verify
```

does a genuine REALITY handshake against the server's own inbound. It is the
only check that proves clients can actually connect — the healthcheck goes
through a loopback inbound and never touches REALITY at all. `install.sh` runs
it for you and refuses to finish if it fails.

Apple and iCloud domains are rejected outright — Xray warns that they get your
IP blocked by the GFW. To inspect a candidate yourself:

```
docker compose exec proxy xray tls ping example.com
```

---

## Capabilities

The container holds **none at all**, verified on a running server:
`CapEff`, `CapPrm` and `CapBnd` all `0000000000000000`, `NoNewPrivs 1`, root
filesystem read-only. The native install holds `CAP_NET_BIND_SERVICE` and
nothing else, because something has to bind 443 and there is no dockerd in
front to do it.

| | Needed? | |
|---|---|---|
| `cap_add: NET_ADMIN` | no | the generated config pins `"noKernelTun": true`, so WARP always runs in Xray's in-process userspace stack regardless of what the container holds. Adding the capability buys nothing and widens the container's privileges. |
| `--device /dev/net/tun` | no | the userspace network stack needs no TUN device |
| `CAP_NET_BIND_SERVICE` | container: no | it listens on 8443 inside; `-p 443:8443` does the privileged bind in dockerd, which also keeps this working under rootless Docker |
| `--network host` | no, and must not be used | it would expose the loopback SOCKS inbound the healthcheck uses, turning your server into an open relay |

For reference, a hand-rolled native Xray unit typically holds `CAP_NET_ADMIN`
*and* `CAP_NET_BIND_SERVICE` with a writable root filesystem. The `NET_ADMIN`
half is only needed for kernel-TUN WARP, which this does not use.

That `noKernelTun` pin is load-bearing rather than decorative. Left unset, Xray
probes for `CAP_NET_ADMIN` and takes the kernel-TUN path when it finds it — and
`createKernelTun` writes to `/proc/sys/.../rp_filter` *before* opening the
device, which fails on Docker's read-only `/proc/sys` with no fallback. Pinning
it makes behaviour independent of capabilities.

To confirm:To confirm:

```
docker compose logs proxy | grep -o 'Using .* TUN'      # container
journalctl -u transtation | grep -o 'Using .* TUN'     # native
# both -> Using gVisor TUN
```

---

## What this does not protect you from

- **Your account.** The VPS is rented in your name with your card. Reality hides
  *what* the traffic is, not *whose* server it is.
- **Traffic analysis over time.** Reality is very good against a prober that
  connects and looks; it is not a defence against an adversary correlating flow
  timing and volume across a link they fully observe.
- **The endpoint.** Sites still see a browser fingerprint, cookies, and a login.
- **Publishing your link.** A `vless://` link is a credential *and* a permanent
  fingerprint of your server. Once it is public, revoke it (`transtation user rm`)
  — the shortId goes with it.
- **BitTorrent.** The default routing blocks *unencrypted* BitTorrent
  handshakes. Encrypted BT (MSE/PE, the modern default) and DHT pass straight
  through. You have no DMCA protection here; your provider will forward the
  notice to you.
- **Outbound abuse from your own box.** Port 25 is blocked by default so a
  WARP-less install is not an open SMTP relay, and the cloud metadata range
  `169.254.0.0/16` is blocked so a client of your proxy cannot read your
  instance's IAM credentials. Everything else your users do leaves from your IP.

## About WARP

With `WARP=1` (the default) traffic exits from a Cloudflare address instead of
your VPS's. Your server's IP never reaches the destination, and cloud-IP
blocklists do not apply to you.

The costs are real: a shared exit pool means more CAPTCHAs, the exit's geography
is Cloudflare's choice and not your VPS's, the free tier is throttled under
sustained load, and MTU drops to 1280. Registration also depends on an
undocumented third-party API. If any of that bothers you, set `WARP=0` — the
proxy works exactly the same, it just egresses from your own address.

If registration fails, the server **starts anyway** with direct egress and says
so on every boot and in `transtation status`. It never retries in a loop:
hammering Cloudflare's registration endpoint is how a source IP, historically a
whole region, gets blocked.

---

## Backup, upgrade, uninstall

```
transtation backup                        # -> /root/transtation-backup.tgz, mode 0600
```

That tarball holds your Reality private key, your users, and your WARP account.
It is the only thing on the box you cannot regenerate. Restoring is one command
into a fresh volume:

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

Upgrades: re-run `install.sh` (with `server --native` if that is how you
installed), or `docker compose pull && docker compose up -d`.
Your identity lives in the volume and survives; the config is regenerated from
the new image every boot, so schema changes come along for free.

```
sudo sh install.sh --uninstall
```

It removes the containers and the compose file, and asks separately before
deleting the data volume.

---

## About `curl | sh`

It is a real objection and this project does not wave it away:

1. **You cannot review what you pipe.** So the documented form downloads the
   script, checks its hash against the release notes, and lets you read it. Do
   that.
2. **A truncated download could execute half a script.** Everything here lives
   in functions and `main "$@"` is the last line, so a truncated file runs
   nothing.
3. **It installs Docker via `get.docker.com`**, a ~780-line third-party script,
   as root. The installer tells you before it does, and skips the step entirely
   if Docker is already present.
4. **The image tag is mutable.** The installer resolves the tag to the digest
   it points at during installation and writes *that* into the compose file, so
   from then on `docker compose up` can only start the exact image the install
   verified. Re-running the installer is how you move to a newer one.

The Xray binary is verified inside the Dockerfile against the `.dgst` file from
the same GitHub release. That defends against a bad mirror or a truncated
transfer, **not** against a compromised upstream — Xray publishes no signatures.
sing-box publishes no checksum file at all, so its hashes are pinned in
`client/Dockerfile` and reviewed as part of this repo.

## What has been tested

Everything below was run, on a Korean client against an AWS Tokyo VPS with the
host's own proxy stopped, so nothing was measured through a second proxy:

- **Server on a real VPS.** `install.sh` on Ubuntu 24.04: installs Docker,
  pulls and digest-pins the image, and `verify` completes a REALITY handshake
  reporting `warp=on colo=NRT`.
- **Client to server across the internet, no tunnels.** Client container in
  Korea to a Tokyo VPS with the host's own proxy stopped, so nothing was
  measured through a second proxy. Steady-state request latency ≈0.20 s,
  throughput 6.5–8.3 MB/s for a 10 MB download, and 0.9 s from `docker run` to
  the first byte through the tunnel.
- **The camouflage, from outside.** `openssl s_client` against the server on
  :443 returns a genuine `C=JP, O=TVer INC., CN=*.tver.jp` certificate over
  TLS 1.3 — the dest the auto-selection chose for a Japanese server, unprompted.
- **Users.** Added a second user, connected as them, revoked them; their client
  stopped working and the first one kept going.
- **Whole-host tunnel.** `MODE=tun` moved the host's egress from its ISP address
  to WARP, kept `DIRECT_SUFFIXES` domains on their real path, and `SIGKILL` of
  the container left `curl` timing out rather than leaking. `transtation-panic`
  restored direct egress with no rules, no interface and no table left behind,
  and without disturbing Tailscale's rules or other containers.
- **The client, natively.** `install.sh client` on this laptop: verified
  sing-box, systemd unit, tunnel up, host egress moved off the ISP address,
  `DIRECT_SUFFIXES` domains still on their real path, other containers on the
  host carried too, and `transtation-panic` putting it all back. Pointed at a
  dead server it reports "still your own address" and exits non-zero.
- **arm64.** The published arm64 server image was run under emulation with a
  client on the other architecture passing traffic through it.
- **Timings, measured rather than asserted.** On that VPS: 7.3 s from
  `docker compose up` to healthy on a first boot that generates keys, picks a
  dest and registers with WARP; 14.4 s to a proven-working proxy. Most of the
  gap between the two is a fixed warm-up inside Xray before its first proxied
  connection, not work this project controls.

## Building and testing yourself

```
git clone https://github.com/sqzer-x/transtation && cd transtation
sh test.sh
```

Builds both images and runs their offline self-checks: the config renders and is
accepted by the pinned Xray with WARP on *and* off, the `xray x25519` parser
survives all three historical output formats, every invariant that protects you
(no empty shortId, port 25 blocked, metadata range blocked, loopback-only health
inbound) holds, both client configs are accepted by sing-box, and malformed
share links are rejected. Everything runs with `--network none`; the test suite
never registers a WARP identity.

## License

MIT. See [LICENSE](LICENSE). Third-party binaries redistributed in the images —
Xray-core (MPL-2.0), wgcf (MIT), sing-box (GPL-3.0-or-later) — and their
obligations are listed in [NOTICE](NOTICE).
