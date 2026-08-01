#!/usr/bin/env bash
# Validate and lint every shell program owned by this repository.

set -uo pipefail
export NO_COLOR=1
export CDPATH=

pass_count=0
fail_count=0
temp_root=$(mktemp -d) || {
  printf 'shellcheck-inventory: could not create a temporary directory\n' >&2
  exit 1
}
trap 'rm -rf "$temp_root"' EXIT HUP INT TERM

_pass() {
  pass_count=$((pass_count + 1))
  printf 'PASS: %s\n' "$*"
}

_fail() {
  fail_count=$((fail_count + 1))
  printf 'FAIL: %s\n' "$*" >&2
}

_test_summary() {
  printf 'shellcheck-inventory: ok=%s failed=%s\n' "$pass_count" "$fail_count"
  [[ "$fail_count" -eq 0 ]] || exit 1
  exit 0
}

_assert_file_exists() {
  local label=$1 path=$2
  if [[ -f "$path" ]]; then
    _pass "$label"
  else
    _fail "$label"
    _test_summary
  fi
}

echo "=== repository ShellCheck inventory ==="

repo_root_input=${1:-${GITHUB_WORKSPACE:-}}
inventory_path=${2-}

if [[ -z "$repo_root_input" ]] ||
  ! repo_root=$(cd -- "$repo_root_input" 2>/dev/null && pwd -P); then
  _fail "repository root is accessible"
  _test_summary
fi
if ! git_root=$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null) ||
  ! git_root=$(cd -- "$git_root" 2>/dev/null && pwd -P) ||
  [[ "$git_root" != "$repo_root" ]]; then
  _fail "repository root is the Git worktree root"
  _test_summary
fi

_shellcheck_normalized_relative_path() {
  local path=$1
  case "$path" in
    '' | . | .. | /* | ./* | ../* | */. | */.. | */../* | */./* | */ | *//* | *$'\n'* | *$'\t'*)
      return 1
      ;;
  esac
  return 0
}

if ! _shellcheck_normalized_relative_path "$inventory_path"; then
  _fail "inventory path is a normalized repository-relative path"
  _test_summary
fi

inventory_file="$repo_root/$inventory_path"
_assert_file_exists "tracked-file inventory exists" "$inventory_file"
if [[ -L "$inventory_file" ]]; then
  _fail "inventory is a regular file, not a symbolic link"
  _test_summary
fi
if ! inventory_parent=$(cd -- "${inventory_file%/*}" 2>/dev/null && pwd -P) ||
  [[ "$inventory_parent" != "$repo_root" && "$inventory_parent" != "$repo_root"/* ]]; then
  _fail "inventory resolves inside the repository"
  _test_summary
fi
if ! git --literal-pathspecs -C "$repo_root" \
  ls-files --error-unmatch -- "$inventory_path" >/dev/null 2>&1; then
  _fail "inventory is tracked by Git"
  _test_summary
fi

_shellcheck_display_path() {
  printf '%q' "$1"
}

_shellcheck_array_contains() {
  local wanted="$1" candidate
  shift
  for candidate; do
    [[ "$candidate" == "$wanted" ]] && return 0
  done
  return 1
}

_shellcheck_shebang_dialect() {
  local line="${1#\#!}" interpreter index=1 via_env=0 env_split=0
  local -a words=()

  line="${line%$'\r'}"
  read -r -a words <<<"$line"
  [[ "${#words[@]}" -gt 0 ]] || return 1
  [[ "${words[0]}" == /* ]] || return 1
  interpreter="${words[0]##*/}"

  if [[ "$interpreter" == env ]]; then
    via_env=1
    if [[ "${words[index]-}" == -S ]]; then
      env_split=1
      index=$((index + 1))
    elif [[ "${words[index]-}" == -* ]]; then
      return 1
    fi
    interpreter="${words[index]-}"
    interpreter="${interpreter##*/}"
    index=$((index + 1))
  fi

  # Map ash and BusyBox launchers to a supported portable-shell dialect.
  case "$interpreter" in
    sh | bash | dash | ksh) printf '%s\n' "$interpreter" ;;
    ash) printf '%s\n' dash ;;
    busybox)
      [[ "$via_env" -eq 0 || "$env_split" -eq 1 ]] || return 1
      case "${words[index]-}" in
        sh | ash) ;;
        *) return 1 ;;
      esac
      printf '%s\n' sh
      ;;
    *) return 1 ;;
  esac
}

