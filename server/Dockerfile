# syntax=docker/dockerfile:1
#
# transtation server -- Xray-core with a VLESS/REALITY inbound and an optional
# Cloudflare WARP outbound.
#
# The image holds NO capabilities and needs NO devices. Xray's WireGuard
# outbound probes for CAP_NET_ADMIN up front and takes its in-process gVisor
# network stack when it is absent -- which is exactly Docker's default. Adding
# --cap-add NET_ADMIN makes it try kernel TUN instead, which writes to
# /proc/sys before opening the device, hits Docker's read-only /proc/sys, and
# fails with no fallback. Do not add capabilities to this image.

FROM --platform=$BUILDPLATFORM alpine:3.23 AS fetch
ARG TARGETARCH
# Latest stable Xray. XTLS marks nearly every other release "prerelease".
ARG XRAY_VERSION=v26.3.27
ARG WGCF_VERSION=2.2.32
RUN apk add --no-cache curl unzip && set -eu; \
    case "$TARGETARCH" in \
      amd64) XZ=Xray-linux-64.zip;        WA=amd64 ;; \
      arm64) XZ=Xray-linux-arm64-v8a.zip; WA=arm64 ;; \
      *) echo "transtation: unsupported TARGETARCH=$TARGETARCH (amd64 and arm64 only)" >&2; exit 1 ;; \
    esac; \
    B=https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}; \
    curl -fsSLO "$B/$XZ"; \
    curl -fsSLO "$B/$XZ.dgst"; \
    EXP=$(awk '/^SHA2-256/ {print $2}' "$XZ.dgst"); \
    # Without this guard a changed .dgst format yields an empty expectation and
    # `sha256sum -c` happily verifies nothing. The label is "SHA2-256= <hex>"
    # (openssl style), not "SHA256".
    printf '%s' "$EXP" | grep -Eq '^[0-9a-f]{64}$' || { echo "no usable SHA2-256 line in $XZ.dgst" >&2; exit 1; }; \
    echo "$EXP  $XZ" | sha256sum -c -; \
    unzip -j "$XZ" xray -d /out; \
    W=https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}; \
    curl -fsSL -o /out/wgcf "$W/wgcf_${WGCF_VERSION}_linux_${WA}"; \
    curl -fsSL "$W/checksums.txt" | grep " wgcf_${WGCF_VERSION}_linux_${WA}\$" \
      | awk '{print $1"  /out/wgcf"}' | sha256sum -c -; \
    chmod 0755 /out/xray /out/wgcf

FROM alpine:3.23
RUN apk add --no-cache ca-certificates curl jq libqrencode-tools \
 && adduser -D -u 10001 xray \
 && mkdir -p /data \
 && chown xray:xray /data \
 && chmod 0700 /data
# /data is created and owned here so that a fresh NAMED VOLUME inherits this
# ownership on first mount. A bind mount does not -- see the error message in
# `transtation run` if you use one.

COPY --from=fetch /out/xray /out/wgcf /usr/local/bin/
COPY server/transtation /usr/local/bin/transtation
COPY NOTICE /NOTICE

# No geoip.dat / geosite.dat on purpose: 29 MiB for one rule that an explicit
# CIDR list replaces. Any "geoip:" or "geosite:" routing rule will fail at
# startup with file-not-found.

ENV TT_MANAGED=docker
USER xray
VOLUME /data
EXPOSE 8443
HEALTHCHECK --interval=5m --timeout=15s --retries=3 --start-period=45s \
  CMD ["/usr/local/bin/transtation", "health"]
ENTRYPOINT ["/usr/local/bin/transtation"]
CMD ["run"]
