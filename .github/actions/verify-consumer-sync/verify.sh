#!/usr/bin/env bash
set -euo pipefail

# Verify the consumer's single-source cgraf78/actions lock and vendored tools.
#
# Literal workflow refs are unavoidable because GitHub resolves `uses:` before
# a job can read repository files. This check turns those literals into derived
# data by requiring every one of them to equal the tracked lock.

repo_root=${GITHUB_WORKSPACE:-$PWD}
repo_root=$(git -C "$repo_root" rev-parse --show-toplevel)
lock_file=.github/cgraf78-actions.lock
reference_regex="uses:[[:space:]]*(\"cgraf78/actions/[^@\"]+@([^\"]+)\"|'cgraf78/actions/[^@']+@([^']+)'|cgraf78/actions/[^@[:space:]]+@([^][[:space:],}]+))"

if ! git -C "$repo_root" ls-files --error-unmatch "$lock_file" >/dev/null 2>&1; then
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

candidate_list=$(mktemp)
trap 'rm -f "$candidate_list"' EXIT
# Workflows have one GitHub-defined home; composite actions may live anywhere
# but have one of two GitHub-defined filenames. Enumerating those tracked files
# covers runtime configuration without mistaking a documentation example for a
# dependency that needs rewriting.
git -C "$repo_root" ls-files -- \
  ':(glob).github/workflows/*.yml' \
  ':(glob).github/workflows/*.yaml' \
  action.yml action.yaml \
  ':(glob)**/action.yml' \
  ':(glob)**/action.yaml' >"$candidate_list"
checked=0
while IFS= read -r relative; do
  [[ -n "$relative" ]] || continue
  definition="$repo_root/$relative"
  if [[ ! -f "$definition" || -L "$definition" ]]; then
    printf 'verify-consumer-sync: workflow/action definition must be a regular file: %s\n' \
      "$relative" >&2
    exit 1
  fi
  line_number=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    consumed=
    remaining=$line
    while [[ "$remaining" =~ $reference_regex ]]; do
      match=${BASH_REMATCH[0]}
      ref=${BASH_REMATCH[2]}
      [[ -n "$ref" ]] || ref=${BASH_REMATCH[3]}
      [[ -n "$ref" ]] || ref=${BASH_REMATCH[4]}
      prefix=${remaining%%"$match"*}
      after_match=${remaining#*"$match"}
      context=${consumed}${prefix}
      checked=$((checked + 1))
      if [[ -n ${BASH_REMATCH[4]} && "$after_match" == ,* &&
        "$context" != *'{'* ]]; then
        printf 'verify-consumer-sync: ambiguous unquoted comma in actions ref: %s:%d\n' \
          "$relative" "$line_number" >&2
        status=1
      fi
      if [[ "$ref" != "$actions_sha" ]]; then
        printf 'verify-consumer-sync: reference differs from lock: %s:%d:%s\n' \
          "$relative" "$line_number" "$match" >&2
        status=1
      fi
      consumed+="${prefix}${match}"
      remaining=$after_match
    done
  done <"$definition"
done <"$candidate_list"

if [[ "$checked" -eq 0 ]]; then
  printf 'verify-consumer-sync: no tracked cgraf78/actions workflow/action references found\n' >&2
  exit 1
fi

if [[ "$status" -ne 0 ]]; then
  cat >&2 <<'EOF'

Run consumer-ci/sync.sh from a cgraf78/actions checkout at the desired commit,
then commit the lock, workflow references, and synchronized release scripts.
EOF
  exit 1
fi

printf 'verify-consumer-sync: %d reference(s) match %s\n' \
  "$checked" "$actions_sha"

export GITHUB_ACTION_PATH
GITHUB_ACTION_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$repo_root"
# Release scripts are another derived view of the same dependency commit. The
# config and generated manifest are paired markers: either one proves the repo
# opted in, and requiring both prevents deletion of only release.conf from
# silently placing the remaining vendored bytes outside future drift checks.
release_config_tracked=false
release_manifest_tracked=false
if git -C "$repo_root" ls-files --error-unmatch \
  scripts/release.conf >/dev/null 2>&1; then
  release_config_tracked=true
fi
if git -C "$repo_root" ls-files --error-unmatch \
  scripts/.release-scripts.manifest >/dev/null 2>&1; then
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
else
  printf 'verify-consumer-sync: no tracked release config; version lock only\n'
fi
