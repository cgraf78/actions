# shellcheck shell=bash

# A provider pin identifies committed bytes. Git errors and display settings
# must never let uncommitted provider changes pass that gate.
require_clean_provider() {
  local root=$1 command=$2 status

  status=$(git -C "$root" status --porcelain --untracked-files=normal --ignore-submodules=none) || {
    printf '%s: cannot check provider worktree status\n' "$command" >&2
    return 1
  }
  if [[ -n "$status" ]]; then
    printf '%s: provider checkout is dirty; commit or discard changes before proceeding\n' \
      "$command" >&2
    return 1
  fi
}
