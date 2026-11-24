# shellcheck shell=bash

# The sync entry point owns the scratch tree and calls cleanup on exit. All
# generation targets the after tree; the before tree proves destination
# ownership and supplies the bytes needed to restore an interrupted update.
stage_paths=()
publish_paths=()
publish_copies=()
publish_backups=()
publish_temps=()
publish_directories=()
publish_directory_count=0
publish_attempted=0
publish_complete=false
stage_lock=''
stage_owner=''

init_staged_files() {
  local probe=${2%/*}/rename-probe flag
  stage_consumer=$1
  before=$2
  prepared=$3
  stage_identity=$(directory_identity "$stage_consumer") || return
  # GNU and BusyBox spell a non-container destination -T. BSD uses -h
  # for symlinks. Probe the actual command because macOS can use GNU mv.
  mkdir -p "$before" "$prepared" "$probe/directory" || return
  ln -s directory "$probe/destination" || return
  printf 'rename probe\n' >"$probe/source" || return
  for flag in T h; do
    if mv "-f$flag" "$probe/source" "$probe/destination" 2>/dev/null &&
      [[ -f "$probe/destination" && ! -L "$probe/destination" ]]; then
      stage_move_flag=$flag
      return 0
    fi
  done
  stage_error 'mv needs a no-follow destination option (-T or -h)'
}

directory_identity() {
  [[ -d "$1" && ! -L "$1" ]] || return 1
  stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1"
}

lock_staged_files() {
  local git_dir nested
  git_dir=$(git -C "$stage_consumer" rev-parse --absolute-git-dir) || return
  stage_lock=$git_dir/cgraf78-consumer-sync.lock
  # Publish the owner in the acquisition itself so early signals can tell
  # which invocation may release the lock.
  stage_owner=consumer-sync.$$.${1##*/}
  if ln -sn "$stage_owner" "$stage_lock" 2>/dev/null; then
    [[ -L "$stage_lock" && $(readlink "$stage_lock") == "$stage_owner" ]] && return 0
    nested=$stage_lock/$stage_owner
    if [[ -d "$stage_lock" && ! -L "$stage_lock" && -L "$nested" &&
      $(readlink "$nested") == "$stage_owner" ]]; then
      rm -f "$nested"
    fi
  fi
  stage_error "another sync owns $stage_lock"
}

stage_error() {
  printf 'consumer-sync: %s\n' "$*" >&2
  return 1
}

stage_parent() {
  local directory=$1 create=$2
  if [[ "$directory" == "$stage_consumer" ]]; then
    [[ $(directory_identity "$directory") == "$stage_identity" ]] ||
      stage_error "consumer directory changed during synchronization: $directory"
    return
  fi
  stage_parent "${directory%/*}" "$create" || return
  if [[ -L "$directory" || (-e "$directory" && ! -d "$directory") ]]; then
    stage_error "destination parent must be a regular directory: $directory"
  elif [[ "$create" == true && ! -d "$directory" ]]; then
    mkdir "$directory" || return
    publish_directories+=("$directory")
    publish_directory_count=$((publish_directory_count + 1))
  fi
}

