#!/bin/sh

install_dotfiles_bootstrap_prereqs() {
  # Keep the deliberately small bootstrap base here, while sourcing commands
  # used by the portable dotfiles suites from capability profiles. This keeps
  # package-name policy reusable and prevents the named setup from drifting
  # away from normal shell CI on minimal images.
  dotfiles_caller_profiles=${PROFILES:-}
  reset_profile_prereqs
  case "$MATRIX_NAME" in
    macOS)
      add_pkg brew_pkgs "bash"
      ;;
    Debian)
      add_pkg apt_pkgs \
        "git curl sudo openssh-client lsof netcat-openbsd procps"
      ;;
    Arch)
      add_pkg arch_pkgs "git curl sudo openssh lsof openbsd-netcat"
      ;;
    CentOS* | Fedora)
      add_pkg dnf_pkgs \
        "git curl sudo openssh-clients lsof nmap-ncat procps-ng"
      ;;
    Alpine)
      add_pkg apk_pkgs \
        "git curl sudo bash coreutils shellcheck lua5.4 openssh-client lsof netcat-openbsd procps"
      ;;
  esac

  # Python runs dot-test's portable timeout supervisor; keep it part of the
  # named setup so every dotfiles consumer gets the same bounded test runner.
  PROFILES=cron,fd,ripgrep,hostname,python
  collect_profile_prereqs
  install_package_lists
  PROFILES=$dotfiles_caller_profiles

  if [ "$MATRIX_NAME" = Alpine ]; then
    # Dotfiles' Lua suite is a direct test contract. Alpine cannot run the
    # bootstrapped glibc Neovim fallback, so provide the plain lua command.
    ensure_lua_command
  fi
}