_shellcheck_directive_dialect() {
  local line="$1" dialect
  [[ "$line" =~ ^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]+shell=([^[:space:]]+) ]] ||
    return 1
  dialect="${BASH_REMATCH[1]}"
  case "$dialect" in
    ash) printf '%s\n' dash ;;
    sh | bash | dash | ksh) printf '%s\n' "$dialect" ;;
    # Ubuntu 24.04's ShellCheck 0.9 rejects this directive before -s can
    # provide a fallback. Keep the gate deterministic across tool versions.
    busybox) printf '%s\n' unsupported:busybox ;;
    *) return 1 ;;
  esac
}

_shellcheck_file_is_program() {
  local path="$1"
  case "$path" in
    *.sh | *.bash | *.bats | *.dash | *.ksh) return 0 ;;
  esac
  [[ -f "$repo_root/$path" ]] || return 1
  _shellcheck_file_dialect "$path" >/dev/null
}

_shellcheck_file_dialect() {
  local path="$1" line line_number=0 shebang_dialect="" directive_dialect

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    if [[ "$line_number" -eq 1 && "$line" == '#!'* ]]; then
      shebang_dialect=$(_shellcheck_shebang_dialect "$line") || true
    fi
    if directive_dialect=$(_shellcheck_directive_dialect "$line"); then
      printf '%s\n' "$directive_dialect"
      return 0
    fi

    # Directives belong to the leading comment header, not the script body.
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] || break
  done <"$repo_root/$path"

  if [[ -n "$shebang_dialect" ]]; then
    printf '%s\n' "$shebang_dialect"
    return 0
  fi
  case "$path" in
    *.bash | *.bats) printf '%s\n' bash ;;
    *.dash) printf '%s\n' dash ;;
    *.ksh) printf '%s\n' ksh ;;
    *) return 1 ;;
  esac
}

inventory_paths=()
lint_files=()
fixture_files=()
inventory_ok=1
if IFS= read -r -d '' _inventory_prefix <"$inventory_file"; then
  _fail "shellcheck: inventory contains a NUL byte"
  inventory_ok=0
fi
unset _inventory_prefix
[[ "$inventory_ok" -eq 1 ]] || _test_summary
line_number=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line_number=$((line_number + 1))
  [[ -n "$line" && "$line" != '#'* ]] || continue
  case "$line" in
    *$'\t'*) ;;
    *)
      _fail "shellcheck: malformed inventory record on line $line_number"
      inventory_ok=0
      continue
      ;;
  esac
  type="${line%%$'\t'*}"
  path="${line#*$'\t'}"
  if ! _shellcheck_normalized_relative_path "$path"; then
    _fail "shellcheck: invalid inventory path on line $line_number"
    inventory_ok=0
    continue
  fi
  case "$type" in
    program | fixture) ;;
    *)
      _fail "shellcheck: unknown inventory type '$type' on line $line_number"
      inventory_ok=0
      continue
      ;;
  esac
  if _shellcheck_array_contains "$path" \
    "${inventory_paths[@]+"${inventory_paths[@]}"}"; then
    _fail "shellcheck: duplicate inventory path: $(_shellcheck_display_path "$path")"
    inventory_ok=0
    continue
  fi
  inventory_paths+=("$path")
  if [[ "$type" == fixture ]]; then
    fixture_files+=("$path")
  else
    lint_files+=("$path")
  fi
done <"$inventory_file"

if [[ "${#lint_files[@]}" -eq 0 ]]; then
  _fail "shellcheck: inventory includes at least one program"
  inventory_ok=0
fi

