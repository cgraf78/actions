#!/bin/sh
set -eu

sudo_if_available() {
  # Hosted Linux runners have sudo, but most container jobs run as root without
  # sudo installed. This helper lets the same package code work in both places.
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

has_profile() {
  # Profiles are passed as a comma-separated string because GitHub reusable
  # workflow inputs do not have an array type. Surrounding with commas avoids
  # false positives such as matching "py" inside "python".
  case ",$PROFILES," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

add_pkg() {
  # Store package lists as strings because every supported package manager
  # accepts plain argv words. The only input to this function is trusted profile
  # metadata below, not caller-provided package names.
  eval "$1=\"\${$1:+\${$1} }$2\""
}

install_yq() {
  # Some distro package managers ship old or incompatible yq variants. checkrun
  # expects mikefarah/yq v4 behavior, so install the upstream binary whenever a
  # suitable v4 command is not already present.
  if command -v yq >/dev/null 2>&1 &&
    yq --version 2>/dev/null | grep -q 'version v4'; then
    return
  fi

  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    *)
      echo "unsupported yq OS: $(uname -s)" >&2
      exit 1
      ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=amd64 ;;
    arm64 | aarch64) arch=arm64 ;;
    *)
      echo "unsupported yq arch: $(uname -m)" >&2
      exit 1
      ;;
  esac

  tmp="${RUNNER_TEMP:-/tmp}/yq"
  curl -fsSL "https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_${os}_${arch}" -o "$tmp"
  chmod +x "$tmp"
  sudo_if_available mv "$tmp" /usr/local/bin/yq
}

ensure_lua() {
  # Debian and Alpine install Lua 5.4 as lua5.4. termnav's tests expect the
  # portable command name "lua", so add a compatibility symlink when needed.
  if command -v lua >/dev/null 2>&1; then
    return
  fi
  if command -v lua5.4 >/dev/null 2>&1; then
    sudo_if_available ln -sf "$(command -v lua5.4)" /usr/local/bin/lua
  fi
}

install_profile_prereqs() {
  brew_pkgs=
  apt_pkgs=
  arch_pkgs=
  dnf_pkgs=
  apk_pkgs=

  # Profiles are the shared contract for normal repos. Callers describe
  # capabilities they need; this action owns distro package names so every repo
  # does not grow its own copy.
  #
  # Keep these profiles capability-oriented instead of repo-oriented. Repo
  # special cases belong in named setup modes below; common tools belong here.
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
    add_pkg dnf_pkgs "python3"
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
    # CentOS Stream/Fedora intentionally skip Neovim to match the existing
    # termnav workflow's lower-friction dnf dependency set.
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
  if has_profile shellcheck; then
    add_pkg brew_pkgs "shellcheck"
    add_pkg apt_pkgs "shellcheck"
    add_pkg arch_pkgs "shellcheck"
    add_pkg dnf_pkgs "ShellCheck"
    add_pkg apk_pkgs "shellcheck"
  fi

  install_package_lists

  if has_profile lua; then
    ensure_lua
  fi
  if has_profile yq && [ "$MATRIX_NAME" != "Alpine" ]; then
    install_yq
  fi
}

install_checkrun_prereqs() {
  # checkrun has a broader formatting/toolchain surface than the small shell
  # tools. Keep that bootstrap centralized here without making every repo pay
  # for these packages.
  case "$MATRIX_NAME" in
    macOS)
      brew install bash jq yq python zsh
      ;;
    Debian | Ubuntu | WSL)
      sudo_if_available apt-get update
      sudo_if_available apt-get install -y bash git curl ca-certificates jq python3 python3-pip python3-venv zsh tar gzip unzip xz-utils
      install_yq
      ;;
    Arch)
      pacman-key --init
      pacman-key --populate
      pacman -Syu --noconfirm bash git curl ca-certificates jq python python-pip zsh tar gzip unzip xz
      install_yq
      ;;
    CentOS* | Fedora)
      dnf install -y --allowerasing bash git curl ca-certificates jq python3 python3-pip zsh tar gzip unzip xz
      install_yq
      ;;
    Alpine)
      # Alpine keeps the smaller historical package set. The later mise/Rust
      # setup step is skipped on Alpine by the workflow.
      apk add --no-cache bash git curl ca-certificates jq python3 tar gzip unzip xz
      ;;
  esac
}

install_dotfiles_bootstrap_prereqs() {
  # Dotfiles CI intentionally installs only this small package set from the
  # workflow. The behavior under test is that dot update/shdeps can install the
  # real toolchain itself, so do not replace this with broader generic profiles.
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

install_package_lists() {
  # Only the generic profile path reaches this function. Named setup modes use
  # explicit package commands above because their package boundaries are part of
  # those repos' CI contracts.
  case "$MATRIX_NAME" in
    macOS)
      if [ -n "$brew_pkgs" ]; then
        # Package lists are assembled by trusted profile names above.
        # shellcheck disable=SC2086
        brew install $brew_pkgs
      fi
      ;;
    Debian | Ubuntu | WSL)
      if [ -n "$apt_pkgs" ]; then
        sudo_if_available apt-get update
        # Package lists are assembled by trusted profile names above.
        # shellcheck disable=SC2086
        sudo_if_available apt-get install -y $apt_pkgs
      fi
      ;;
    Arch)
      pacman-key --init
      pacman-key --populate
      if [ -n "$arch_pkgs" ]; then
        # Package lists are assembled by trusted profile names above.
        # shellcheck disable=SC2086
        pacman -Syu --noconfirm $arch_pkgs
      fi
      ;;
    CentOS* | Fedora)
      if [ -n "$dnf_pkgs" ]; then
        # Package lists are assembled by trusted profile names above.
        # shellcheck disable=SC2086
        dnf install -y --allowerasing $dnf_pkgs
      fi
      ;;
    Alpine)
      if [ -n "$apk_pkgs" ]; then
        # Package lists are assembled by trusted profile names above.
        # shellcheck disable=SC2086
        apk add --no-cache $apk_pkgs
      fi
      ;;
  esac
}

case "$SETUP" in
  none)
    # Normal shell-tool repos use shared profiles and one repo-owned test
    # command. This is the default path for termnav, sley, cmdblocks,
    # agentguard, and ds.
    install_profile_prereqs
    ;;
  checkrun)
    # checkrun needs a larger base image before its dev-tool bootstrap can run.
    # Keep it as a named path instead of bloating the generic profiles.
    install_checkrun_prereqs
    ;;
  dotfiles)
    # Dotfiles keeps an exact, intentionally small package list because shdeps
    # installation behavior is what the CI is validating.
    install_dotfiles_bootstrap_prereqs
    ;;
  *)
    echo "unsupported setup mode: $SETUP" >&2
    exit 2
    ;;
esac
