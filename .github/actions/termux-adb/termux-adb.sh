#!/usr/bin/env bash

# Keep every interaction with the emulator behind a supervisor. A disconnected
# or wedged adb server must fail this phase before the outer Actions job limit.
termux_adb() {
  local timeout_seconds=$1
  shift

  timeout --kill-after=5 "$timeout_seconds" adb "$@"
}

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

  return 1
}
