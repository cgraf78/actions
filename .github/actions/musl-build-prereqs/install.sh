#!/bin/sh
set -eu

# Install what a Linux musl Rust target needs to link.
#
# Rust ships the musl libc, but any crate with a C dependency still needs a musl
# linker. Every consumer that builds musl release archives was carrying the same
# apt invocation inline; this is the single copy.

sudo_if_available() {
  # Hosted Linux runners have sudo, while container jobs usually run as root
  # with no sudo binary. The Rust matrix uses both forms.
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

# musl targets only exist on Linux. Callers gate on the matrix row too, but a
# no-op here keeps the action safe to invoke unconditionally.
if [ "${RUNNER_OS:-Linux}" != "Linux" ]; then
  echo "musl-build-prereqs: skipping on ${RUNNER_OS:-unknown}"
  exit 0
fi

sudo_if_available apt-get update
sudo_if_available apt-get install -y --no-install-recommends musl-tools

# Direct action callers may ask this helper to add a target as well as the host
# linker. The reusable CI and release workflows normally install their targets
# separately, so they leave RUST_TARGET empty and use only the linker behavior.
if [ -n "${RUST_TARGET:-}" ]; then
  rustup target add "$RUST_TARGET"
fi
