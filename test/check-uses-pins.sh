#!/usr/bin/env bash
#
# check-uses-pins.sh [root]
#
# Third-party pin policy for GitHub workflows and composite actions: every
# third-party `uses:` ref must be an immutable 40-char SHA, and all use
# sites of one action repository must agree on a single SHA. Dependabot
# bumps every site of one action in a single PR, so agreement (not an
# absolute SHA) is the invariant that survives version bumps. Version
# review happens on the bump PR itself.
#
# Local (`./...`) references are unpinned by design and self
# (`cgraf78/actions@...`) references follow .github/cgraf78-actions.lock
# through dedicated assertions, so both are ignored here.

set -euo pipefail

target=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

failures=0
report() {
  printf 'uses-pins: %s\n' "$1" >&2
  failures=1
}

shopt -s nullglob
files=("$target"/.github/workflows/*.yml "$target"/.github/actions/*/*.yml)
shopt -u nullglob
if [[ ${#files[@]} -eq 0 ]]; then
  report "no workflow or action files under $target"
  exit 1
fi

records=$(mktemp)
trap 'rm -f "$records"' EXIT

for file in "${files[@]}"; do
  short=${file#"$target"/}
  if ! refs=$(yq -r '.. | select(tag == "!!map") | select(has("uses")) | .uses | select(. != null)' "$file"); then
    report "cannot parse $short"
    continue
  fi
  while IFS= read -r uses; do
    [[ -n "$uses" ]] || continue
    case "$uses" in
      ./*) continue ;;
      cgraf78/actions/*) continue ;;
    esac
    if [[ ! "$uses" =~ ^([^/[:space:]]+/[^/@[:space:]]+)(/[^@[:space:]]+)?@([0-9a-f]{40})$ ]]; then
      report "third-party use is not a pinned SHA: $uses ($short)"
      continue
    fi
    printf '%s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "$short" >>"$records"
  done <<<"$refs"
done

# Group records by repository without associative arrays so the check also
# runs on stock Bash 3.2. Any group with more than one distinct SHA fails.
while IFS= read -r repo; do
  [[ -n "$repo" ]] || continue
  count=$(awk -v repo="$repo" '$1 == repo { print $2 }' "$records" | sort -u | wc -l)
  if [[ "$count" -gt 1 ]]; then
    first=$(awk -v repo="$repo" '$1 == repo { print $3; exit }' "$records")
    report "$repo pins disagree across use sites (first seen in $first)"
  fi
done < <(awk '{ print $1 }' "$records" | sort -u)

exit "$failures"
