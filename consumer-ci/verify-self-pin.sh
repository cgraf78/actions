#!/usr/bin/env bash
set -euo pipefail

root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
lock_file="$root/.github/cgraf78-actions.lock"

if [[ ! -f "$lock_file" || -L "$lock_file" ]]; then
  printf 'verify-self-pin: missing regular provider lock: %s\n' "$lock_file" >&2
  exit 1
fi

actions_sha=$(tr -d '\n' <"$lock_file")
if [[ ! "$actions_sha" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'verify-self-pin: provider lock is not a full commit SHA: %s\n' \
    "$actions_sha" >&2
  exit 1
fi

if ! git -C "$root" cat-file -e "$actions_sha^{commit}" 2>/dev/null; then
  export GIT_TERMINAL_PROMPT=0
  if timeout -k 5 120 git -C "$root" \
    -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=30 \
    fetch --no-tags --depth=1 origin "$actions_sha"; then
    :
  else
    rc=$?
    if [[ $rc -eq 124 ]]; then
      printf 'infra-stall: provider lock fetch exceeded 120 seconds\n' >&2
    fi
    printf 'verify-self-pin: cannot fetch provider lock commit: %s\n' \
      "$actions_sha" >&2
    exit "$rc"
  fi
fi

if ! git -C "$root" diff --quiet "$actions_sha"..HEAD -- .github/actions; then
  cat >&2 <<EOF
verify-self-pin: internal action implementations differ from lock $actions_sha
Commit the implementation, then run consumer-ci/sync.sh --self and commit the generated lock and refs.
EOF
  exit 1
fi

printf 'verify-self-pin: internal actions match %s\n' "$actions_sha"
