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

# Shared download options for every curl in this action.
#
# `--retry` alone does not help a transfer that connects and then goes quiet:
# curl waits indefinitely for bytes that never arrive. `--speed-limit` with
# `--speed-time` detects a stalled body, while `--max-time` makes the bound
# absolute even when a transfer keeps trickling. Keep the retry window short
# enough that the ShellCheck path (two apt loops, then this download) still
# finishes or emits its failure before the workflow's 10m prerequisite-step
# cap.
CURL_SPEED_TIME=${CURL_SPEED_TIME:-30}
CURL_RETRIES=${CURL_RETRIES:-2}
CURL_RETRY_DELAY=${CURL_RETRY_DELAY:-1}
CURL_MAX_TIME=${CURL_MAX_TIME:-60}
CURL_NET_OPTS="--connect-timeout 10 --max-time $CURL_MAX_TIME --speed-limit 1024 --speed-time $CURL_SPEED_TIME --retry $CURL_RETRIES --retry-all-errors --retry-delay $CURL_RETRY_DELAY"

# GitHub rate-limits unauthenticated release downloads per egress IP, and
# shared runners trip that limit: the download then fails with 403 on every
# retry. When the caller provides GITHUB_TOKEN, authenticate the download so
# it counts against the token's limit instead. The token reaches curl through
# a config file, never argv, because retry_pkg prints the failed command.
# Prints the curl arguments for the config file, or nothing without a token.
github_download_auth_args() {
  config_file=$1
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    return 0
  fi
  # A token containing a quote, whitespace, or control character cannot be
  # real, and it would break the config line or inject a second directive.
  # Stay anonymous instead: anonymous is the previous behavior, so a
  # degenerate token degrades to it, never to a failure. The guard rejects
  # only characters that can break the line, not a fixed token format, so
  # future token formats keep working.
  if printf '%s' "$GITHUB_TOKEN" | grep -q '["[:space:][:cntrl:]]'; then
    return 0
  fi
  # The file holds the token, so create it 0600 from the start. Remove any
  # stale file first: truncating an existing one would keep its old mode.
  rm -f -- "$config_file"
  (umask 077; printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" >"$config_file") || return 1
  printf '%s\n' "-K $config_file"
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
        # Package lists and install options are assembled by trusted
        # profile names and the package-manager library.
        # shellcheck disable=SC2086
        retry_pkg brew install $BREW_INSTALL_OPTS $brew_pkgs
      fi
      ;;
    Debian | Ubuntu | WSL)
      if [ -n "$apt_pkgs" ]; then
        # Package lists and network options are assembled here, not by callers.
        # shellcheck disable=SC2086
        retry_pkg $SUDO $APT_GET $APT_NET_OPTS update
        # shellcheck disable=SC2086
        retry_pkg $SUDO $APT_GET $APT_NET_OPTS install -y $apt_pkgs
      fi
      ;;
    Arch)
      pacman-key --init
      pacman-key --populate
      if [ -n "$arch_pkgs" ]; then
        # pacman has no transfer-timeout option of its own, so the `bounded`
        # supervisor in retry_pkg is the only stall guard on this platform.
        # Package lists are assembled by trusted profile names.
        # shellcheck disable=SC2086
        pacman_install $arch_pkgs
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

ensure_modern_python() (
  candidate=
  resolved=

  if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import tomllib' >/dev/null 2>&1; then
    return
  fi

  for candidate in python3.14 python3.13 python3.12 python3.11; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    "$candidate" -c 'import tomllib' >/dev/null 2>&1 || continue
    resolved=$(command -v "$candidate") || return 1
    # CentOS Stream 9 keeps newer parallel Python runtimes versioned. Publish
    # the portable command name without replacing the distribution package.
    sudo_if_available ln -sf "$resolved" /usr/local/bin/python3
    hash -r 2>/dev/null || true
    python3 -c 'import tomllib' >/dev/null 2>&1 || return 1
    return
  done

  echo 'python3 with standard-library tomllib is required' >&2
  return 1
)

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
  auth_config=${RUNNER_TEMP:-/tmp}/curl-github-auth.conf
  auth_args=$(github_download_auth_args "$auth_config") || return 1
  # shellcheck disable=SC2086
  if ! curl -fsSL $CURL_NET_OPTS $auth_args \
    "https://github.com/mikefarah/yq/releases/download/v${version}/yq_${os}_${arch}" \
    -o "$tmp"; then
    rm -f "$tmp" "$auth_config"
    return 1
  fi
  rm -f -- "$auth_config"
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

