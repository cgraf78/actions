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
    if bounded "$@"; then
      return 0
    else
      _rc=$?
    fi
    if [ "$_attempt" -ge "$PKG_RETRIES" ]; then
      # Exit 124 is the owned supervisor deadline. Package-manager semantic
      # failures keep their native status and must not opt a workflow into an
      # infrastructure rerun.
      if [ "$_rc" -eq 124 ]; then
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
