#!/usr/bin/env bash
set -euo pipefail

# Match the sync command's cross-platform manifest ordering regardless of the
# runner's configured locale.
export LC_ALL=C

# Verify that a consumer directory's vendored copy of one provider script
# family still matches the shared copy shipped with this actions checkout.
#
# Vendoring keeps tooling usable locally and in CI without pulling code over
# the network. This gate is what makes the vendored files a derived artifact
# rather than an independently maintained fork: any divergence fails the
# consumer's CI with the exact diff and the resync command. Every vendored
# family shares this one comparison so content, mode, and managed-set rules
# match consumer-ci/vendor-scripts.sh for all of them.
#
# usage: verify-vendored-scripts.sh <shared-dir> <consumer-dir> <manifest-name>
#          <label> <description>
# <label> prefixes diagnostics; <description> names the family in the
# remediation text, for example "release scripts".

if [[ $# -ne 5 ]]; then
  printf '%s\n' \
    'usage: verify-vendored-scripts.sh <shared-dir> <consumer-dir> <manifest-name> <label> <description>' >&2
  exit 2
fi
shared_dir=$1
scripts_dir=$2
manifest_name=$3
label=$4
description=$5

if [[ ! -d "$shared_dir" ]]; then
  printf '%s: shared copy not found at %s\n' "$label" "$shared_dir" >&2
  exit 1
fi

if [[ ! -d "$scripts_dir" || -L "$scripts_dir" ]]; then
  printf '%s: consumer scripts dir must be a regular directory, not a symlink: %s\n' \
    "$label" "$scripts_dir" >&2
  exit 1
fi

status=0
checked=0
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
    printf '%s: missing vendored script or not a regular non-symlink file: %s\n' \
      "$label" "$vendored" >&2
    status=1
    continue
  fi

  if ! diff -u "$shared" "$vendored" >/dev/null 2>&1; then
    printf '%s: %s differs from the shared copy\n' "$label" "$vendored" >&2
    diff -u --label "shared/$name" --label "$vendored" "$shared" "$vendored" >&2 || true
    status=1
  fi

  # An entry point that loses its executable bit fails at use time with a
  # confusing error, and content comparison alone would not catch it.
  if [[ -x "$shared" && ! -x "$vendored" ]]; then
    printf '%s: %s must be executable\n' "$label" "$vendored" >&2
    status=1
  elif [[ ! -x "$shared" && -x "$vendored" ]]; then
    printf '%s: %s must not be executable\n' "$label" "$vendored" >&2
    status=1
  fi
done

if [[ "$checked" -eq 0 ]]; then
  printf '%s: shared copy contains no scripts; refusing to pass\n' "$label" >&2
  exit 1
fi

# Content comparison proves today's files match; the managed manifest also
# proves a file removed upstream did not survive indefinitely in the consumer.
# Repo-owned neighbors remain outside the manifest and are intentionally
# ignored, so this check does not guess ownership from a broad filename glob.
if [[ ! -f "$consumer_manifest" || -L "$consumer_manifest" ]]; then
  printf '%s: missing managed manifest: %s\n' \
    "$label" "$consumer_manifest" >&2
  status=1
elif [[ -x "$consumer_manifest" ]]; then
  printf '%s: managed manifest must not be executable: %s\n' \
    "$label" "$consumer_manifest" >&2
  status=1
elif ! diff -u "$expected_manifest" "$consumer_manifest" >/dev/null 2>&1; then
  printf '%s: managed filename set differs: %s\n' \
    "$label" "$consumer_manifest" >&2
  diff -u --label shared/managed-files --label "$consumer_manifest" \
    "$expected_manifest" "$consumer_manifest" >&2 || true
  status=1
fi

if [[ "$status" -ne 0 ]]; then
  cat >&2 <<EOF

Vendored $description are out of date. From a cgraf78/actions checkout at the
commit this repository pins, run:

  consumer-ci/sync.sh <this-repo>

That one command keeps the repository's lock, literal workflow references, and
vendored $description on the same reviewed actions commit. Commit all of its
output alongside the dependency bump.
EOF
  exit 1
fi

printf '%s: %d vendored script(s) match the shared copy\n' "$label" "$checked"