# The oldest tmux the repositories that opt into the `tmux-floor` profile
# support. That profile gives every leg a tmux at least this new: the
# distribution's, except where tmux_floor_builds_here says that tmux is older
# than the floor, so that leg builds this release from source and tests the
# floor itself. The plain `tmux` profile keeps every distribution's own package.
# test/tmux-floor-check and test/shell-ci-prereqs-test read these values.
# A floor bump changes the version and checksum; if tmux-floor-check then fails
# on another leg, add that leg to tmux_floor_builds_here and give its package
# manager the build packages.
TMUX_FLOOR_VERSION=3.3a
TMUX_FLOOR_SHA256=e4fd347843bd0772c4f48d6dde625b0b109b7a380ff15db21e97c11a4dcdf93f
# Everything the build needs on a minimal CentOS Stream 9 image, all from its
# default BaseOS and AppStream repositories. profiles.sh installs them.
# shellcheck disable=SC2034
TMUX_FLOOR_BUILD_PKGS="gcc make bison pkgconf-pkg-config libevent-devel ncurses-devel tar gzip"

# Ubuntu callers can opt into the exact floor independently of the full
# platform matrix. The older tmux-floor profile still builds it on CentOS.
tmux_floor_builds_here() {
  if [ "$MATRIX_NAME" = Ubuntu ] && has_profile tmux-floor-exact; then
    return 0
  fi
  case "$MATRIX_NAME" in
    CentOS*) return 0 ;;
  esac
  return 1
}

install_floor_tmux() {
  archive="${RUNNER_TEMP:?}/tmux-$TMUX_FLOOR_VERSION.tar.gz"
  source_dir="$RUNNER_TEMP/tmux-$TMUX_FLOOR_VERSION"
  install_dir="$RUNNER_TEMP/tmux-floor"
  build_log="$RUNNER_TEMP/tmux-floor-build.log"
  url="https://github.com/tmux/tmux/releases/download/$TMUX_FLOOR_VERSION/tmux-$TMUX_FLOOR_VERSION.tar.gz"

  rm -rf "$source_dir" "$install_dir"
  mkdir -p "$RUNNER_TEMP"
  # The bounded retry reports an exhausted deadline as an infrastructure
  # stall, so infra-retry can rerun the job.
  auth_config=$RUNNER_TEMP/curl-github-auth.conf
  auth_args=$(github_download_auth_args "$auth_config") || return 1
  # shellcheck disable=SC2086
  retry_pkg curl -fsSL $CURL_NET_OPTS $auth_args \
    "$url" -o "$archive"
  rm -f -- "$auth_config"
  # Explicit, so a caller that tests this function cannot suspend the check.
  if ! verify_sha256 "$TMUX_FLOOR_SHA256" "$archive"; then
    echo "tmux $TMUX_FLOOR_VERSION source does not match its checksum" >&2
    exit 1
  fi
  tar -xzf "$archive" -C "$RUNNER_TEMP"
  rm -f "$archive"
  # The build is quiet unless it fails, when its whole log is the diagnostic.
  # There is no fallback to the distribution's older tmux.
  if ! (
    cd "$source_dir" &&
      ./configure --prefix="$install_dir" &&
      make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" &&
      make install
  ) >"$build_log" 2>&1; then
    cat "$build_log" >&2
    echo "tmux $TMUX_FLOOR_VERSION did not build" >&2
    exit 1
  fi
  rm -rf "$source_dir" "$build_log"

  if ! "$install_dir/bin/tmux" -V | grep -Fx "tmux $TMUX_FLOOR_VERSION" >/dev/null; then
    echo "the built tmux does not report tmux $TMUX_FLOOR_VERSION" >&2
    exit 1
  fi
  printf '%s\n' "$install_dir/bin" >>"${GITHUB_PATH:?}"
}

# Name the floor this job provides, so the caller's suites can check that
# their own declared minimum matches it. Where this leg built the floor,
# CI_TMUX_FLOOR_EXACT=1 also tells them the tmux they run must be exactly
# that release, so no newer tmux earlier on PATH can stand in for it.
export_tmux_floor() {
  printf 'CI_TMUX_FLOOR=%s\n' "$TMUX_FLOOR_VERSION" >>"${GITHUB_ENV:?}"
  if tmux_floor_builds_here; then
    printf 'CI_TMUX_FLOOR_EXACT=1\n' >>"$GITHUB_ENV"
  fi
}

