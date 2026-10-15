#!/usr/bin/env bash
# Put wasi-sdk where scripts/build-cosigner-wasm.sh finds it: the C toolchain for secp256k1-sys,
# the one C library the cosigner compiles to wasm32-wasip2.
#
# Idempotent: with the SDK already unpacked this exits at once. Pinned by version and by the sha256
# of the tarball, since wasi-sdk publishes no checksums of its own. Recompute with:
#   sha256sum wasi-sdk-25.0-x86_64-linux.tar.gz
set -euo pipefail

WASI_SDK_VERSION="${WASI_SDK_VERSION:-25}"
WASI_SDK_RELEASE="${WASI_SDK_RELEASE:-25.0}"
WASI_SDK="${WASI_SDK:-$HOME/wasi-sdk}"
WASI_SDK_SHA256="${WASI_SDK_SHA256:-52640dde13599bf127a95499e61d6d640256119456d1af8897ab6725bcf3d89c}"

if [[ -x "$WASI_SDK/bin/clang" ]]; then
    echo "wasi-sdk already at $WASI_SDK"
    exit 0
fi

tarball="$(mktemp -d)/wasi-sdk.tar.gz"
url="https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_SDK_VERSION}/wasi-sdk-${WASI_SDK_RELEASE}-x86_64-linux.tar.gz"
curl -fsSL --retry 3 --retry-all-errors --max-time 600 -o "$tarball" "$url"
echo "$WASI_SDK_SHA256  $tarball" | sha256sum -c -

mkdir -p "$WASI_SDK"
tar xf "$tarball" -C "$WASI_SDK" --strip-components=1
rm -rf "$(dirname "$tarball")"
[[ -x "$WASI_SDK/bin/clang" ]] || { echo "unpacked wasi-sdk has no bin/clang at $WASI_SDK" >&2; exit 1; }
echo "wasi-sdk $WASI_SDK_RELEASE installed at $WASI_SDK"
