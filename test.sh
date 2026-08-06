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
echo "== the installer must never hand capabilities to the server =="
# Adding NET_ADMIN makes Xray attempt kernel TUN, which writes to /proc/sys
# before opening the device, hits Docker's read-only /proc/sys, and fails with
# no fallback to userspace. This is the single easiest way to break a working
# install, so it gets a test rather than only a comment.
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
docker build -q -f server/Dockerfile -t "$SERVER_IMG" . >/dev/null && ok "server image builds"
docker build -q -f client/Dockerfile -t "$CLIENT_IMG" . >/dev/null && ok "client image builds"

echo
echo "== server selftest (offline) =="
docker run --rm --network none "$SERVER_IMG" selftest || fail=1

echo
echo "== server image holds no capabilities and runs as a non-root user =="
check "server image default user is not root" \
	sh -c "test \"\$(docker run --rm --network none --entrypoint id $SERVER_IMG -u)\" != 0"
check "server image ships no geodata (it would be dead weight)" \
	sh -c "! docker run --rm --network none --entrypoint ls $SERVER_IMG /usr/local/share/xray 2>/dev/null | grep -q dat"

echo
echo "== client config renders and sing-box accepts it =="
docker run --rm --network none \
	-e TT_URI="$FIXTURE_URI" \
	-e DIRECT_SUFFIXES=naver.com,go.kr \
	"$CLIENT_IMG" check || fail=1

echo
echo "== client rejects malformed links at the trust boundary =="
rejects() { ! docker run --rm --network none -e TT_URI="$1" "$CLIENT_IMG" check >/dev/null 2>&1; }
check "rejects a non-vless scheme" rejects 'https://example.com'
check "rejects a bad uuid" rejects 'vless://not-a-uuid@203.0.113.10:443?pbk=6ZP9LtQm3vXk8sT2wYnBcRfJhGdA1uEoI0pZxCyN4Vs&sid=1c69b566b0480c74&sni=a.com'
check "rejects a short pbk" rejects 'vless://8f3e21c4-7a09-4b2e-9d51-6c0f1a2b3c4d@203.0.113.10:443?pbk=tooshort&sid=1c69b566b0480c74&sni=a.com'
check "rejects an odd-length sid" rejects 'vless://8f3e21c4-7a09-4b2e-9d51-6c0f1a2b3c4d@203.0.113.10:443?pbk=6ZP9LtQm3vXk8sT2wYnBcRfJhGdA1uEoI0pZxCyN4Vs&sid=abc&sni=a.com'
check "rejects a bad port" rejects 'vless://8f3e21c4-7a09-4b2e-9d51-6c0f1a2b3c4d@203.0.113.10:99999?pbk=6ZP9LtQm3vXk8sT2wYnBcRfJhGdA1uEoI0pZxCyN4Vs&sid=1c69b566b0480c74&sni=a.com'

echo
[ "$fail" = 0 ] || { echo "FAILED"; exit 1; }
echo "all tests passed"
echo
