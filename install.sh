#!/bin/sh
# transtation installer.
#
#   sh install.sh                          install the server
#   sh install.sh client                   install the client, proxy mode
#   sh install.sh client --tun             install the client, whole-host tunnel
#   sh install.sh client --tun --killswitch   ... and a fail-closed egress filter
#   sh install.sh --uninstall              remove whichever is installed here
#
# `set -eu`, deliberately NOT `-o pipefail`: /bin/sh is dash on Debian and
# Ubuntu -- the primary target -- and `curl | sh` ignores the shebang, so
# pipefail would abort this script on its first line.
#
# Everything of substance lives in functions, and main() is invoked on the very
# last line. If the download is truncated, nothing runs.
set -eu

VERSION=${TT_VERSION:-v1.0.8}
IMAGE_SERVER=${TT_IMAGE_SERVER:-ghcr.io/sqzer-x/transtation}
IMAGE_CLIENT=${TT_IMAGE_CLIENT:-ghcr.io/sqzer-x/transtation-client}
# Filled in by the release workflow. A tag is mutable -- the same stolen-token
# compromise we already concede for Xray's .dgst would let someone retag
# v1.0.8, and the hash-verified installer you read would vouch for nothing.
SERVER_DIGEST=${TT_SERVER_DIGEST:-}
CLIENT_DIGEST=${TT_CLIENT_DIGEST:-}

DIR=${TT_DIR:-/opt/transtation}
URI_DIR=/etc/transtation
RAW=https://raw.githubusercontent.com/sqzer-x/transtation/$VERSION

say() { printf '%s\n' "$*"; }
# Under `curl | sh` stdin is the script itself, so a bare `read` swallows the
# rest of this file. Under cron or CI there is no /dev/tty at all. Try the
# terminal, fall back to stdin, and treat "neither" as no answer.
ask() {
	printf '%s' "$1"
	REPLY=""
	# `[ -r /dev/tty ]` is not enough: the node exists and looks readable even
	# with no controlling terminal, and opening it then fails with ENXIO and
	# prints to stderr. Try the open for real, suppress it, fall back to stdin.
	if { read -r REPLY </dev/tty; } 2>/dev/null && [ -n "$REPLY" ]; then
		return 0
	fi
	read -r REPLY 2>/dev/null || REPLY=""
}
step() { printf '  %-14s%s\n' "$1" "$2"; }
die() { printf '\ntranstation: %s\n\n' "$*" >&2; exit 1; }

server_image() { printf '%s:%s%s' "$IMAGE_SERVER" "$VERSION" "${SERVER_DIGEST:+@$SERVER_DIGEST}"; }
client_image() { printf '%s:%s%s' "$IMAGE_CLIENT" "$VERSION" "${CLIENT_DIGEST:+@$CLIENT_DIGEST}"; }

need_root() {
	[ "$(id -u)" = 0 ] || die "this needs root. Re-run as root, or with sudo:
    curl -fsSLO $RAW/install.sh && sudo sh install.sh"
}

check_arch() {
	case "$(uname -m)" in
		x86_64 | amd64 | aarch64 | arm64) ;;
		*) die "unsupported architecture: $(uname -m). transtation ships amd64 and arm64 images only." ;;
	esac
}

os_id() {
	# shellcheck disable=SC1091
	[ -r /etc/os-release ] && . /etc/os-release && printf '%s' "${ID:-unknown}" || printf 'unknown'
}

