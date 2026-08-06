# transtation

Your own VLESS + REALITY proxy, with optional Cloudflare WARP egress, in one
container on any Linux box that has Docker.

```
curl -fsSLO https://raw.githubusercontent.com/sqzer-x/transtation/v1.0.2/install.sh
sha256sum install.sh      # compare against the hash in the v1.0.2 release notes
less install.sh           # please actually read it
sudo sh install.sh
```

That is the whole server install. It generates its own Reality keypair, its own
user, registers a WARP identity, and prints a `vless://` link and a QR code you
scan with any client app.

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

### Install

Two-step form above is the recommended one. If you are going to pipe it anyway:

```
curl -fsSL https://raw.githubusercontent.com/sqzer-x/transtation/v1.0.2/install.sh | sudo sh
```

The installer needs root, refuses anything other than x86_64/aarch64, installs
Docker if it is missing, writes `/opt/transtation/{docker-compose.yml,.env}`,
and waits for the container to report healthy. Running it again is an upgrade:
it pulls and restarts, and never re-provisions.

If you already run Docker and prefer to do it yourself:

```yaml
# /opt/transtation/docker-compose.yml
services:
  proxy:
    image: ghcr.io/sqzer-x/transtation:v1.0.2
    container_name: transtation
    restart: unless-stopped
    ports: ["443:8443"]
    volumes: ["transtation-data:/data"]
    env_file: .env
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
volumes:
  transtation-data:
    name: transtation-data      # pinned; otherwise Compose prefixes it with the directory name
```

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

You do not need this project's client at all. Any app that speaks VLESS +
REALITY works with the link:

| Platform | Use |
|---|---|
| Android | v2rayNG, Hiddify |
| iOS | sing-box, Streisand, Shadowrocket |
| Windows / macOS | v2rayN, Hiddify, sing-box |
| Linux desktop, permanently | the native `sing-box` package plus upstream's systemd unit |

The container is for headless Linux and for people who would rather not install
anything.

### Proxy mode (default) — a local SOCKS5 + HTTP proxy

```
sudo sh install.sh client
```

or by hand:

```
install -Dm600 /dev/stdin /etc/transtation/uri   # paste the vless:// link, then Ctrl-D
docker run -d --name transtation-client --restart unless-stopped \
  -p 127.0.0.1:1080:1080 \
  -v /etc/transtation:/etc/transtation:ro \
  ghcr.io/sqzer-x/transtation-client:v1.0.2
```

```
export ALL_PROXY=socks5h://127.0.0.1:1080
export HTTPS_PROXY=http://127.0.0.1:1080 HTTP_PROXY=http://127.0.0.1:1080
```

The **`h`** in `socks5h` is load-bearing: plain `socks5://` makes curl resolve
DNS locally and leaks every hostname you visit. In Firefox, tick "Proxy DNS when
using SOCKS v5".

No capabilities, no devices, no host networking. Works under rootless Docker,
rootless Podman and Docker Desktop.

**Not covered:** QUIC (browsers do not send UDP over SOCKS, so it silently falls
back to TCP), and any application that ignores proxy environment variables.
**No killswitch is needed here** — nothing is redirected, so if the container
dies, proxied connections simply fail. That is this mode's biggest advantage.

### Tun mode — the whole host

```
sudo sh install.sh client --tun --killswitch
```

or by hand:

```
docker run -d --name transtation-client --restart unless-stopped \
  --network host --cap-add NET_ADMIN --device /dev/net/tun \
  -e MODE=tun \
  -e DIRECT_SUFFIXES=example.com,example.net \
  -v /etc/transtation:/etc/transtation:ro \
  ghcr.io/sqzer-x/transtation-client:v1.0.2
```

Exactly three extra flags. `--privileged` is **not** needed and must not be
used. `--network host` is not optional: without it the tunnel comes up inside
the container's own network namespace and your host's traffic is untouched.

