# shellcheck shell=bash

# The base repository uses the home directory as its worktree. Its harness
# belongs alongside its existing CI helpers instead of a top-level test dir.
capability_harness_layouts() {
  printf '%s\n' test/lib .local/lib/dotfiles/tests/capability-harness
}

# An ancestor symlink must not send the generator outside the chosen checkout.
capability_harness_local() {
  local root directory
  root=$(cd -P -- "$1" && pwd -P) || return
  directory=$(cd -P -- "$root/$2" && pwd -P) || return
  [[ "$directory" == "$root/$2" ]]
}