install_docker() {
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		step docker "$(docker --version | cut -d, -f1), compose $(docker compose version --short)"
		return 0
	fi
	say ""
	step docker "not found -- installing"
	case "$(os_id)" in
		alpine)
			# get.docker.com hard-fails on Alpine.
			apk add --no-cache docker docker-cli-compose >/dev/null
			rc-update add docker default >/dev/null 2>&1 || true
			service docker start >/dev/null 2>&1 || true
			;;
		arch | archarm | manjaro | endeavouros)
			# get.docker.com hard-fails on Arch too.
			pacman -S --needed --noconfirm docker docker-compose >/dev/null
			systemctl enable --now docker >/dev/null 2>&1 || true
			;;
		*)
			say "                 NOTE: this runs https://get.docker.com, a ~780-line third-party"
			say "                 script, as root. We do not review it. If you would rather not,"
			say "                 install Docker yourself and run this installer again."
			curl -fsSL https://get.docker.com | sh >/dev/null
			systemctl enable --now docker >/dev/null 2>&1 || true
			;;
	esac
	command -v docker >/dev/null 2>&1 || die "Docker installation failed. Install it yourself and re-run."
	docker compose version >/dev/null 2>&1 || die "the Docker Compose plugin is missing. Install docker-compose-plugin and re-run."
	step docker "$(docker --version | cut -d, -f1), compose $(docker compose version --short)"
	say "                 note: installing Docker sets net.ipv4.ip_forward=1 on this host."
}

wait_healthy() {
	_name=$1 _limit=${2:-120} _t=0
	while [ "$_t" -lt "$_limit" ]; do
		case "$(docker inspect -f '{{.State.Health.Status}}' "$_name" 2>/dev/null || echo none)" in
			healthy) printf 'healthy (%ss)\n' "$_t"; return 0 ;;
			unhealthy | none) ;;
		esac
		sleep 3
		_t=$((_t + 3))
		printf '.'
	done
	printf 'TIMED OUT (%ss)\n' "$_limit"
	return 1
}

# ------------------------------------------------------------------ server

install_server() {
	need_root
	check_arch
	say ""
	say "  transtation $VERSION -- your own VLESS + REALITY proxy"
	say "  https://github.com/sqzer-x/transtation"
	say ""
	step host "$(os_id) / $(uname -m) / root"
	install_docker

	mkdir -p "$DIR"
	if [ -f "$DIR/docker-compose.yml" ]; then
		step config "already present at $DIR -- reusing it (this is an upgrade, not a reinstall)"
	else
		cat >"$DIR/docker-compose.yml" <<-EOF
			services:
			  proxy:
			    image: $(server_image)
			    container_name: transtation
			    restart: unless-stopped
			    ports: ["\${PORT:-443}:8443"]
			    volumes: ["transtation-data:/data"]
			    env_file: .env
			    # Hardening. The process already holds zero effective capabilities
			    # (verified: CapEff 0000000000000000), so these mostly shrink what a
			    # future change could quietly re-acquire.
			    cap_drop: [ALL]
			    security_opt: ["no-new-privileges:true"]
			    read_only: true
			    tmpfs: ["/tmp:rw,noexec,nosuid,size=16m"]
			    logging:
			      driver: json-file
			      options: { max-size: "10m", max-file: "3" }
			    # Do NOT add cap_add: NET_ADMIN or devices: /dev/net/tun here.
			    # Both BREAK the WARP outbound. See README, "Capabilities".
			volumes:
			  transtation-data:
			    # Pinned. Without an explicit name Docker Compose prefixes it with
			    # the project name, which comes from the directory -- so the volume
			    # would be called something else on every host and every documented
			    # backup, restore and uninstall command would silently address a
			    # volume that does not exist.
			    name: transtation-data
		EOF
		: >"$DIR/.env"
		chmod 600 "$DIR/.env"
		# If PORT came from the environment, write it down. Compose would honour
		# it for the published port while the container -- which reads only
		# env_file -- would still think it is 443, and the share link would name
		# the wrong port.
		[ -n "${PORT:-}" ] && printf 'PORT=%s\n' "$PORT" >>"$DIR/.env"
		step config "wrote $DIR/docker-compose.yml and $DIR/.env"
	fi
	[ -n "$SERVER_DIGEST" ] || say "                 note: image pinned by tag, not digest (unreleased build)"

	install_wrapper
	step wrapper "installed /usr/local/bin/transtation"

	printf '  %-14s' image
	docker compose -f "$DIR/docker-compose.yml" --project-directory "$DIR" pull -q 2>/dev/null || true
	say "pulled $(server_image)"

	printf '  %-14s' start
	docker compose -f "$DIR/docker-compose.yml" --project-directory "$DIR" up -d >/dev/null 2>&1
	if ! wait_healthy transtation 120; then
		say ""
		say "  The container is up but not healthy yet. Most common causes:"
		say "    - the WARP tunnel is not passing traffic (some providers block outbound"
		say "      UDP/2408 even though registration, which is TCP, succeeded). Fix:"
		say "        sed -i 's/^WARP=1/WARP=0/' $DIR/.env || echo WARP=0 >> $DIR/.env"
		say "        cd $DIR && docker compose up -d"
		say "    - no outbound HTTPS from this host at all."
		say ""
		say "  Diagnose with:  transtation status   and   transtation logs"
		exit 1
	fi

	# The healthcheck proves egress, but it goes through a loopback inbound and
	# never touches REALITY -- so a dest whose certificate chain is too large
	# produces a permanently "healthy" server that no client can connect to.
	# This is the only check that catches it.
	printf '  %-14s' verify
	if transtation verify; then :; else
		say ""
		say "  The server is running but clients cannot complete the REALITY handshake."
		say "  Fix the dest and try again:"
		say "      echo 'SNI=dl.google.com' >> $DIR/.env"
		say "      cd $DIR && docker compose up -d && transtation verify"
		exit 1
	fi

	say ""
	transtation status || true
	_port=$(sed -n 's/^PORT=//p' "$DIR/.env" 2>/dev/null | tail -1)
	cat <<-EOF
		  DO THIS NOW -- it is the only irreplaceable thing on this box:
		      transtation backup

		  Your link:   transtation show
		  Add a user:  transtation user add alice
		  Uninstall:   sh install.sh --uninstall

		  >> If a client cannot connect, open TCP ${_port:-443} in your provider's
		     firewall or security group. The healthcheck above only proves OUTBOUND
		     traffic works; inbound cannot be verified from this host. Note that
		     Docker's published ports bypass ufw in both directions.

	EOF
}

