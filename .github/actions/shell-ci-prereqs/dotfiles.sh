#!/bin/sh

install_dotfiles_bootstrap_prereqs() {
  # Dotfiles CI intentionally installs only this exact package set from the
  # workflow. The behavior under test is that dot update/shdeps can install the
  # real toolchain itself, so do not route dotfiles through generic profiles.
  case "$MATRIX_NAME" in
    macOS)
      brew install bash
      ;;
    Debian)
      apt-get update && apt-get install -y git curl sudo openssh-client lsof netcat-openbsd
      ;;
    Arch)
      pacman-key --init && pacman-key --populate
      pacman -Syu --noconfirm git curl sudo openssh lsof openbsd-netcat
      ;;
    CentOS* | Fedora)
      dnf install -y --allowerasing git curl sudo openssh-clients lsof nmap-ncat
      ;;
    Alpine)
      apk add --no-cache git curl sudo bash coreutils shellcheck openssh-client lsof netcat-openbsd
      ;;
    Ubuntu | WSL)
      # Hosted Ubuntu/WSL runners keep their default image packages. This
      # mirrors the original dotfiles workflow exactly.
      ;;
  esac
}
