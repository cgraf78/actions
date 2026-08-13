#!/usr/bin/env bash

set -euo pipefail

: "${ASSET_GLOB:?ASSET_GLOB is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${TAG:?TAG is required}"

retry_delays=${RELEASE_UPLOAD_RETRY_DELAYS:-1,3}
IFS=, read -r -a delays <<<"$retry_delays"

# The glob is trusted caller configuration from the reusable workflow. Preserve
# its historical shell expansion contract while making an empty match fatal.
shopt -s nullglob
# shellcheck disable=SC2206
assets=($ASSET_GLOB)
shopt -u nullglob
if ((${#assets[@]} == 0)); then
  printf 'release asset glob matched no files: %s\n' "$ASSET_GLOB" >&2
  exit 1
fi

remote_size() {
  local asset_name=$1
  local response

  if ! response=$(gh release view "$TAG" \
    --repo "$GITHUB_REPOSITORY" --json assets); then
    return 2
  fi
  jq -r --arg name "$asset_name" \
    '.assets[] | select(.name == $name) | .size' <<<"$response" | head -n 1
}

matches_remote() {
  local asset_name=$1
  local expected_size=$2
  local actual_size

  actual_size=$(remote_size "$asset_name") || return 1
  [[ "$actual_size" == "$expected_size" ]]
}

upload_one() {
  local asset=$1
  local asset_name=${asset##*/}
  local asset_size
  local attempt
  local delay

  [[ -f "$asset" ]] || {
    printf 'release asset is not a regular file: %s\n' "$asset" >&2
    return 1
  }
  asset_size=$(wc -c <"$asset" | tr -d ' ')

  if matches_remote "$asset_name" "$asset_size"; then
    printf 'release asset already uploaded: %s\n' "$asset_name"
    return 0
  fi

  for attempt in 1 2 3; do
    if gh release upload "$TAG" "$asset" \
      --repo "$GITHUB_REPOSITORY" --clobber; then
      if matches_remote "$asset_name" "$asset_size"; then
        return 0
      fi
      printf 'release asset upload returned success but verification failed: %s\n' \
        "$asset_name" >&2
    elif matches_remote "$asset_name" "$asset_size"; then
      printf 'release asset arrived after an ambiguous upload error: %s\n' \
        "$asset_name"
      return 0
    fi

    if ((attempt < 3)); then
      delay=${delays[attempt - 1]:-3}
      printf 'retrying release asset upload (%d/3) in %ss: %s\n' \
        "$((attempt + 1))" "$delay" "$asset_name" >&2
      sleep "$delay"
    fi
  done

  printf 'release asset upload failed after 3 attempts: %s\n' "$asset_name" >&2
  return 1
}

for asset in "${assets[@]}"; do
  upload_one "$asset"
done
