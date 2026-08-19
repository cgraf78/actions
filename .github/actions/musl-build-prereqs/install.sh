#!/bin/sh
set -eu

SCRIPT_DIR=${0%/*}
# shellcheck source=../package-manager/lib.sh
. "$SCRIPT_DIR/../package-manager/lib.sh"

# Install what a Linux musl Rust target needs to link.
#
# Rust ships the musl libc, but any crate with a C dependency still needs a musl
# linker. Every consumer that builds musl release archives was carrying the same
# apt invocation inline; this is the single copy.

# musl targets only exist on Linux. Callers gate on the matrix row too, but a
# no-op here keeps the action safe to invoke unconditionally.
if [ "${RUNNER_OS:-Linux}" != "Linux" ]; then
  echo "musl-build-prereqs: skipping on ${RUNNER_OS:-unknown}"
  exit 0
fi

# shellcheck disable=SC2086
retry_pkg $SUDO apt-get $APT_NET_OPTS update
# shellcheck disable=SC2086
retry_pkg $SUDO apt-get $APT_NET_OPTS install -y --no-install-recommends musl-tools

# Direct action callers may ask this helper to add a target as well as the host
# linker. The reusable CI and release workflows normally install their targets
# separately, so they leave RUST_TARGET empty and use only the linker behavior.
if [ -n "${RUST_TARGET:-}" ]; then
  rustup target add "$RUST_TARGET"
fi
