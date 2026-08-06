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

VERSION=${TT_VERSION:-v1.0.16}
IMAGE_SERVER=${TT_IMAGE_SERVER:-ghcr.io/sqzer-x/transtation}
# Filled in by the release workflow. A tag is mutable -- the same stolen-token
# compromise we already concede for Xray's .dgst would let someone retag
# v1.0.16, and the hash-verified installer you read would vouch for nothing.
SERVER_DIGEST=${TT_SERVER_DIGEST:-}

# sing-box ships no checksum file, so these were computed once from the official
# release artifacts and are reviewed as part of this repo. The -musl builds are
# statically linked, so one binary runs on any distribution.
XRAY_VERSION=${TT_XRAY_VERSION:-v26.3.27}
WGCF_VERSION=${TT_WGCF_VERSION:-2.2.32}
SINGBOX_VERSION=${TT_SINGBOX_VERSION:-1.13.16}
SINGBOX_SHA_amd64=9ff0345fde4157a6bdab45a615668d41ccc93f6d0f361108042a48b8a49a9baa
SINGBOX_SHA_arm64=3ea951c68f2eea10fd3ee8f8cc7794c12ccc7405afa99279a79e0b41cb183adf

# Our copies of third-party binaries live here, never in /usr/local/bin. That
# is where the official Xray installer and hand-rolled setups put theirs, and
# writing there means overwriting somebody's working server -- and then deleting
# it on uninstall. Which is exactly what happened once.
PRIVLIB=/usr/local/lib/transtation

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

# --- native server -------------------------------------------------------

# The two server installs both own /usr/local/bin/transtation and both want the
# same port. Installing one over the other leaves the first running and
# orphaned -- still holding a port, still serving its own identity, no longer
# reachable by the command. Refuse instead.
refuse_other_server() {
	case "$1" in
		container)
			[ -e /etc/systemd/system/transtation.service ] &&
				die "a native server is already installed here.
    Remove it first:  sh install.sh --uninstall
    Or keep it -- it is the same software."
			;;
		native)
			{ [ -e "$DIR/docker-compose.yml" ] || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx transtation; } &&
				die "a containerised server is already installed here.
    Remove it first:  sh install.sh --uninstall
    Or keep it -- it is the same software."
			;;
	esac
	return 0
}


fetch_verified_xray() {
	case "$(uname -m)" in
		x86_64 | amd64) _xz=Xray-linux-64.zip; _wa=amd64 ;;
		aarch64 | arm64) _xz=Xray-linux-arm64-v8a.zip; _wa=arm64 ;;
	esac
	_t=$(mktemp -d)
	_b="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}"
	curl -fsSL -o "$_t/$_xz" "$_b/$_xz" || { rm -rf "$_t"; die "could not download Xray ${XRAY_VERSION}"; }
	curl -fsSL -o "$_t/$_xz.dgst" "$_b/$_xz.dgst" || { rm -rf "$_t"; die "could not download the Xray checksum"; }
	_exp=$(awk '/^SHA2-256/ {print $2}' "$_t/$_xz.dgst")
	# Same guard as the Dockerfile: an empty expectation makes sha256sum verify
	# nothing at all.
	printf '%s' "$_exp" | grep -Eq '^[0-9a-f]{64}$' ||
		{ rm -rf "$_t"; die "no usable SHA2-256 line in $_xz.dgst"; }
	( cd "$_t" && echo "$_exp  $_xz" | sha256sum -c - >/dev/null 2>&1 ) ||
		{ rm -rf "$_t"; die "Xray checksum mismatch -- refusing to install it"; }
	command -v unzip >/dev/null 2>&1 || install_pkg unzip
	unzip -q -j "$_t/$_xz" xray -d "$_t"
	install -Dm0755 "$_t/xray" "$PRIVLIB/xray"

	_w="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}"
	curl -fsSL -o "$_t/wgcf" "$_w/wgcf_${WGCF_VERSION}_linux_${_wa}" ||
		{ rm -rf "$_t"; die "could not download wgcf"; }
	curl -fsSL "$_w/checksums.txt" | grep " wgcf_${WGCF_VERSION}_linux_${_wa}\$" |
		awk -v f="$_t/wgcf" '{print $1"  "f}' | sha256sum -c - >/dev/null 2>&1 ||
		{ rm -rf "$_t"; die "wgcf checksum mismatch -- refusing to install it"; }
	install -Dm0755 "$_t/wgcf" "$PRIVLIB/wgcf"
	rm -rf "$_t"
	step binaries "xray $("$PRIVLIB/xray" version | head -1 | cut -d' ' -f2) and wgcf ${WGCF_VERSION}, both checksum-verified, in $PRIVLIB"
}

