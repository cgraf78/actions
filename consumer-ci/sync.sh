#!/usr/bin/env bash
set -euo pipefail

# Synchronize a consumer repository to one reviewed cgraf78/actions commit.
#
# GitHub resolves `uses:` before jobs start and rejects variables in the ref, so
# consumers cannot read a lock file at runtime. The YAML literals updated here
# are generated copies: the lock remains the only version decision, while the
# committed workflows retain the static form GitHub requires.

usage() {
  cat >&2 <<'EOF'
usage: consumer-ci/sync.sh <consumer-repository>
       consumer-ci/sync.sh --self

Run this command from the cgraf78/actions checkout at the commit the consumer
should pin. It writes the consumer lock, updates every tracked workflow/action
reference, refreshes vendored release scripts, capability-harness scripts and
the Shdeps tmux and WezTerm build locks, and regenerates opted-in installers.

Use --self after committing provider changes to generate cgraf78/actions' own
internal lock and literal action references from that implementation commit.
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

source_root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
# The checkout itself selects the dependency version. This prevents a caller
# from supplying a SHA that does not describe the scripts copied below.
actions_sha=$(git -C "$source_root" rev-parse HEAD)
if [[ $1 == --self ]]; then
  consumer=$source_root
else
  consumer=$1
fi
# shellcheck source=../.github/actions/verify-consumer-sync/references.sh
. "$source_root/.github/actions/verify-consumer-sync/references.sh"
if ! actions_yq_available; then
  printf 'consumer-sync: Mike Farah yq v4 is required to read workflow YAML\n' >&2
  exit 1
fi

if [[ ! "$actions_sha" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'consumer-sync: actions HEAD is not a full commit SHA: %s\n' \
    "$actions_sha" >&2
  exit 1
fi
# A lock identifies committed bytes, not merely a nearby checkout. Refuse all
# tracked or untracked provider changes before touching the consumer; otherwise
# the generated refs can name HEAD while vendored files came from worktree
# content that no future checkout of that commit can reproduce.
# shellcheck source=provider-status.sh
. "$source_root/consumer-ci/provider-status.sh"
require_clean_provider "$source_root" consumer-sync
# Git status intentionally omits ignored files, but the release synchronizer
# sees filesystem globs. Require every candidate source script to belong to the
# commit before any consumer bytes are changed, closing that otherwise subtle
# gap between a clean checkout and reproducible vendored output.
shopt -s nullglob
for provider_script in "$source_root"/release-scripts/*.sh; do
  provider_relative=${provider_script#"$source_root"/}
  if [[ ! -f "$provider_script" || -L "$provider_script" ]] ||
    ! git -C "$source_root" ls-files --error-unmatch -- \
      "$provider_relative" >/dev/null 2>&1; then
    printf 'consumer-sync: provider script is not a tracked regular file: %s\n' \
      "$provider_relative" >&2
    exit 1
  fi
done
for provider_script in "$source_root"/capability-harness/*.sh \
  "$source_root/consumer-ci/vendor-scripts.sh"; do
  provider_relative=${provider_script#"$source_root"/}
  if [[ ! -f "$provider_script" || -L "$provider_script" ]] ||
    ! git -C "$source_root" ls-files --error-unmatch -- \
      "$provider_relative" >/dev/null 2>&1; then
    printf 'consumer-sync: provider script is not a tracked regular file: %s\n' \
      "$provider_relative" >&2
    exit 1
  fi
done
for provider_installer in \
  "$source_root/installer-common/exclusive-mkdir.sh" \
  "$source_root/release-installer/render.sh" \
  "$source_root/release-installer/install.sh.in" \
  "$source_root/checkout-installer/render.sh" \
  "$source_root/checkout-installer/install.sh.in" \
  "$source_root/checkout-installer/lock-v1.sh.in" \
  "$source_root/checkout-installer/bash-resolver-v1.sh.in"; do
  provider_relative=${provider_installer#"$source_root"/}
  if [[ ! -f "$provider_installer" || -L "$provider_installer" ]] ||
    ! git -C "$source_root" ls-files --error-unmatch -- \
      "$provider_relative" >/dev/null 2>&1; then
    printf 'consumer-sync: installer provider is not a tracked regular file: %s\n' \
      "$provider_relative" >&2
    exit 1
  fi
done
if [[ ! -d "$consumer" ]] || ! git -C "$consumer" rev-parse --show-toplevel >/dev/null 2>&1; then
  printf 'consumer-sync: not a Git repository: %s\n' "$consumer" >&2
  exit 1
fi

consumer=$(git -C "$consumer" rev-parse --show-toplevel)

# shellcheck source=staged-files.sh
. "$source_root/consumer-ci/staged-files.sh"
staging_root=''
# shellcheck disable=SC2329  # Invoked on exit.
cleanup() {
  local status=$?
  trap '' HUP INT TERM
  if cleanup_staged_files; then
    [[ -z "$staging_root" ]] || rm -rf -- "$staging_root"
  else
    printf 'consumer-sync: original files preserved for recovery in %s\n' "$before" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
staging_root=$(mktemp -d)
before=$staging_root/before
prepared=$staging_root/after
init_staged_files "$consumer" "$before" "$prepared"
lock_staged_files "$staging_root"

shdeps_hooks=.config/shdeps/hooks.d
build_lock_sources="$source_root/.github/actions/shell-ci-prereqs"

# shellcheck source=../.github/actions/verify-consumer-sync/tracked-paths.sh
. "$source_root/.github/actions/verify-consumer-sync/tracked-paths.sh"
tracked_hooks=$(consumer_index_paths "$consumer" "$shdeps_hooks/tmux.sh" "$shdeps_hooks/wezterm.sh")
shdeps_build_locks=()
for tool in tmux wezterm; do
  hook="$shdeps_hooks/$tool.sh"
  build_lock="$tool-build.lock"
  if ! consumer_tracks "$tracked_hooks" "$hook"; then
    continue
  fi
  # The tracked hook opts in. Keep its data next to the hook so Shdeps needs
  # no runtime dependency on the provider repo or on GitHub Actions.
  if [[ ! -f "$consumer/$hook" || -L "$consumer/$hook" ||
    -L "$consumer/.config" || -L "$consumer/.config/shdeps" ||
    -L "$consumer/$shdeps_hooks" ]]; then
    printf 'consumer-sync: Shdeps hook must be a regular file in the checkout: %s\n' "$hook" >&2
    exit 1
  fi
  destination="$consumer/$shdeps_hooks/$build_lock"
  if [[ -L "$destination" || (-e "$destination" && ! -f "$destination") ]]; then
    printf 'consumer-sync: Shdeps build lock must be a regular file: %s\n' "$destination" >&2
    exit 1
  fi
  lock_source="$build_lock_sources/$build_lock"
  if [[ ! -f "$lock_source" || -L "$lock_source" || -x "$lock_source" ]] ||
    ! git -C "$source_root" ls-files --error-unmatch -- \
      "${lock_source#"$source_root"/}" >/dev/null 2>&1; then
    printf 'consumer-sync: provider build lock must be a tracked regular data file: %s\n' "$lock_source" >&2
    exit 1
  fi
  shdeps_build_locks+=("$build_lock")
done
checkout_config="$consumer/scripts/checkout-installer.conf"
checkout_config_present=false
checkout_generated_header='# Generated by cgraf78/actions checkout-installer. Do not edit.'
checkout_bash_generated_header='# Generated by cgraf78/actions checkout Bash resolver. Do not edit.'
if [[ -e "$checkout_config" || -L "$checkout_config" ]]; then
  if [[ ! -f "$checkout_config" || -L "$checkout_config" ]]; then
    printf 'consumer-sync: checkout installer config must be a regular file: %s\n' \
      "$checkout_config" >&2
    exit 1
  fi
  checkout_config_present=true
elif [[ -f "$consumer/install.sh" && ! -L "$consumer/install.sh" &&
  $(sed -n '2p' "$consumer/install.sh") == "$checkout_generated_header" ]]; then
  printf 'consumer-sync: generated checkout installer exists without config: %s\n' \
    "$consumer/install.sh" >&2
  exit 1
elif [[ -f "$consumer/support/checkout-bash-v1.sh" &&
  ! -L "$consumer/support/checkout-bash-v1.sh" &&
  $(sed -n '2p' "$consumer/support/checkout-bash-v1.sh") == "$checkout_bash_generated_header" ]]; then
  printf 'consumer-sync: generated checkout Bash resolver exists without config: %s\n' \
    "$consumer/support/checkout-bash-v1.sh" >&2
  exit 1
fi

# Discover the dependency before writing anything. This catches a mistyped
# target repository without leaving behind a lock that falsely looks like a
# completed synchronization.
candidate_list=$staging_root/candidates
updated=0
# GitHub executes workflows only from .github/workflows, while composite
# actions may live anywhere but must be named action.yml or action.yaml. Scan
# exactly those tracked definitions: this covers every runtime use without
# rewriting documentation or unrelated YAML that happens to contain an example.
git -C "$consumer" ls-files -z -- \
  ':(glob).github/workflows/*.yml' \
  ':(glob).github/workflows/*.yaml' \
  action.yml action.yaml \
  ':(glob)**/action.yml' \
  ':(glob)**/action.yaml' >"$candidate_list"
while IFS= read -r -d '' relative; do
  [[ -n "$relative" ]] || continue
  if [[ ! -f "$consumer/$relative" || -L "$consumer/$relative" ]]; then
    printf 'consumer-sync: workflow/action definition must be a regular file: %s\n' \
      "$relative" >&2
    exit 1
  fi
  stage_file "$relative"
  source_snapshot="$before/$relative"
  references=$(read_actions_references "$source_snapshot" "$relative")
  [[ -n "$references" ]] || continue
  # Expanding a whole-step alias can point to the same unchanged scalar span.
  references=$(LC_ALL=C sort -t $'\t' -k1,1n -k2,2n <<<"$references" | uniq)
  # Stage all YAML edits before publishing the new lock. A missing literal
  # span or parse error must leave every dependency file as it was.
  reference_tmp="$staging_root/reference"
  render_actions_references "$source_snapshot" "$relative" "$actions_sha" "$references" >"$reference_tmp"
  chmod "$(file_mode "$source_snapshot")" "$reference_tmp"
  mv "$reference_tmp" "$prepared/$relative"
  updated=$((updated + 1))
done <"$candidate_list"
if ((updated == 0)); then
  printf 'consumer-sync: no tracked cgraf78/actions workflow/action references found\n' >&2
  exit 1
fi

release_config="$consumer/scripts/release.conf"
release_manifest="$consumer/scripts/.release-scripts.manifest"
release_enabled=false
if [[ -e "$release_config" || -L "$release_config" ]]; then
  if [[ ! -f "$release_config" || -L "$release_config" ]]; then
    printf 'consumer-sync: release config must be a regular file: %s\n' \
      "$release_config" >&2
    exit 1
  fi
  release_enabled=true
elif [[ -e "$release_manifest" || -L "$release_manifest" ]]; then
  # A manifest is durable evidence that this repository opted into vendoring.
  # Silently treating it as a non-release consumer after config deletion would
  # leave the formerly managed scripts outside future drift checks.
  printf 'consumer-sync: release manifest exists without release.conf: %s\n' \
    "$release_manifest" >&2
  exit 1
fi

# Keep the paired-marker check at every layout the consumer verifier supports.
# shellcheck source=../.github/actions/verify-consumer-sync/capability-layouts.sh
. "$source_root/.github/actions/verify-consumer-sync/capability-layouts.sh"
harness_destinations=()
while IFS= read -r harness_dir; do
  harness_config="$consumer/$harness_dir/capability-harness.conf"
  harness_manifest="$consumer/$harness_dir/.capability-harness.manifest"
  if [[ -e "$harness_config" || -L "$harness_config" ]]; then
    if [[ ! -f "$harness_config" || -L "$harness_config" ]] ||
      ! capability_harness_local "$consumer" "$harness_dir"; then
      printf 'consumer-sync: capability harness config must be a regular file inside the checkout: %s\n' \
        "$harness_config" >&2
      exit 1
    fi
    harness_destinations+=("$harness_dir")
  elif [[ -e "$harness_manifest" || -L "$harness_manifest" ]]; then
    printf 'consumer-sync: capability harness manifest exists without capability-harness.conf: %s\n' \
      "$harness_manifest" >&2
    exit 1
  fi
done < <(capability_harness_layouts)

installer_policy_enabled() {
  local config=$1 variable=$2

  (
    unset "$variable"
    # shellcheck source=/dev/null
    . "$config"
    [[ ${!variable:-} == true ]]
  )
}

checkout_installer_enabled=false
release_installer_enabled=false
if [[ "$checkout_config_present" == true ]]; then
  stage_file scripts/checkout-installer.conf
  if installer_policy_enabled "$prepared/scripts/checkout-installer.conf" CHECKOUT_INSTALLER_ENABLED; then
    checkout_installer_enabled=true
  fi
fi
if [[ "$release_enabled" == true ]]; then
  stage_file scripts/release.conf
  if installer_policy_enabled "$prepared/scripts/release.conf" RELEASE_STANDALONE_INSTALLER; then
    release_installer_enabled=true
  fi
fi
if [[ "$checkout_installer_enabled" == true &&
  "$release_installer_enabled" == true ]]; then
  printf '%s\n' \
    'consumer-sync: release and checkout installer policies cannot both own install.sh' >&2
  exit 1
fi

# Seed each staged family with just its managed paths. The vendor command
# still owns manifest validation, allowed removals, and executable modes.
stage_vendor() {
  local provider_dir=$1 destination_dir=$2 manifest=$3 item name
  stage_file "$destination_dir/$manifest"
  for item in "$provider_dir"/*.sh; do
    name=${item##*/}
    [[ "$name" != sync.sh ]] || continue
    stage_file "$destination_dir/$name"
    # The existing link remains in the before snapshot for ownership and
    # rollback. A renderer must never follow it out of the scratch tree.
    if [[ -L "$prepared/$destination_dir/$name" ]]; then
      rm -f "$prepared/$destination_dir/$name"
    fi
  done
  if [[ -f "$before/$destination_dir/$manifest" &&
    ! -L "$before/$destination_dir/$manifest" ]]; then
    while IFS= read -r name || [[ -n "$name" ]]; do
      # The vendor command will report malformed records. Do not resolve
      # even a staged path outside its family while preparing that check.
      case "$name" in
        '' | . | .. | */*) continue ;;
      esac
      stage_file "$destination_dir/$name"
    done <"$before/$destination_dir/$manifest"
  fi
  "$source_root/consumer-ci/vendor-scripts.sh" \
    "$provider_dir" "$prepared/$destination_dir" "$manifest"
}

if [[ "$checkout_config_present" == true || "$release_enabled" == true ]]; then
  stage_file install.sh true
fi
resolver_relative=support/checkout-bash-v1.sh
resolver_parent_unsafe=false
if [[ "$checkout_config_present" == true ]]; then
  if [[ -L "$consumer/support" || (-e "$consumer/support" && ! -d "$consumer/support") ]]; then
    # A disabled resolver can coexist with an unrelated support path.
    # Publication of a new resolver will refuse this unsafe parent.
    resolver_parent_unsafe=true
  else
    stage_file "$resolver_relative" true
  fi
fi

# Retire a disabled checkout-generated installer before a release renderer
# claims the shared top-level path during a policy transition.
if [[ "$checkout_config_present" == true &&
  "$checkout_installer_enabled" != true ]]; then
  "$source_root/checkout-installer/render.sh" --output-root "$prepared" "$consumer" >/dev/null
fi
if [[ "$release_enabled" == true ]]; then
  stage_vendor "$source_root/release-scripts" scripts .release-scripts.manifest >/dev/null
  "$source_root/release-installer/render.sh" --output-root "$prepared" "$consumer" >/dev/null
fi
for harness_dir in ${harness_destinations[@]+"${harness_destinations[@]}"}; do
  stage_vendor "$source_root/capability-harness" "$harness_dir" .capability-harness.manifest >/dev/null
done
for build_lock in ${shdeps_build_locks[@]+"${shdeps_build_locks[@]}"}; do
  relative="$shdeps_hooks/$build_lock"
  stage_file "$relative"
  if [[ -L "$prepared/$relative" ]]; then
    printf 'consumer-sync: Shdeps build lock must be a regular file: %s\n' "$relative" >&2
    exit 1
  fi
  install -m 0644 "$build_lock_sources/$build_lock" "$prepared/$relative"
done
# An enabled checkout renderer runs only after a disabled release renderer has
# had the same opportunity to retire its generated installer.
if [[ "$checkout_installer_enabled" == true ]]; then
  "$source_root/checkout-installer/render.sh" --output-root "$prepared" "$consumer" >/dev/null
fi

if [[ "$resolver_parent_unsafe" == true && -e "$prepared/$resolver_relative" ]]; then
  printf 'consumer-sync: checkout Bash resolver parent must be a regular directory: %s/support\n' \
    "$consumer" >&2
  exit 1
fi
if [[ "$checkout_installer_enabled" == true && -f "$prepared/$resolver_relative" ]]; then
  # A generated installer can use the resolver as soon as it is visible.
  # When retiring the resolver, keep the default installer-first order.
  ordered_paths=()
  for relative in "${stage_paths[@]}"; do
    [[ "$relative" == install.sh ]] || ordered_paths+=("$relative")
    [[ "$relative" != "$resolver_relative" ]] || ordered_paths+=(install.sh)
  done
  stage_paths=("${ordered_paths[@]}")
fi

# Publish the lock last. A change that cannot be rendered must never repin
# workflows, retire their installer, or imply a completed sync.
relative=.github/cgraf78-actions.lock
stage_file "$relative"
if [[ -L "$prepared/$relative" ]]; then
  printf 'consumer-sync: Actions lock must be a regular file: %s\n' "$relative" >&2
  exit 1
fi
printf '%s\n' "$actions_sha" >"$prepared/$relative"
chmod 0644 "$prepared/$relative"
publish_staged_files

printf 'consumer-sync: locked %d reference file(s) to %s\n' \
  "$updated" "$actions_sha"
