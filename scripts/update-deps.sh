#!/usr/bin/env bash
# Keep grapheion's peat dependencies current — PUBLISHED-CRATE build model
# (graduated 2026-06-30; replaced the old local-source build).
#
# grapheion path-depends on the sibling ../peat-flutter. On `main`, peat-flutter
# builds peat-ffi from the published crates.io `peat-ffi` crate via its `rust/`
# wrapper (rust/Cargo.toml pins the exact version). So "stay current" =
# fast-forward both siblings to upstream main + rebuild the plugin's native FFI
# libs (the macOS .dylib / iOS .xcframework / Android jniLibs that link into the
# app). The vendored BLE frameworks in grapheion's ios/+macos/ (PeatAppleFFI /
# PeatBtle) are a SEPARATE symbol namespace and stay as-is.
#
# Run before a build session (or weekly), then RUN-verify on a device after.
set -euo pipefail

GRAPHEION="$(cd "$(dirname "$0")/.." && pwd)"
PEAT="$GRAPHEION/../peat"                  # source reference + where upstream PRs branch
PEAT_FLUTTER="$GRAPHEION/../peat-flutter"  # the published-crate plugin we build against

ff() { # <dir> <label>
  local d="$1" label="$2"
  if [ ! -d "$d/.git" ]; then echo "   ⚠ $label not found ($d)"; return; fi
  git -C "$d" fetch origin --quiet
  [ "$(git -C "$d" branch --show-current)" = "main" ] || git -C "$d" checkout main --quiet
  if git -C "$d" merge --ff-only origin/main >/dev/null 2>&1; then
    echo "   ✓ $label $(git -C "$d" rev-parse --short HEAD)"
  else
    echo "   ⚠ $label couldn't fast-forward (local commits / dirty tree):"
    git -C "$d" status -sb | head -3
  fi
}

echo "==> peat-flutter (the published-crate plugin grapheion builds against)"
ff "$PEAT_FLUTTER" "peat-flutter"
echo "==> peat (source reference + where upstream PRs branch from)"
ff "$PEAT" "peat"

echo "==> rebuild the plugin's native FFI libs from the rust/ wrapper (macOS + iOS)"
echo "    (Android jniLibs rebuild automatically during the app's gradle build)"
if ( cd "$PEAT_FLUTTER" && bash macos/build-rust.sh && bash ios/build-rust.sh ); then
  echo "   ✓ libpeat_ffi.dylib + PeatFFI.xcframework rebuilt"
else
  echo "   ⚠ native build failed — review above"; exit 1
fi

echo "==> grapheion: flutter pub get + analyze (smoke check)"
if ( cd "$GRAPHEION" && flutter pub get && flutter analyze lib/ ); then
  echo "✓ deps current + analyzes clean."
  echo "  Rebuild (flutter clean first), then RUN-verify the node comes up"
  echo "  (look for 'create_node' in the launch log) on a device before trusting."
else
  echo "⚠ analyze found issues — a dep update may have shifted an API. Review above."
  exit 1
fi