install_wrapper() {
	cat >/usr/local/bin/transtation <<-EOF
		#!/bin/sh
		set -eu
		C="docker compose -f $DIR/docker-compose.yml --project-directory $DIR"
		case "\${1:-}" in
		  backup)
		    f=\${2:-/root/transtation-backup.tgz}
		    [ -e "\$f" ] && { echo "\$f exists -- refusing to overwrite" >&2; exit 1; }
		    # root's umask is 022 on every target distro, which would make a
		    # world-readable tarball of your Reality private key, your WARP private
		    # key and your WARP bearer token.
		    umask 077
		    \$C exec -T proxy transtation backup > "\$f"
		    echo "backed up to \$f (mode 0600): reality key, users, WARP account."
		    ;;
		  restore)
		    f=\${2:-}
		    [ -n "\$f" ] && [ -r "\$f" ] || { echo "usage: transtation restore <backup.tgz>" >&2; exit 1; }
		    tar tzf "\$f" 2>/dev/null | grep -q '^state.env$' || { echo "\$f does not look like a transtation backup" >&2; exit 1; }
		    if \$C ps -q proxy 2>/dev/null | grep -q .; then
		      echo "stop the server first:  cd $DIR && docker compose down" >&2; exit 1
		    fi
		    # --user 0 so it can read a 0600 archive; the transtation image so that
		    # Docker seeds a fresh volume with the right /data ownership; tar then
		    # restores each file's archived uid.
		    docker run --rm --user 0 \\
		      -v transtation-data:/data \\
		      -v "\$(cd "\$(dirname "\$f")" && pwd)":/b:ro \\
		      --entrypoint sh $(server_image) \\
		      -c "tar xzf /b/\$(basename "\$f") -C /data"
		    echo "restored. start it again:  cd $DIR && docker compose up -d"
		    ;;
		  logs) shift; exec \$C logs "\$@" ;;
		  up|down|pull|restart) exec \$C "\$@" ;;
		  *) exec \$C exec proxy transtation "\$@" ;;
		esac
	EOF
	chmod 0755 /usr/local/bin/transtation
}