install_pkg() {
	case "$(os_id)" in
		alpine) apk add --no-cache "$1" >/dev/null 2>&1 ;;
		arch | archarm | manjaro | endeavouros) pacman -S --needed --noconfirm "$1" >/dev/null 2>&1 ;;
		*) DEBIAN_FRONTEND=noninteractive apt-get -y -qq install "$1" >/dev/null 2>&1 ||
			dnf -y -q install "$1" >/dev/null 2>&1 || true ;;
	esac
}

install_server_native() {
	need_root
	check_arch
	refuse_other_server native
	say ""
	say "  transtation $VERSION -- native install, no container runtime"
	say "  https://github.com/sqzer-x/transtation"
	say ""
	step host "$(os_id) / $(uname -m) / root"
	[ -d /run/systemd/system ] || die "the native install is managed by systemd, which is not running here.
    Use the container install instead:  sh install.sh"
	command -v curl >/dev/null 2>&1 || die "curl is required"

	fetch_verified_xray
	install -Dm0755 "$(server_script)" "$PRIVLIB/server"

	id -u transtation >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin transtation 2>/dev/null ||
		adduser -S -D -H -s /sbin/nologin transtation 2>/dev/null || true
	install -d -o transtation -g transtation -m 0700 /var/lib/transtation
	mkdir -p /etc/transtation
	[ -e /etc/transtation/server.env ] || { : >/etc/transtation/server.env; chmod 600 /etc/transtation/server.env; }
	[ -n "${PORT:-}" ] && ! grep -q '^PORT=' /etc/transtation/server.env &&
		printf 'PORT=%s\n' "$PORT" >>/etc/transtation/server.env
	# Every command has to run as the service user. Run as root, the script would
	# create root-owned files in the state directory and the service -- which is
	# not root -- would stop being able to read its own identity.
	install -Dm0755 /dev/stdin /usr/local/bin/transtation <<-'WRAP'
		#!/bin/sh
		set -eu
		if [ "$(id -un)" = transtation ]; then
		  exec env TT_DATA=/var/lib/transtation PATH=/usr/local/lib/transtation:$PATH /usr/local/lib/transtation/server "$@"
		fi
		[ "$(id -u)" = 0 ] || { echo "transtation: run this as root or as the transtation user" >&2; exit 1; }
		if command -v runuser >/dev/null 2>&1; then
		  exec runuser -u transtation -- env TT_DATA=/var/lib/transtation PATH=/usr/local/lib/transtation:$PATH /usr/local/lib/transtation/server "$@"
		fi
		exec su -s /bin/sh transtation -c 'exec env TT_DATA=/var/lib/transtation PATH=/usr/local/lib/transtation:$PATH /usr/local/lib/transtation/server "$@"' -- sh "$@"
	WRAP
	step config "wrote /etc/transtation/server.env, data in /var/lib/transtation"

	cat >/etc/systemd/system/transtation.service <<-'EOF'
		[Unit]
		Description=transtation server
		After=network-online.target
		Wants=network-online.target

		[Service]
		Type=simple
		User=transtation
		Group=transtation
		Environment=TT_DATA=/var/lib/transtation
		Environment=PATH=/usr/local/lib/transtation:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
		EnvironmentFile=-/etc/transtation/server.env
		ExecStart=/usr/local/lib/transtation/server run
		Restart=on-failure
		RestartSec=3s
		# The container needs no capability because dockerd performs the
		# privileged bind. Here nothing is in front of us, so we keep exactly
		# one -- and nothing else is even reachable.
		AmbientCapabilities=CAP_NET_BIND_SERVICE
		CapabilityBoundingSet=CAP_NET_BIND_SERVICE
		NoNewPrivileges=true
		ProtectSystem=strict
		ProtectHome=true
		PrivateTmp=true
		PrivateDevices=true
		ProtectKernelTunables=true
		ProtectControlGroups=true
		RestrictSUIDSGID=true
		ReadWritePaths=/var/lib/transtation

		[Install]
		WantedBy=multi-user.target
	EOF
	systemctl daemon-reload
	printf '  %-14s' start
	systemctl enable --now transtation.service >/dev/null 2>&1 || true
	_i=0
	while [ "$_i" -lt 40 ]; do
		/usr/local/bin/transtation health >/dev/null 2>&1 && break
		_i=$((_i + 1)); printf '.'; sleep 3
	done
	systemctl is-active --quiet transtation || {
		say "FAILED"
		say "  journalctl -u transtation -n 40"
		exit 1
	}
	say "running"

	printf '  %-14s' verify
	/usr/local/bin/transtation verify || {
		say ""
		say "  The server is running but clients cannot complete the REALITY handshake."
		say "      echo 'SNI=dl.google.com' >> /etc/transtation/server.env"
		say "      systemctl restart transtation && transtation verify"
		exit 1
	}
	say ""
	/usr/local/bin/transtation status || true
	cat <<-EOF
		  DO THIS NOW -- it is the only irreplaceable thing on this box:
		      transtation backup

		  Your link:   transtation show
		  Add a user:  transtation user add alice
		  Logs:        journalctl -u transtation -f
		  Uninstall:   sh install.sh --uninstall

		  >> If a client cannot connect, open the port in your provider's firewall
		     or security group. The healthcheck only proves OUTBOUND traffic works.

	EOF
}