discovery_file="$temp_root/repository-files"
if ! git -C "$repo_root" ls-files -z --cached --others \
  --exclude-standard -- >"$discovery_file"; then
  _fail "shellcheck: repository files can be discovered"
  inventory_ok=0
fi

discovered=()
while IFS= read -r -d '' path; do
  if _shellcheck_file_is_program "$path"; then
    if [[ -L "$repo_root/$path" ]]; then
      _fail "shellcheck: shell program is a symbolic link: $(_shellcheck_display_path "$path")"
      inventory_ok=0
    else
      discovered+=("$path")
    fi
  fi
done <"$discovery_file"

for path in "${discovered[@]+"${discovered[@]}"}"; do
  if ! _shellcheck_array_contains "$path" \
    "${inventory_paths[@]+"${inventory_paths[@]}"}"; then
    _fail "shellcheck: unlisted shell program: $(_shellcheck_display_path "$path")"
    inventory_ok=0
  fi
done
for path in "${inventory_paths[@]+"${inventory_paths[@]}"}"; do
  if ! _shellcheck_array_contains "$path" \
    "${discovered[@]+"${discovered[@]}"}"; then
    _fail "shellcheck: inventory path is not a detected shell program: $(_shellcheck_display_path "$path")"
    inventory_ok=0
  fi
done
[[ "$inventory_ok" -ne 1 ]] ||
  _pass "shellcheck: inventory covers every repository shell program"

printf 'shellcheck: fixture exclusions: %s\n' "${#fixture_files[@]}"
for path in "${fixture_files[@]+"${fixture_files[@]}"}"; do
  printf 'shellcheck: fixture: %s\n' "$(_shellcheck_display_path "$path")"
done

[[ "$inventory_ok" -eq 1 ]] || _test_summary

if ! command -v shellcheck >/dev/null 2>&1; then
  _fail "ShellCheck command is unavailable"
else
  _pass "shellcheck: command is available"
  shellcheck_auto_files=()
  shellcheck_sh_files=()
  shellcheck_bash_files=()
  shellcheck_dash_files=()
  shellcheck_ksh_files=()
  for path in "${lint_files[@]}"; do
    if dialect=$(_shellcheck_file_dialect "$path"); then
      case "$dialect" in
        sh) shellcheck_sh_files+=("$path") ;;
        bash) shellcheck_bash_files+=("$path") ;;
        dash) shellcheck_dash_files+=("$path") ;;
        ksh) shellcheck_ksh_files+=("$path") ;;
        unsupported:*)
          _fail "shellcheck: unsupported directive dialect '${dialect#*:}' in $(_shellcheck_display_path "$path")"
          ;;
      esac
    else
      shellcheck_auto_files+=("$path")
    fi
  done
  [[ "$fail_count" -eq 0 ]] || _test_summary
  if (
    cd "$repo_root" || exit 1
    shellcheck_status=0
    [[ "${#shellcheck_auto_files[@]}" -eq 0 ]] ||
      shellcheck -x -P SCRIPTDIR -- "${shellcheck_auto_files[@]}" || shellcheck_status=1
    [[ "${#shellcheck_sh_files[@]}" -eq 0 ]] ||
      shellcheck -x -P SCRIPTDIR -s sh -- "${shellcheck_sh_files[@]}" || shellcheck_status=1
    [[ "${#shellcheck_bash_files[@]}" -eq 0 ]] ||
      shellcheck -x -P SCRIPTDIR -s bash -- "${shellcheck_bash_files[@]}" || shellcheck_status=1
    [[ "${#shellcheck_dash_files[@]}" -eq 0 ]] ||
      shellcheck -x -P SCRIPTDIR -s dash -- "${shellcheck_dash_files[@]}" || shellcheck_status=1
    [[ "${#shellcheck_ksh_files[@]}" -eq 0 ]] ||
      shellcheck -x -P SCRIPTDIR -s ksh -- "${shellcheck_ksh_files[@]}" || shellcheck_status=1
    exit "$shellcheck_status"
  ); then
    _pass "shellcheck: repository shell programs pass"
  else
    _fail "shellcheck: repository shell programs pass"
  fi
fi

_test_summary