install_pinned_tmux() (
  # Keep inherited settings from supplying a version missing in a legacy lock.
  unset TMUX_BUILD_REPORTED_VERSION
  # shellcheck source=./tmux-build.lock
  . "$SCRIPT_DIR/tmux-build.lock"
  expected_version=${TMUX_BUILD_REPORTED_VERSION:-$TMUX_BUILD_VERSION}

  target="$(uname -s):$(uname -m)"
  case "$target" in
    Linux:x86_64 | Linux:amd64)
      asset=linux-x86_64 checksum=$TMUX_BUILD_LINUX_X86_64
      ;;
    Linux:aarch64 | Linux:arm64)
      asset=linux-arm64 checksum=$TMUX_BUILD_LINUX_ARM64
      ;;
    Darwin:x86_64 | Darwin:amd64)
      asset=macos-x86_64 checksum=$TMUX_BUILD_MACOS_X86_64
      ;;
    Darwin:aarch64 | Darwin:arm64)
      asset=macos-arm64 checksum=$TMUX_BUILD_MACOS_ARM64
      ;;
    *)
      printf 'no pinned tmux build for %s\n' "$target" >&2
      exit 1
      ;;
  esac

  stage=$(mktemp -d "${RUNNER_TEMP:?}/tmux-pinned.XXXXXX") || exit 1
  trap 'rm -rf -- "$stage"' EXIT
  archive=$stage/tmux.tar.gz
  url="https://github.com/cgraf78/tmux-builds/releases/download/$TMUX_BUILD_RELEASE/tmux-$TMUX_BUILD_VERSION-$asset.tar.gz"
  auth_args=$(github_download_auth_args "$stage/curl-github-auth.conf") || exit 1
  # shellcheck disable=SC2086 # Trusted shared curl options and the auth config are separate args.
  retry_pkg curl -fsSL $CURL_NET_OPTS $auth_args "$url" -o "$archive" || exit 1
  rm -f -- "$stage/curl-github-auth.conf"
  if ! verify_sha256 "$checksum" "$archive"; then
    printf 'tmux %s archive for %s failed checksum verification\n' "$TMUX_BUILD_RELEASE" "$asset" >&2
    exit 1
  fi
  tar -xzf "$archive" -C "$stage" tmux || exit 1
  rm -f -- "$archive" || exit 1
  binary=$stage/tmux
  if [ ! -f "$binary" ] || [ -L "$binary" ] || [ ! -x "$binary" ] ||
    ! reported=$("$binary" -V) || [ "$reported" != "tmux $expected_version" ]; then
    printf 'tmux %s archive for %s did not provide tmux %s\n' \
      "$TMUX_BUILD_RELEASE" "$asset" "$expected_version" >&2
    exit 1
  fi
  printf '%s\n' "$stage" >>"${GITHUB_PATH:?}" || exit 1
  printf 'CI_TMUX_PINNED_BIN=%s\nCI_TMUX_PINNED_VERSION=%s\nCI_TMUX_PINNED_RELEASE=%s\n' \
    "$binary" "$expected_version" "$TMUX_BUILD_RELEASE" >>"${GITHUB_ENV:?}" || exit 1
  trap - EXIT
  printf 'Installed tmux %s (%s, %s)\n' "$expected_version" "$TMUX_BUILD_RELEASE" "$asset"
)

wezterm_runner_target() (
  case "$MATRIX_NAME:$(uname -s):$(uname -m)" in
    macOS:Darwin:arm64 | macOS:Darwin:aarch64 | macOS:Darwin:x86_64 | macOS:Darwin:amd64)
      printf '%s\n' macos
      exit 0
      ;;
    Ubuntu:Linux:x86_64 | Ubuntu:Linux:amd64) ;;
    *) exit 2 ;;
  esac
  [ -r /etc/os-release ] || exit 2
  ID='' VERSION_ID=''
  # shellcheck disable=SC1091 # Runner-owned platform identity.
  . /etc/os-release
  [ "$ID:$VERSION_ID" = ubuntu:24.04 ] || exit 2
  printf '%s\n' ubuntu24.04-x86_64
)

