#!/usr/bin/env bash
set -euo pipefail

retry() {
  # The engine bootstrap, dot update, and mise install depend on external
  # package hosts. Retry each command as a unit so flakes do not mask whether
  # the bootstrap logic works.
  local attempt rc delay
  for attempt in 1 2 3; do
    if "$@"; then
      return 0
    else
      rc=$?
    fi

    if [ "$attempt" -eq 3 ]; then
      return "$rc"
    fi

    delay=$((attempt * 15))
    echo "$* failed (attempt $attempt/3, exit $rc); retrying in ${delay}s..." >&2
    sleep "$delay"
  done
}

dotfiles_bootstrap_read_cutover() {
  local lock=$1 size header revision_line extra=''

  [[ -f "$lock" && ! -L "$lock" ]] || return 1
  size=$(wc -c <"$lock" 2>/dev/null) || return 1
  size=${size//[[:space:]]/}
  case $size in
    '' | *[!0-9]*) return 1 ;;
  esac
  [[ ${#size} -le 4 && $size -le 1024 ]] || return 1
  {
    IFS= read -r header || return 1
    IFS= read -r revision_line || return 1
    if IFS= read -r extra || [[ -n $extra ]]; then
      return 1
    fi
  } <"$lock"
  [[ $header == 'cgraf78 dot client cutover v1' &&
    $revision_line == minimum_revision=* ]] || return 1
  revision_line=${revision_line#minimum_revision=}
  [[ $revision_line =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$revision_line"
}

dotfiles_bootstrap_locked_engine() {
  local revision=$1 repo_url staging origin installer fetched tree metadata path
  local stage_parent=${RUNNER_TEMP:-${TMPDIR:-/tmp}}

  repo_url=${DOTFILES_BOOTSTRAP_DOT_REPO_URL:-https://github.com/cgraf78/dot.git}
  staging=$(mktemp -d "$stage_parent/dotfiles-bootstrap.XXXXXXXX") || return 1
  chmod 0700 "$staging"
  origin=$staging/dot-origin.git
  installer=$staging/install.sh

  git init --quiet --bare "$origin"
  retry git --git-dir="$origin" fetch --quiet --force --no-tags --depth=1 \
    "$repo_url" "$revision"
  fetched=$(git --git-dir="$origin" rev-parse --verify 'FETCH_HEAD^{commit}')
  [[ $fetched == "$revision" ]] || {
    echo "dot bootstrap fetched $fetched, expected $revision" >&2
    return 1
  }
  git --git-dir="$origin" update-ref refs/heads/main "$revision"
  git --git-dir="$origin" symbolic-ref HEAD refs/heads/main

  tree=$(git --git-dir="$origin" ls-tree "$revision" -- install.sh) || return 1
  IFS=$'\t' read -r metadata path <<<"$tree"
  # shellcheck disable=SC2086 # The fixed three-field ls-tree header is parsed deliberately.
  set -- $metadata
  [[ $# -eq 3 && $1 == 100755 && $2 == blob &&
    $3 =~ ^[0-9a-f]{40}$ && $path == install.sh ]] || {
    echo "locked dot revision has an unsafe installer entry: $revision" >&2
    return 1
  }
  git --git-dir="$origin" show "$revision:install.sh" >"$installer"
  chmod 0600 "$installer"

  export CGRAF78_CHECKOUT_INSTALL_REPO_URL=$origin
  export SHDEPS_DOT_REPO=$origin
  # The installed checkout keeps this exact origin for the rest of the job.
  # Preserve it beyond this composite-action step instead of introducing a
  # second hard-coded dot revision or racing the public branch tip.
  printf 'SHDEPS_DOT_REPO=%s\n' "$origin" >>"$GITHUB_ENV"
  bash "$installer"
}

# Retry the network-heavy bootstrap path. Once dot update installs mise,
# explicitly verify the tools that later dotfiles checks rely on so a partial
# bootstrap failure is reported at the source. Keep CI setup non-quiet: the
# dependency logs are the evidence we need when bootstrap behavior regresses.
dot_update_args=(--skip-pull)
cutover_lock=$HOME/.local/lib/dotfiles/dot-cutover.lock
if [[ -e "$cutover_lock" || -L "$cutover_lock" ]]; then
  dot_revision=$(dotfiles_bootstrap_read_cutover "$cutover_lock") || {
    echo "unsafe or malformed dot cutover lock: $cutover_lock" >&2
    exit 1
  }
  dotfiles_bootstrap_locked_engine "$dot_revision"
  dot_update_args=()
fi
retry .local/bin/dot update "${dot_update_args[@]}"

export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
if [ "Alpine" = "${MATRIX_NAME:-}" ]; then
  # Alpine is a musl smoke target for dotfiles shell behavior. Some global mise
  # tools, such as zizmor, only publish glibc Linux artifacts, so the full
  # editor/linter toolset is intentionally not enforced there.
  echo "full mise tool verification is skipped on Alpine" >&2
elif command -v mise >/dev/null 2>&1 && mise --version >/dev/null 2>&1; then
  mise trust "$HOME/.config/mise/config.toml" >/dev/null || true
  if [ -z "${MISE_GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    # Dotfiles' mise config installs several GitHub-hosted tools. The token
    # reduces rate-limit failures while keeping the workflow read-only.
    export MISE_GITHUB_TOKEN="$GITHUB_TOKEN"
  fi
  retry mise install

  # These commands are required by later dotfiles checks. Verifying them here
  # makes bootstrap failures point to the install step instead of a later test.
  for tool in actionlint ruff shellcheck shfmt zizmor; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "$tool missing after mise install" >&2
      exit 1
    fi
  done
else
  echo "mise missing or unusable after dot update" >&2
  exit 1
fi

{
  echo "$HOME/.local/bin"
  echo "$HOME/.local/share/mise/shims"
} >>"$GITHUB_PATH"
