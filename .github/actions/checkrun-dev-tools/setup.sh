#!/usr/bin/env bash
set -euo pipefail

retry() {
  # mise, rustup, and pip all touch the network. Retrying here avoids noisy CI
  # failures from transient registry/network blips while still surfacing a real
  # failure after three attempts.
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

curl https://mise.run | sh
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

if [ -n "${GITHUB_TOKEN:-}" ]; then
  # mise/aqua/ubi can hit GitHub API limits when resolving release metadata.
  # Reusing the Actions token keeps installs reliable without granting write
  # permissions.
  export MISE_GITHUB_TOKEN="$GITHUB_TOKEN"
fi

export MISE_GLOBAL_CONFIG_FILE="$PWD/.github/mise/checkrun-ci.toml"
echo "MISE_GLOBAL_CONFIG_FILE=$MISE_GLOBAL_CONFIG_FILE" >>"$GITHUB_ENV"
# Trust the checked-in CI tool manifest so mise can install without prompting.
mise trust "$MISE_GLOBAL_CONFIG_FILE" >/dev/null || true
retry mise install

# checkrun tests exercise Python linters/formatters through real commands, so
# install those Python-only tools into a workspace-local virtualenv.
python3 -m venv "$HOME/.venv"
"$HOME/.venv/bin/python" -m pip install --upgrade pip
"$HOME/.venv/bin/python" -m pip install clang-format jsonschema PyYAML tomli

curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal --component rustfmt

# Persist tool paths for the final test step in the reusable workflow.
{
  echo "$HOME/.local/bin"
  echo "$HOME/.local/share/mise/shims"
  echo "$HOME/.venv/bin"
  echo "$HOME/.cargo/bin"
} >>"$GITHUB_PATH"
