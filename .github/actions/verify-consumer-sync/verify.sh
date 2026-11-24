#!/usr/bin/env bash
set -euo pipefail

# Verify the consumer's single-source cgraf78/actions lock and vendored tools.
#
# Literal workflow refs are unavoidable because GitHub resolves `uses:` before
# a job can read repository files. This check turns those literals into derived
# data by requiring every one of them to equal the tracked lock.

repo_root=${GITHUB_WORKSPACE:-$PWD}
repo_root=$(git -C "$repo_root" rev-parse --show-toplevel)
export GITHUB_ACTION_PATH
GITHUB_ACTION_PATH=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=capability-layouts.sh
. "$GITHUB_ACTION_PATH/capability-layouts.sh"
# shellcheck source=references.sh
. "$GITHUB_ACTION_PATH/references.sh"
# shellcheck source=tracked-paths.sh
. "$GITHUB_ACTION_PATH/tracked-paths.sh"

lock_file=.github/cgraf78-actions.lock
release_config=scripts/release.conf
release_manifest=scripts/.release-scripts.manifest
checkout_config=scripts/checkout-installer.conf
shdeps_hooks=.config/shdeps/hooks.d
harness_layouts=$(capability_harness_layouts)
markers=("$lock_file" "$release_config" "$release_manifest" "$checkout_config")
for tool in tmux wezterm; do
  markers+=("$shdeps_hooks/$tool.sh" "$shdeps_hooks/$tool-build.lock")
done
while IFS= read -r harness_dir; do
  markers+=("$harness_dir/capability-harness.conf" "$harness_dir/.capability-harness.manifest")
done <<<"$harness_layouts"
tracked_paths=$(consumer_index_paths "$repo_root" "${markers[@]}")

if ! consumer_tracks "$tracked_paths" "$lock_file"; then
  printf 'verify-consumer-sync: lock file is not tracked: %s\n' "$lock_file" >&2
  exit 1
fi
if [[ ! -f "$repo_root/$lock_file" || -L "$repo_root/$lock_file" ]]; then
  printf 'verify-consumer-sync: lock must be a regular non-symlink file: %s\n' \
    "$lock_file" >&2
  exit 1
fi
if [[ -x "$repo_root/$lock_file" ]]; then
  printf 'verify-consumer-sync: lock must not be executable: %s\n' \
    "$lock_file" >&2
  exit 1
fi

actions_sha=$(tr -d '\n' <"$repo_root/$lock_file")
if [[ ! "$actions_sha" =~ ^[0-9a-f]{40}$ ]] ||
  [[ $(wc -l <"$repo_root/$lock_file") -ne 1 ]]; then
  printf 'verify-consumer-sync: lock must contain one full lowercase commit SHA: %s\n' \
    "$lock_file" >&2
  exit 1
fi

status=0
if [[ -z ${ACTION_REF:-} ]]; then
  printf 'verify-consumer-sync: missing action ref; cannot prove verifier revision\n' >&2
  status=1
elif [[ "$ACTION_REF" != "$actions_sha" ]]; then
  # Include the verifier itself in the invariant. Otherwise all other uses can
  # match the lock while the policy code still executes from an older commit.
  printf 'verify-consumer-sync: verifier ref %s differs from lock %s\n' \
    "$ACTION_REF" "$actions_sha" >&2
  status=1
fi

scratch=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/verify-consumer-sync.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
if ! actions_yq_available; then
  if [[ ${GITHUB_ACTIONS:-} != true ]]; then
    printf 'verify-consumer-sync: Mike Farah yq v4 is required to read workflow YAML\n' >&2
    exit 1
  fi
  # Hosted workers supply yq. Use the existing checksum-pinned prerequisite
  # installer for minimal workers, confined to this invocation's scratch.
  actions_yq="$scratch/actions-yq"
  (
    export RUNNER_TEMP="$scratch"
    # shellcheck source=../../../capability-harness/github-release.sh
    . "$GITHUB_ACTION_PATH/../../../capability-harness/github-release.sh"
    # shellcheck source=../shell-ci-prereqs/lib.sh
    . "$GITHUB_ACTION_PATH/../shell-ci-prereqs/lib.sh"
    install_yq_v4 "$actions_yq"
  )
  actions_yq_available || {
    printf 'verify-consumer-sync: installed yq cannot read Actions reference positions\n' >&2
    exit 1
  }