stage_file() {
  local relative=$1 prior live=$stage_consumer/$1 parent=. opaque=${2:-false}
  for prior in ${stage_paths[@]+"${stage_paths[@]}"}; do
    [[ "$prior" != "$relative" ]] || return 0
  done
  stage_parent "${live%/*}" false || return
  stage_paths+=("$relative")
  [[ "$relative" != */* ]] || parent=${relative%/*}
  mkdir -p "$before/$parent" "$prepared/$parent" || return
  if [[ -L "$live" || -f "$live" ]]; then
    cp -pP "$live" "$before/$relative" &&
      cp -pP "$before/$relative" "$prepared/$relative"
  elif [[ -e "$live" && "$opaque" == true ]]; then
    # Disabled installers leave foreign path types alone. A directory
    # placeholder lets the renderer make the same ownership decision.
    mkdir "$before/$relative" "$prepared/$relative"
  elif [[ -e "$live" ]]; then
    stage_error "destination must be a file: $relative"
  fi
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

same_staged_file() {
  local first=$1 second=$2 left right
  if [[ -L "$first" ]]; then
    [[ -L "$second" ]] || return 1
    left=$(readlink -n "$first" && printf '.') || return 1
    right=$(readlink -n "$second" && printf '.') || return 1
    [[ "$left" == "$right" ]]
  elif [[ -f "$first" ]]; then
    [[ -f "$second" && ! -L "$second" ]] || return 1
    left=$(file_mode "$first") && right=$(file_mode "$second") &&
      [[ "$left" == "$right" ]] && cmp -s "$first" "$second"
  elif [[ -d "$first" ]]; then
    [[ -e "$second" && ! -f "$second" && ! -L "$second" ]]
  else
    [[ ! -e "$first" && ! -e "$second" && ! -L "$second" ]]
  fi
}

stage_publication() {
  local relative=$1 live=$stage_consumer/$1 copy='' backup=''
  stage_parent "${live%/*}" false || return
  same_staged_file "$before/$relative" "$live" ||
    {
      stage_error "destination changed during preparation: $relative"
      return 1
    }
  same_staged_file "$before/$relative" "$prepared/$relative" && return 0
  stage_parent "${live%/*}" true || return

  # Final renames and restores stay on the destination filesystem, including
  # when the worktree spans mount points or TMPDIR is on another volume.
  if [[ -e "$prepared/$relative" || -L "$prepared/$relative" ]]; then
    if [[ -L "$live" && -d "$live" ]]; then
      stage_error "refusing to replace a symlink to a directory: $relative"
      return 1
    fi
    copy=$(mktemp "$live.sync.XXXXXX") || return
    publish_temps+=("$copy")
    cp -pP "$prepared/$relative" "$copy" || return
  fi
  if [[ -e "$before/$relative" || -L "$before/$relative" ]]; then
    backup=$(mktemp "$live.sync.XXXXXX") || return
    publish_temps+=("$backup")
    cp -pP "$before/$relative" "$backup" || return
  fi
  publish_paths+=("$relative")
  publish_copies+=("$copy")
  publish_backups+=("$backup")
}

publish_file() {
  local relative=$1 copy=$2 backup=$3 live=$stage_consumer/$1
  local nested=$stage_consumer/$1/${2##*/}

  if [[ -L "$live" && -d "$live" ]]; then
    stage_error "refusing to replace a symlink to a directory: $relative"
    return 1
  elif [[ -n "$backup" ]]; then
    mv "-f$stage_move_flag" "$copy" "$live" || return
  elif ! ln -n "$copy" "$live"; then
    # Use no-clobber creation even where the filesystem lacks hard links.
    if [[ -e "$live" || -L "$live" ]]; then
      stage_error "destination appeared before publication: $relative"
      return 1
    fi
    mv "-n$stage_move_flag" "$copy" "$live" || return
    if [[ -e "$copy" || -L "$copy" ]]; then
      stage_error "destination appeared before publication: $relative"
      return 1
    fi
  fi
  same_staged_file "$prepared/$relative" "$live" && return 0

  # Portable ln/mv can treat a late directory as a container. Remove only
  # the matching copy at this invocation's unique temporary basename.
  if [[ -d "$live" && ! -L "$live" ]] &&
    same_staged_file "$prepared/$relative" "$nested"; then
    rm -f "$nested"
  fi
  stage_error "did not publish a canonical file: $relative"
}

publish_staged_files() {
  local relative live index
  for relative in ${stage_paths[@]+"${stage_paths[@]}"}; do
    stage_publication "$relative" || return
  done
  for index in "${!publish_paths[@]}"; do
    relative=${publish_paths[index]}
    live=$stage_consumer/$relative
    stage_parent "${live%/*}" false || return
    same_staged_file "$before/$relative" "$live" ||
      {
        stage_error "destination changed before publication: $relative"
        return 1
      }
    publish_attempted=$((index + 1))
    if [[ -n "${publish_copies[index]}" ]]; then
      publish_file "$relative" "${publish_copies[index]}" "${publish_backups[index]}" || return
    else
      rm -f "$live" || return
    fi
  done
  publish_complete=true
  for relative in ${publish_paths[@]+"${publish_paths[@]}"}; do
    printf 'consumer-sync: %s\n' "$relative"
  done
}

cleanup_staged_files() {
  local index relative live copy recovery_ok=true
  if [[ "$publish_complete" != true ]]; then
    for ((index = publish_attempted - 1; index >= 0; index--)); do
      relative=${publish_paths[index]}
      live=$stage_consumer/$relative
      copy=${publish_copies[index]}
      if ! stage_parent "${live%/*}" false; then
        printf 'consumer-sync: cannot restore %s across a changed parent\n' "$live" >&2
        recovery_ok=false
      elif same_staged_file "$prepared/$relative" "$live"; then
        if [[ -n "${publish_backups[index]}" ]]; then
          if ! mv "-f$stage_move_flag" "${publish_backups[index]}" "$live" ||
            ! same_staged_file "$before/$relative" "$live"; then
            printf 'consumer-sync: could not restore %s\n' "$live" >&2
            recovery_ok=false
          fi
        elif [[ -z "$copy" || ! -e "$copy" || "$copy" -ef "$live" ]]; then
          if ! rm -f "$live"; then
            printf 'consumer-sync: could not remove %s\n' "$live" >&2
            recovery_ok=false
          fi
        fi
      elif ! same_staged_file "$before/$relative" "$live"; then
        printf 'consumer-sync: cannot restore a concurrently edited path: %s\n' "$live" >&2
        recovery_ok=false
      fi
    done
  fi
  if [[ "$recovery_ok" == true ]]; then
    rm -f -- ${publish_temps[@]+"${publish_temps[@]}"}
    if [[ "$publish_complete" != true ]]; then
      for ((index = publish_directory_count - 1; index >= 0; index--)); do
        rmdir "${publish_directories[index]}" 2>/dev/null || :
      done
    fi
  fi
  if [[ -n "$stage_lock" && -L "$stage_lock" &&
    $(readlink "$stage_lock") == "$stage_owner" ]]; then
    rm -f "$stage_lock"
  fi
  [[ "$recovery_ok" == true ]]
}
