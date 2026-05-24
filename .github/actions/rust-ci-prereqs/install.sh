#!/bin/sh
set -eu

sudo_if_available() {
  # Hosted Linux runners have sudo, while container jobs usually run as root
  # with no sudo binary. The Rust matrix uses both forms.
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

case "$MATRIX_NAME" in
  macOS)
    # GitHub's macOS image already has the system linker, curl, git, and CA
    # roots needed by rustup and cargo. Avoid extra Homebrew work on the
    # slowest runner unless a future Rust repo proves it needs more.
    ;;
  Debian | Ubuntu | WSL)
    sudo_if_available apt-get update
    sudo_if_available apt-get install -y \
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
    pacman -Syu --noconfirm \
      base-devel \
      bash \
      ca-certificates \
      curl \
      git \
      pkgconf
    ;;
  CentOS* | Fedora)
    dnf install -y --allowerasing \
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
    apk add --no-cache \
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
