#!/bin/sh

# Shared bounded package-manager policy for composite actions. Keep transport
# options and retry classification here so Rust, musl, and shell setup fail in
# the same bounded, retryable way when a runner mirror stops transferring.
PKG_NETWORK_TIMEOUT=${PKG_NETWORK_TIMEOUT:-30}
PKG_COMMAND_TIMEOUT=${PKG_COMMAND_TIMEOUT:-120}
PKG_COMMAND_KILL_AFTER=${PKG_COMMAND_KILL_AFTER:-5}
PKG_RETRIES=${PKG_RETRIES:-3}

# Provider-owned stall token. This POSIX library cannot locate the shared
# marker file, so the literal is defined once here; keep it identical to
# PACKAGE_COMMAND_STALL_MARKER in shared/infra-stall-markers.sh, which the
# infrastructure retry classifier matches on.
PKG_STALL_MARKER='infra-stall: package command exhausted bounded retries'

# These globals are the sourceable library's public interface.
# shellcheck disable=SC2034
APT_NET_OPTS="-o Acquire::http::Timeout=$PKG_NETWORK_TIMEOUT -o Acquire::https::Timeout=$PKG_NETWORK_TIMEOUT -o Acquire::Retries=$PKG_RETRIES"
# shellcheck disable=SC2034
DNF_NET_OPTS="--setopt=timeout=$PKG_NETWORK_TIMEOUT --setopt=retries=$PKG_RETRIES"
# shellcheck disable=SC2034
APK_NET_OPTS="--timeout $PKG_NETWORK_TIMEOUT"
# Container images set neither TERM nor a debconf frontend, so every package
# configuration walks debconf's Dialog -> Readline -> Teletype fallback and
# prints each failure; hosted Ubuntu runners print none of this. Select the
# noninteractive frontend through `env` so it survives a `sudo` prefix that
# resets the environment.
# shellcheck disable=SC2034
APT_GET="env DEBIAN_FRONTEND=noninteractive apt-get"

# Hosted images already carry some requested packages, and Homebrew prints an
# "already installed and up-to-date" warning for each one. `--quiet` drops that
# warning along with caveats and other advisory notes; missing or outdated
# formulae still install, and real failures keep their exit status.
# shellcheck disable=SC2034
BREW_INSTALL_OPTS="--quiet"
# `--needed` stops pacman reinstalling packages that are already current. It
# still warns "up to date -- skipping" for each such target, so pacman_install
# also names only missing targets through pacman_missing.
# shellcheck disable=SC2034
PACMAN_SYNC_OPTS="--noconfirm --needed"

if command -v sudo >/dev/null 2>&1; then
  SUDO=sudo
else
  # shellcheck disable=SC2034
  SUDO=
fi

configure_ubuntu_archive_mirror() {
  _mirror_list=${APT_MIRROR_LIST:-/etc/apt/apt-mirrors.txt}
  _archive_mirror=https://archive.ubuntu.com/ubuntu

  # GitHub's Ubuntu runner mirrorlist currently prefers a cloud regional
  # mirror (Azure, or the EC2 mirror on AWS-hosted runners). When that
  # endpoint accepts connections but stops serving, apt's fallback still
  # leaves package requests assigned to it, so a slow mirror stalls the
  # whole install past the bounded command timeout. Use Ubuntu's official
  # archive directly. A file naming a cloud regional mirror is replaced
  # wholesale with the official archive; official country mirrors,
  # mirrorlists that already point at the official archive, and
  # non-mirrorlist configurations stay intact.
  # Match the host, not the path, so port-qualified entries are caught too;
  # the match is case-insensitive because DNS hostnames are.
  if [ ! -f "$_mirror_list" ] || [ -L "$_mirror_list" ] ||
    ! grep -Fiq -e 'azure.archive.ubuntu.com' \
      -e '.ec2.archive.ubuntu.com' -e '.gce.archive.ubuntu.com' \
      "$_mirror_list"; then
    return 0
  fi

  if [ -w "$_mirror_list" ]; then
    printf '%s\n' "$_archive_mirror" >"$_mirror_list"
  elif [ -n "$SUDO" ]; then
    printf '%s\n' "$_archive_mirror" | "$SUDO" tee "$_mirror_list" >/dev/null
  else
    printf 'cannot replace unreliable Ubuntu mirrorlist: %s\n' \
      "$_mirror_list" >&2
    return 1
  fi
  printf 'package manager: using %s instead of cloud mirrorlist\n' \
    "$_archive_mirror" >&2
}

# Print the requested pacman targets that no installed package satisfies, one
# per line. pacman_install's `pacman -Syu` still upgrades everything already
# installed, so naming only missing targets changes no package outcome; it only
# avoids pacman's per-target "up to date" warning. Any other query status
# prints the full request so the install still runs and reports the problem.
# Status 127 is also the shell's "command not found", but pacman_install's
# preceding sync has already failed the same way, so nothing is hidden.
pacman_missing() {
  if _missing=$(pacman -T "$@"); then
    return 0
  else
    _rc=$?
  fi
  if [ "$_rc" -eq 127 ]; then
    printf '%s\n' "$_missing"
  else
    printf '%s\n' "$@"
  fi
}

