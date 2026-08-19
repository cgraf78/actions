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

# Command prefix form of sudo_if_available, for the package commands that are
# wrapped by `bounded`. A supervisor cannot exec a shell function, so those
# call sites need the privilege decision as an expandable word instead.
if command -v sudo >/dev/null 2>&1; then
  SUDO=sudo
else
  SUDO=
fi

# Bound every package-manager network operation.
#
# Package managers do not fail fast on a stalled mirror: a wedged socket to
# azure.archive.ubuntu.com leaves `apt-get update` blocked with no output and
# no exit, so the job burns the workflow timeout instead of failing into the
# retry path. Give each manager its native transfer timeout where it has one,
# and wrap the whole command in a hard supervisor as the backstop for the ones
# that do not.
PKG_NETWORK_TIMEOUT=${PKG_NETWORK_TIMEOUT:-30}
PKG_COMMAND_TIMEOUT=${PKG_COMMAND_TIMEOUT:-600}
PKG_RETRIES=${PKG_RETRIES:-3}

# Native per-transfer knobs. Retries stay at the manager level too, so a single
# slow mirror is re-tried without re-running the whole (expensive) command.
APT_NET_OPTS="-o Acquire::http::Timeout=$PKG_NETWORK_TIMEOUT -o Acquire::https::Timeout=$PKG_NETWORK_TIMEOUT -o Acquire::Retries=$PKG_RETRIES"
DNF_NET_OPTS="--setopt=timeout=$PKG_NETWORK_TIMEOUT --setopt=retries=$PKG_RETRIES"
APK_NET_OPTS="--timeout $PKG_NETWORK_TIMEOUT"

# Shared download options for every curl in this action.
#
# `--retry` alone does not help a transfer that connects and then goes quiet:
# curl waits indefinitely for bytes that never arrive. `--speed-limit` with
# `--speed-time` is the stall guard that `--max-time` cannot be here, because a
# fixed deadline would also kill a slow-but-healthy large download.
CURL_NET_OPTS="--connect-timeout 10 --speed-limit 1024 --speed-time 60 --retry 3 --retry-all-errors --retry-delay 1"

bounded() {
  # `timeout` is coreutils and is absent from a stock macOS runner. Falling
  # back to an unsupervised run keeps brew working rather than failing the
  # action outright on the one platform that cannot supervise.
  if command -v timeout >/dev/null 2>&1; then
    timeout "$PKG_COMMAND_TIMEOUT" "$@"
  else
    "$@"
  fi
}

retry_pkg() {
  # Covers mirror flake that the managers' own retry knobs do not, and turns a
  # `bounded` timeout kill into a retry rather than an immediate job failure.
  _attempt=1
  while :; do
    # Capture the status inside `else`. A bare `$?` after `fi` reads the exit
    # status of the `if` compound itself, which is 0 when the condition fails
    # and there is no else branch - that would report an exhausted retry loop
    # as success.
    if bounded "$@"; then
      return 0
    else
      _rc=$?
    fi
    if [ "$_attempt" -ge "$PKG_RETRIES" ]; then
      # Stable marker consumed by infra-retry's allowlist. Keep the wording in
      # sync with is_retryable_bounded_stall in .github/actions/infra-retry.
      echo "infra-stall: package command exhausted bounded retries" >&2
      echo "package command failed after $PKG_RETRIES attempts (exit $_rc): $*" >&2
      return "$_rc"
    fi
    _delay=$((_attempt * 5))
    echo "package command failed (attempt $_attempt/$PKG_RETRIES, exit $_rc); retrying in ${_delay}s..." >&2
    sleep "$_delay"
    _attempt=$((_attempt + 1))
  done
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
        retry_pkg brew install $brew_pkgs
      fi
      ;;
    Debian | Ubuntu | WSL)
      if [ -n "$apt_pkgs" ]; then
        # Package lists and network options are assembled here, not by callers.
        # shellcheck disable=SC2086
        retry_pkg $SUDO apt-get $APT_NET_OPTS update
        # shellcheck disable=SC2086
        retry_pkg $SUDO apt-get $APT_NET_OPTS install -y $apt_pkgs
      fi
      ;;
    Arch)
      pacman-key --init
      pacman-key --populate
      if [ -n "$arch_pkgs" ]; then
        # pacman has no transfer-timeout option of its own, so the `bounded`
        # supervisor in retry_pkg is the only stall guard on this platform.
        # shellcheck disable=SC2086
        retry_pkg pacman -Syu --noconfirm $arch_pkgs
      fi
      ;;
    CentOS* | Fedora)
      if [ -n "$dnf_pkgs" ]; then
        if [ "$MATRIX_NAME" != "Fedora" ] && needs_centos_epel; then
          # Keep the base image small, but enable EPEL for profiles whose dnf
          # packages are not shipped in the base CentOS Stream repos.
          # shellcheck disable=SC2086
          retry_pkg dnf $DNF_NET_OPTS install -y --allowerasing epel-release
        fi
        # Package lists are assembled by trusted profile names.
        # shellcheck disable=SC2086
        retry_pkg dnf $DNF_NET_OPTS install -y --allowerasing $dnf_pkgs
      fi
      ;;
    Alpine)
      if [ -n "$apk_pkgs" ]; then
        # Package lists are assembled by trusted profile names.
        # shellcheck disable=SC2086
        retry_pkg apk $APK_NET_OPTS add --no-cache $apk_pkgs
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
  # shellcheck disable=SC2086
  if ! curl -fsSL $CURL_NET_OPTS \
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
  # shellcheck disable=SC2086
  curl -fsSL $CURL_NET_OPTS \
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