**Linux only, rootful Docker only.** On Docker Desktop (Windows, macOS)
`--network host` joins the *virtual machine's* namespace, so tun mode there is
not unsupported, it is architecturally incapable. Under rootless Docker or
Podman it cannot work either: a capability held in a child user namespace does
not authorise operations on a network namespace owned by the initial one. The
container detects both cases at startup and says so.

Be honest with yourself about what this buys: a container with `--network host`
and `CAP_NET_ADMIN` provides **no isolation whatsoever**, while adding the
SELinux/AppArmor/rootless matrix and losing systemd-resolved integration (the
container has no `resolvectl`, so sing-box falls back to hijacking port 53). For
a permanent desktop setup the native `sing-box` package with upstream's hardened
systemd unit is the better answer. Tun mode ships because it is genuinely useful
on a headless box, not because it is more secure.

`DIRECT_SUFFIXES` is a comma-separated list of domain suffixes that bypass the
tunnel entirely — for sites that block proxy IPs, or a bank that objects to a
foreign exit. Those domains also resolve locally rather than through the tunnel,
so you get the geographically correct answer before connecting.

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

Six lines, no network and no Docker needed. It also exists as a verb of the
client image (`docker run --rm --network host --cap-add NET_ADMIN <image> panic`),
and the three raw commands are printed in the client's startup banner every
boot, so they are in `docker logs` and in your scrollback.

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

## Capabilities: none, and none needed

| | Needed? | |
|---|---|---|
| `cap_add: NET_ADMIN` | no | the generated config pins `"noKernelTun": true`, so WARP always runs in Xray's in-process userspace stack regardless of what the container holds. Adding the capability buys nothing and widens the container's privileges. |
| `--device /dev/net/tun` | no | the userspace network stack needs no TUN device |
| `CAP_NET_BIND_SERVICE` | no | it listens on 8443 inside; `-p 443:8443` does the privileged bind in dockerd, which also keeps this working under rootless Docker |
| `--network host` | no, and must not be used | it would expose the loopback SOCKS inbound the healthcheck uses, turning your server into an open relay |

That `noKernelTun` pin is load-bearing rather than decorative. Left unset, Xray
probes for `CAP_NET_ADMIN` and takes the kernel-TUN path when it finds it — and
`createKernelTun` writes to `/proc/sys/.../rp_filter` *before* opening the
device, which fails on Docker's read-only `/proc/sys` with no fallback. Pinning
it makes the container's behaviour independent of its capabilities.

To confirm:

```
docker compose logs proxy | grep -o 'Using .* TUN'    # -> Using gVisor TUN
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

Upgrades: re-run `install.sh`, or `docker compose pull && docker compose up -d`.
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
4. **The image tag is mutable.** Release builds pin the image by SHA-256 digest
   in the compose file, so a retagged image will not be pulled.

The Xray binary is verified inside the Dockerfile against the `.dgst` file from
the same GitHub release. That defends against a bad mirror or a truncated
transfer, **not** against a compromised upstream — Xray publishes no signatures.
sing-box publishes no checksum file at all, so its hashes are pinned in
`client/Dockerfile` and reviewed as part of this repo.

## What has actually been tested

Claims in this README are things that were run, not things that were reasoned
about. The full picture, on a Korean client and an AWS Tokyo VPS:

- **Server on a real VPS.** `install.sh` on Ubuntu 24.04: installs Docker,
  pulls the image, healthy in 12s, `verify` completes a REALITY handshake and
  reports `warp=on colo=NRT`.
- **Client to server across the internet, no tunnels.** Client container in
  Korea to `203.0.113.10:443` in Tokyo. 10 MB in 1.21 s (≈8.3 MB/s) through
  Korea → Tokyo → WARP.
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
- **Rootless.** `MODE=proxy` works under rootless Podman. `MODE=tun` there
  refuses with the reason rather than half-starting; under rootful Podman it
  works.
- **arm64.** The published arm64 image runs its selftest under emulation.

Not tested, and therefore not claimed: SELinux hosts, Docker Desktop on Windows
or macOS, Docker older than 29, and IPv6-only hosts (the killswitch refuses
those outright rather than building a broken ruleset).

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
