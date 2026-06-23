#!/usr/bin/env bash
#
# Bootstrap a macOS dev environment for grapheion from a fresh clone.
#
# grapheion path-depends on its sibling `peat-flutter`, which links a native
# Rust library (`peat-ffi`) built from the sibling `peat` workspace. So a bare
# `git clone grapheion` will NOT build on its own. This script:
#   1. checks/installs prerequisites (Rust, protoc, CocoaPods),
#   2. clones `peat` + `peat-flutter` as siblings (on the right branches),
#   3. builds the peat-ffi dylib + the peat-btle (BLE) xcframework,
#   4. runs `flutter pub get`.
# After it finishes:  flutter run -d macos
#
# Run it from inside the grapheion repo:
#   ./scripts/bootstrap-macos.sh
#
set -euo pipefail

# --- repo coordinates -------------------------------------------------------
PEAT_FLUTTER_URL="https://github.com/defenseunicorns/peat-flutter.git"
PEAT_FLUTTER_BRANCH="feat/reconnect-supervisor-wiring"
PEAT_URL="https://github.com/defenseunicorns/peat.git"
PEAT_BRANCH="feat/roster-store"

# --- locate the repos -------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPHEION_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="$(cd "${GRAPHEION_DIR}/.." && pwd)" # parent that will hold all three repos
PEAT_FLUTTER_DIR="${ROOT}/peat-flutter"
PEAT_DIR="${ROOT}/peat"

say() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }
die() { printf "\n\033[1;31mERROR: %s\033[0m\n" "$*" >&2; exit 1; }

# --- prerequisites ----------------------------------------------------------
say "Checking prerequisites"
command -v git >/dev/null || die "git not found."
command -v flutter >/dev/null ||
  die "Flutter not found. Install the stable channel: https://docs.flutter.dev/get-started/install/macos"
xcode-select -p >/dev/null 2>&1 ||
  die "Xcode command-line tools missing. Run: xcode-select --install  (and install Xcode from the App Store)."
flutter config --enable-macos-desktop >/dev/null 2>&1 || true

HAS_BREW=0
command -v brew >/dev/null && HAS_BREW=1

# protoc — required by peat-ffi's build
if ! command -v protoc >/dev/null; then
  if [ "${HAS_BREW}" = 1 ]; then say "Installing protobuf (protoc)"; brew install protobuf
  else die "protoc not found. Install Homebrew (https://brew.sh) then: brew install protobuf"; fi
fi

# CocoaPods — Flutter runs `pod install` for the macOS plugins
if ! command -v pod >/dev/null; then
  if [ "${HAS_BREW}" = 1 ]; then say "Installing CocoaPods"; brew install cocoapods
  else die "CocoaPods not found. Install: brew install cocoapods  (or: sudo gem install cocoapods)"; fi
fi

# Rust + the macOS targets
if ! command -v cargo >/dev/null; then
  say "Installing Rust (rustup)"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  # shellcheck disable=SC1091
  source "${HOME}/.cargo/env"
fi
say "Adding Rust macOS targets"
rustup target add aarch64-apple-darwin x86_64-apple-darwin

# --- clone the sibling repos ------------------------------------------------
clone_or_update() {
  local dir="$1" url="$2" branch="$3"
  if [ -d "${dir}/.git" ]; then
    say "Updating $(basename "${dir}") → ${branch}"
    git -C "${dir}" fetch --quiet origin "${branch}"
    git -C "${dir}" checkout --quiet "${branch}"
  else
    say "Cloning $(basename "${dir}") → ${branch}"
    git clone --branch "${branch}" "${url}" "${dir}" ||
      die "Failed to clone ${url} (${branch}). These are private repos — make sure your GitHub access + SSH/HTTPS auth is set up."
  fi
}
clone_or_update "${PEAT_DIR}" "${PEAT_URL}" "${PEAT_BRANCH}"
clone_or_update "${PEAT_FLUTTER_DIR}" "${PEAT_FLUTTER_URL}" "${PEAT_FLUTTER_BRANCH}"

# --- build the native libraries ---------------------------------------------
# Order matters: build-rust.sh's cargo build populates the registry cache that
# build-btle.sh needs for the peat-btle crate.
say "Building peat-ffi (universal macOS dylib)"
PEAT_WORKSPACE_DIR="${PEAT_DIR}" bash "${PEAT_FLUTTER_DIR}/macos/build-rust.sh"

say "Building peat-btle (macOS BLE xcframework)"
PEAT_WORKSPACE_DIR="${PEAT_DIR}" bash "${GRAPHEION_DIR}/macos/build-btle.sh"

# --- flutter deps -----------------------------------------------------------
say "flutter pub get"
(cd "${GRAPHEION_DIR}" && flutter pub get)

say "Done. Launch the app with:"
printf "    cd %s && flutter run -d macos\n\n" "${GRAPHEION_DIR}"
