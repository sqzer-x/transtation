#!/bin/sh
# transtation test suite. Builds both images and runs their offline self-checks.
#
#   sh test.sh
#
# Needs Docker. Everything it runs is offline (--network none), so it is safe on
# a laptop and it never registers a WARP identity -- hammering Cloudflare's
# registration endpoint from CI is how a source IP gets blocked.
set -eu
cd "$(dirname "$0")"

SERVER_IMG=${SERVER_IMG:-transtation-test-server}
CLIENT_IMG=${CLIENT_IMG:-transtation-test-client}
FIXTURE_URI='vless://8f3e21c4-7a09-4b2e-9d51-6c0f1a2b3c4d@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=6ZP9LtQm3vXk8sT2wYnBcRfJhGdA1uEoI0pZxCyN4Vs&sid=1c69b566b0480c74&spx=%2F&type=tcp&headerType=none#transtation-test'

fail=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }
check() { _d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$_d"; else bad "$_d"; fi; }

echo
echo "== shell syntax =="
for f in install.sh test.sh server/transtation client/transtation-client \
	host/transtation-killswitch host/transtation-panic; do
	check "sh -n $f" sh -n "$f"
done
if command -v shellcheck >/dev/null 2>&1; then
	for f in install.sh server/transtation client/transtation-client \
		host/transtation-killswitch host/transtation-panic; do
		check "shellcheck $f" shellcheck -s sh -S warning "$f"
	done
else
	echo "  skip  shellcheck (not installed)"
fi

echo
echo "== the installer must ask for no capabilities and no devices =="
# Least privilege: the server needs no capabilities and no devices, so the
# installer must never quietly grant any. (The generated config also pins
# "noKernelTun": true, which makes WARP independent of capabilities -- but the
# compose file should still ask for nothing.)
# Scoped to the compose block the installer actually writes, with comments
# stripped -- an earlier version of this test matched its own warning comment
# and "failed" on a correct file.
server_compose() {
	awk '/docker-compose\.yml" <<-EOF/ { f = 1; next } f && /^[\t ]*EOF$/ { f = 0 } f' install.sh |
		sed 's/[[:space:]]*#.*//'
}
absent_in_compose() { ! server_compose | grep -qE "$1"; }
uncommented_absent() { ! sed 's/[[:space:]]*#.*//' "$2" | grep -qE "$1"; }

check "the compose block sets no cap_add" absent_in_compose 'cap_add'
check "the compose block mounts no devices" absent_in_compose 'devices:'
check "the compose block does not use network_mode: host" absent_in_compose 'network_mode'
present_in_compose() { server_compose | grep -qE "$1"; }
check "the compose block caps the log size (xray logs to stdout)" present_in_compose 'max-size'
check "the compose block uses a named volume, not a bind mount" present_in_compose 'transtation-data:/data'
check "no script ever runs 'nft flush ruleset'" uncommented_absent 'flush ruleset' host/transtation-killswitch
# Hardening the compose file grants. The running process was verified to hold
# CapEff 0000000000000000 with these in place.
check "the compose block drops all capabilities" present_in_compose "cap_drop"
check "the compose block sets no-new-privileges" present_in_compose "no-new-privileges"
check "the compose block mounts the root filesystem read-only" present_in_compose "read_only"


if ! command -v docker >/dev/null 2>&1; then
	echo
	echo "  skip  image builds and runtime checks (docker not installed)"
	echo
	[ "$fail" = 0 ] || { echo "FAILED"; exit 1; }
	echo "static checks passed"
	exit 0
fi

echo
echo "== build =="
# buildx, not the legacy builder: the Dockerfiles use --platform=$BUILDPLATFORM
# on the fetch stage so that cross-arch CI builds do not run curl and unzip
# under QEMU, and the legacy builder cannot parse it.
docker buildx version >/dev/null 2>&1 || {
	echo "  FAIL  docker buildx is required (Arch: pacman -S docker-buildx)"
	exit 1
}
# A failed build must be fatal. Everything below runs `docker run`, and a
# missing image makes those commands fail in exactly the way a *passing*
# negative test looks like -- which is how an earlier version of this file
# reported all green against images that did not exist.
docker buildx build --load -f server/Dockerfile -t "$SERVER_IMG" . >/dev/null 2>&1 ||
	{ bad "server image builds"; exit 1; }
ok "server image builds"
docker buildx build --load -f client/Dockerfile -t "$CLIENT_IMG" . >/dev/null 2>&1 ||
	{ bad "client image builds"; exit 1; }
ok "client image builds"
docker image inspect "$SERVER_IMG" >/dev/null 2>&1 || { bad "server image exists"; exit 1; }
docker image inspect "$CLIENT_IMG" >/dev/null 2>&1 || { bad "client image exists"; exit 1; }

echo
echo "== server selftest (offline) =="
docker run --rm --network none "$SERVER_IMG" selftest || fail=1

echo
echo "== server image runs unprivileged and carries no dead weight =="
image_user_nonroot() {
	_u=$(docker run --rm --network none --entrypoint id "$SERVER_IMG" -u) || return 1
	[ -n "$_u" ] && [ "$_u" != 0 ]
}
no_geodata() {
	_l=$(docker run --rm --network none --entrypoint ls "$SERVER_IMG" -1 /usr/local/share/xray 2>&1) || return 0
	case "$_l" in *.dat*) return 1 ;; *) return 0 ;; esac
}
check "server image default user is not root" image_user_nonroot
check "server image ships no geoip/geosite data" no_geodata