# ------------------------------------------------------------------ client

install_client() {
	need_root
	check_arch
	_tun=0 _ks=0 _uri=""
	for a in "$@"; do
		case "$a" in
			--tun) _tun=1 ;;
			--killswitch) _ks=1 ;;
			vless://*) _uri=$a ;;
			*) die "unknown option: $a" ;;
		esac
	done
	[ "$_ks" = 0 ] || [ "$_tun" = 1 ] || die "--killswitch only makes sense together with --tun"

	say ""
	say "  transtation client $VERSION"
	say ""

	if [ -z "$_uri" ] && [ ! -r "$URI_DIR/uri" ]; then
		say "  paste the link from your server (run 'transtation show' there):"
		ask '  > '
		_uri=$REPLY
		[ -n "$_uri" ] || die "no link given. Pass it as an argument instead:
    sh install.sh client 'vless://...'"
	fi
	if [ -n "$_uri" ]; then
		mkdir -p "$URI_DIR"
		umask 077
		printf '%s\n' "$_uri" >"$URI_DIR/uri"
		chmod 600 "$URI_DIR/uri"
		step link "stored at $URI_DIR/uri (0600)"
	else
		step link "reusing $URI_DIR/uri"
	fi

	install_docker
	docker rm -f transtation-client >/dev/null 2>&1 || true

	if [ "$_tun" = 1 ]; then
		step mode "tun -- whole-host transparent tunnel"
		set --
		[ -n "${DIRECT_SUFFIXES:-}" ] && set -- -e "DIRECT_SUFFIXES=$DIRECT_SUFFIXES"
		docker run -d --name transtation-client --restart unless-stopped \
			--network host --cap-add NET_ADMIN --device /dev/net/tun \
			-e MODE=tun "$@" \
			-v "$URI_DIR":"$URI_DIR":ro \
			"$(client_image)" >/dev/null
		install -Dm0755 /dev/stdin /usr/local/sbin/transtation-panic <<-'EOF'
			#!/bin/sh
			set -u
			TUN_IFACE=${TUN_IFACE:-tt0}
			nft delete table inet transtation 2>/dev/null
			nft delete table ip6 transtation 2>/dev/null
			for f in -4 -6; do
			  ip $f rule list 2>/dev/null | sed -n 's/^\(90[0-9][0-9]\):.*/\1/p' | while read -r p; do
			    ip $f rule del priority "$p" 2>/dev/null
			  done
			done
			ip route flush table 2022 2>/dev/null
			ip -6 route flush table 2022 2>/dev/null
			ip link del "$TUN_IFACE" 2>/dev/null
			docker rm -f transtation-client 2>/dev/null >/dev/null
			echo "killswitch removed, policy routing flushed. You are back on direct egress."
		EOF
		step panic "installed /usr/local/sbin/transtation-panic"
		if [ "$_ks" = 1 ]; then
			curl -fsSL "$RAW/host/transtation-killswitch" -o /usr/local/sbin/transtation-killswitch 2>/dev/null ||
				die "could not fetch the killswitch script from $RAW"
			chmod 0755 /usr/local/sbin/transtation-killswitch
			/usr/local/sbin/transtation-killswitch on
		fi
	else
		step mode "proxy -- local SOCKS5 + HTTP, no root privileges used at runtime"
		docker run -d --name transtation-client --restart unless-stopped \
			-p 127.0.0.1:1080:1080 \
			-v "$URI_DIR":"$URI_DIR":ro \
			"$(client_image)" >/dev/null
	fi

	printf '  %-14s' self-test
	# The result has to be captured and tested. An earlier version piped curl
	# into grep into tr with `|| printf "no answer yet"` on the end -- which hangs
	# off `tr`, the last command in the pipeline, and `tr` always succeeds. The
	# fallback could never fire, so a client that was not passing any traffic at
	# all still finished with a success banner.
	_probe=""
	_n=0
	while [ "$_n" -lt 6 ]; do
		if [ "$_tun" = 1 ]; then
			_probe=$(curl -fsS --max-time 10 https://cloudflare.com/cdn-cgi/trace 2>/dev/null |
				grep -E '^(ip|warp|colo)=' | tr '\n' ' ')
		else
			_probe=$(curl -fsS --max-time 10 --socks5-hostname 127.0.0.1:1080 https://cloudflare.com/cdn-cgi/trace 2>/dev/null |
				grep -E '^(ip|warp|colo)=' | tr '\n' ' ')
		fi
		[ -n "$_probe" ] && break
		_n=$((_n + 1))
		sleep 2
	done
	if [ -n "$_probe" ]; then
		say "$_probe"
	else
		say "NO TRAFFIC"
		say ""
		say "  The client started but nothing is getting through. Look at:"
		say "      docker logs transtation-client"
		[ "$_tun" = 1 ] && say "      sudo transtation-panic     # to undo the tunnel and killswitch"
		exit 1
	fi

	if [ "$_tun" = 0 ]; then
		cat <<-'EOF'

			  export ALL_PROXY=socks5h://127.0.0.1:1080 HTTPS_PROXY=http://127.0.0.1:1080 HTTP_PROXY=http://127.0.0.1:1080

			    The "h" in socks5h is load-bearing: plain socks5:// makes curl resolve DNS
			    locally and leaks every hostname you visit. In Firefox, tick "Proxy DNS
			    when using SOCKS v5".
			    Not covered by this mode: QUIC (it degrades to TCP) and any app that
			    ignores proxy environment variables.

			  Whole-system tunnel instead:  sudo sh install.sh client --tun --killswitch

		EOF
	else
		say ""
		say "  If your network ever dies:  sudo transtation-panic"
		say ""
	fi
}

