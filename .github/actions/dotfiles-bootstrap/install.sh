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

dotfiles_bootstrap_file_has_mode() {
  local path=$1 expected=$2 mode

  if mode=$(stat -c '%a' "$path" 2>/dev/null); then
    case $mode in
      '' | *[!0-7]*) return 1 ;;
    esac
    [[ $mode == "$expected" || $mode == "0$expected" ]]
    return
  fi
  mode=$(stat -f '%Lp' "$path" 2>/dev/null) || return 1
  case $mode in
    '' | *[!0-7]*) return 1 ;;
  esac
  [[ $mode == "$expected" || $mode == "0$expected" ]]
}

dotfiles_bootstrap_engine_git() {
  # Replacement refs are ambient repository state. Revision verification and
  # installer extraction must address the fetched object itself; otherwise
  # rev-parse can match the lock while ls-tree or show reads substituted bytes.
  GIT_NO_REPLACE_OBJECTS=1 git "$@"
}

dotfiles_bootstrap_verify_engine_origin() {
  local origin=$1 revision=$2 fetched head tree metadata path

  [[ -d "$origin" && ! -L "$origin" ]] || {
    echo "dot bootstrap origin is not a regular directory: $origin" >&2
    return 1
  }
  fetched=$(dotfiles_bootstrap_engine_git --git-dir="$origin" rev-parse --verify \
    'refs/heads/main^{commit}' 2>/dev/null) || return 1
  [[ $fetched == "$revision" ]] || {
    echo "dot bootstrap origin has $fetched, expected $revision" >&2
    return 1
  }
  head=$(dotfiles_bootstrap_engine_git --git-dir="$origin" \
    symbolic-ref HEAD 2>/dev/null) || return 1
  [[ $head == refs/heads/main ]] || {
    echo "dot bootstrap origin has an unexpected HEAD: $head" >&2
    return 1
  }
  tree=$(dotfiles_bootstrap_engine_git --git-dir="$origin" \
    ls-tree "$revision" -- install.sh) || return 1
  IFS=$'\t' read -r metadata path <<<"$tree"
  # shellcheck disable=SC2086 # The fixed three-field ls-tree header is parsed deliberately.
  set -- $metadata
  [[ $# -eq 3 && $1 == 100755 && $2 == blob &&
    $3 =~ ^[0-9a-f]{40}$ && $path == install.sh ]] || {
    echo "locked dot revision has an unsafe installer entry: $revision" >&2
    return 1
  }
}

