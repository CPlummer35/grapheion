#!/usr/bin/env bash
#
# Push the current branch to your fork and open a PR against upstream.
#
# Run it from inside a repo that has BOTH remotes:
#   origin = upstream (e.g. defenseunicorns/peat)
#   fork   = your fork (e.g. CPlummer35/peat)
# i.e. the peat / peat-flutter clones — not grapheion itself.
#
#   cd ../peat
#   ../grapheion/scripts/upstream.sh --title "feat(peat-ffi): ..."
#
# Options:
#   --title "..."     PR title           (default: the branch's last commit subject)
#   --body-file FILE  PR body from a file (default: gh opens your editor)
#   --base BRANCH     upstream base       (default: origin's default branch)
#   --draft           open as a draft PR
#
set -euo pipefail

title=""; base=""; draft=""; body_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --title)     title="$2"; shift 2 ;;
    --body-file) body_args=(--body-file "$2"); shift 2 ;;
    --base)      base="$2"; shift 2 ;;
    --draft)     draft="--draft"; shift ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

command -v gh >/dev/null || { echo "gh CLI not found — https://cli.github.com" >&2; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "not inside a git repo" >&2; exit 1; }

branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" != "HEAD" ] || { echo "detached HEAD — check out a branch first" >&2; exit 1; }
git remote get-url origin >/dev/null 2>&1 || { echo "no 'origin' remote (upstream)" >&2; exit 1; }
git remote get-url fork   >/dev/null 2>&1 || { echo "no 'fork' remote (your fork)" >&2; exit 1; }

# Parse owner/repo from the remote URLs (handles https + ssh forms).
fork_owner="$(git remote get-url fork | sed -E 's#.*github\.com[:/]([^/]+)/.*#\1#')"
upstream_repo="$(git remote get-url origin | sed -E 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?.*#\1#')"
[ -n "$fork_owner" ] || { echo "could not parse fork owner" >&2; exit 1; }

# Default base = origin's HEAD branch (usually main).
if [ -z "$base" ]; then
  base="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')"
  [ -n "$base" ] || base="main"
fi
[ -n "$title" ] || title="$(git log -1 --format='%s')"

echo "==> Pushing '${branch}' to fork (${fork_owner})"
git push fork "$branch" --force-with-lease

echo "==> Opening PR  ${fork_owner}:${branch}  ->  ${upstream_repo}:${base}"
gh pr create \
  --repo "$upstream_repo" \
  --base "$base" \
  --head "${fork_owner}:${branch}" \
  --title "$title" \
  ${draft:+$draft} \
  ${body_args[@]+"${body_args[@]}"}