server_script() {
	_d=$(dirname -- "$0" 2>/dev/null || echo .)
	if [ -r "$_d/server/transtation" ]; then
		printf '%s' "$_d/server/transtation"
		return 0
	fi
	_f=$(mktemp)
	curl -fsSL "$RAW/server/transtation" -o "$_f" || die "could not fetch the server script from $RAW"
	printf '%s' "$_f"
}

# ------------------------------------------------------ server (container)

install_server() {
	need_root
	check_arch
	refuse_other_server container
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

	install_wrapper
	step wrapper "installed /usr/local/bin/transtation"

	printf '  %-14s' image
	docker pull -q "$(server_image)" >/dev/null 2>&1 || true
	# Resolve the tag to the digest it points at *now* and pin the compose file
	# to that. A tag is mutable; once this is written, `docker compose up` can
	# only ever start the exact image this install verified. Rewritten on every
	# run so re-running the installer is still how you upgrade.
	_ref=$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$(server_image)" 2>/dev/null)
	case "$_ref" in
		*@sha256:*)
			sed -i "s|^\( *image: \).*|\1$_ref|" "$DIR/docker-compose.yml"
			say "pinned to ${_ref#*@}"
			;;
		*)
			say "pulled $(server_image) (no digest available; the compose file pins by tag)"
			;;
	esac

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

# Run from a git checkout, or piped from the internet -- fetch what is missing.
client_script() {
	_d=$(dirname -- "$0" 2>/dev/null || echo .)
	if [ -r "$_d/client/transtation-client" ]; then
		printf '%s' "$_d/client/transtation-client"
		return 0
	fi
	_f=$(mktemp)
	curl -fsSL "$RAW/client/transtation-client" -o "$_f" ||
		die "could not fetch the client from $RAW"
	printf '%s' "$_f"
}

install_panic() {
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
		systemctl stop transtation-client 2>/dev/null
		echo "killswitch removed, policy routing flushed. You are back on direct egress."
	EOF
}

