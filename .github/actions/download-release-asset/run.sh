#!/bin/sh
set -eu

# shellcheck source=../../../capability-harness/github-release.sh
. "$GITHUB_ACTION_PATH/../../../capability-harness/github-release.sh"

case "$RELEASE_SHA256" in
  '' | *[!0-9a-f]*)
    printf 'Invalid release asset SHA-256\n' >&2
    exit 2
    ;;
esac
[ "${#RELEASE_SHA256}" -eq 64 ] || {
  printf 'Invalid release asset SHA-256 length\n' >&2
  exit 2
}
case "$RELEASE_MAX_TIME" in
  '' | 0* | *[!0-9]*)
    printf 'Invalid release max-time\n' >&2
    exit 2
    ;;
esac
case "$RELEASE_RETRIES" in
  '' | 0?* | *[!0-9]*)
    printf 'Invalid release retry count\n' >&2
    exit 2
    ;;
esac
[ "$RELEASE_MAX_TIME" -le 600 ] && [ "$RELEASE_RETRIES" -le 10 ] || {
  printf 'Maximum release limits are 600 seconds per attempt and 10 retries\n' >&2
  exit 2
}
[ -n "$RELEASE_OUTPUT" ] && [ ! -d "$RELEASE_OUTPUT" ] || exit 2

# Curl honors Retry-After even with --retry-delay. Bound when the last
# retry may start as well as the duration of each transfer.
retry_start_limit=$((RELEASE_RETRIES * (RELEASE_MAX_TIME + 1) + 1))

# Keep an existing destination intact until we prove the archive matches the
# caller's pin. Stage on the same filesystem so the final move is atomic.
stage=$(mktemp -d "$(dirname -- "$RELEASE_OUTPUT")/.verified-release.XXXXXX")
trap 'rm -rf -- "$stage"' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
github_release_download "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$RELEASE_ASSET" "$stage/asset" \
  --connect-timeout 10 --max-time "$RELEASE_MAX_TIME" \
  --speed-limit 1024 --speed-time 30 \
  --retry "$RELEASE_RETRIES" --retry-all-errors --retry-delay 1 \
  --retry-max-time "$retry_start_limit"

if command -v sha256sum >/dev/null 2>&1; then
  hash=$(sha256sum <"$stage/asset")
else
  hash=$(shasum -a 256 <"$stage/asset")
fi
if [ "${hash%% *}" != "$RELEASE_SHA256" ]; then
  printf 'SHA-256 mismatch for %s\n' "$RELEASE_ASSET" >&2
  exit 1
fi
mv -f -- "$stage/asset" "$RELEASE_OUTPUT"
