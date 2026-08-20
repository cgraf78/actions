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

timeout_secs=${CGRAF78_SELF_PIN_NETWORK_TIMEOUT_SECS:-120}
timeout_command=${CGRAF78_SELF_PIN_TIMEOUT_COMMAND:-}
if [[ ! "$timeout_secs" =~ ^[1-9][0-9]*$ || "$timeout_secs" -gt 600 ]]; then
  printf 'verify-self-pin: invalid network timeout: %s\n' "$timeout_secs" >&2
  exit 2
fi
if [[ -n "$timeout_command" ]]; then
  if ! timeout_command=$(command -v "$timeout_command"); then
    printf 'verify-self-pin: configured timeout command is unavailable: %s\n' \
      "$CGRAF78_SELF_PIN_TIMEOUT_COMMAND" >&2
    exit 2
  fi
elif timeout_command=$(command -v timeout 2>/dev/null); then
  :
elif timeout_command=$(command -v gtimeout 2>/dev/null); then
  :
else
  printf '%s\n' \
    'verify-self-pin: timeout or gtimeout is required; install GNU coreutils and retry' >&2
  exit 2
fi
tag_ref="refs/tags/self-pin/$actions_sha"
export GIT_TERMINAL_PROMPT=0
fetch_args=(fetch --no-tags)
if [[ $(git -C "$root" rev-parse --is-shallow-repository) == true ]]; then
  fetch_args+=(--depth=1)
fi
fetch_args+=(origin "$tag_ref")
set +e
"$timeout_command" -k 5 "$timeout_secs" git -C "$root" \
  -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=30 \
  "${fetch_args[@]}"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  if [[ "$rc" -eq 124 ]]; then
    printf 'infra-stall: provider retention tag fetch exceeded %s seconds\n' \
      "$timeout_secs" >&2
  fi
  cat >&2 <<EOF
verify-self-pin: implementation commit is not retained by $tag_ref
Run consumer-ci/retain-self-pin.sh, then rerun this check before squash-merging.
EOF
  exit "$rc"
fi
fetched_sha=$(git -C "$root" rev-parse FETCH_HEAD)
if [[ "$fetched_sha" != "$actions_sha" ]]; then
  printf 'verify-self-pin: retention tag %s resolved to %s, want %s\n' \
    "$tag_ref" "$fetched_sha" "$actions_sha" >&2
  exit 1
fi

if ! git -C "$root" diff --quiet "$actions_sha"..HEAD -- .github/actions; then
  cat >&2 <<EOF
verify-self-pin: internal action implementations differ from lock $actions_sha
Commit the implementation, then run consumer-ci/sync.sh --self and commit the generated lock and refs.
EOF
  exit 1
fi

printf 'verify-self-pin: internal actions match %s\n' "$actions_sha"
