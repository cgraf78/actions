#!/usr/bin/env bash
set -euo pipefail

# Copy the shared release scripts into a consumer repository.
#
# The shared copy in this repo is authoritative; consumers vendor it so release
# tooling keeps working locally and in CI without a network bootstrap on the
# release path. `verify-release-scripts` fails the consumer's CI when the two
# diverge, which is how vendoring stays equivalent to a single source rather
# than three copies maintained by convention.

usage() {
  cat >&2 <<'EOF'
usage: release-scripts/sync.sh <consumer-scripts-dir>

Example:
  release-scripts/sync.sh ~/git/hive-memory/scripts
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

dest=$1
source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ ! -d "$dest" ]]; then
  printf 'sync: destination is not a directory: %s\n' "$dest" >&2
  exit 1
fi

shopt -s nullglob
copied=0
for script in "$source_dir"/*.sh; do
  name=$(basename "$script")
  # sync.sh is maintainer tooling for this repo, not part of the vendored set.
  [[ "$name" == sync.sh ]] && continue
  # Entry points must stay executable and the sourced library must not become
  # so; mirror the source mode rather than forcing one.
  mode=0644
  [[ -x "$script" ]] && mode=0755
  install -m "$mode" "$script" "$dest/$name"
  printf 'sync: %s\n' "$dest/$name"
  copied=$((copied + 1))
done

if [[ "$copied" -eq 0 ]]; then
  printf 'sync: no scripts found in %s\n' "$source_dir" >&2
  exit 1
fi

printf 'sync: %d file(s) updated\n' "$copied"
