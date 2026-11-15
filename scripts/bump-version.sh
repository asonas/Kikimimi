#!/usr/bin/env bash
# Sets MARKETING_VERSION in project.yml and increments CURRENT_PROJECT_VERSION, then regenerates the project.
# Sparkle compares CURRENT_PROJECT_VERSION (CFBundleVersion), so it must grow with every release.
# Run via `mise run bump <x.y.z>`.
set -euo pipefail

version="${1:-}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: mise run bump <x.y.z>  (got: '${version}')" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

current_build="$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml | head -1)"
[[ -n "$current_build" ]] || { echo "Could not find CURRENT_PROJECT_VERSION in project.yml" >&2; exit 1; }
next_build="$((current_build + 1))"

sed -i '' \
  -e "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"${version}\"/" \
  -e "s/CURRENT_PROJECT_VERSION: \"[0-9]*\"/CURRENT_PROJECT_VERSION: \"${next_build}\"/" \
  project.yml

xcodegen generate >/dev/null

echo "Bumped to ${version} (build ${next_build})."
