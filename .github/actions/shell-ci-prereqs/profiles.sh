#!/bin/sh

reset_profile_prereqs() {
  # These package-list variables are consumed by install_package_lists in
  # lib.sh. ShellCheck cannot see that cross-file use when this module is
  # checked directly.
  # shellcheck disable=SC2034
  brew_pkgs=
  # shellcheck disable=SC2034
  apt_pkgs=
  # shellcheck disable=SC2034
  arch_pkgs=
  # shellcheck disable=SC2034
  dnf_pkgs=
  # shellcheck disable=SC2034
  apk_pkgs=
}

collect_profile_prereqs() {
  # Profiles are capability-oriented. Repo-specific package boundaries belong
  # in named setup modes such as checkrun or dotfiles.
  if has_profile base; then
    add_pkg brew_pkgs "bash"
    add_pkg apt_pkgs "bash git curl ca-certificates"
    add_pkg arch_pkgs "bash git curl ca-certificates"
    add_pkg dnf_pkgs "bash git curl ca-certificates"
    add_pkg apk_pkgs "bash git curl ca-certificates"
  fi
  if has_profile jq; then
    add_pkg brew_pkgs "jq"
    add_pkg apt_pkgs "jq"
    add_pkg arch_pkgs "jq"
    add_pkg dnf_pkgs "jq"
    add_pkg apk_pkgs "jq"
  fi
  if has_profile python; then
    add_pkg brew_pkgs "python"
    add_pkg apt_pkgs "python3"
    add_pkg arch_pkgs "python"
    case "$MATRIX_NAME" in
      CentOS*) add_pkg dnf_pkgs "python3.11" ;;
      *) add_pkg dnf_pkgs "python3" ;;
    esac
    add_pkg apk_pkgs "python3"
  fi
  if has_profile zsh; then
    add_pkg brew_pkgs "zsh"
    add_pkg apt_pkgs "zsh"
    add_pkg arch_pkgs "zsh"
    add_pkg dnf_pkgs "zsh"
    add_pkg apk_pkgs "zsh"
  fi
  if has_profile lua; then
    add_pkg brew_pkgs "lua"
    add_pkg apt_pkgs "lua5.4"
    add_pkg arch_pkgs "lua"
    add_pkg dnf_pkgs "lua"
    add_pkg apk_pkgs "lua5.4"
  fi
  if has_profile neovim; then
    add_pkg brew_pkgs "neovim"
    add_pkg apt_pkgs "neovim"
    add_pkg arch_pkgs "neovim"
    add_pkg dnf_pkgs "neovim"
    add_pkg apk_pkgs "neovim"
  fi
  if has_profile tmux; then
    add_pkg brew_pkgs "tmux"
    add_pkg apt_pkgs "tmux"
    add_pkg arch_pkgs "tmux"
    add_pkg dnf_pkgs "tmux"
    add_pkg apk_pkgs "tmux"
  fi
  if has_profile openssh-netcat-lsof; then
    add_pkg apt_pkgs "lsof openssh-client netcat-openbsd"
    add_pkg arch_pkgs "lsof openssh openbsd-netcat"
    add_pkg dnf_pkgs "lsof openssh-clients nmap-ncat"
    add_pkg apk_pkgs "lsof openssh-client netcat-openbsd"
  fi
  if has_profile procps; then
    # macOS provides a compatible ps command without a Homebrew package.
    add_pkg apt_pkgs "procps"
    add_pkg arch_pkgs "procps-ng"
    add_pkg dnf_pkgs "procps-ng"
    add_pkg apk_pkgs "procps"
  fi
  if has_profile cron; then
    # macOS ships crontab as part of the base system.
    add_pkg apt_pkgs "cron"
    add_pkg arch_pkgs "cronie"
    add_pkg dnf_pkgs "cronie"
    add_pkg apk_pkgs "dcron"
  fi
  if has_profile fd; then
    add_pkg brew_pkgs "fd"
    # Debian-family distributions expose the command as fdfind so it does not
    # collide with the unrelated fd package.
    add_pkg apt_pkgs "fd-find"
    add_pkg arch_pkgs "fd"
    add_pkg dnf_pkgs "fd-find"
    add_pkg apk_pkgs "fd"
  fi
  if has_profile ripgrep; then
    add_pkg brew_pkgs "ripgrep"
    add_pkg apt_pkgs "ripgrep"
    add_pkg arch_pkgs "ripgrep"
    add_pkg dnf_pkgs "ripgrep"
    add_pkg apk_pkgs "ripgrep"
  fi
  if has_profile hostname; then
    # macOS and Alpine's BusyBox base provide hostname without an extra
    # package. Keep the profile about the command rather than package symmetry.
    add_pkg apt_pkgs "hostname"
    add_pkg arch_pkgs "inetutils"
    add_pkg dnf_pkgs "hostname"
  fi
  if has_profile shellcheck; then
    add_pkg brew_pkgs "shellcheck"
    # The shared lint leaf runs on Ubuntu. Pin its analyzer independently of
    # the runner image so coverage cannot silently regress when apt changes.
    [ "$MATRIX_NAME" = Ubuntu ] || add_pkg apt_pkgs "shellcheck"
    add_pkg arch_pkgs "shellcheck"
    add_pkg dnf_pkgs "ShellCheck"
    add_pkg apk_pkgs "shellcheck"
  fi
}

install_profile_prereqs() {
  reset_profile_prereqs
  collect_profile_prereqs

  install_package_lists

  if has_profile python; then
    ensure_modern_python
  fi
  if has_profile lua; then
    ensure_lua_command
  fi
  if has_profile shellcheck && [ "$MATRIX_NAME" = Ubuntu ]; then
    install_pinned_shellcheck
  fi
}
