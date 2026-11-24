# shellcheck shell=sh
# Fixture setup for suites that create repositories or prepend mock commands.

actions_fixture_git() {
  if [ ! -d "$1" ]; then
    printf '%s\n' 'actions test: Git fixtures require a private temporary directory' >&2
    return 2
  fi
  # These selectors take precedence over git -C and local config, so a
  # fixture could otherwise write to the caller's repository or run its hooks.
  unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_DIR GIT_GRAFT_FILE
  unset GIT_INDEX_FILE GIT_NAMESPACE GIT_NO_REPLACE_OBJECTS GIT_OBJECT_DIRECTORY
  unset GIT_PREFIX GIT_QUARANTINE_PATH GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE
  unset GIT_TEMPLATE_DIR GIT_WORK_TREE GIT_IMPLICIT_WORK_TREE
  unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$1/gitconfig"
}

actions_fixture_path() {
  case "$1" in
    '' | *:*)
      printf '%s\n' 'actions test: TMPDIR must produce a nonempty temporary path without a colon (:) for mock PATH entries' >&2
      return 2
      ;;
  esac
}

# Keep package fixtures on the real watchdog path with a PATH that cannot
# reach host package managers or escalate privileges.
actions_fixture_apt_tools() (
  bin=$1
  with_sudo=$2
  mkdir -p "$bin" || exit
  launcher=setsid
  command -v "$launcher" >/dev/null 2>&1 || launcher=python3
  for tool in env ln mktemp rm sh sleep "$launcher"; do
    executable=$(command -v "$tool") || {
      printf 'actions test: package fixtures require %s\n' "$tool" >&2
      exit 1
    }
    ln -s "$executable" "$bin/$tool" || exit
  done

  cat >"$bin/apt-get" <<'EOF' || exit
#!/bin/sh
printf 'apt-get %s %s\n' "${DEBIAN_FRONTEND:-unset}" "$*" >>"$STUB_LOG"
if [ "${STUB_APT_HANG:-0}" = 1 ]; then
  exec sleep 5
fi
EOF
  chmod 0755 "$bin/apt-get" || exit
  if [ "$with_sudo" = 1 ]; then
    cat >"$bin/sudo" <<'EOF' || exit
#!/bin/sh
printf 'sudo %s\n' "$*" >>"$STUB_LOG"
exec "$@"
EOF
    chmod 0755 "$bin/sudo"
  fi
)

actions_fixture_nonexclusive_mkdir() (
  bin=$1
  mkdir -p "$bin" || exit
  cat >"$bin/mkdir" <<'EOF'
#!/bin/sh
# Match the uutils race's externally visible result for this exact lock.
if [ "$#" -eq 1 ] && [ "$1" = "$ACTIONS_TEST_LOCK" ]; then
  exit 0
fi
exec "$ACTIONS_TEST_REAL_MKDIR" "$@"
EOF
  cat >"$bin/gnumkdir" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >"$ACTIONS_TEST_MKDIR_LOG" || exit
exec "$ACTIONS_TEST_REAL_MKDIR" "$@"
EOF
  chmod 0755 "$bin/mkdir" "$bin/gnumkdir"
)

# Interrupt the installer immediately after the real filesystem operation,
# before its shell can act on the command's status. The PID exported by the
# launcher stays valid even if the installer isolates mkdir in a subshell.
actions_fixture_signal_mkdir() (
  mkdir -p "$1" || exit
  cat >"$1/mkdir" <<'EOF'
#!/bin/sh
for last do :; done
if [ "$last" = "$ACTIONS_TEST_DIRECTORY" ] && [ "${ACTIONS_TEST_CONTENDER:-}" = yes ]; then
  "$ACTIONS_TEST_REAL_MKDIR" "$last" || exit
fi
status=0
"$ACTIONS_TEST_REAL_MKDIR" "$@" || status=$?
if [ "$last" = "$ACTIONS_TEST_DIRECTORY" ]; then
  printf '%s\n' "$status" >"$ACTIONS_TEST_MKDIR_LOG" || exit
  kill -s "$ACTIONS_TEST_SIGNAL" "$ACTIONS_TEST_INSTALLER_PID" || exit
fi
exit "$status"
EOF
  chmod 0755 "$1/mkdir" || exit
  ln -s mkdir "$1/gnumkdir"
)

# Assert both the injection point and the exit status. In the contender case
# the competing mkdir wins just before our command gets EEXIST.
actions_fixture_cancel_mkdir() (
  bin=$1
  ACTIONS_TEST_DIRECTORY=$2
  ACTIONS_TEST_SIGNAL=$3
  expected=$4
  ACTIONS_TEST_CONTENDER=$5
  shift 5
  ACTIONS_TEST_REAL_MKDIR=$(command -v gnumkdir || command -v mkdir) || exit
  ACTIONS_TEST_MKDIR_LOG=$bin/status
  export ACTIONS_TEST_DIRECTORY ACTIONS_TEST_SIGNAL ACTIONS_TEST_CONTENDER
  export ACTIONS_TEST_REAL_MKDIR ACTIONS_TEST_MKDIR_LOG
  rm -f "$ACTIONS_TEST_MKDIR_LOG" || exit
  status=0
  PATH="$bin:$PATH" sh -c 'ACTIONS_TEST_INSTALLER_PID=$$; export ACTIONS_TEST_INSTALLER_PID; exec "$@"' \
    sh "$@" >/dev/null || status=$?
  mkdir_status=$(cat "$ACTIONS_TEST_MKDIR_LOG") || exit
  [ "$status" = "$expected" ] || {
    printf '%s at %s returned %s (expected %s)\n' "$ACTIONS_TEST_SIGNAL" "$ACTIONS_TEST_DIRECTORY" "$status" "$expected" >&2
    exit 1
  }
  if [ "$ACTIONS_TEST_CONTENDER" = yes ]; then
    [ "$mkdir_status" -ne 0 ]
  else
    [ "$mkdir_status" -eq 0 ]
  fi
)
