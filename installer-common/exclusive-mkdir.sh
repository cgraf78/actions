# shellcheck shell=bash
# Included in the standalone and legacy checkout installer templates.

installer_exclusive_mkdir() {
  local mkdir_command
  # Ubuntu's uutils mkdir can return success on EEXIST when another process
  # created the directory first. Ubuntu also ships GNU mkdir as gnumkdir.
  mkdir_command=$(type -P gnumkdir) || mkdir_command='mkdir'
  command "$mkdir_command" "$@"
}

# Bash dispatches a pending trap after a foreground command, before the next
# assignment. Record the command's real outcome before EXIT cleanup can use
# lock_held. The command also ignores group-directed signals so it cannot die
# between its successful system call and reporting that success.
installer_acquire_lock() {
  local directory=$1 status=0 pending='' saved_traps
  saved_traps=$(trap -p HUP INT TERM)
  trap 'pending=${pending:-129}' HUP
  trap 'pending=${pending:-130}' INT
  trap 'pending=${pending:-143}' TERM
  if (
    trap '' HUP INT TERM
    installer_exclusive_mkdir "$directory"
  ); then
    # shellcheck disable=SC2034 # The generated installer's EXIT trap reads this.
    lock_held=1
  else
    status=$?
  fi
  # trap -p emits shell-quoted commands that restore the installer's handlers.
  eval "$saved_traps"
  [[ -z "$pending" ]] || exit "$pending"
  return "$status"
}
