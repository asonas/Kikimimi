#!/usr/bin/env bash
# Publishes build/appcast.xml to the gh-pages branch, which GitHub Pages serves as
# https://asonas.github.io/Kikimimi/appcast.xml (the app's SUFeedURL).
# Run via `mise run publish:appcast`, after the GitHub Release exists: the appcast points at its ZIP.
set -euo pipefail

cd "$(dirname "$0")/.."
: "${GITHUB_REPO:?run through mise}" "${BUILD_DIR:?run through mise}"
appcast="$PWD/$BUILD_DIR/appcast.xml"
[[ -f "$appcast" ]] || { echo "Missing $appcast. Run 'mise run release' first." >&2; exit 1; }
version="$(scripts/version.sh)"

# The enclosure must be downloadable before users are told about it.
url="$(sed -n 's/.*enclosure url="\([^"]*\)".*/\1/p' "$appcast" | head -1)"
gh release view "v$version" --repo "$GITHUB_REPO" --json assets --jq '.assets[].url' | grep -Fxq "$url" \
  || { echo "The release v$version has no asset at $url. Run 'mise run publish:release' first." >&2; exit 1; }

worktree="$(mktemp -d)"
trap 'git worktree remove --force "$worktree" 2>/dev/null || true' EXIT
git fetch origin gh-pages
git worktree add --detach "$worktree" origin/gh-pages
command cp "$appcast" "$worktree/appcast.xml"
git -C "$worktree" add appcast.xml
if git -C "$worktree" diff --cached --quiet; then
  echo "appcast.xml on gh-pages is already up to date."
else
  git -C "$worktree" commit -m "Reflect v$version in the appcast"
  git -C "$worktree" push origin HEAD:gh-pages
fi

# A failed Pages build keeps serving the old file forever, so ask the build API instead of polling the URL.
echo "Waiting for the GitHub Pages build..."
for _ in $(seq 1 30); do
  status="$(gh api "repos/$GITHUB_REPO/pages/builds/latest" --jq .status)"
  case "$status" in
    built) break ;;
    errored) echo "Pages build failed. Retry with: gh api -X POST repos/$GITHUB_REPO/pages/builds" >&2; exit 1 ;;
  esac
  sleep 10
done
[[ "$status" == built ]] || { echo "Pages build still '$status' after 5 minutes." >&2; exit 1; }
owner="${GITHUB_REPO%%/*}"; name="${GITHUB_REPO##*/}"
echo "Published. Check: https://$owner.github.io/$name/appcast.xml"