# Upgrade the system and install the requested targets. pacman registers every
# configured sync database at startup and, for any operation but a sync, warns
# "database file for 'core' does not exist" for each one the container image
# ships without, so the pacman_missing query must wait for a first `-Sy`. The
# install keeps `-y`: once the databases exist it costs one freshness check
# and no warning, and each retry still picks up databases a mirror replaced
# mid-run instead of chasing packages they no longer list. A sync that
# exhausts its retries stops before the query and install.
pacman_install() {
  # shellcheck disable=SC2086
  retry_pkg pacman -Sy $PACMAN_SYNC_OPTS || return
  # shellcheck disable=SC2046,SC2086
  retry_pkg pacman -Syu $PACMAN_SYNC_OPTS $(pacman_missing "$@")
}

_pkg_session() {
  if command -v setsid >/dev/null 2>&1; then
    exec setsid "$@"
  fi
  # Stock macOS has no setsid utility. Use Python only to create the same
  # session as the util-linux and BusyBox variants do on Linux.
  exec python3 -c '
import os
import sys

os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])
' "$@"
}

# The session may still be starting when interrupted. If the group does
# not exist yet, signal the launcher too, then check for a racing setsid.
_pkg_signal_group() {
  # Dash and Bash 3.2 parse a negative group ID after -s as another
  # option. BusyBox instead rejects --, so spell the signal as -TERM.
  if ! kill "-$1" "-$2" 2>/dev/null; then
    kill -s "$1" "$2" 2>/dev/null || :
    kill "-$1" "-$2" 2>/dev/null || :
  fi
}

# This runs only in the supervisor's background subshell. An interrupted
# timer must reap its own sleep before the caller removes its state directory.
_pkg_timer() {
  timer_child=
  timer_stopped=false
  # shellcheck disable=SC2329 # Reached by the timer's signal traps.
  _pkg_stop_timer() {
    timer_stopped=true
    [ -n "$timer_child" ] || return 0
    trap '' HUP INT TERM
    kill -s TERM "$timer_child" 2>/dev/null || :
    wait "$timer_child" 2>/dev/null || :
    exit 0
  }
  trap _pkg_stop_timer HUP INT TERM
  command sleep "$PKG_COMMAND_TIMEOUT" &
  timer_child=$!
  # A signal between the fork and assignment is handled once we have $!.
  [ "$timer_stopped" = false ] || _pkg_stop_timer
  wait "$timer_child" || return "$?"
  timer_child=
  printf 'deadline\n' >"$pkg_dir/timeout" &&
    { ln "$pkg_dir/timeout" "$pkg_dir/result" 2>/dev/null || [ -f "$pkg_dir/result" ]; }
}

