#!/usr/bin/env bash

set -euo pipefail

notice() {
  printf 'infra-retry: %s\n' "$*"
}

cleanup() {
  if [[ -n "${retry_tmp:-}" ]]; then
    rm -rf "$retry_tmp"
  fi
}

is_required_aggregate() {
  local name=$1

  [[ "$name" == Required || "$name" == *' / Required' ]]
}

is_retryable_docker_pull() {
  local log=$1

  grep -Fq 'Docker pull failed with exit code' "$log" &&
    grep -Eiq \
      'context deadline exceeded|TLS handshake timeout|i/o timeout|connection reset by peer|unexpected EOF|toomanyrequests|429 Too Many Requests|502 Bad Gateway|503 Service Unavailable|request canceled while waiting for connection' \
      "$log"
}

validate_inputs() {
  [[ "$TARGET_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    notice "invalid repository: $TARGET_REPOSITORY"
    return 2
  }
  [[ "$TARGET_RUN_ID" =~ ^[0-9]+$ ]] || {
    notice "invalid run ID: $TARGET_RUN_ID"
    return 2
  }
  [[ "$TARGET_RUN_ATTEMPT" =~ ^[0-9]+$ ]] || {
    notice "invalid run attempt: $TARGET_RUN_ATTEMPT"
    return 2
  }
}

main() {
  : "${GH_TOKEN:?GH_TOKEN is required}"
  : "${TARGET_CONCLUSION:?TARGET_CONCLUSION is required}"
  : "${TARGET_REPOSITORY:?TARGET_REPOSITORY is required}"
  : "${TARGET_RUN_ATTEMPT:?TARGET_RUN_ATTEMPT is required}"
  : "${TARGET_RUN_ID:?TARGET_RUN_ID is required}"

  validate_inputs

  if [[ "$TARGET_CONCLUSION" != failure ]]; then
    notice "conclusion $TARGET_CONCLUSION is not eligible"
    return 0
  fi
  if [[ "$TARGET_RUN_ATTEMPT" != 1 ]]; then
    notice "attempt $TARGET_RUN_ATTEMPT is not eligible; automatic retry is capped at one"
    return 0
  fi

  local jobs
  retry_tmp=$(mktemp -d)
  trap cleanup EXIT
  jobs="$retry_tmp/jobs.json"
  gh api \
    "repos/$TARGET_REPOSITORY/actions/runs/$TARGET_RUN_ID/jobs?filter=latest&per_page=100" \
    >"$jobs"

  local listed_jobs total_jobs
  listed_jobs=$(jq '.jobs | length' "$jobs")
  total_jobs=$(jq '.total_count // (.jobs | length)' "$jobs")
  if ((listed_jobs != total_jobs)); then
    notice "job list is incomplete ($listed_jobs of $total_jobs); leaving run failed"
    return 0
  fi

  local failed_leaf=0
  local retryable_leaf=0
  local unclassified_leaf=0
  local job_id name log
  while IFS=$'\t' read -r job_id name; do
    if is_required_aggregate "$name"; then
      notice "ignoring derived aggregate failure: $name"
      continue
    fi

    failed_leaf=$((failed_leaf + 1))
    log="$retry_tmp/$job_id.log"
    if ! gh api "repos/$TARGET_REPOSITORY/actions/jobs/$job_id/logs" >"$log"; then
      notice "could not read failed job log: $name"
      unclassified_leaf=$((unclassified_leaf + 1))
      continue
    fi

    if is_retryable_docker_pull "$log"; then
      notice "allowlisted Docker pull failure: $name"
      retryable_leaf=$((retryable_leaf + 1))
    else
      notice "not an allowlisted infrastructure failure: $name"
      unclassified_leaf=$((unclassified_leaf + 1))
    fi
  done < <(jq -r '
    .jobs[]
    | select(.conclusion == "failure")
    | [.id, .name]
    | @tsv
  ' "$jobs")

  if ((failed_leaf == 0)); then
    notice "no failed leaf jobs were available to classify"
    return 0
  fi
  if ((retryable_leaf == 0 || unclassified_leaf > 0)); then
    notice "leaving run failed without automatic retry"
    return 0
  fi

  notice "rerunning failed jobs once after $retryable_leaf allowlisted infrastructure failure(s)"
  gh api --method POST \
    "repos/$TARGET_REPOSITORY/actions/runs/$TARGET_RUN_ID/rerun-failed-jobs" \
    >/dev/null
}

main "$@"
