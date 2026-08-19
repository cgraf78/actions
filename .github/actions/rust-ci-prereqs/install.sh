#!/bin/sh
set -eu

SCRIPT_DIR=${0%/*}
# shellcheck source=../package-manager/lib.sh
. "$SCRIPT_DIR/../package-manager/lib.sh"

case "$MATRIX_NAME" in
  macOS)
    # GitHub's macOS image already has the system linker, curl, git, and CA
    # roots needed by rustup and cargo. Avoid extra Homebrew work on the
    # slowest runner unless a future Rust repo proves it needs more.
    ;;
  Debian | Ubuntu | WSL)
    # shellcheck disable=SC2086
    retry_pkg $SUDO apt-get $APT_NET_OPTS update
    # shellcheck disable=SC2086
    retry_pkg $SUDO apt-get $APT_NET_OPTS install -y \
      bash \
      build-essential \
      ca-certificates \
      curl \
      git \
      pkg-config
    ;;
  Arch)
    pacman-key --init
    pacman-key --populate
    retry_pkg pacman -Syu --noconfirm \
      base-devel \
      bash \
      ca-certificates \
      curl \
      git \
      pkgconf
    ;;
  CentOS* | Fedora)
    # shellcheck disable=SC2086
    retry_pkg dnf $DNF_NET_OPTS install -y --allowerasing \
      bash \
      ca-certificates \
      curl \
      gcc \
      gcc-c++ \
      git \
      make \
      pkgconf-pkg-config
    ;;
  Alpine)
    # shellcheck disable=SC2086
    retry_pkg apk $APK_NET_OPTS add --no-cache \
      bash \
      build-base \
      ca-certificates \
      curl \
      git \
      pkgconf
    ;;
  *)
    echo "unsupported matrix platform: $MATRIX_NAME" >&2
    exit 2
    ;;
esac
