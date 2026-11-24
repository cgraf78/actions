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
# Parse quoted scalars through their matching quote, while an unquoted scalar
# ends at whitespace or a closing flow delimiter. The loop below consumes one
# match at a time so two step mappings on one line cannot hide a second ref.
reference_regex="uses:[[:space:]]*(\"cgraf78/actions/[^@\"]+@([^\"]+)\"|'cgraf78/actions/[^@']+@([^']+)'|cgraf78/actions/[^@[:space:]]+@([^][[:space:],}]+))"

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
candidate_list=$(mktemp)
reference_list=$(mktemp)
build_lock_tmp=''
trap 'rm -f "$candidate_list" "$reference_list" "$build_lock_tmp"' EXIT
# GitHub executes workflows only from .github/workflows, while composite
# actions may live anywhere but must be named action.yml or action.yaml. Scan
# exactly those tracked definitions: this covers every runtime use without
# rewriting documentation or unrelated YAML that happens to contain an example.
git -C "$consumer" ls-files -- \
  ':(glob).github/workflows/*.yml' \
  ':(glob).github/workflows/*.yaml' \
  action.yml action.yaml \
  ':(glob)**/action.yml' \
  ':(glob)**/action.yaml' >"$candidate_list"
while IFS= read -r relative; do
  [[ -n "$relative" ]] || continue
  if [[ ! -f "$consumer/$relative" || -L "$consumer/$relative" ]]; then
    printf 'consumer-sync: workflow/action definition must be a regular file: %s\n' \
      "$relative" >&2
    exit 1
  fi
  file_has_reference=false
  while IFS= read -r line || [[ -n "$line" ]]; do
    consumed=
    remaining=$line
    while [[ "$remaining" =~ $reference_regex ]]; do
      match=${BASH_REMATCH[0]}
      prefix=${remaining%%"$match"*}
      after_match=${remaining#*"$match"}
      context=${consumed}${prefix}
      # A comma is a delimiter inside a flow mapping, but part of a block-style
      # unquoted scalar. Refuse the ambiguous block spelling instead of
      # accepting a matching SHA prefix and leaving hidden suffix text behind.
      if [[ -n ${BASH_REMATCH[4]} && "$after_match" == ,* &&
        "$context" != *'{'* ]]; then
        printf 'consumer-sync: quote an actions ref containing a comma: %s\n' \
          "$line" >&2
        exit 1
      fi
      file_has_reference=true
      consumed+="${prefix}${match}"
      remaining=$after_match
    done
  done <"$consumer/$relative"
  if [[ "$file_has_reference" == true ]]; then
    printf '%s\n' "$relative" >>"$reference_list"
  fi
done <"$candidate_list"
if [[ ! -s "$reference_list" ]]; then
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
if [[ "$checkout_config_present" == true ]] &&
  installer_policy_enabled "$checkout_config" CHECKOUT_INSTALLER_ENABLED; then
  checkout_installer_enabled=true
fi
if [[ "$release_enabled" == true ]] &&
  installer_policy_enabled "$release_config" RELEASE_STANDALONE_INSTALLER; then
  release_installer_enabled=true
fi
if [[ "$checkout_installer_enabled" == true &&
  "$release_installer_enabled" == true ]]; then
  printf '%s\n' \
    'consumer-sync: release and checkout installer policies cannot both own install.sh' >&2
  exit 1
fi

mkdir -p "$consumer/.github"
lock_tmp=$(mktemp "$consumer/.github/cgraf78-actions.lock.XXXXXX")
printf '%s\n' "$actions_sha" >"$lock_tmp"
chmod 0644 "$lock_tmp"
mv "$lock_tmp" "$consumer/.github/cgraf78-actions.lock"

rewrite_reference_file() {
  local file=$1 line match old_ref prefix remaining rewritten suffix tmp

  if [[ ! -f "$file" || -L "$file" ]]; then
    printf 'consumer-sync: workflow reference file must be a regular file: %s\n' \
      "$file" >&2
    return 1
  fi

  # Rewrite through a same-directory temporary file. `cp -p` preserves the
  # mode on both GNU and BSD userlands; `sed -i` has incompatible Linux/macOS
  # syntax and would make this maintainer command less portable.
  tmp=$(mktemp "$file.XXXXXX")
  cp -p "$file" "$tmp"
  : >"$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    remaining=$line
    rewritten=
    while [[ "$remaining" =~ $reference_regex ]]; do
      match=${BASH_REMATCH[0]}
      old_ref=${BASH_REMATCH[2]}
      [[ -n "$old_ref" ]] || old_ref=${BASH_REMATCH[3]}
      [[ -n "$old_ref" ]] || old_ref=${BASH_REMATCH[4]}
      prefix=${remaining%%"$match"*}
      suffix=${match#*@"$old_ref"}
      rewritten+="${prefix}${match%%@*}@${actions_sha}${suffix}"
      remaining=${remaining#*"$match"}
    done
    line=${rewritten}${remaining}
    printf '%s\n' "$line" >>"$tmp"
  done <"$file"
  mv "$tmp" "$file"
}

updated=0
while IFS= read -r relative; do
  [[ -n "$relative" ]] || continue
  rewrite_reference_file "$consumer/$relative"
  printf 'consumer-sync: %s\n' "$relative"
  updated=$((updated + 1))
done <"$reference_list"

# Retire a disabled checkout-generated installer before a release renderer
# claims the shared top-level path during a policy transition.
if [[ "$checkout_config_present" == true &&
  "$checkout_installer_enabled" != true ]]; then
  "$source_root/checkout-installer/render.sh" "$consumer"
fi
if [[ "$release_enabled" == true ]]; then
  "$source_root/release-scripts/sync.sh" "$consumer/scripts"
  "$source_root/release-installer/render.sh" "$consumer"
fi
for harness_dir in ${harness_destinations[@]+"${harness_destinations[@]}"}; do
  "$source_root/consumer-ci/vendor-scripts.sh" \
    "$source_root/capability-harness" "$consumer/$harness_dir" \
    .capability-harness.manifest
done
for build_lock in ${shdeps_build_locks[@]+"${shdeps_build_locks[@]}"}; do
  destination="$consumer/$shdeps_hooks/$build_lock"
  build_lock_tmp=$(mktemp "$destination.XXXXXX")
  cp "$build_lock_sources/$build_lock" "$build_lock_tmp"
  chmod 0644 "$build_lock_tmp"
  mv "$build_lock_tmp" "$destination"
done
# An enabled checkout renderer runs only after a disabled release renderer has
# had the same opportunity to retire its generated installer.
if [[ "$checkout_installer_enabled" == true ]]; then
  "$source_root/checkout-installer/render.sh" "$consumer"
fi

printf 'consumer-sync: locked %d reference file(s) to %s\n' \
  "$updated" "$actions_sha"