dotfiles_bootstrap_prepare_engine_origin() {
  local revision=$1 staging=$2 repo_url origin fetched

  [[ -d "$staging" && ! -L "$staging" ]] || return 1
  origin=$staging/dot-origin.git
  [[ ! -e "$origin" && ! -L "$origin" ]] || return 1
  repo_url=${DOTFILES_BOOTSTRAP_DOT_REPO_URL:-https://github.com/cgraf78/dot.git}
  dotfiles_bootstrap_engine_git init --quiet --bare "$origin"
  retry dotfiles_bootstrap_engine_git --git-dir="$origin" fetch --quiet \
    --force --no-tags --depth=1 "$repo_url" "$revision"
  fetched=$(dotfiles_bootstrap_engine_git --git-dir="$origin" \
    rev-parse --verify 'FETCH_HEAD^{commit}')
  [[ $fetched == "$revision" ]] || {
    echo "dot bootstrap fetched $fetched, expected $revision" >&2
    return 1
  }
  dotfiles_bootstrap_engine_git --git-dir="$origin" \
    update-ref refs/heads/main "$revision"
  dotfiles_bootstrap_engine_git --git-dir="$origin" \
    symbolic-ref HEAD refs/heads/main
  dotfiles_bootstrap_verify_engine_origin "$origin" "$revision"
}

dotfiles_bootstrap_install_engine_origin() {
  local revision=$1 origin=$2 installer origin_url
  local stage_parent=${RUNNER_TEMP:-${TMPDIR:-/tmp}}

  dotfiles_bootstrap_verify_engine_origin "$origin" "$revision" || return 1
  installer=$(mktemp "$stage_parent/dotfiles-bootstrap-installer.XXXXXXXX") ||
    return 1
  dotfiles_bootstrap_engine_git --git-dir="$origin" \
    show "$revision:install.sh" >"$installer"
  chmod 0600 "$installer"

  # Git's local-path clone optimization hardlinks object files and ignores
  # shallow-clone bounds. A file URL keeps the checkout self-contained while
  # retaining this already-verified local origin as the only source of bytes.
  origin_url=file://$origin
  export CGRAF78_CHECKOUT_INSTALL_REPO_URL=$origin_url
  export SHDEPS_DOT_REPO=$origin_url
  # Both exports are intentional: the checkout installer consumes the first
  # for managed checkout clone/update, while Dot/Shdeps consumes the second for
  # later provider operations. Keep both bound to this one verified origin and
  # preserve it beyond this composite-action step instead of introducing a
  # second hard-coded revision or racing the public branch tip.
  if [[ -n ${GITHUB_ENV:-} ]]; then
    printf 'SHDEPS_DOT_REPO=%s\n' "$origin_url" >>"$GITHUB_ENV"
  fi
  GIT_NO_REPLACE_OBJECTS=1 bash "$installer"
}

dotfiles_bootstrap_locked_engine() {
  local revision=$1 staging
  local stage_parent=${RUNNER_TEMP:-${TMPDIR:-/tmp}}

  staging=$(mktemp -d "$stage_parent/dotfiles-bootstrap.XXXXXXXX") || return 1
  chmod 0700 "$staging"
  dotfiles_bootstrap_prepare_engine_origin "$revision" "$staging" || return 1
  dotfiles_bootstrap_install_engine_origin \
    "$revision" "$staging/dot-origin.git"
}

dotfiles_bootstrap_stage_payload() {
  local revision=$1 destination=$2 parent marker_tmp

  case $destination in
    /*) ;;
    *)
      echo 'dotfiles bootstrap stage directory must be absolute' >&2
      return 1
      ;;
  esac
  parent=${destination%/*}
  [[ -n "$parent" && "$parent" != "$destination" &&
    -d "$parent" && ! -L "$parent" ]] || {
    echo "dotfiles bootstrap stage parent is not a regular directory: $parent" >&2
    return 1
  }
  [[ ! -e "$destination" && ! -L "$destination" ]] || {
    echo "dotfiles bootstrap stage destination already exists: $destination" >&2
    return 1
  }
  [[ -f "$0" && ! -L "$0" ]] || {
    echo "dotfiles bootstrap source is not a regular file: $0" >&2
    return 1
  }

  mkdir "$destination" || return 1
  chmod 0700 "$destination"
  dotfiles_bootstrap_prepare_engine_origin "$revision" "$destination" ||
    return 1
  cp "$0" "$destination/bootstrap.sh" || return 1
  chmod 0500 "$destination/bootstrap.sh"
  marker_tmp=$destination/.payload-v1.tmp
  (
    umask 077
    printf '%s\n' 'cgraf78 dotfiles bootstrap payload v1' >"$marker_tmp"
  ) || return 1
  chmod 0400 "$marker_tmp" || return 1
  dotfiles_bootstrap_file_has_mode "$marker_tmp" 400 || {
    echo 'dotfiles bootstrap completion marker has an unsafe mode' >&2
    return 1
  }
  # This rename is the payload commit point and deliberately remains the
  # function's final filesystem operation.
  mv "$marker_tmp" "$destination/payload-v1"
}

dotfiles_bootstrap_staged_origin() {
  local payload=$1 revision=$2 marker extra='' script_parent payload_root origin

  [[ -d "$payload" && ! -L "$payload" ]] || return 1
  [[ -f "$payload/payload-v1" && ! -L "$payload/payload-v1" ]] || return 1
  dotfiles_bootstrap_file_has_mode "$payload/payload-v1" 400 || {
    echo 'staged dotfiles bootstrap marker has an unsafe mode' >&2
    return 1
  }
  {
    IFS= read -r marker || return 1
    if IFS= read -r extra || [[ -n $extra ]]; then
      return 1
    fi
  } <"$payload/payload-v1"
  [[ $marker == 'cgraf78 dotfiles bootstrap payload v1' ]] || return 1
  [[ ${0##*/} == bootstrap.sh && -f "$0" && ! -L "$0" ]] || return 1
  script_parent=${0%/*}
  [[ -n "$script_parent" && "$script_parent" != "$0" ]] || return 1
  script_parent=$(cd -P -- "$script_parent" 2>/dev/null && pwd -P) || return 1
  payload_root=$(cd -P -- "$payload" 2>/dev/null && pwd -P) || return 1
  [[ $script_parent == "$payload_root" ]] || return 1

  origin=$payload/dot-origin.git
  dotfiles_bootstrap_verify_engine_origin "$origin" "$revision" || return 1
  DOTFILES_BOOTSTRAP_STAGED_ORIGIN=$origin
}

dotfiles_bootstrap_adopt_client() {
  local branch origin

  [[ -d "$HOME/.git" && ! -L "$HOME/.git" ]] || {
    echo "dotfiles bootstrap requires an ordinary Git checkout at HOME: $HOME" >&2
    return 1
  }
  origin=$(git -C "$HOME" config --local --get-all remote.origin.url 2>/dev/null) || {
    echo 'dotfiles bootstrap requires exactly one client origin URL' >&2
    return 1
  }
  if [[ -z "$origin" || "$origin" == *$'\n'* || "$origin" == *$'\r'* ]]; then
    echo 'dotfiles bootstrap requires exactly one single-line client origin URL' >&2
    return 1
  fi
  # Keep the historical no-pull CI contract for both detached pull-request
  # merges and attached push/schedule checkouts. A local branch at the exact
  # tested commit lets dot bind durable ordinary-checkout identity while the
  # missing upstream makes repository convergence preserve that generation.
  branch=dot-ci-bootstrap
  git -C "$HOME" checkout --quiet -B "$branch" HEAD || return 1
  git -C "$HOME" config --local --unset-all "branch.$branch.remote" \
    >/dev/null 2>&1 || true
  git -C "$HOME" config --local --unset-all "branch.$branch.merge" \
    >/dev/null 2>&1 || true
  if git -C "$HOME" rev-parse --verify '@{u}' >/dev/null 2>&1; then
    echo 'dotfiles bootstrap synthetic client branch unexpectedly has an upstream' >&2
    return 1
  fi
  retry .local/bin/dot init --branch "$branch" "$origin"
}

dotfiles_bootstrap_require_cutover_revision() {
  local lock=$HOME/.local/lib/dotfiles/dot-cutover.lock

  [[ -e "$lock" || -L "$lock" ]] || {
    echo "dotfiles bootstrap requires a cutover lock: $lock" >&2
    return 1
  }
  DOTFILES_BOOTSTRAP_CUTOVER_REVISION=$(dotfiles_bootstrap_read_cutover "$lock") || {
    echo "unsafe or malformed dot cutover lock: $lock" >&2
    return 1
  }
}

dotfiles_bootstrap_require_stage_directory() {
  local mode=$1 destination=$2

  [[ -n "$destination" ]] || {
    echo "dotfiles bootstrap $mode mode requires a stage directory" >&2
    return 1
  }
  # `install-staged` may persist the derived origin through GITHUB_ENV. Reject
  # line breaks before any filesystem mutation so the path cannot create an
  # additional or malformed environment record.
  case $destination in
    *$'\n'* | *$'\r'*)
      echo 'dotfiles bootstrap stage directory must be a single-line path' >&2
      return 1
      ;;
  esac
}

dotfiles_bootstrap_use_checkout_roots() {
  # CI runners can inherit XDG roots that point outside the checked-out HOME.
  # Dot must discover the client's committed config and publish all generated
  # state below that checkout, so remove only the path-root overrides. Keep the
  # rest of the caller environment intact for client-specific bootstrap policy.
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME \
    XDG_RUNTIME_DIR
}

bootstrap_mode=${DOTFILES_BOOTSTRAP_MODE:-full}
stage_directory=${DOTFILES_BOOTSTRAP_STAGE_DIR:-}
# GitHub resolves the composite action on the host, outside sandboxes such as
# the Termux guest. `stage` prepares one locked, self-verifying payload there;
# `install-staged` consumes that payload without choosing a second revision.
case $bootstrap_mode in
  stage)
    dotfiles_bootstrap_require_stage_directory \
      "$bootstrap_mode" "$stage_directory" || exit 2
    dotfiles_bootstrap_require_cutover_revision
    dotfiles_bootstrap_stage_payload \
      "$DOTFILES_BOOTSTRAP_CUTOVER_REVISION" "$stage_directory"
    exit 0
    ;;
  install-staged)
    dotfiles_bootstrap_require_stage_directory \
      "$bootstrap_mode" "$stage_directory" || exit 2
    dotfiles_bootstrap_require_cutover_revision
    dotfiles_bootstrap_staged_origin \
      "$stage_directory" "$DOTFILES_BOOTSTRAP_CUTOVER_REVISION"
    dotfiles_bootstrap_use_checkout_roots
    dotfiles_bootstrap_install_engine_origin \
      "$DOTFILES_BOOTSTRAP_CUTOVER_REVISION" \
      "$DOTFILES_BOOTSTRAP_STAGED_ORIGIN"
    dotfiles_bootstrap_adopt_client
    exit 0
    ;;
  full) ;;
  *)
    echo "unsupported dotfiles bootstrap mode: $bootstrap_mode" >&2
    exit 2
    ;;
esac

dotfiles_bootstrap_use_checkout_roots

# Retry the network-heavy bootstrap path. Once dot update installs mise,
# explicitly verify the tools that later dotfiles checks rely on so a partial
# bootstrap failure is reported at the source. Keep CI setup non-quiet: the
# dependency logs are the evidence we need when bootstrap behavior regresses.
standalone_engine=false
cutover_lock=$HOME/.local/lib/dotfiles/dot-cutover.lock
if [[ -e "$cutover_lock" || -L "$cutover_lock" ]]; then
  dot_revision=$(dotfiles_bootstrap_read_cutover "$cutover_lock") || {
    echo "unsafe or malformed dot cutover lock: $cutover_lock" >&2
    exit 1
  }
  dotfiles_bootstrap_locked_engine "$dot_revision"
  standalone_engine=true
fi
if [[ "$standalone_engine" == true ]]; then
  dotfiles_bootstrap_adopt_client
else
  retry .local/bin/dot update --skip-pull
fi

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
