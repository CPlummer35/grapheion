#!/usr/bin/env bash
# Keep grapheion's peat dependencies current — LOCAL-SOURCE build model.
# Run before a build session (or weekly).
#
# How grapheion builds (as of 2026-06-24): it compiles `peat-ffi` DIRECTLY from
# your ../peat checkout, via peat-flutter's `feat/reconnect-supervisor-wiring`
# branch build scripts. So "stay current" = fast-forward ../peat to upstream
# main. peat-flutter intentionally STAYS on its build branch — upstream
# peat-flutter `main` switched to a published-crate `rust/` wrapper that does
# NOT yet run on iOS for grapheion (the app crashes on launch), so we do not
# track it here. Revisit graduating to the published crate once that iOS wrapper
# issue is diagnosed + fixed.
set -euo pipefail

GRAPHEION="$(cd "$(dirname "$0")/.." && pwd)"
PEAT="$GRAPHEION/../peat"                     # the peat-ffi SOURCE grapheion compiles
PEAT_FLUTTER="$GRAPHEION/../peat-flutter"     # Dart bindings + build scripts (build branch)

echo "==> peat (peat-ffi source grapheion compiles)"
if [ -d "$PEAT/.git" ]; then
  git -C "$PEAT" fetch origin --quiet
  [ "$(git -C "$PEAT" branch --show-current)" = "main" ] || git -C "$PEAT" checkout main --quiet
  if git -C "$PEAT" merge --ff-only origin/main >/dev/null 2>&1; then
    echo "   ✓ $(git -C "$PEAT" rev-parse --short HEAD) (current with origin/main)"
  else
    echo "   ⚠ couldn't fast-forward (local commits / dirty tree) — resolve manually:"
    git -C "$PEAT" status -sb | head -3
  fi
else
  echo "   ⚠ ../peat not found — skipping"
fi

echo "==> peat-flutter stays on its build branch: $(git -C "$PEAT_FLUTTER" branch --show-current 2>/dev/null || echo '?')"
echo "   (NOT switched to main: its published-crate wrapper crashes on iOS for grapheion — revisit later)"

echo "==> grapheion: flutter pub get + analyze (smoke check)"
if ( cd "$GRAPHEION" && flutter pub get && flutter analyze lib/ ); then
  echo "✓ deps current + grapheion analyzes clean — safe to build."
else
  echo "⚠ analyze found issues — a dep update may have shifted an API. Review above."
  exit 1
fi