fi

candidate_list="$scratch/definitions"
# Workflows have one GitHub-defined home; composite actions may live anywhere
# but have one of two GitHub-defined filenames. Enumerating those tracked files
# covers runtime configuration without mistaking a documentation example for a
# dependency that needs rewriting.
git -C "$repo_root" ls-files -z -- \
  ':(glob).github/workflows/*.yml' \
  ':(glob).github/workflows/*.yaml' \
  action.yml action.yaml \
  ':(glob)**/action.yml' \
  ':(glob)**/action.yaml' >"$candidate_list"
checked=0
while IFS= read -r -d '' relative; do
  [[ -n "$relative" ]] || continue
  definition="$repo_root/$relative"
  if [[ ! -f "$definition" || -L "$definition" ]]; then
    printf 'verify-consumer-sync: workflow/action definition must be a regular file: %s\n' \
      "$relative" >&2
    exit 1
  fi
  references=$(read_actions_references "$definition" "$relative")
  while IFS=$'\t' read -r row _ style controls value; do
    [[ -n "$row" ]] || continue
    checked=$((checked + 1))
    if ! valid_actions_ref "$value" "$controls" "$style" "$relative" "$row"; then
      status=1
    elif [[ "${value#*@}" != "$actions_sha" ]]; then
      printf 'verify-consumer-sync: reference differs from lock: %s:%s:%s\n' \
        "$relative" "$row" "$value" >&2
      status=1
    fi
  done <<<"$references"
done <"$candidate_list"

if [[ "$checked" -eq 0 ]]; then
  printf 'verify-consumer-sync: no tracked cgraf78/actions workflow/action references found\n' >&2
  exit 1
fi

if [[ "$status" -ne 0 ]]; then
  cat >&2 <<'EOF'

Run consumer-ci/sync.sh from a cgraf78/actions checkout at the desired commit,
then commit the lock, workflow references, and synchronized vendored scripts.
EOF
  exit 1
fi

printf 'verify-consumer-sync: %d reference(s) match %s\n' \
  "$checked" "$actions_sha"

cd "$repo_root"
# The Shdeps hook and its generated lock travel together. Verify all platform
# hashes here, including architectures that the current job does not run.
for tool in tmux wezterm; do
  hook="$shdeps_hooks/$tool.sh"
  build_lock="$shdeps_hooks/$tool-build.lock"
  if consumer_tracks "$tracked_paths" "$hook" ||
    consumer_tracks "$tracked_paths" "$build_lock"; then
    if [[ ! -f "$hook" || -L "$hook" || -L .config || -L .config/shdeps || -L "$shdeps_hooks" ||
      ! -f "$build_lock" || -L "$build_lock" || -x "$build_lock" ]] ||
      ! consumer_tracks "$tracked_paths" "$hook" ||
      ! consumer_tracks "$tracked_paths" "$build_lock" ||
      ! cmp -s "$GITHUB_ACTION_PATH/../shell-ci-prereqs/$tool-build.lock" "$build_lock"; then
      printf 'verify-consumer-sync: Shdeps %s lock differs from the Actions pin. Run consumer-ci/sync.sh.\n' "$tool" >&2
      exit 1
    fi
  fi
done

# Release scripts are another derived view of the same dependency commit. The
# config and generated manifest are paired markers: either one proves the repo
# opted in, and requiring both prevents deletion of only release.conf from
# silently placing the remaining vendored bytes outside future drift checks.
release_config_tracked=false
release_manifest_tracked=false
if consumer_tracks "$tracked_paths" "$release_config"; then
  release_config_tracked=true
fi
if consumer_tracks "$tracked_paths" "$release_manifest"; then
  release_manifest_tracked=true
