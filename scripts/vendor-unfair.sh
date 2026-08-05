#!/bin/bash
# Re-vendor github.com/lbr77/unfair into Vendor/unfair at a given revision.
#
#   scripts/vendor-unfair.sh              # re-sync the revision recorded in Vendor/unfair/UPSTREAM
#   scripts/vendor-unfair.sh <revision>   # sync to a specific commit, tag or branch
set -euo pipefail

repository="https://github.com/lbr77/unfair.git"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="$root/Vendor/unfair"
manifest="$destination/UPSTREAM"

requested="${1:-}"
if [[ -z "$requested" ]]; then
  if [[ ! -f "$manifest" ]]; then
    echo "no revision given and $manifest is missing" >&2
    exit 1
  fi
  requested="$(awk '$1 == "revision:" { print $2; exit }' "$manifest")"
  if [[ -z "$requested" ]]; then
    echo "no revision recorded in $manifest" >&2
    exit 1
  fi
fi

checkout="$(mktemp -d)"
trap 'rm -rf "$checkout"' EXIT

echo "fetching $repository @ $requested"
git init --quiet "$checkout"
git -C "$checkout" remote add origin "$repository"
if ! git -C "$checkout" fetch --quiet --depth 1 origin "$requested"; then
  git -C "$checkout" fetch --quiet origin
fi
git -C "$checkout" checkout --quiet FETCH_HEAD 2>/dev/null || git -C "$checkout" checkout --quiet "$requested"

revision="$(git -C "$checkout" rev-parse HEAD)"
subject="$(git -C "$checkout" log -1 --pretty=%s)"

rm -rf "$destination"
mkdir -p "$destination"
git -C "$checkout" archive HEAD Package.swift LICENSE README.txt Sources Tests | tar -x -C "$destination"

cat > "$manifest" <<MANIFEST
repository: $repository
revision:   $revision
subject:    $subject

Vendored copy of UnfairKit / UnfairSupport. Re-sync with:

    scripts/vendor-unfair.sh [revision]

Only Package.swift, LICENSE, README.txt, Sources/ and Tests/ are vendored.
Upstream CI, Makefile and build scripts are intentionally left out.

Do not edit files under Sources/ or Tests/ directly. Land the change upstream
first, then re-run the sync script, otherwise the next sync silently reverts it.
MANIFEST

echo "vendored $revision ($subject) into Vendor/unfair"
echo "run 'swift package resolve' to refresh Package.resolved"
