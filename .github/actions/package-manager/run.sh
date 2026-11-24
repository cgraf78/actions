#!/bin/sh
# The runner signals only this PID. Keep it alive until package cleanup ends.
set -u

# shellcheck source=./lib.sh
. "${0%/*}/lib.sh"

step_dir=''
step_worker=''
step_signal=''
step_group=false

step_cleanup() {
  [ -z "$step_dir" ] || rm -rf -- "$step_dir"
}

step_signal_worker() {
  if [ "$step_group" = true ]; then
    _pkg_signal_group "$1" "$step_worker"
  else
    kill -s "$1" "$step_worker" 2>/dev/null || :
  fi
}

step_has_watchdog() {
  for state in "$step_dir/$_PKG_DEADLINE_PREFIX"*; do
    [ ! -f "$state/$_PKG_DEADLINE_ACTIVE" ] || return 0
  done
  return 1
}

step_cancel() {
  step_signal=${step_signal:-$1}
  # A signal during startup is handled after the worker PID is registered.
  [ -n "$step_worker" ] || return 0
  trap '' HUP INT TERM

  if ! printf '%s\n' "$step_signal" >"$_PKG_STEP_CANCEL_FILE"; then
    step_signal_worker TERM
  fi
  idle=0
  while kill -0 "$step_worker" 2>/dev/null; do
    if step_has_watchdog; then
      # The watchdog owns its separate package group and its TERM grace.
      idle=0
    else
      # Let the cancellation unwind through the installer and any staging
      # subshells. An installer blocked outside the watchdog still gets TERM.
      idle=$((idle + 1))
      if [ "$idle" -ge 5 ]; then
        step_signal_worker TERM
        sleep 0.25
        if kill -0 "$step_worker" 2>/dev/null; then
          step_signal_worker KILL
        fi
        break
      fi
    fi
    sleep 0.05
  done
  wait "$step_worker" 2>/dev/null || :
  exit "$step_signal"
}

trap step_cleanup EXIT
trap 'step_cancel 129' HUP
trap 'step_cancel 130' INT
trap 'step_cancel 143' TERM

step_temp=${TMPDIR:-/tmp}
case "$step_temp" in
  /*) ;;
  # Installers may change directory before invoking the watchdog.
  *) step_temp=$(pwd -P)/"$step_temp" || exit 125 ;;
esac
step_dir=$(mktemp -d "$step_temp/package-step.XXXXXX") || exit 125
[ -z "$step_signal" ] || exit "$step_signal"
_PKG_STEP_CANCEL_FILE="$step_dir/cancel"
export _PKG_STEP_CANCEL_FILE

# Preserve stdin despite using an asynchronous worker so wait is interruptible.
exec 5<&0
if _pkg_can_start_session; then
  step_group=true
  set +m
  _pkg_session "$@" <&5 5<&- &
else
  # Some platform branches are no-ops. Let them keep working without a
  # session launcher, and let bounded report its usual dependency error.
  "$@" <&5 5<&- &
fi
step_worker=$!
exec 5<&-
[ -z "$step_signal" ] || step_cancel "$step_signal"
wait "$step_worker"
