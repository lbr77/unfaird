#!/bin/bash
# Build unfaird debs for several Theos package schemes in one run.
#
#   scripts/package.sh                        # rootless + roothide
#   scripts/package.sh rootless               # one scheme
#   scripts/package.sh rootless roothide ''   # '' means the rootful scheme
#
# Each scheme gets its own Theos staging root so the runs cannot clobber each
# other, and every produced deb is copied into debs/ under its scheme name.
#
# Requirements per scheme:
#   rootless  standard Theos (mod/rootless -> prefix /var/jb, iphoneos-arm64)
#   roothide  RootHide's Theos fork (mod/roothide -> empty prefix, iphoneos-arm64e)
# A scheme whose module is absent is reported and skipped; the script fails at
# the end if nothing was built, and exits non-zero if any requested scheme failed.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

THEOS="${THEOS:-$HOME/theos}"
export THEOS

package_dir="${THEOS_PACKAGE_DIR_NAME:-debs}"
log_dir=".build-packaging"

if [[ $# -gt 0 ]]; then
  schemes=("$@")
else
  schemes=(rootless roothide)
fi

if [[ ! -d "$THEOS" ]]; then
  echo "theos not found at $THEOS; set THEOS to your Theos checkout" >&2
  exit 1
fi

scheme_label() {
  if [[ -z "$1" ]]; then printf 'rootful\n'; else printf '%s\n' "$1"; fi
}

scheme_supported() {
  local scheme="$1"
  # The rootful scheme is the empty string and is always available.
  [[ -z "$scheme" ]] && return 0
  [[ -d "$THEOS/vendor/mod/$scheme" || -d "$THEOS/mod/$scheme" ]]
}

mkdir -p "$package_dir" "$log_dir"

built=()
skipped=()
failed=()

for scheme in "${schemes[@]}"; do
  label="$(scheme_label "$scheme")"

  if ! scheme_supported "$scheme"; then
    echo "== $label: skipped (no $THEOS/vendor/mod/$scheme or $THEOS/mod/$scheme)"
    skipped+=("$label")
    continue
  fi

  echo "== $label: building"
  staging="_$label"
  log="$log_dir/$label.log"

  # A dedicated staging dir name keeps each scheme's DEBIAN/ and payload apart.
  # Removing it first stops a previous scheme's tree from leaking into this deb.
  rm -rf ".theos/$staging" ".theos/${staging}tmp"

  before="$(ls -1 "$package_dir" 2>/dev/null | sort)"

  if make package \
      THEOS_PACKAGE_SCHEME="$scheme" \
      THEOS_STAGING_DIR_NAME="$staging" \
      THEOS_PACKAGE_DIR_NAME="$package_dir" \
      FINALPACKAGE=1 \
      >"$log" 2>&1; then
    after="$(ls -1 "$package_dir" 2>/dev/null | sort)"
    new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep '\.deb$' || true)"

    if [[ -z "$new" ]]; then
      echo "   built, but no new deb appeared in $package_dir/ (see $log)"
      failed+=("$label")
      continue
    fi

    while IFS= read -r deb; do
      [[ -z "$deb" ]] && continue
      renamed="${deb%.deb}_$label.deb"
      mv "$package_dir/$deb" "$package_dir/$renamed"
      echo "   $package_dir/$renamed"
      built+=("$package_dir/$renamed")
    done <<< "$new"
  else
    echo "   FAILED (see $log)"
    tail -n 20 "$log" | sed 's/^/   | /'
    failed+=("$label")
  fi
done

echo
echo "built:   ${#built[@]} ${built[*]:-}"
[[ ${#skipped[@]} -gt 0 ]] && echo "skipped: ${skipped[*]}"
[[ ${#failed[@]} -gt 0 ]] && echo "failed:  ${failed[*]}"

if [[ ${#failed[@]} -gt 0 ]]; then
  exit 1
fi
if [[ ${#built[@]} -eq 0 ]]; then
  echo "no packages were built" >&2
  exit 1
fi
exit 0
