#!/usr/bin/env bash

# shellcheck source=.github/actions/shared/infra-stall-markers.sh
source "${BASH_SOURCE[0]%/*}/../shared/infra-stall-markers.sh" || return 1

# Keep every interaction with the emulator behind a supervisor. A disconnected
# or wedged adb server must fail this phase before the outer Actions job limit.
_termux_adb_timeout_exec() {
  local timeout_seconds=$1
  shift

  exec env LC_ALL=C timeout --kill-after=5 "$timeout_seconds" "$@"
}

_termux_adb_timeout() {
  (
    _termux_adb_timeout_exec "$@"
  )
}

termux_adb() {
  local timeout_seconds=$1
  local adb_command=${TERMUX_ADB_REAL:-adb}
  shift

  _termux_adb_timeout "$timeout_seconds" "$adb_command" "$@"
}

# Termux unpacks its bootstrap on first launch, before any caller code runs.
# Exhaustion prints the stable infra-stall marker so a launch that never
# finishes unpacking is retried as infrastructure.
termux_wait_for_runtime() {
  local attempts=$1
  local timeout_seconds=$2
  local delay_seconds=$3
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if termux_adb "$timeout_seconds" shell run-as com.termux \
      test -x files/usr/bin/bash; then
      return 0
    fi
    if ((attempt < attempts)); then
      sleep "$delay_seconds"
    fi
  done

  printf '%s\n' "$TERMUX_BOOTSTRAP_TIMEOUT_MARKER" >&2
  return 1
}

# The emulator reports boot completion before Android's package manager
# service accepts binder calls, and an install in that window fails with
# "Failure calling service package: Broken pipe". Poll a cheap package query
# until the service answers. Exhaustion prints the stable infra-stall marker so
# the job-level retry classifier treats a stuck emulator as infrastructure.
termux_wait_for_package_service() {
  local attempts=$1
  local timeout_seconds=$2
  local delay_seconds=$3
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if termux_adb "$timeout_seconds" shell pm path android >/dev/null; then
      return 0
    fi
    if ((attempt < attempts)); then
      sleep "$delay_seconds"
    fi
  done

  printf '%s\n' "$TERMUX_PACKAGE_SERVICE_MARKER" >&2
  return 1
}

# `install -r` replaces the package in place, so retrying a failed attempt is
# idempotent. Retry on exit status alone: the service can still drop a
# streamed install shortly after it first answers.
termux_install_apk() {
  local attempts=$1
  local timeout_seconds=$2
  local delay_seconds=$3
  local apk=$4
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if termux_adb "$timeout_seconds" install -r "$apk"; then
      return 0
    fi
    if ((attempt < attempts)); then
      sleep "$delay_seconds"
    fi
  done

  printf '%s\n' "$TERMUX_PACKAGE_SERVICE_MARKER" >&2
  return 1
}

# EXIT trap for the emulator host script: on failure, print Android's crash
# buffer so a native crash in caller code arrives with its crash summary
# (signal, abort message, backtrace). It must run inside the emulator
# runner's script, because the runner kills the emulator as soon as the
# script returns, so a later `if: failure()` step would find no device. The
# buffer also holds any system crashes since boot. A cancelled job gets no
# dump, since the signal never reaches this trap as a failure status; no
# caller failure needs explaining there.
#
# Diagnostics only: the dump is bounded, and the whole block is guarded
# because under the host script's `set -e` any failing command in a trap
# would replace the script's exit status.
termux_dump_crash_log() {
  local rc=$?
  local timeout_seconds=$1

  if ((rc != 0)); then
    {
      printf '::group::Android crash log (host script exit %s)\n' "$rc"
      termux_adb "$timeout_seconds" logcat -b crash -d ||
        printf 'Android crash log unavailable\n'
      printf '::endgroup::\n'
    } || true
  fi
  return "$rc"
}
