#!/usr/bin/env bash

dotfiles_bootstrap_bounded() {
  local timeout=${DOTFILES_BOOTSTRAP_COMMAND_TIMEOUT:-90}
  local grace=${DOTFILES_BOOTSTRAP_COMMAND_KILL_AFTER:-5}
  local heartbeat=${DOTFILES_BOOTSTRAP_HEARTBEAT:-60}
  local label=${DOTFILES_BOOTSTRAP_COMMAND_LABEL:-${1##*/}}

  command -v python3 >/dev/null 2>&1 || {
    echo 'dotfiles bootstrap bounded commands require python3' >&2
    return 127
  }
  python3 - "$timeout" "$grace" "$heartbeat" "$label" "$@" <<'PY'
import os
import signal
import subprocess
import sys
import time

timeout = float(sys.argv[1])
grace = float(sys.argv[2])
heartbeat = float(sys.argv[3])
label = sys.argv[4]
process = subprocess.Popen(sys.argv[5:], start_new_session=True)

class ForwardedSignal(Exception):
    def __init__(self, signum):
        self.signum = signum

def forward(signum, _frame):
    signal.signal(signum, signal.SIG_IGN)
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass
    except PermissionError:
        process.send_signal(signum)
    raise ForwardedSignal(signum)

def terminate_group(initial_signal):
    for handled_signal in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(handled_signal, signal.SIG_IGN)
    try:
        os.killpg(process.pid, initial_signal)
    except ProcessLookupError:
        pass
    except PermissionError:
        process.send_signal(initial_signal)
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            break
        except PermissionError:
            # POSIX reports EPERM when the group still exists but its remaining
            # members cannot be signaled by this user. Keep the bounded grace
            # period instead of mistaking that state for a supervisor failure.
            pass
        time.sleep(0.05)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        # The direct child belongs to this supervisor even when a privileged
        # descendant makes the process-group operation fail on macOS.
        process.kill()
    process.wait()
    try:
        os.killpg(process.pid, 0)
    except ProcessLookupError:
        pass
    except PermissionError:
        print(
            "dotfiles bootstrap cleanup: process group still contains "
            "protected descendants",
            file=sys.stderr,
        )

signal.signal(signal.SIGHUP, forward)
signal.signal(signal.SIGINT, forward)
signal.signal(signal.SIGTERM, forward)
started = time.monotonic()
deadline = started + timeout
next_heartbeat = started + heartbeat
try:
    while True:
        now = time.monotonic()
        if now >= deadline:
            raise subprocess.TimeoutExpired(process.args, timeout)
        next_event = min(deadline, next_heartbeat)
        try:
            status = process.wait(timeout=max(0.001, next_event - now))
            break
        except subprocess.TimeoutExpired:
            now = time.monotonic()
            if now >= deadline:
                raise
            if now >= next_heartbeat:
                elapsed = now - started
                print(
                    f"dotfiles bootstrap {label} command still running "
                    f"({elapsed:.0f}s elapsed)",
                    file=sys.stderr,
                )
                next_heartbeat += heartbeat
except subprocess.TimeoutExpired:
    print(
        f"infra-stall: dotfiles bootstrap {label} command timed out after "
        f"{timeout:g}s",
        file=sys.stderr,
    )
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
  local attempt rc delay attempts command_timeout
  local delays=${DOTFILES_BOOTSTRAP_RETRY_DELAYS:-15,30}
  local delay_one delay_two
  IFS=, read -r delay_one delay_two <<<"$delays"

  case $label in
    Dot)
      attempts=${DOTFILES_BOOTSTRAP_DOT_ATTEMPTS:-1}
      command_timeout=${DOTFILES_BOOTSTRAP_DOT_TIMEOUT:-900}
      ;;
    *)
      attempts=${DOTFILES_BOOTSTRAP_SHORT_ATTEMPTS:-2}
      command_timeout=${DOTFILES_BOOTSTRAP_SHORT_TIMEOUT:-90}
      ;;
  esac

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if DOTFILES_BOOTSTRAP_COMMAND_LABEL=$label \
      DOTFILES_BOOTSTRAP_COMMAND_TIMEOUT=$command_timeout \
      dotfiles_bootstrap_bounded "$@"; then
      return 0
    else
      rc=$?
    fi
    if [[ "$attempt" -eq "$attempts" ]]; then
      if [[ "$rc" -eq 124 ]]; then
        printf 'infra-stall: dotfiles bootstrap %s command exhausted bounded retries\n' \
          "$label" >&2
      fi
      return "$rc"
    fi
    if [[ "$attempt" -eq 1 ]]; then delay=${delay_one:-15}; else delay=${delay_two:-30}; fi
    printf '%s failed (attempt %s/%s, exit %s); retrying in %ss...\n' \
      "$label" "$attempt" "$attempts" "$rc" "$delay" >&2
    sleep "$delay"
  done
}
