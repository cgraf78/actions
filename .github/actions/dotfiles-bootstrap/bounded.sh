#!/usr/bin/env bash

dotfiles_bootstrap_bounded() {
  local timeout=${DOTFILES_BOOTSTRAP_COMMAND_TIMEOUT:-90}
  local grace=${DOTFILES_BOOTSTRAP_COMMAND_KILL_AFTER:-5}

  command -v python3 >/dev/null 2>&1 || {
    echo 'dotfiles bootstrap bounded commands require python3' >&2
    return 127
  }
  python3 - "$timeout" "$grace" "$@" <<'PY'
import os
import signal
import subprocess
import sys
import time

timeout = float(sys.argv[1])
grace = float(sys.argv[2])
process = subprocess.Popen(sys.argv[3:], start_new_session=True)

class ForwardedSignal(Exception):
    def __init__(self, signum):
        self.signum = signum

def forward(signum, _frame):
    signal.signal(signum, signal.SIG_IGN)
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass
    raise ForwardedSignal(signum)

def terminate_group(initial_signal):
    for handled_signal in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(handled_signal, signal.SIG_IGN)
    try:
        os.killpg(process.pid, initial_signal)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.05)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()

signal.signal(signal.SIGHUP, forward)
signal.signal(signal.SIGINT, forward)
signal.signal(signal.SIGTERM, forward)
try:
    status = process.wait(timeout=timeout)
except subprocess.TimeoutExpired:
    terminate_group(signal.SIGTERM)
    status = 124
except ForwardedSignal as interruption:
    terminate_group(interruption.signum)
    status = 128 + interruption.signum

sys.exit(status if status >= 0 else 128 - status)
PY
}

dotfiles_bootstrap_retry() {
  local label=$1
  shift
  local attempt rc delay
  local delays=${DOTFILES_BOOTSTRAP_RETRY_DELAYS:-15,30}
  local delay_one delay_two
  IFS=, read -r delay_one delay_two <<<"$delays"

  for attempt in 1 2 3; do
    if dotfiles_bootstrap_bounded "$@"; then
      return 0
    else
      rc=$?
    fi
    if [[ "$attempt" -eq 3 ]]; then
      if [[ "$rc" -eq 124 ]]; then
        printf 'infra-stall: dotfiles bootstrap %s command exhausted bounded retries\n' \
          "$label" >&2
      fi
      return "$rc"
    fi
    if [[ "$attempt" -eq 1 ]]; then delay=${delay_one:-15}; else delay=${delay_two:-30}; fi
    printf '%s failed (attempt %s/3, exit %s); retrying in %ss...\n' \
      "$label" "$attempt" "$rc" "$delay" >&2
    sleep "$delay"
  done
}
