#!/usr/bin/env bash
set -euo pipefail

case $RUSTUP_MODE in
  toolchain)
    if command -v rustup >/dev/null 2>&1; then
      exit 0
    fi
    # Keep toolchain selection in the following Rust toolchain step.
    install_args=(--default-toolchain none)
    ;;
  checkrun)
    install_args=(--profile minimal --component rustfmt)
    ;;
  *)
    printf 'Unsupported Rustup setup mode: %s\n' "$RUSTUP_MODE" >&2
    exit 1
    ;;
esac

system=$(uname -s)
arch=$(uname -m)
case $system/$arch in
  Linux/x86_64 | Linux/aarch64)
    # GNU hosts can also have musl installed for cross builds. Prefer their
    # actual glibc host over the presence of a second loader.
    if [[ -r /lib/ld-musl-$arch.so.1 ]] && ! getconf GNU_LIBC_VERSION >/dev/null 2>&1; then
      target=$arch-unknown-linux-musl
    else
      target=$arch-unknown-linux-gnu
    fi
    ;;
  Darwin/x86_64) target=x86_64-apple-darwin ;;
  Darwin/arm64) target=aarch64-apple-darwin ;;
  *)
    printf 'Unsupported Rustup host: %s/%s\n' "$system" "$arch" >&2
    exit 1
    ;;
esac

# Derive all pins from the official checksums for one Rustup archive release.
version=1.29.3
case $target in
  x86_64-unknown-linux-gnu) expected=b1c8cb14e30889e7e2999e6b69e62d9e9b9ffc0f4df8180564d306d9680e6c55 ;;
  aarch64-unknown-linux-gnu) expected=9f608c142e0e38a78957d0661ba1dfaf0b6fb37184cfaa4b9a0aa57af6184282 ;;
  x86_64-unknown-linux-musl) expected=1552169aba2836777136ccff7a381e95c17233b5d8250cd5e10ae3cb971bfcfc ;;
  aarch64-unknown-linux-musl) expected=956deacdc27ab82ae7ac821d5d3e9e95e4795d476d17efe99743bb8531ca1031 ;;
  x86_64-apple-darwin) expected=bc107f1fb0228de7fa32413c89c1b305cea9cd256e94b01150cd054128145429 ;;
  aarch64-apple-darwin) expected=63752a1919a3a4793173ec70f8f212621a7ce38ba6a246095984482f4de20f9f ;;
esac

scratch=$(mktemp -d "$RUNNER_TEMP/rustup.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
rustup_init="$scratch/rustup-init"
url="https://static.rust-lang.org/rustup/archive/$version/$target/rustup-init"
if ! status=$(curl --disable --fail --location --show-error --silent \
  --proto '=https' --proto-redir '=https' \
  --connect-timeout 10 --max-time 120 --speed-limit 1024 --speed-time 30 \
  --retry 2 --retry-all-errors --retry-delay 1 --retry-max-time 242 \
  --output "$rustup_init" --write-out '%{http_code}' "$url") || [[ $status != 2[0-9][0-9] ]]; then
  printf 'Rustup download failed for %s (%s)\n' "$target" "$status" >&2
  exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum <"$rustup_init")
else
  actual=$(shasum -a 256 <"$rustup_init")
fi
if [[ ${actual%% *} != "$expected" ]]; then
  printf 'Rustup SHA-256 mismatch for %s\n' "$target" >&2
  exit 1
fi
chmod 0700 "$rustup_init"
# Container jobs can intentionally install under HOME as root.
RUSTUP_INIT_SKIP_SUDO_CHECK=yes "$rustup_init" -y "${install_args[@]}"
cargo_bin=${CARGO_HOME:-$HOME/.cargo}/bin
if [[ ! -x $cargo_bin/rustup ]]; then
  printf 'Rustup did not install an executable in %s\n' "$cargo_bin" >&2
  exit 1
fi
printf '%s\n' "$cargo_bin" >>"$GITHUB_PATH"
