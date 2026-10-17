#!/usr/bin/env bash

# Pre-install the SDK packages that the pinned
# reactivecircus/android-emulator-runner installs in its "Install Android SDK"
# phase. That action makes a single unbounded `sdkmanager --install` attempt
# per package group, so one truncated archive download ("Error on ZipFile
# unknown archive") fails the whole job. Installing the identical package set
# here, with bounded retries, leaves the action's own calls finding every
# package current, so they download no archives; they still fetch the small
# repository manifests. Exhaustion prints a stable marker that `infra-retry`
# reruns once.

set -euo pipefail

# shellcheck source=.github/actions/shared/infra-stall-markers.sh
source "${BASH_SOURCE[0]%/*}/../shared/infra-stall-markers.sh"

notice() {
  printf 'android-sdk-packages: %s\n' "$*" >&2
}

: "${ANDROID_SDK_API_LEVEL:?ANDROID_SDK_API_LEVEL is required}"
: "${ANDROID_SDK_ARCH:?ANDROID_SDK_ARCH is required}"
: "${ANDROID_SDK_BUILD_TOOLS_VERSION:?ANDROID_SDK_BUILD_TOOLS_VERSION is required}"
: "${ANDROID_SDK_TARGET:?ANDROID_SDK_TARGET is required}"
# Healthy installs take under a minute. A 180s attempt is three times that
# without letting one stalled download consume the job; a manifest outage
# that outlasts it spends the attempts and then the one job rerun. Tests
# shorten these knobs, and an empty delay list means a single attempt;
# production uses the defaults.
attempt_timeout=${ANDROID_SDK_ATTEMPT_TIMEOUT:-180}
kill_after=${ANDROID_SDK_KILL_AFTER:-10}
read -r -a retry_delays <<<"${ANDROID_SDK_RETRY_DELAYS-30 90}"

# Values reach sdkmanager as package paths, so reject anything that could add
# another package or option rather than name the one the emulator runner uses.
[[ $ANDROID_SDK_API_LEVEL =~ ^[1-9][0-9]*$ &&
  $ANDROID_SDK_ARCH =~ ^[a-z0-9_-]+$ &&
  $ANDROID_SDK_TARGET =~ ^[a-z0-9_-]+$ &&
  $ANDROID_SDK_BUILD_TOOLS_VERSION =~ ^[0-9]+(\.[0-9]+)*(-rc[0-9]+)?$ &&
  $attempt_timeout =~ ^[1-9][0-9]*$ &&
  $kill_after =~ ^[1-9][0-9]*$ ]] || {
  notice 'invalid Android SDK package or retry configuration'
  exit 2
}
for delay in "${retry_delays[@]}"; do
  [[ $delay =~ ^[0-9]+$ ]] || {
    notice "invalid retry delay: $delay"
    exit 2
  }
done

sdkmanager=${ANDROID_HOME:-}/cmdline-tools/latest/bin/sdkmanager
if [[ -z ${ANDROID_HOME:-} || ! -x $sdkmanager ]]; then
  # The emulator runner downloads its own command-line tools when the image
  # has none. Skipping keeps that path working with its single attempt rather
  # than failing a job the runner could still provision.
  printf '::warning::Android SDK command-line tools are unavailable; leaving SDK installation to the emulator runner\n'
  exit 0
fi

# The same paths, in the same channel, as the pinned runner's
# lib/sdk-installer.js. It installs the first three without `--channel`,
# whose default is the stable channel 0 used here for all five.
packages=(
  "build-tools;$ANDROID_SDK_BUILD_TOOLS_VERSION"
  platform-tools
  "platforms;android-$ANDROID_SDK_API_LEVEL"
  emulator
  "system-images;android-$ANDROID_SDK_API_LEVEL;$ANDROID_SDK_TARGET;$ANDROID_SDK_ARCH"
)

# Runs one sdkmanager command until the attempt's shared deadline. sdkmanager
# must be timeout's direct child: `--kill-after` escalates only while that
# child lives, so a wrapper shell that exits on TERM would leave a JVM that
# ignores TERM running into the next attempt. Progress bars go to stdout;
# warnings and errors stay visible on stderr.
bounded_sdkmanager() {
  local remaining=$((deadline - SECONDS))

  ((remaining > 0)) || return 124
  timeout --kill-after="$kill_after" "$remaining" "$sdkmanager" "$@" >/dev/null
}

install_once() {
  deadline=$((SECONDS + attempt_timeout))
  # `yes` answers every license prompt and ends on SIGPIPE once sdkmanager
  # stops reading; process substitution keeps that out of the status.
  bounded_sdkmanager --licenses < <(yes) &&
    bounded_sdkmanager --install "${packages[@]}" --channel=0
}

# A killed or corrupt download can leave partial archives that a later
# attempt would resume rather than fetch again. Both directories hold only
# sdkmanager's in-flight downloads.
clear_partial_downloads() {
  rm -rf -- "$ANDROID_HOME/.temp" "$ANDROID_HOME/.downloadIntermediates"
}

attempts=$((${#retry_delays[@]} + 1))
for ((attempt = 1; ; attempt++)); do
  if install_once; then
    notice "installed ${packages[*]} (attempt $attempt/$attempts)"
    exit 0
  else
    rc=$?
  fi
  ((attempt < attempts)) || break
  delay=${retry_delays[attempt - 1]}
  notice "attempt $attempt/$attempts failed (exit $rc); retrying in ${delay}s"
  sleep "$delay"
  clear_partial_downloads
done

# Every attempt is retried regardless of exit status because sdkmanager uses
# 1 for transport and configuration errors alike. A configuration error would
# cost one extra job rerun; it cannot loop, since infra-retry reruns once.
notice "attempt $attempt/$attempts failed (exit $rc); giving up"
printf '%s\n' "$ANDROID_SDK_INSTALL_MARKER" >&2
exit "$rc"
