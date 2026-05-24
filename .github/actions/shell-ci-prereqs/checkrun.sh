#!/bin/sh

install_checkrun_prereqs() {
  # checkrun has a broader formatting/toolchain surface than the small shell
  # tools. Keep that bootstrap centralized without making every repo pay for
  # these packages.
  case "$MATRIX_NAME" in
    macOS)
      brew install bash jq yq python zsh
      ;;
    Debian | Ubuntu | WSL)
      sudo_if_available apt-get update
      sudo_if_available apt-get install -y bash git curl ca-certificates jq python3 python3-pip python3-venv zsh tar gzip unzip xz-utils
      install_yq_v4
      ;;
    Arch)
      pacman-key --init
      pacman-key --populate
      pacman -Syu --noconfirm bash git curl ca-certificates jq python python-pip zsh tar gzip unzip xz
      install_yq_v4
      ;;
    CentOS* | Fedora)
      dnf install -y --allowerasing bash git curl ca-certificates jq python3 python3-pip zsh tar gzip unzip xz
      install_yq_v4
      ;;
    Alpine)
      # Alpine keeps the smaller historical package set. The later mise/Rust
      # setup step is skipped on Alpine by the workflow.
      apk add --no-cache bash git curl ca-certificates jq python3 tar gzip unzip xz
      ;;
  esac
}