fi
if [[ "$release_config_tracked" != "$release_manifest_tracked" ]]; then
  printf '%s\n' \
    'verify-consumer-sync: inconsistent release markers; release.conf and managed manifest must be tracked together' >&2
  exit 1
fi
if [[ "$release_config_tracked" == true ]]; then
  export SCRIPTS_DIR=scripts
  "$GITHUB_ACTION_PATH/../verify-release-scripts/verify.sh"
  actions_root=$(cd "$GITHUB_ACTION_PATH/../../.." && pwd)
  "$actions_root/release-installer/render.sh" --check "$repo_root"
else
  printf 'verify-consumer-sync: no tracked release config; version lock only\n'
fi

# Dotfiles repositories vendor the shared capability test harness from the
# same locked commit. As with release scripts, the marker config and generated
# manifest must be tracked together so neither can be dropped alone.
harness_verified=false
while IFS= read -r harness_dir; do
  harness_config="$harness_dir/capability-harness.conf"
  harness_manifest="$harness_dir/.capability-harness.manifest"
  harness_config_tracked=false
  harness_manifest_tracked=false
  if consumer_tracks "$tracked_paths" "$harness_config"; then
    harness_config_tracked=true
  fi
  if consumer_tracks "$tracked_paths" "$harness_manifest"; then
    harness_manifest_tracked=true
  fi
  if [[ "$harness_config_tracked" != "$harness_manifest_tracked" ]]; then
    printf 'verify-consumer-sync: inconsistent capability harness markers in %s; capability-harness.conf and managed manifest must be tracked together\n' "$harness_dir" >&2
    exit 1
  fi
  [[ "$harness_config_tracked" == true ]] || continue
  if [[ ! -f "$harness_config" || -L "$harness_config" ]] ||
    ! capability_harness_local "$repo_root" "$harness_dir"; then
    printf 'verify-consumer-sync: capability-harness.conf must be a regular non-symlink file inside the checkout: %s\n' "$harness_config" >&2
    exit 1
  fi
  actions_root=$(cd "$GITHUB_ACTION_PATH/../../.." && pwd)
  "$GITHUB_ACTION_PATH/../shared/verify-vendored-scripts.sh" \
    "$actions_root/capability-harness" "$harness_dir" .capability-harness.manifest \
    verify-capability-harness 'capability-harness scripts'
  harness_verified=true
done <<<"$harness_layouts"
if [[ "$harness_verified" == false ]]; then
  printf 'verify-consumer-sync: no tracked capability harness config\n'
fi

# Source-distributed consumers use the same lock for their generated checkout
# bootstrap. Presence of the tracked config is the opt-in marker; the renderer
# owns enabled/disabled policy and the exact committed bytes.
checkout_generated_header='# Generated by cgraf78/actions checkout-installer. Do not edit.'
checkout_bash_generated_header='# Generated by cgraf78/actions checkout Bash resolver. Do not edit.'
if consumer_tracks "$tracked_paths" "$checkout_config"; then
  actions_root=$(cd "$GITHUB_ACTION_PATH/../../.." && pwd)
  "$actions_root/checkout-installer/render.sh" --check "$repo_root"
elif [[ -f "$repo_root/install.sh" && ! -L "$repo_root/install.sh" &&
  $(sed -n '2p' "$repo_root/install.sh") == "$checkout_generated_header" ]]; then
  printf '%s\n' \
    'verify-consumer-sync: generated checkout installer is tracked without checkout-installer.conf' >&2
  exit 1
elif [[ -f "$repo_root/support/checkout-bash-v1.sh" &&
  ! -L "$repo_root/support/checkout-bash-v1.sh" &&
  $(sed -n '2p' "$repo_root/support/checkout-bash-v1.sh") == "$checkout_bash_generated_header" ]]; then
  printf '%s\n' \
    'verify-consumer-sync: generated checkout Bash resolver is tracked without checkout-installer.conf' >&2
  exit 1
else
  printf 'verify-consumer-sync: no tracked checkout installer config\n'
fi