install_sing_box() {
	command -v sing-box >/dev/null 2>&1 && [ -z "${TT_FORCE_SINGBOX:-}" ] && {
		step sing-box "$(sing-box version | head -1)  (already installed)"
		SINGBOX=$(command -v sing-box)
		return 0
	}
	case "$(uname -m)" in
		x86_64 | amd64) _a=amd64; _sum=$SINGBOX_SHA_amd64 ;;
		aarch64 | arm64) _a=arm64; _sum=$SINGBOX_SHA_arm64 ;;
	esac
	_n="sing-box-${SINGBOX_VERSION}-linux-${_a}-musl"
	_t=$(mktemp -d)
	curl -fsSL -o "$_t/sb.tgz" \
		"https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${_n}.tar.gz" ||
		die "could not download sing-box ${SINGBOX_VERSION}"
	echo "$_sum  $_t/sb.tgz" | sha256sum -c - >/dev/null 2>&1 ||
		{ rm -rf "$_t"; die "sing-box checksum mismatch -- refusing to install it"; }
	tar xzf "$_t/sb.tgz" -C "$_t"
	install -Dm0755 "$_t/$_n/sing-box" "$PRIVLIB/sing-box"
	rm -rf "$_t"
	SINGBOX=$PRIVLIB/sing-box
	step sing-box "$($SINGBOX version | head -1)  (verified, statically linked)"
}