_pkg_bounded() (
  if ! command -v setsid >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    echo 'bounded package command requires setsid or python3' >&2
    exit 127
  fi

  pkg_dir='' pkg_worker='' pkg_timer='' pkg_status='' pkg_finished=false
  # shellcheck disable=SC2329 # Invoked by the EXIT trap.
  _pkg_cleanup() {
    trap '' HUP INT TERM
    if [ -n "$pkg_timer" ]; then
      kill -s TERM "$pkg_timer" 2>/dev/null || :
      wait "$pkg_timer" 2>/dev/null || :
    fi
    if [ -n "$pkg_worker" ]; then
      if [ "$pkg_finished" = true ]; then
        # The package completed normally. Release only the stopped wrapper
        # so package hooks keep their normal process behavior.
        kill -s KILL "$pkg_worker" 2>/dev/null || :
      else
        _pkg_signal_group KILL "$pkg_worker"
      fi
      wait "$pkg_worker" 2>/dev/null || :
    fi
    [ -z "$pkg_dir" ] || rm -rf "$pkg_dir"
  }
  trap _pkg_cleanup EXIT
  trap 'pkg_status=${pkg_status:-129}' HUP
  trap 'pkg_status=${pkg_status:-130}' INT
  trap 'pkg_status=${pkg_status:-143}' TERM
  pkg_dir=$(mktemp -d "${TMPDIR:-/tmp}/package-deadline.XXXXXX") || exit 125
  [ -z "$pkg_status" ] || exit "$pkg_status"

  # setsid stays in the launcher's PID when the caller has disabled job
  # control. Keep that process in the group through teardown, even when
  # the package exits on TERM but its descendants keep running.
  set +m
  exec 5<&0
  # shellcheck disable=SC2016 # The session shell expands its own arguments.
  _pkg_session sh -c '
    state_dir=$1
    shift
    stopping=false
    trap "stopping=true" HUP INT TERM
    "$@" <&5 5<&- &
    child=$!
    status=0
    wait "$child" || status=$?
    if [ "$stopping" = true ]; then
      # A trapped signal can interrupt wait before the child is reaped.
      wait "$child" || :
    else
      printf "%s\n" "$status" >"$state_dir/command" &&
        { ln "$state_dir/command" "$state_dir/result" 2>/dev/null ||
          [ -f "$state_dir/result" ]; } || exit 125
    fi
    kill -s STOP "$$"
  ' package-worker "$pkg_dir" "$@" 3>&- &
  pkg_worker=$!
  exec 5<&-
  _pkg_timer 3>&- &
  pkg_timer=$!

  while [ -z "$pkg_status" ]; do
    if ! kill -0 "$pkg_worker" 2>/dev/null; then
      # A failed launcher is a normal error, even if the timer also fired.
      pkg_status=0
      wait "$pkg_worker" || pkg_status=$?
      pkg_worker=
      exit "$pkg_status"
    fi
    # The timer and command publish their fully written results with the
    # same exclusive link. A delayed observer cannot reorder those events.
    if [ -f "$pkg_dir/result" ]; then
      read -r pkg_result <"$pkg_dir/result" || exit 125
      if [ "$pkg_result" = deadline ]; then
        # The timer reached its terminal state. Reap its handle before
        # waiting out the package group's TERM grace.
        if [ -n "$pkg_timer" ]; then
          wait "$pkg_timer" || exit 125
          pkg_timer=
        fi
        pkg_status=124
        printf 'deadline\n' >&3
        break
      fi
      pkg_finished=true
      exit "$pkg_result"
    fi
    if [ -n "$pkg_timer" ] && ! kill -0 "$pkg_timer" 2>/dev/null; then
      wait "$pkg_timer" || exit 125
      pkg_timer=
      continue
    fi
    command sleep 0.05
  done

  trap '' HUP INT TERM
  _pkg_signal_group TERM "$pkg_worker"
  command sleep "$PKG_COMMAND_KILL_AFTER" || :
  exit "$pkg_status"
)

bounded() {
  # Capture only the supervisor event. Preserve the command's stdin,
  # streaming stdout and stderr, and native exit status.
  { _pkg_deadline=$(_pkg_bounded "$@" 3>&1 1>&4 4>&-); } 4>&1
}

# Whether the requested command is an `apt-get update`: the one
# `apt-get` invocation whose failure modes are index-fetch failures
# rather than package semantics. Both the mirror guard and the stall
# classification use this single definition so they cannot diverge.
apt_get_update_command() {
  case "$*" in
    *apt-get*' update') return 0 ;;
    *) return 1 ;;
  esac
}

retry_pkg() {
  if apt_get_update_command "$@"; then
    configure_ubuntu_archive_mirror
  fi
  _attempt=1
  while :; do
    _pkg_deadline=
    if bounded "$@"; then
      return 0
    else
      _rc=$?
    fi
    if [ "$_attempt" -ge "$PKG_RETRIES" ]; then
      # Only a deadline observed by this supervisor opts the workflow into
      # an infrastructure rerun.
      if [ "$_pkg_deadline" = deadline ]; then
        echo "$PKG_STALL_MARKER" >&2
      fi
      if apt_get_update_command "$@"; then
        # `apt-get update` fetches indexes and installs nothing. In the
        # prereq actions its sources are runner-owned, so an exhausted
        # exit 100 is treated as infrastructure: a mirror answering an
        # InRelease with a 5xx page exits 100 instead of stalling to
        # the 124 deadline, which is the same transient outage. This
        # deliberately does not distinguish a permanent update failure
        # (404, malformed sources) from a transient one: the retry
        # controller reruns at most once, and a permanent failure stays
        # red after it. The log classifier still applies its 5xx
        # discrimination to pre-token logs and to installs, whose exit
        # 100 means held or broken packages and keeps its native
        # status here. Other update exits keep theirs too.
        if [ "$_rc" -eq 100 ]; then
          echo "$PKG_STALL_MARKER" >&2
        fi
      fi
      echo "package command failed after $PKG_RETRIES attempts (exit $_rc): $*" >&2
      return "$_rc"
    fi
    _delay=$((_attempt * 5))
    echo "package command failed (attempt $_attempt/$PKG_RETRIES, exit $_rc); retrying in ${_delay}s..." >&2
    sleep "$_delay"
    # A bounded-timeout kill can interrupt dpkg mid-unpack. Without recovery
    # the next install attempt then fails with exit 100 ("dpkg was
    # interrupted") even though the package set is fine, turning a transient
    # stall into a permanent failure. dpkg --configure -a completes the
    # interrupted configuration and is a no-op on a healthy system.
    case "$*" in
      *apt-get*install* | *apt*' install'*)
        # shellcheck disable=SC2086
        bounded $SUDO env DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
        ;;
    esac
    _attempt=$((_attempt + 1))
  done
}
