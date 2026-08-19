#!/bin/sh

install_checkrun_prereqs() {
  # checkrun has a broader formatting/toolchain surface than the small shell
  # tools. Keep that bootstrap centralized without making every repo pay for
  # these packages.
  case "$MATRIX_NAME" in
    macOS)
      retry_pkg brew install bash jq yq python zsh
      ;;
    Debian | Ubuntu | WSL)
      # Keep this named setup behind the same native transfer limits and hard
      # supervisor as profile-based installs. Otherwise a checkrun consumer
      # can still spend the whole outer prerequisite cap on one apt mirror.
      # shellcheck disable=SC2086
      retry_pkg $SUDO apt-get $APT_NET_OPTS update
      # shellcheck disable=SC2086
      retry_pkg $SUDO apt-get $APT_NET_OPTS install -y bash git curl ca-certificates jq python3 python3-pip python3-venv zsh tar gzip unzip xz-utils
      install_yq_v4
      ;;
    Arch)
      pacman-key --init
      pacman-key --populate
      retry_pkg pacman -Syu --noconfirm bash git curl ca-certificates jq python python-pip zsh tar gzip unzip xz
      install_yq_v4
      ;;
    CentOS* | Fedora)
      # shellcheck disable=SC2086
      retry_pkg dnf $DNF_NET_OPTS install -y --allowerasing bash git curl ca-certificates jq python3 python3-pip zsh tar gzip unzip xz
      install_yq_v4
      ;;
    Alpine)
      # Alpine keeps the smaller historical package set. The later mise/Rust
      # setup step is skipped on Alpine by the workflow.
      # shellcheck disable=SC2086
      retry_pkg apk $APK_NET_OPTS add --no-cache bash git curl ca-certificates jq python3 tar gzip unzip xz
      ;;
  esac
}
