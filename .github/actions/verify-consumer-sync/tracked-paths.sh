# shellcheck shell=bash

# A failed index read is different from an optional path that is untracked.
# Collect the requested literal paths successfully before testing membership.
consumer_index_paths() {
  local repo=$1
  shift

  git -C "$repo" ls-files -- "$@" || {
    printf '%s\n' 'cannot read tracked consumer paths' >&2
    return 1
  }
}

# Match complete lines. A pathspec for a file can match descendants when a
# consumer has a directory at the marker path, which is not an opt-in.
consumer_tracks() {
  [[ $'\n'"$1"$'\n' == *$'\n'"$2"$'\n'* ]]
}
