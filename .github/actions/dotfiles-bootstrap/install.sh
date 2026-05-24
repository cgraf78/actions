#!/usr/bin/env bash
set -euo pipefail

retry() {
  # dot update and mise install both depend on external package hosts. Retry the
  # command as a unit so flakes do not mask whether the bootstrap logic works.
  local attempt rc delay
  for attempt in 1 2 3; do
    if "$@"; then
      return 0
    fi

    rc=$?
    if [ "$attempt" -eq 3 ]; then
      return "$rc"
    fi

    delay=$((attempt * 15))
    echo "$* failed (attempt $attempt/3, exit $rc); retrying in ${delay}s..." >&2
    sleep "$delay"
  done
}

# Retry the network-heavy bootstrap path. Once dot update installs mise,
# explicitly verify the tools that later dotfiles checks rely on so a partial
# bootstrap failure is reported at the source.
retry .local/bin/dot update --skip-pull --quiet

export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
if command -v mise >/dev/null 2>&1 && mise --version >/dev/null 2>&1; then
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
elif [ "Alpine" = "${MATRIX_NAME:-}" ]; then
  # The current dotfiles bootstrap cannot provide mise on Alpine, but Alpine is
  # still useful for the shell portions of the test suite.
  echo "mise is unavailable on Alpine; skipping explicit mise install verification" >&2
else
  echo "mise missing or unusable after dot update" >&2
  exit 1
fi

{
  echo "$HOME/.local/bin"
  echo "$HOME/.local/share/mise/shims"
} >>"$GITHUB_PATH"