install_client() {
	need_root
	check_arch
	_mode=tun _ks=0 _uri=""
	for a in "$@"; do
		case "$a" in
			--tun) _mode=tun ;;
			--proxy) _mode=proxy ;;
			--killswitch) _ks=1 ;;
			vless://*) _uri=$a ;;
			*) die "unknown option: $a" ;;
		esac
	done

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

	install_sing_box
	install -Dm0755 "$(client_script)" /usr/local/bin/transtation-client
	install_panic
	step scripts "installed /usr/local/bin/transtation-client and /usr/local/sbin/transtation-panic"

	# Taken before the tunnel exists, so the self-test can tell "the tunnel is
	# carrying traffic" from "a request happened to succeed". Without this the
	# check passes while routing is still settling and the answer came out the
	# ordinary way -- observed, and reported as success.
	_before=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)

	[ -d /run/systemd/system ] || die "this needs systemd to manage the client.
    Without it, run it yourself:
      MODE=$_mode /usr/local/bin/transtation-client run"

	cat >/etc/systemd/system/transtation-client.service <<-EOF
		[Unit]
		Description=transtation client ($_mode)
		After=network-online.target
		Wants=network-online.target

		[Service]
		Type=simple
		Environment=MODE=$_mode
		Environment=TT_SINGBOX=$SINGBOX
		${DIRECT_SUFFIXES:+Environment=DIRECT_SUFFIXES=$DIRECT_SUFFIXES}
		ExecStart=/usr/local/bin/transtation-client run
		Restart=on-failure
		RestartSec=3s
		RuntimeDirectory=transtation
		RuntimeDirectoryMode=0700
		# Root is needed to own the routing table in tun mode; the bounding set
		# keeps that to what sing-box actually uses.
		CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_DAC_READ_SEARCH
		NoNewPrivileges=true
		ProtectHome=true
		ProtectSystem=strict
		ReadWritePaths=/run/transtation

		[Install]
		WantedBy=multi-user.target
	EOF
	systemctl daemon-reload
	systemctl enable --now transtation-client.service >/dev/null 2>&1 || true
	step service "transtation-client.service enabled ($_mode mode)"

	if [ "$_ks" = 1 ]; then
		[ "$_mode" = tun ] || die "--killswitch only makes sense with the whole-host tunnel"
		curl -fsSL "$RAW/host/transtation-killswitch" -o /usr/local/sbin/transtation-killswitch ||
			die "could not fetch the killswitch script from $RAW"
		chmod 0755 /usr/local/sbin/transtation-killswitch
		/usr/local/sbin/transtation-killswitch on
	fi

	printf '  %-14s' self-test
	_probe=""
	_n=0
	while [ "$_n" -lt 15 ]; do
		if [ "$_mode" = tun ]; then
			_trace=$(curl -fsS --max-time 8 https://cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
			_ip=$(printf '%s' "$_trace" | sed -n 's/^ip=//p')
			# The address has to have MOVED. A reply on its own only proves the
			# network works, which it did before any of this was installed.
			if [ -n "$_ip" ] && [ -n "$_before" ] && [ "$_ip" != "$_before" ]; then
				_probe=$(printf '%s' "$_trace" | grep -E '^(ip|warp|colo)=' | tr '\n' ' ')
			elif [ -n "$_ip" ] && [ -z "$_before" ]; then
				_probe="$(printf '%s' "$_trace" | grep -E '^(ip|warp|colo)=' | tr '\n' ' ')(could not compare: no address before install)"
			fi
		else
			_probe=$(curl -fsS --max-time 8 --socks5-hostname 127.0.0.1:1080 https://cloudflare.com/cdn-cgi/trace 2>/dev/null |
				grep -E '^(ip|warp|colo)=' | tr '\n' ' ')
		fi
		[ -n "$_probe" ] && break
		_n=$((_n + 1))
		sleep 2
	done
	if [ -n "$_probe" ]; then
		[ "$_mode" = tun ] && say "$_probe" || say "through the proxy: $_probe"
	else
		[ "$_mode" = tun ] && say "STILL YOUR OWN ADDRESS (${_before:-unknown})" || say "NO TRAFFIC"
		say ""
		say "  The client is running but traffic is not going through the tunnel. Look at:"
		say "      journalctl -u transtation-client -n 40"
		[ "$_mode" = tun ] && say "      sudo transtation-panic     # undo the tunnel and killswitch"
		exit 1
	fi

	if [ "$_mode" = tun ]; then
		cat <<-'EOF'

			  Every program on this machine now goes through the tunnel, with no
			  per-program configuration.

			  stop:    sudo systemctl stop transtation-client
			  logs:    journalctl -u transtation-client -f
			  panic:   sudo transtation-panic        # undo everything, needs no network

		EOF
	else
		cat <<-'EOF'

			  THIS DOES NOT PUT YOUR MACHINE BEHIND THE PROXY. It opens a proxy on
			  127.0.0.1:1080 and nothing else; each program has to be pointed at it.
			  Re-run with --tun for the whole machine.

			  export ALL_PROXY=socks5h://127.0.0.1:1080 HTTPS_PROXY=http://127.0.0.1:1080 HTTP_PROXY=http://127.0.0.1:1080
			    Those apply to that shell and what it starts, and nothing else.

		EOF
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
	if [ -e /etc/systemd/system/transtation.service ]; then
		systemctl disable --now transtation.service >/dev/null 2>&1 || true
		rm -f /etc/systemd/system/transtation.service
		systemctl daemon-reload 2>/dev/null || true
		rm -rf /usr/local/bin/transtation "$PRIVLIB"
		say "native server removed. Its data is still in /var/lib/transtation."
		ask 'also delete /var/lib/transtation? That destroys your Reality key and every issued link. [y/N] '
		say ""
		case "$REPLY" in
			y | Y) rm -rf /var/lib/transtation; say "data deleted." ;;
			*) say "data kept in /var/lib/transtation" ;;
		esac
	fi
	if [ -e /etc/systemd/system/transtation-client.service ]; then
		systemctl disable --now transtation-client.service >/dev/null 2>&1 || true
		rm -f /etc/systemd/system/transtation-client.service
		systemctl daemon-reload 2>/dev/null || true
		rm -f /usr/local/bin/transtation-client
		rm -f "$PRIVLIB/sing-box"
		rmdir "$PRIVLIB" 2>/dev/null || true
		say "client removed."
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
		server)
			case "${1:-}" in
				--native) install_server_native ;;
				'') install_server ;;
				*) die "unknown option: $1 (expected --native)" ;;
			esac
			;;
		--native) install_server_native ;;
		client) install_client "$@" ;;
		--uninstall | uninstall) uninstall ;;
		-h | --help)
			sed -n '2,10p' "$0" 2>/dev/null || say "see https://github.com/sqzer-x/transtation"
			;;
		*) die "unknown command: $_cmd (expected: server, client, --uninstall)" ;;
	esac
}

main "$@"
