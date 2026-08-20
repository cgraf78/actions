#!/usr/bin/env bash
set -euo pipefail

root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
lock_file="$root/.github/cgraf78-actions.lock"
timeout_secs=${CGRAF78_SELF_PIN_NETWORK_TIMEOUT_SECS:-120}
timeout_command=${CGRAF78_SELF_PIN_TIMEOUT_COMMAND:-}

if [[ ! "$timeout_secs" =~ ^[1-9][0-9]*$ || "$timeout_secs" -gt 600 ]]; then
  printf 'retain-self-pin: invalid network timeout: %s\n' "$timeout_secs" >&2
  exit 2
fi
if [[ -n "$timeout_command" ]]; then
  if ! timeout_command=$(command -v "$timeout_command"); then
    printf 'retain-self-pin: configured timeout command is unavailable: %s\n' \
      "$CGRAF78_SELF_PIN_TIMEOUT_COMMAND" >&2
    exit 2
  fi
elif timeout_command=$(command -v timeout 2>/dev/null); then
  :
elif timeout_command=$(command -v gtimeout 2>/dev/null); then
  :
else
  printf '%s\n' \
    'retain-self-pin: timeout or gtimeout is required; install GNU coreutils and retry' >&2
  exit 2
fi
if [[ ! -f "$lock_file" || -L "$lock_file" ]]; then
  printf 'retain-self-pin: missing regular provider lock: %s\n' "$lock_file" >&2
  exit 1
fi

actions_sha=$(tr -d '\n' <"$lock_file")
if [[ ! "$actions_sha" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'retain-self-pin: provider lock is not a full commit SHA: %s\n' \
    "$actions_sha" >&2
  exit 1
fi
if [[ -n $(git -C "$root" status --porcelain --untracked-files=normal) ]]; then
  printf '%s\n' \
    'retain-self-pin: provider checkout is dirty; commit or discard changes before retaining a self-pin' >&2
  exit 1
fi
if ! git -C "$root" cat-file -e "$actions_sha^{commit}" 2>/dev/null; then
  printf 'retain-self-pin: provider lock commit is not available locally: %s\n' \
    "$actions_sha" >&2
  exit 1
fi
if ! git -C "$root" diff --quiet "$actions_sha"..HEAD -- .github/actions; then
  cat >&2 <<EOF
retain-self-pin: internal action implementations differ from lock $actions_sha
Commit the implementation, run consumer-ci/sync.sh --self, and commit the generated lock and refs before retention.
EOF
  exit 1
fi

tag_name="self-pin/$actions_sha"
tag_ref="refs/tags/$tag_name"

network_git() {
  local operation=$1
  shift
  local status

  set +e
  "$timeout_command" -k 5 "$timeout_secs" git \
    -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=30 "$@"
  status=$?
  set -e
  if [[ "$status" -eq 124 ]]; then
    printf 'infra-stall: self-pin %s exceeded %s seconds\n' \
      "$operation" "$timeout_secs" >&2
  fi
  return "$status"
}

read_remote_tag() {
  local output status line_count remote_ref

  set +e
  output=$(cd "$root" && network_git 'tag lookup' \
    ls-remote --refs origin "$tag_ref")
  status=$?
  set -e
  [[ "$status" -eq 0 ]] || return "$status"
  if [[ -z "$output" ]]; then
    remote_tag_sha=
    return 0
  fi
  line_count=$(printf '%s\n' "$output" | awk 'END { print NR }')
  if [[ "$line_count" -ne 1 || "$output" != *$'\t'* ]]; then
    printf 'retain-self-pin: unexpected remote tag response for %s: %s\n' \
      "$tag_ref" "$output" >&2
    return 1
  fi
  remote_tag_sha=${output%%$'\t'*}
  remote_ref=${output#*$'\t'}
  if [[ ! "$remote_tag_sha" =~ ^[0-9a-f]{40}$ || "$remote_ref" != "$tag_ref" ]]; then
    printf 'retain-self-pin: unexpected remote tag response for %s: %s\n' \
      "$tag_ref" "$output" >&2
    return 1
  fi
}

remote_tag_sha=
if ! read_remote_tag; then
  printf 'retain-self-pin: cannot inspect retention tag: %s\n' "$tag_ref" >&2
  exit 1
fi
if [[ -n "$remote_tag_sha" ]]; then
  if [[ "$remote_tag_sha" != "$actions_sha" ]]; then
    printf 'retain-self-pin: retention tag %s points to %s, want %s; refusing to move it\n' \
      "$tag_ref" "$remote_tag_sha" "$actions_sha" >&2
    exit 1
  fi
  printf 'retain-self-pin: retained %s at %s\n' "$tag_ref" "$actions_sha"
  exit 0
fi

set +e
(cd "$root" && network_git 'tag push' \
  push origin "$actions_sha:$tag_ref")
push_status=$?
set -e
if [[ "$push_status" -ne 0 ]]; then
  # A transport failure can race a successful remote mutation. Reconcile the
  # exact content-addressed ref before deciding whether the operation failed.
  remote_tag_sha=
  if read_remote_tag && [[ "$remote_tag_sha" == "$actions_sha" ]]; then
    printf 'retain-self-pin: retained %s at %s\n' "$tag_ref" "$actions_sha"
    exit 0
  fi
  printf 'retain-self-pin: cannot create retention tag %s at %s; retry this command after restoring network access\n' \
    "$tag_ref" "$actions_sha" >&2
  exit "$push_status"
fi

remote_tag_sha=
if ! read_remote_tag || [[ "$remote_tag_sha" != "$actions_sha" ]]; then
  printf 'retain-self-pin: pushed retention tag did not reconcile to %s: %s\n' \
    "$actions_sha" "$tag_ref" >&2
  exit 1
fi
printf 'retain-self-pin: retained %s at %s\n' "$tag_ref" "$actions_sha"
