#!/usr/bin/env bash
#
# Install the local DCO sign-off hook into the peat + peat-flutter clones, so
# every commit there is auto-signed (equivalent to `git commit -s`).
#
# .git/hooks is NOT version-controlled, so re-run this after re-cloning either
# repo. The macOS bootstrap calls it for you; you can also run it directly:
#   ./scripts/install-hooks.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)" # parent holding grapheion + siblings

# The hook body (literal — quoted heredoc, so nothing here is expanded now).
read -r -d '' HOOK <<'HOOK_EOF' || true
#!/usr/bin/env bash
# Auto-append a DCO Signed-off-by trailer to every commit (idempotent).
# Installed by grapheion/scripts/install-hooks.sh — local, not committed.
set -euo pipefail
msg_file="$1"
name="$(git config user.name || true)"
email="$(git config user.email || true)"
[ -n "$name" ] && [ -n "$email" ] || exit 0
sob="Signed-off-by: ${name} <${email}>"
grep -qiF "$sob" "$msg_file" && exit 0
git interpret-trailers --in-place --if-exists doNothing --trailer "$sob" "$msg_file"
HOOK_EOF

installed=0
for repo in peat peat-flutter; do
  dir="${ROOT}/${repo}"
  if [ -d "${dir}/.git" ]; then
    printf '%s\n' "${HOOK}" > "${dir}/.git/hooks/prepare-commit-msg"
    chmod +x "${dir}/.git/hooks/prepare-commit-msg"
    echo "✓ DCO sign-off hook → ${repo}/.git/hooks/prepare-commit-msg"
    installed=$((installed + 1))
  else
    echo "· skip ${repo} (not cloned at ${dir})"
  fi
done
[ "${installed}" -gt 0 ] ||
  echo "No sibling repos found — clone peat/peat-flutter first (see SETUP.md)."
