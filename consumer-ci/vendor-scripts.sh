#!/usr/bin/env bash
set -euo pipefail

# The manifest is committed and later compared byte-for-byte on another OS.
# Use one portable collation order so locale differences cannot look like
# managed-set drift.
export LC_ALL=C

# Low-level copy of one provider script family into a consumer directory.
#
# Each provider family directory in this repo is authoritative; consumers
# vendor it so the tooling keeps working locally and in CI without a network
# bootstrap. `verify-consumer-sync` fails the consumer's CI when the two
# diverge, which is how vendoring stays equivalent to a single source rather
# than copies maintained by convention. Every family shares this one copy and
# manifest contract so ownership, stale-file removal, and mode rules cannot
# drift between families. Normal consumer version updates use
# consumer-ci/sync.sh so the dependency lock and YAML refs move with these
# bytes; family wrappers such as release-scripts/sync.sh remain for focused
# tests and reuse.

usage() {
  cat >&2 <<'EOF'
usage: consumer-ci/vendor-scripts.sh <provider-family-dir> <consumer-dir> <manifest-name>

Copies every tracked top-level *.sh in the provider family except sync.sh and
records the managed set in <consumer-dir>/<manifest-name>. Consumer
repositories should normally run consumer-ci/sync.sh instead so the actions
lock, workflow refs, and these files advance together.
EOF
}

if [[ $# -ne 3 ]]; then
  usage
  exit 2
fi

dest=$2
manifest_name=$3
source_dir=$(cd "$1" && pwd) || {
  printf 'sync: provider family directory is missing: %s\n' "$1" >&2
  exit 1
}
source_root=$(git -C "$source_dir" rev-parse --show-toplevel 2>/dev/null) || {
  printf 'sync: shared scripts must come from a Git checkout: %s\n' \
    "$source_dir" >&2
  exit 1
}
# The manifest lives beside repository-owned files, so restrict it to one
# hidden basename that cannot collide with a vendored script or escape DEST.
if [[ ! "$manifest_name" =~ ^\.[A-Za-z0-9][A-Za-z0-9._-]*\.manifest$ ]]; then
  printf 'sync: unsafe managed manifest name: %s\n' "$manifest_name" >&2
  exit 1
fi

if [[ ! -d "$dest" || -L "$dest" ]]; then
  printf 'sync: destination must be a regular directory, not a symlink: %s\n' \
    "$dest" >&2
  exit 1
fi

shopt -s nullglob
shared_scripts=("$source_dir"/*.sh)
manifest_tmp=$(mktemp)
trap 'rm -f "$manifest_tmp"' EXIT
for script in "${shared_scripts[@]}"; do
  name=$(basename "$script")
  # sync.sh is maintainer tooling for this repo, not part of the vendored set.
  [[ "$name" == sync.sh ]] && continue
  if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.sh$ ]]; then
    printf 'sync: unsafe shared script filename: %s\n' "$name" >&2
    exit 1
  fi
  source_relative=${script#"$source_root"/}
  if [[ ! -f "$script" || -L "$script" ]] ||
    ! git -C "$source_root" ls-files --error-unmatch -- \
      "$source_relative" >/dev/null 2>&1; then
    printf 'sync: shared script is not a tracked regular file: %s\n' \
      "$source_relative" >&2
    exit 1
  fi
  printf '%s\n' "$name" >>"$manifest_tmp"
done

if [[ ! -s "$manifest_tmp" ]]; then
  printf 'sync: no scripts found in %s\n' "$source_dir" >&2
  exit 1
fi

# The manifest is what makes deletion a synchronized operation. Comparing only
# today's source files would never notice an executable that was removed or
# renamed upstream, while deleting by filename pattern could erase repo-owned
# hooks. Remove only names that a previous manifest explicitly marked managed.
old_manifest="$dest/$manifest_name"
old_names=()
stale_names=()
if [[ -e "$old_manifest" || -L "$old_manifest" ]]; then
  if [[ ! -f "$old_manifest" || -L "$old_manifest" ]]; then
    printf 'sync: managed manifest must be a regular file: %s\n' \
      "$old_manifest" >&2
    exit 1
  fi
  while IFS= read -r old_name || [[ -n "$old_name" ]]; do
    if [[ ! "$old_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.sh$ ]] ||
      [[ "$old_name" == sync.sh ]]; then
      printf 'sync: invalid managed filename in %s: %s\n' \
        "$old_manifest" "$old_name" >&2
      exit 1
    fi
    old_names+=("$old_name")
  done <"$old_manifest"

  # Validate every stale path type before deleting any of them. A corrupt later
  # record or a path that became a directory must not turn failure into partial
  # cleanup of the valid records that appeared first.
  for old_name in "${old_names[@]}"; do
    if ! grep -Fxq "$old_name" "$manifest_tmp"; then
      stale="$dest/$old_name"
      if [[ -d "$stale" && ! -L "$stale" ]]; then
        printf 'sync: refusing to remove managed path that became a directory: %s\n' \
          "$stale" >&2
        exit 1
      fi
      stale_names+=("$old_name")
    fi
  done
  for old_name in "${stale_names[@]}"; do
    stale="$dest/$old_name"
    if [[ -e "$stale" || -L "$stale" ]]; then
      rm -f "$stale"
      printf 'sync: removed stale %s\n' "$stale"
    fi
  done
fi

copied=0
for script in "${shared_scripts[@]}"; do
  name=$(basename "$script")
  [[ "$name" == sync.sh ]] && continue
  # Entry points must stay executable and the sourced library must not become
  # so; mirror the source mode rather than forcing one.
  mode=0644
  [[ -x "$script" ]] && mode=0755
  install -m "$mode" "$script" "$dest/$name"
  printf 'sync: %s\n' "$dest/$name"
  copied=$((copied + 1))
done

# Publish the new managed set only after every current file was installed. A
# failed copy therefore leaves the previous manifest available for a safe retry.
install -m 0644 "$manifest_tmp" "$old_manifest"
printf 'sync: %s\n' "$old_manifest"

printf 'sync: %d file(s) updated\n' "$copied"
