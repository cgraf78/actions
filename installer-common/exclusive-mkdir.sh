# shellcheck shell=bash
# Included in the standalone and legacy checkout installer templates.

installer_exclusive_mkdir() {
  local mkdir_command
  # Ubuntu's uutils mkdir can return success on EEXIST when another process
  # created the directory first. Ubuntu also ships GNU mkdir as gnumkdir.
  mkdir_command=$(type -P gnumkdir) || mkdir_command='mkdir'
  command "$mkdir_command" "$1"
}
