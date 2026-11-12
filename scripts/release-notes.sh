#!/usr/bin/env bash
# Prints a version's section of the changelog: betas from CHANGELOG.beta.md, stable versions (and
# betas before the beta branch) from CHANGELOG.md.
# Usage: scripts/release-notes.sh <version>
set -euo pipefail
version="$1"
section() { [ -f "$1" ] && awk -v v="$version" 'index($0, "## [" v "]") == 1 {f=1; next} /^## \[/ {f=0} f' "$1"; }
case "$version" in *-*) files="CHANGELOG.beta.md CHANGELOG.md" ;; *) files="CHANGELOG.md" ;; esac
for f in $files; do
  notes="$(section "$f" || true)"
  if [ -n "$notes" ]; then printf '%s\n' "$notes"; exit 0; fi
done