install_pinned_wezterm() (
  target=$1
  # Unlike the tmux lock, this one has per-package rows and never contains
  # shell assignments. Read only the exact runner's single package record.
  if ! pin=$(awk -v target="$target" '
    $1 == target {
      rows++
      if (NF != 4 || $2 !~ /^[0-9]+-[0-9]+-[0-9a-f]+$/ ||
          length($3) != 64 || $3 !~ /^[0-9a-f]+$/) exit 1
      print $2, $3, $4
    }
    END { if (rows != 1) exit 1 }
  ' "$SCRIPT_DIR/wezterm-build.lock"); then
    printf 'expected one valid WezTerm lock row for %s\n' "$target" >&2
    exit 1
  fi
  IFS=' ' read -r expected_version checksum url <<EOF
$pin
EOF
  snapshot_root=https://github.com/cgraf78/wezterm-builds/releases/download/
  case "$target:$url" in
    ubuntu24.04-x86_64:"$snapshot_root"snapshot-*/*.deb | macos:"$snapshot_root"snapshot-*/*.zip) ;;
    *)
      printf 'invalid WezTerm snapshot package URL for %s\n' "$target" >&2
      exit 1
      ;;
  esac
  release=${url#"$snapshot_root"}
  release=${release%%/*}

  stage=$(mktemp -d "${RUNNER_TEMP:?}/wezterm-pinned.XXXXXX") || exit 1
  trap 'rm -rf -- "$stage"' EXIT
  archive=$stage/wezterm.${url##*.}
  auth_args=$(github_download_auth_args "$stage/curl-github-auth.conf") || exit 1
  # shellcheck disable=SC2086 # Trusted shared curl options and the auth config are separate args.
  retry_pkg curl -fsSL $CURL_NET_OPTS $auth_args "$url" -o "$archive" || exit 1
  rm -f -- "$stage/curl-github-auth.conf"
  if ! verify_sha256 "$checksum" "$archive"; then
    printf 'WezTerm %s package for %s failed checksum verification\n' "$release" "$target" >&2
    exit 1
  fi
  if [ "$target" = macos ]; then
    # Keep the signed GUI app intact and private to this job's runner.
    ditto -x -k "$archive" "$stage" || exit 1
    rm -f -- "$archive" || exit 1
    set -- "$stage"/WezTerm-macos-*/WezTerm.app
    if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
      printf 'WezTerm %s package for %s did not provide one app bundle\n' "$release" "$target" >&2
      exit 1
    fi
    bin_dir=$1/Contents/MacOS
  else
    # APT's unprivileged fetcher needs to traverse the verified package directory.
    chmod 0755 "$stage" && chmod 0644 "$archive" || exit 1
    # shellcheck disable=SC2086 # Trusted package-manager options are separate args.
    retry_pkg $SUDO $APT_GET $APT_NET_OPTS install -y --no-install-recommends \
      --reinstall --allow-downgrades "$archive" || exit 1
    bin_dir=/usr/bin
  fi

  binary=$bin_dir/wezterm
  gui=$bin_dir/wezterm-gui
  if ! reported=$("$binary" --version) || [ "$reported" != "wezterm $expected_version" ]; then
    printf 'WezTerm %s package for %s did not provide wezterm %s\n' \
      "$release" "$target" "$expected_version" >&2
    exit 1
  fi
  if [ ! -f "$gui" ] || [ ! -x "$gui" ]; then
    printf 'WezTerm %s package for %s did not provide an executable GUI\n' "$release" "$target" >&2
    exit 1
  fi
  printf 'CI_WEZTERM_PINNED_BIN=%s\nCI_WEZTERM_PINNED_GUI=%s\nCI_WEZTERM_PINNED_VERSION=%s\nCI_WEZTERM_PINNED_RELEASE=%s\n' \
    "$binary" "$gui" "$expected_version" "$release" >>"${GITHUB_ENV:?}" || exit 1
  if [ "$target" = macos ]; then
    printf '%s\n' "$bin_dir" >>"${GITHUB_PATH:?}" || exit 1
    trap - EXIT
  fi
  printf 'Installed WezTerm %s (%s, %s)\n' "$expected_version" "$release" "$target"
)

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
  auth_config=$RUNNER_TEMP/curl-github-auth.conf
  auth_args=$(github_download_auth_args "$auth_config") || return 1
  # shellcheck disable=SC2086
  curl -fsSL $CURL_NET_OPTS $auth_args \
    "$url" -o "$archive"
  rm -f -- "$auth_config"
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