# --------------------------------------------------------------- uninstall

uninstall() {
	need_root
	if [ -d "$DIR" ]; then
		docker compose -f "$DIR/docker-compose.yml" --project-directory "$DIR" down >/dev/null 2>&1 || true
		rm -f "$DIR/docker-compose.yml" "$DIR/.env" /usr/local/bin/transtation
		rmdir "$DIR" 2>/dev/null || true
		say "server removed."
		ask 'also delete the data volume? That destroys your Reality key and every issued link. [y/N] '
		say ""
		case "$REPLY" in
			y | Y)
				if docker volume rm transtation-data >/dev/null 2>&1; then
					say "volume deleted."
				else
					say "could not delete the volume (in use, or already gone):"
					docker volume ls --format '  {{.Name}}' | grep transtation || say "  none found"
				fi
				;;
			*) say "volume kept: 'docker volume ls | grep transtation-data'" ;;
		esac
	fi
	if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx transtation-client; then
		docker rm -f transtation-client >/dev/null
		say "client removed."
	fi
	if [ -x /usr/local/sbin/transtation-killswitch ]; then
		/usr/local/sbin/transtation-killswitch off || true
		rm -f /usr/local/sbin/transtation-killswitch
	fi
	rm -f /usr/local/sbin/transtation-panic
	say "done. $URI_DIR was left in place; remove it yourself if you are finished with it."
}

main() {
	# `shift` with no positional parameters is a special-builtin error, and a
	# POSIX shell exits on those -- `|| true` does not save you. dash is
	# /bin/sh on Debian and Ubuntu, so `sh install.sh` with no arguments used
	# to die here, silently, on the primary target. bash (Arch's /bin/sh) is
	# forgiving, which is exactly why local testing never saw it.
	_cmd=${1:-server}
	if [ $# -gt 0 ]; then shift; fi
	case "$_cmd" in
		server) install_server ;;
		client) install_client "$@" ;;
		--uninstall | uninstall) uninstall ;;
		-h | --help)
			sed -n '2,10p' "$0" 2>/dev/null || say "see https://github.com/sqzer-x/transtation"
			;;
		*) die "unknown command: $_cmd (expected: server, client, --uninstall)" ;;
	esac
}

main "$@"
