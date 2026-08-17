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

verify_sha256() {
  expected=$1
  file=$2

  case "$(uname -s)" in
    Darwin) printf '%s  %s\n' "$expected" "$file" | shasum -a 256 -c - ;;
    *) printf '%s  %s\n' "$expected" "$file" | sha256sum -c - ;;
  esac
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
  has_profile shellcheck || has_profile neovim || has_profile fd ||
    has_profile ripgrep
}

add_pkg() {
  # Package lists are built from trusted profile metadata in profiles.sh, not
  # from caller-provided package names.
  eval "$1=\"\${$1:+\${$1} }$2\""
}

install_package_lists() {
  # Generic profiles reach this function directly. Named setup modes may add a
  # small repo-specific bootstrap base, then compose the same profile package
  # lists so command capabilities keep one cross-platform mapping.
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

  version=4.53.3

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

  case "${os}_${arch}" in
    linux_amd64) checksum=fa52a4e758c63d38299163fbdd1edfb4c4963247918bf9c1c5d31d84789eded4 ;;
    linux_arm64) checksum=578648e463a11c1b6db6010cbf41eafed6bee79466fcffa1bb446672cf7945ea ;;
    darwin_amd64) checksum=b4ba1ecce3c47f00803f4f964de38394326c7a32eb6540616e04fb2935a0f08d ;;
    darwin_arm64) checksum=877de31753a4dd2401aa048937aa9a7fc4d5f6ce858cf31508c5802954297213 ;;
  esac

  tmp="${RUNNER_TEMP:-/tmp}/yq"
  rm -f "$tmp"
  if ! curl -fsSL --retry 3 --retry-all-errors --retry-delay 1 \
    "https://github.com/mikefarah/yq/releases/download/v${version}/yq_${os}_${arch}" \
    -o "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! verify_sha256 "$checksum" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod +x "$tmp"
  if ! "$tmp" --version | grep -Fq "version v${version}"; then
    rm -f "$tmp"
    return 1
  fi
  sudo_if_available mv "$tmp" /usr/local/bin/yq
}

install_pinned_shellcheck() {
  version=0.11.0
  checksum=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198

  case "$(uname -m)" in
    x86_64 | amd64) architecture=x86_64 ;;
    *)
      echo "unsupported pinned ShellCheck architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac

  archive_name="shellcheck-v${version}.linux.${architecture}.tar.xz"
  archive="${RUNNER_TEMP:?}/$archive_name"
  install_dir="$RUNNER_TEMP/shellcheck-v${version}"
  url="https://github.com/koalaman/shellcheck/releases/download/v${version}/${archive_name}"

  rm -rf "$install_dir"
  mkdir -p "$RUNNER_TEMP"
  curl -fsSL --retry 3 --retry-all-errors --retry-delay 1 \
    "$url" -o "$archive"
  verify_sha256 "$checksum" "$archive"
  tar -xJf "$archive" -C "$RUNNER_TEMP"
  rm -f "$archive"

  "$install_dir/shellcheck" --version | grep -Fq "version: $version"
  printf '%s\n' "$install_dir" >>"${GITHUB_PATH:?}"
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
