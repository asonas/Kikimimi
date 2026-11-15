#!/usr/bin/env bash
# Prints MARKETING_VERSION from project.yml, the one place the version is written.
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(sed -n 's/.*MARKETING_VERSION: "\([^"]*\)".*/\1/p' project.yml | head -1)"
[[ -n "$version" ]] || { echo "Could not find MARKETING_VERSION in project.yml" >&2; exit 1; }
echo "$version"
