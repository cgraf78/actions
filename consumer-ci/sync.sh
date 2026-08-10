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

Run this command from the cgraf78/actions checkout at the commit the consumer
should pin. It writes the consumer lock, updates every tracked workflow/action
reference, refreshes vendored release scripts, and regenerates an opted-in
standalone installer when release.conf is present.
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
consumer=$1
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
if [[ -n $(git -C "$source_root" status --porcelain --untracked-files=normal) ]]; then
  printf '%s\n' \
    'consumer-sync: actions checkout is dirty; commit or discard provider changes before synchronizing' >&2
  exit 1
fi
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
for provider_installer in \
  "$source_root/release-installer/render.sh" \
  "$source_root/release-installer/install.sh.in"; do
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
# Discover the dependency before writing anything. This catches a mistyped
# target repository without leaving behind a lock that falsely looks like a
# completed synchronization.
candidate_list=$(mktemp)
reference_list=$(mktemp)
trap 'rm -f "$candidate_list" "$reference_list"' EXIT
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

if [[ "$release_enabled" == true ]]; then
  "$source_root/release-scripts/sync.sh" "$consumer/scripts"
  "$source_root/release-installer/render.sh" "$consumer"
fi

printf 'consumer-sync: locked %d reference file(s) to %s\n' \
  "$updated" "$actions_sha"
