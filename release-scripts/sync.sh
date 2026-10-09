#!/usr/bin/env bash
set -euo pipefail

# Low-level copy of the shared release scripts into a consumer repository.
#
# The shared copy in this repo is authoritative; consumers vendor it so release
# tooling keeps working locally and in CI without a network bootstrap on the
# release path. `verify-release-scripts` fails the consumer's CI when the two
# diverge. The copy and managed-manifest contract itself belongs to
# consumer-ci/vendor-scripts.sh, which every vendored family shares. Normal
# consumer version updates use consumer-ci/sync.sh so the dependency lock and
# YAML refs move with these bytes; this narrow command remains separate for its
# focused tests and reuse.

usage() {
  cat >&2 <<'EOF'
usage: release-scripts/sync.sh <consumer-scripts-dir>

Consumer repositories should normally run consumer-ci/sync.sh instead so the
actions lock, workflow refs, and these files advance together.
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec "$source_dir/../consumer-ci/vendor-scripts.sh" \
  "$source_dir" "$1" .release-scripts.manifest
