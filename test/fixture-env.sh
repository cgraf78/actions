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
