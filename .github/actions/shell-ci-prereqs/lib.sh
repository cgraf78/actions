#!/bin/sh

sudo_if_available() {
  # Hosted Linux runners have sudo, but most container jobs run as root without
  # sudo installed. This helper lets package commands work in both places.
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

has_profile() {
  # Reusable workflow inputs do not have an array type. Surrounding the
  # comma-separated profile string avoids false positives like matching "py"
  # inside "python".
  case ",$PROFILES," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

needs_centos_epel() {
  has_profile shellcheck || has_profile neovim
}

add_pkg() {
  # Package lists are built from trusted profile metadata in profiles.sh, not
  # from caller-provided package names.
  eval "$1=\"\${$1:+\${$1} }$2\""
}

install_package_lists() {
  # Only generic profiles reach this function. Named setup modes use explicit
  # commands because their package boundaries are part of repo-specific CI
  # contracts.
  case "$MATRIX_NAME" in
    macOS)
      if [ -n "$brew_pkgs" ]; then
        # Package lists are assembled by trusted profile names.
        # shellcheck disable=SC2086
        brew install $brew_pkgs
      fi
      ;;
    Debian | Ubuntu | WSL)
      if [ -n "$apt_pkgs" ]; then
        sudo_if_available apt-get update
        # Package lists are assembled by trusted profile names.
        # shellcheck disable=SC2086
        sudo_if_available apt-get install -y $apt_pkgs
      fi
      ;;
    Arch)
      pacman-key --init
      pacman-key --populate
      if [ -n "$arch_pkgs" ]; then
        # Package lists are assembled by trusted profile names.
        # shellcheck disable=SC2086
        pacman -Syu --noconfirm $arch_pkgs
      fi
      ;;
    CentOS* | Fedora)
      if [ -n "$dnf_pkgs" ]; then
        if [ "$MATRIX_NAME" != "Fedora" ] && needs_centos_epel; then
          # Keep the base image small, but enable EPEL for profiles whose dnf
          # packages are not shipped in the base CentOS Stream repos.
          dnf install -y --allowerasing epel-release
        fi
        # Package lists are assembled by trusted profile names.
        # shellcheck disable=SC2086
        dnf install -y --allowerasing $dnf_pkgs
      fi
      ;;
    Alpine)
      if [ -n "$apk_pkgs" ]; then
        # Package lists are assembled by trusted profile names.
        # shellcheck disable=SC2086
        apk add --no-cache $apk_pkgs
      fi
      ;;
  esac
}

install_yq_v4() {
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

ensure_lua_command() {
  # Debian and Alpine install Lua 5.4 as lua5.4. termnav's tests expect the
  # portable command name "lua", so add a compatibility symlink when needed.
  if command -v lua >/dev/null 2>&1; then
    return
  fi
  if command -v lua5.4 >/dev/null 2>&1; then
    sudo_if_available ln -sf "$(command -v lua5.4)" /usr/local/bin/lua
  fi
}
