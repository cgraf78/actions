#!/bin/sh

# Shared bounded package-manager policy for composite actions. Keep transport
# options and retry classification here so Rust, musl, and shell setup fail in
# the same bounded, retryable way when a runner mirror stops transferring.
PKG_NETWORK_TIMEOUT=${PKG_NETWORK_TIMEOUT:-30}
PKG_COMMAND_TIMEOUT=${PKG_COMMAND_TIMEOUT:-50}
PKG_COMMAND_KILL_AFTER=${PKG_COMMAND_KILL_AFTER:-5}
PKG_RETRIES=${PKG_RETRIES:-3}

# These globals are the sourceable library's public interface.
# shellcheck disable=SC2034
APT_NET_OPTS="-o Acquire::http::Timeout=$PKG_NETWORK_TIMEOUT -o Acquire::https::Timeout=$PKG_NETWORK_TIMEOUT -o Acquire::Retries=$PKG_RETRIES"
# shellcheck disable=SC2034
DNF_NET_OPTS="--setopt=timeout=$PKG_NETWORK_TIMEOUT --setopt=retries=$PKG_RETRIES"
# shellcheck disable=SC2034
APK_NET_OPTS="--timeout $PKG_NETWORK_TIMEOUT"

if command -v sudo >/dev/null 2>&1; then
  SUDO=sudo
else
  # shellcheck disable=SC2034
  SUDO=
fi

bounded() {
  if command -v timeout >/dev/null 2>&1; then
    timeout -k "$PKG_COMMAND_KILL_AFTER" "$PKG_COMMAND_TIMEOUT" "$@"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$PKG_COMMAND_TIMEOUT" "$PKG_COMMAND_KILL_AFTER" "$@" <<'PY'
import os
import signal
import subprocess
import sys

timeout = float(sys.argv[1])
grace = float(sys.argv[2])
process = subprocess.Popen(sys.argv[3:], start_new_session=True)
try:
    status = process.wait(timeout=timeout)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    try:
        status = process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        status = 124

sys.exit(status if status >= 0 else 128 - status)
PY
  else
    echo 'bounded package command requires timeout or python3' >&2
    return 127
  fi
}

retry_pkg() {
  _attempt=1
  while :; do
    if bounded "$@"; then
      return 0
    else
      _rc=$?
    fi
    if [ "$_attempt" -ge "$PKG_RETRIES" ]; then
      echo "infra-stall: package command exhausted bounded retries" >&2
      echo "package command failed after $PKG_RETRIES attempts (exit $_rc): $*" >&2
      return "$_rc"
    fi
    _delay=$((_attempt * 5))
    echo "package command failed (attempt $_attempt/$PKG_RETRIES, exit $_rc); retrying in ${_delay}s..." >&2
    sleep "$_delay"
    _attempt=$((_attempt + 1))
  done
}
