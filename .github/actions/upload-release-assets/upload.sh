#!/usr/bin/env bash

set -euo pipefail

: "${ASSET_GLOB:?ASSET_GLOB is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${TAG:?TAG is required}"

retry_delays=${RELEASE_UPLOAD_RETRY_DELAYS:-1,3}
IFS=, read -r -a delays <<<"$retry_delays"

run_gh() {
  python3 "$GITHUB_ACTION_PATH/run-with-timeout.py" \
    "${RELEASE_GH_TIMEOUT_SECONDS:-120}" 5 -- gh "$@"
}

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

asset_names=()
for asset in "${assets[@]}"; do
  asset_name=${asset##*/}
  for existing_name in ${asset_names[@]+"${asset_names[@]}"}; do
    if [[ "$existing_name" == "$asset_name" ]]; then
      printf 'duplicate release asset name: %s\n' "$asset_name" >&2
      exit 1
    fi
  done
  asset_names+=("$asset_name")
done

remote_size() {
  local asset_name=$1
  local response

  if ! response=$(run_gh release view "$TAG" \
    --repo "$GITHUB_REPOSITORY" --json assets); then
    return 2
  fi
  jq -r --arg name "$asset_name" \
    '.assets[] | select(.name == $name) | .size' <<<"$response" | head -n 1
}

remote_state() {
  local asset_name=$1
  local expected_size=$2
  local actual_size

  if ! actual_size=$(remote_size "$asset_name"); then
    printf 'unknown\n'
  elif [[ "$actual_size" == "$expected_size" ]]; then
    printf 'matching\n'
  else
    printf 'different\n'
  fi
}

upload_one() {
  local asset=$1
  local asset_name=${asset##*/}
  local asset_size
  local attempt
  local delay
  local state

  [[ -f "$asset" ]] || {
    printf 'release asset is not a regular file: %s\n' "$asset" >&2
    return 1
  }
  asset_size=$(wc -c <"$asset" | tr -d ' ')

  state=$(remote_state "$asset_name" "$asset_size")
  if [[ "$state" == matching ]]; then
    printf 'release asset already uploaded: %s\n' "$asset_name"
    return 0
  fi

  for attempt in 1 2 3; do
    if ((attempt > 1)); then
      state=$(remote_state "$asset_name" "$asset_size")
      if [[ "$state" == matching ]]; then
        return 0
      fi
      if [[ "$state" == unknown ]]; then
        printf 'release asset state is unknown; deferring mutation: %s\n' \
          "$asset_name" >&2
      else
        state=different
      fi
    fi

    if [[ "$state" == unknown ]]; then
      upload_status=1
    elif run_gh release upload "$TAG" "$asset" \
      --repo "$GITHUB_REPOSITORY" --clobber; then
      upload_status=0
    else
      upload_status=$?
    fi

    state=$(remote_state "$asset_name" "$asset_size")
    if [[ "$state" == matching ]]; then
      if ((upload_status != 0)); then
        printf 'release asset arrived after an ambiguous upload error: %s\n' \
          "$asset_name"
      fi
      return 0
    fi
    if ((upload_status == 0)); then
      printf 'release asset upload returned success but verification failed: %s\n' \
        "$asset_name" >&2
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
