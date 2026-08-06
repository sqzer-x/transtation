# syntax=docker/dockerfile:1
#
# transtation client -- sing-box with a VLESS/REALITY outbound.
#
#   MODE=proxy (default)  local SOCKS5 + HTTP on :1080. No capabilities, no
#                         devices, no host network. Works under rootless Docker
#                         and Podman.
#   MODE=tun              transparent whole-host tunnel. Needs --network host,
#                         --cap-add NET_ADMIN and --device /dev/net/tun, and
#                         only works on Linux with rootful Docker.
#
# sing-box publishes no checksum file, so the hashes below were computed once
# from the official release artifacts and are reviewed as part of this repo.
# Bump them together with SINGBOX_VERSION.

FROM --platform=$BUILDPLATFORM alpine:3.23 AS fetch
ARG TARGETARCH
ARG SINGBOX_VERSION=1.13.16
ARG SHA256_AMD64=9ff0345fde4157a6bdab45a615668d41ccc93f6d0f361108042a48b8a49a9baa
ARG SHA256_ARM64=3ea951c68f2eea10fd3ee8f8cc7794c12ccc7405afa99279a79e0b41cb183adf
RUN apk add --no-cache curl && set -eu; \
    case "$TARGETARCH" in \
      amd64) SUM=$SHA256_AMD64 ;; \
      arm64) SUM=$SHA256_ARM64 ;; \
      *) echo "transtation: unsupported TARGETARCH=$TARGETARCH (amd64 and arm64 only)" >&2; exit 1 ;; \
    esac; \
    # The -musl build is statically linked and ships no libcronet.so; the plain
    # linux-<arch> build is dynamically linked against glibc and will not run
    # on Alpine.
    N=sing-box-${SINGBOX_VERSION}-linux-${TARGETARCH}-musl; \
    curl -fsSLO "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${N}.tar.gz"; \
    echo "$SUM  ${N}.tar.gz" | sha256sum -c -; \
    tar xzf "${N}.tar.gz"; \
    install -D -m 0755 "${N}/sing-box" /out/sing-box

FROM alpine:3.23
# nftables + iproute2 are here only for the `panic` verb, so that the recovery
# path works from an image the user has already pulled, with no network.
RUN apk add --no-cache ca-certificates curl musl-utils nftables iproute2
COPY --from=fetch /out/sing-box /usr/local/bin/sing-box
COPY client/transtation-client /usr/local/bin/transtation-client
COPY NOTICE /NOTICE

ENV MODE=proxy
EXPOSE 1080
ENTRYPOINT ["/usr/local/bin/transtation-client"]
CMD ["run"]
