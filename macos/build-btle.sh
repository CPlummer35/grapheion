#!/usr/bin/env bash
# Build the peat-btle CoreBluetooth FFI for macOS and package it as
# Frameworks/PeatBtle.xcframework + Runner/peat_btle.swift, mirroring how the
# iOS example ships PeatAppleFFI.xcframework. macOS has no prebuilt peat-btle
# Apple lib, so we build it from the published `peat-btle` crate.
#
# Why this exists: the macOS app's CoreBluetooth bridge (Runner/BleBridge.swift)
# calls the peat-btle mesh via the generated `PeatMesh` UniFFI bindings. Those
# need a macOS-native libpeat_btle + Swift bindings, which this produces.
#
# Requires: Rust macOS targets, the peat workspace (for uniffi-bindgen 0.31).
#   rustup target add aarch64-apple-darwin x86_64-apple-darwin
#
# Usage (from example/macos):
#   PEAT_WORKSPACE_DIR=/path/to/peat ./build-btle.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# peat workspace (has peat-ffi's uniffi-bindgen 0.31 binary, version-matched).
PEAT_DIR="${PEAT_WORKSPACE_DIR:-"${SCRIPT_DIR}/../../../peat"}"
# Pinned to the peat-btle version the peat workspace resolves. Bump together.
BTLE_VERSION="${PEAT_BTLE_VERSION:-0.4.0}"
# macos needs the same uniffi extras the `android` feature bundles, or a
# uniffi-exported method (publish_peat_lite_document) fails to compile.
FEATURES="macos,uniffi,peat-lite-frame,translator-codec"

BUILD="${TMPDIR:-/tmp}/peat-btle-macos-build"
FRAMEWORKS_DIR="${SCRIPT_DIR}/Frameworks"
RUNNER_DIR="${SCRIPT_DIR}/Runner"

# Locate the published crate source in the cargo registry cache.
SRC="$(find "${HOME}/.cargo/registry/src" -maxdepth 2 -type d -name "peat-btle-${BTLE_VERSION}" 2>/dev/null | head -1)"
if [ -z "${SRC}" ]; then
  echo "error: peat-btle-${BTLE_VERSION} not in the cargo registry cache." >&2
  echo "       Run a cargo build in ${PEAT_DIR} first to fetch it." >&2
  exit 1
fi

echo "==> Staging peat-btle ${BTLE_VERSION} from ${SRC}"
rm -rf "${BUILD}"; mkdir -p "${BUILD}"; cp -R "${SRC}/." "${BUILD}/"; chmod -R u+w "${BUILD}"

for TRIPLE in aarch64-apple-darwin x86_64-apple-darwin; do
  echo "==> Building peat-btle for ${TRIPLE}"
  ( cd "${BUILD}" && cargo build --release --features "${FEATURES}" --target "${TRIPLE}" )
  install_name_tool -id @rpath/libpeat_btle.dylib \
    "${BUILD}/target/${TRIPLE}/release/libpeat_btle.dylib"
done

echo "==> lipo universal dylib"
UNI="${BUILD}/libpeat_btle.dylib"
lipo -create \
  "${BUILD}/target/aarch64-apple-darwin/release/libpeat_btle.dylib" \
  "${BUILD}/target/x86_64-apple-darwin/release/libpeat_btle.dylib" \
  -output "${UNI}"

echo "==> Generating Swift bindings (uniffi 0.31, library mode)"
SWIFT_OUT="${BUILD}/swift-bindings"; rm -rf "${SWIFT_OUT}"
( cd "${PEAT_DIR}" && cargo run --release -p peat-ffi --bin uniffi-bindgen -- \
    generate --library "${UNI}" --language swift --out-dir "${SWIFT_OUT}" )

echo "==> Assembling headers (modulemap convention)"
HDR="${BUILD}/headers"; rm -rf "${HDR}"; mkdir -p "${HDR}"
cp "${SWIFT_OUT}/peat_btleFFI.h" "${HDR}/"
cp "${SWIFT_OUT}/peat_btleFFI.modulemap" "${HDR}/module.modulemap"

echo "==> Creating PeatBtle.xcframework"
rm -rf "${FRAMEWORKS_DIR}/PeatBtle.xcframework"
mkdir -p "${FRAMEWORKS_DIR}"
xcodebuild -create-xcframework -library "${UNI}" -headers "${HDR}" \
  -output "${FRAMEWORKS_DIR}/PeatBtle.xcframework"

echo "==> Installing peat_btle.swift into Runner"
cp "${SWIFT_OUT}/peat_btle.swift" "${RUNNER_DIR}/peat_btle.swift"

echo "==> Done: ${FRAMEWORKS_DIR}/PeatBtle.xcframework + ${RUNNER_DIR}/peat_btle.swift"
