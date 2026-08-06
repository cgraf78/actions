#!/usr/bin/env bash
set -euo pipefail

# Match the sync command's cross-platform manifest ordering regardless of the
# runner's configured locale.
export LC_ALL=C

# Verify that a consumer repository's vendored release scripts still match the
# shared copy shipped with this action.
#
# Vendoring keeps release tooling usable locally and in CI without pulling code
# over the network on the release path. This gate is what makes the vendored
# files a derived artifact rather than an independently maintained fork: any
# divergence fails the consumer's CI with the exact diff and the resync command.

# $GITHUB_ACTION_PATH points at .github/actions/verify-release-scripts inside
# the checked-out actions repo; the shared scripts live at its root.
action_path=$(cd "$GITHUB_ACTION_PATH" && pwd)
shared_dir=$(cd "$action_path/../../.." && pwd)/release-scripts

if [[ ! -d "$shared_dir" ]]; then
  printf 'verify-release-scripts: shared copy not found at %s\n' "$shared_dir" >&2
  exit 1
fi

scripts_dir=${SCRIPTS_DIR:-scripts}
if [[ ! -d "$scripts_dir" || -L "$scripts_dir" ]]; then
  printf 'verify-release-scripts: consumer scripts dir must be a regular directory, not a symlink: %s\n' \
    "$scripts_dir" >&2
  exit 1
fi

status=0
checked=0
manifest_name=.release-scripts.manifest
consumer_manifest="$scripts_dir/$manifest_name"
expected_manifest=$(mktemp)
trap 'rm -f "$expected_manifest"' EXIT

shopt -s nullglob
for shared in "$shared_dir"/*.sh; do
  name=$(basename "$shared")
  # sync.sh is maintainer tooling for the actions repo, never vendored.
  [[ "$name" == sync.sh ]] && continue
  printf '%s\n' "$name" >>"$expected_manifest"

  vendored="$scripts_dir/$name"
  checked=$((checked + 1))

  if [[ ! -f "$vendored" || -L "$vendored" ]]; then
    printf 'verify-release-scripts: missing vendored script or not a regular non-symlink file: %s\n' \
      "$vendored" >&2
    status=1
    continue
  fi

  if ! diff -u "$shared" "$vendored" >/dev/null 2>&1; then
    printf 'verify-release-scripts: %s differs from the shared copy\n' "$vendored" >&2
    diff -u --label "shared/$name" --label "$vendored" "$shared" "$vendored" >&2 || true
    status=1
  fi

  # An entry point that loses its executable bit fails at release time with a
  # confusing error, and content comparison alone would not catch it.
  if [[ -x "$shared" && ! -x "$vendored" ]]; then
    printf 'verify-release-scripts: %s must be executable\n' "$vendored" >&2
    status=1
  elif [[ ! -x "$shared" && -x "$vendored" ]]; then
    printf 'verify-release-scripts: %s must not be executable\n' "$vendored" >&2
    status=1
  fi
done

if [[ "$checked" -eq 0 ]]; then
  printf 'verify-release-scripts: shared copy contains no scripts; refusing to pass\n' >&2
  exit 1
fi

# Content comparison proves today's files match; the managed manifest also
# proves a file removed upstream did not survive indefinitely in the consumer.
# Repo-owned neighbors remain outside the manifest and are intentionally
# ignored, so this check does not guess ownership from a broad filename glob.
if [[ ! -f "$consumer_manifest" || -L "$consumer_manifest" ]]; then
  printf 'verify-release-scripts: missing managed manifest: %s\n' \
    "$consumer_manifest" >&2
  status=1
elif [[ -x "$consumer_manifest" ]]; then
  printf 'verify-release-scripts: managed manifest must not be executable: %s\n' \
    "$consumer_manifest" >&2
  status=1
elif ! diff -u "$expected_manifest" "$consumer_manifest" >/dev/null 2>&1; then
  printf 'verify-release-scripts: managed filename set differs: %s\n' \
    "$consumer_manifest" >&2
  diff -u --label shared/managed-files --label "$consumer_manifest" \
    "$expected_manifest" "$consumer_manifest" >&2 || true
  status=1
fi

if [[ "$status" -ne 0 ]]; then
  cat >&2 <<EOF

Vendored release scripts are out of date. From a cgraf78/actions checkout at the
commit this repository pins, run:

  consumer-ci/sync.sh <this-repo>

That one command keeps the repository's lock, literal workflow references, and
vendored release scripts on the same reviewed actions commit. Commit all of its
output alongside the dependency bump.
EOF
  exit 1
fi

printf 'verify-release-scripts: %d vendored script(s) match the shared copy\n' "$checked"