echo
echo "== the installer runs under a real POSIX /bin/sh, not just bash =="
# `shift` with no positional parameters is a special-builtin error and a POSIX
# shell EXITS on it, `|| true` notwithstanding. dash is /bin/sh on Debian and
# Ubuntu, so `sh install.sh` with no arguments died there silently while every
# bash-based test passed. Run the real thing, as a non-root user, in both
# shells, and require the root message rather than merely a non-zero exit.
posix_sh_ok() {
	_o=$(docker run --rm -v "$PWD":/w:ro -u 65534 "$1" sh -c "cd /w && $2 install.sh" 2>&1) || true
	case "$_o" in *"needs root"*) return 0 ;; *) return 1 ;; esac
}
check "install.sh survives dash (Debian, Ubuntu) with no arguments" posix_sh_ok debian:stable-slim dash
check "install.sh survives busybox ash (Alpine) with no arguments" posix_sh_ok alpine:3.23 sh

echo
echo "== client config renders and sing-box accepts it =="
docker run --rm --network none \
	-e TT_URI="$FIXTURE_URI" \
	-e DIRECT_SUFFIXES=naver.com,go.kr \
	"$CLIENT_IMG" check || fail=1

echo
echo "== client rejects malformed links at the trust boundary =="
# Not just "the command failed" -- it must have failed with OUR validation
# error. Otherwise a broken image passes every one of these.
rejects() {
	_out=$(docker run --rm --network none -e TT_URI="$1" "$CLIENT_IMG" check 2>&1) && return 1
	case "$_out" in *transtation-client:*) return 0 ;; *) return 1 ;; esac
}
check "rejects a non-vless scheme" rejects 'https://example.com'
check "rejects a bad uuid" rejects 'vless://not-a-uuid@203.0.113.10:443?pbk=6ZP9LtQm3vXk8sT2wYnBcRfJhGdA1uEoI0pZxCyN4Vs&sid=1c69b566b0480c74&sni=a.com'
check "rejects a short pbk" rejects 'vless://8f3e21c4-7a09-4b2e-9d51-6c0f1a2b3c4d@203.0.113.10:443?pbk=tooshort&sid=1c69b566b0480c74&sni=a.com'
check "rejects an odd-length sid" rejects 'vless://8f3e21c4-7a09-4b2e-9d51-6c0f1a2b3c4d@203.0.113.10:443?pbk=6ZP9LtQm3vXk8sT2wYnBcRfJhGdA1uEoI0pZxCyN4Vs&sid=abc&sni=a.com'
# A share link is something somebody hands you -- in a chat, on a forum, as a
# QR code. Both of these once rendered a config that sing-box ACCEPTED, which
# is how a "friendly" link becomes someone else's server with certificate
# checking turned off.
check "rejects JSON injection through flow=" rejects 'vless://8f3e21c4-7a09-4b2e-9d51-6c0f1a2b3c4d@203.0.113.10:443?pbk=6ZP9LtQm3vXk8sT2wYnBcRfJhGdA1uEoI0pZxCyN4Vs&sid=1c69b566b0480c74&sni=a.com&flow=xtls-rprx-vision","server":"6.6.6.6","x":"'
check "rejects JSON injection through fp=" rejects 'vless://8f3e21c4-7a09-4b2e-9d51-6c0f1a2b3c4d@203.0.113.10:443?pbk=6ZP9LtQm3vXk8sT2wYnBcRfJhGdA1uEoI0pZxCyN4Vs&sid=1c69b566b0480c74&sni=a.com&fp=chrome"},"insecure":true,"utls":{"enabled":true,"fingerprint":"chrome'
check "rejects an unknown uTLS fingerprint" rejects 'vless://8f3e21c4-7a09-4b2e-9d51-6c0f1a2b3c4d@203.0.113.10:443?pbk=6ZP9LtQm3vXk8sT2wYnBcRfJhGdA1uEoI0pZxCyN4Vs&sid=1c69b566b0480c74&sni=a.com&fp=nonesuch'

echo
echo "== client rejects hostile operator environment =="
env_rejects() {
	_out=$(docker run --rm --network none -e TT_URI="$FIXTURE_URI" "$@" "$CLIENT_IMG" check 2>&1) && return 1
	case "$_out" in *transtation-client:*) return 0 ;; *) return 1 ;; esac
}
check "rejects a non-numeric SOCKS_PORT" env_rejects -e 'SOCKS_PORT=1080, "sniff": true'
check "rejects DIRECT_SUFFIXES that is not a domain list" env_rejects -e 'DIRECT_SUFFIXES=a.com"],"outbound":"direct"},{"x":"'

check "rejects a bad port" rejects 'vless://8f3e21c4-7a09-4b2e-9d51-6c0f1a2b3c4d@203.0.113.10:99999?pbk=6ZP9LtQm3vXk8sT2wYnBcRfJhGdA1uEoI0pZxCyN4Vs&sid=1c69b566b0480c74&sni=a.com'

echo
[ "$fail" = 0 ] || { echo "FAILED"; exit 1; }
echo "all tests passed"
echo
