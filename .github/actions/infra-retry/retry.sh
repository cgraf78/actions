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

read_job_log() {
  local endpoint=$1 log=$2 error="${2}.error"

  if gh api "$endpoint" >"$log" 2>"$error"; then
    return 0
  fi

  # Newer gh releases protect terminals by refusing responses with control
  # bytes, even when stdout is a private file. Retry only that exact refusal:
  # older gh versions never see their unsupported flag, and every other API
  # error remains unclassified. The raw log is parsed in place and never
  # rendered, so escape bytes stay inert and can only make matching fail closed.
  grep -Fqx \
    'the response contains terminal escape sequences; pass --allow-escape-sequences to output it anyway' \
    "$error" || return 1
  gh api --allow-escape-sequences "$endpoint" >"$log" 2>"$error"
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

is_retryable_termux_bootstrap() {
  local log=$1

  grep -Fq 'Installing Termux APK' "$log" &&
    grep -Fq 'Waiting for Termux bootstrap' "$log" &&
    grep -Fq 'Termux bootstrap did not become ready' "$log"
}

is_retryable_shellcheck_download() {
  local log=$1 final_curl final_exit

  # Curl prints every failed retry, including attempts that later recover.
  # Require its final diagnostic and the action's final exit to agree on the
  # same transient failure. This leaves recovered downloads, permanent HTTP
  # errors, checksum failures, and real lint findings red.
  grep -Fq '/.github/actions/shell-ci-prereqs@' "$log" || return 1
  grep -Fq 'profiles: base,shellcheck' "$log" || return 1
  grep -Fq 'setup: none' "$log" || return 1
  ! grep -Fq '=== repository ShellCheck inventory ===' "$log" || return 1

  final_curl=$(grep -E 'curl: \((22|28|56)\)' "$log" | tail -n 1) || return 1
  final_exit=$(grep -E 'Process completed with exit code (22|28|56)\.' "$log" |
    tail -n 1) || return 1

  case "$final_exit" in
    *'exit code 22.'*)
      case "$final_curl" in
        *'curl: (22) The requested URL returned error: 429' | \
          *'curl: (22) The requested URL returned error: 5'??) return 0 ;;
      esac
      ;;
    *'exit code 56.'*)
      case "$final_curl" in
        *'curl: (56) Connection died, tried '*' times before giving up')
          return 0
          ;;
      esac
      ;;
    *'exit code 28.'*)
      # Curl uses 28 for both connect and low-speed timeouts. The surrounding
      # action/profile signature above proves this was the pinned ShellCheck
      # transport, so retrying cannot mask a caller's arbitrary curl failure.
      [[ "$final_curl" == *'curl: (28) '* ]] && return 0
      ;;
  esac
  return 1
}

is_retryable_bounded_stall() {
  local log=$1

  # `retry_pkg` prints this exact token when a package command has exhausted
  # its bounded attempts. It is a marker this repo owns, not runner prose, so
  # classification does not depend on any package manager's wording.
  grep -Fq 'infra-stall: package command exhausted bounded retries' "$log"
}

is_retryable_step_timeout() {
  local log=$1

  # A `timeout-minutes` kill is the deliberate outcome of a network step that
  # stalled, so it must be retryable - otherwise adding those caps would just
  # convert a slow-but-green job into a red one with no automatic recovery.
  #
  # Unlike the markers above, the timeout notice is emitted by the runner after
  # it SIGKILLs the step, so there is no opportunity for our own code to print a
  # token. Matching runner prose is therefore unavoidable here; keep it narrow
  # by also requiring the run to be one of the network bootstrap steps that
  # carries an explicit cap, so a genuinely hung test suite stays red.
  grep -Eq \
    "The action has timed out\\.|has timed out after [0-9]+ minutes|exceeded the maximum execution time of [0-9]+ minutes" \
    "$log" || return 1

  grep -Eq \
    "Install OS prerequisites|Install ShellCheck prerequisites|Bootstrap dotfiles dependencies" "$log"
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
    if ! read_job_log \
      "repos/$TARGET_REPOSITORY/actions/jobs/$job_id/logs" "$log"; then
      notice "could not read failed job log: $name"
      unclassified_leaf=$((unclassified_leaf + 1))
      continue
    fi

    if is_retryable_docker_pull "$log"; then
      notice "allowlisted Docker pull failure: $name"
      retryable_leaf=$((retryable_leaf + 1))
    elif is_retryable_termux_bootstrap "$log"; then
      notice "allowlisted Termux bootstrap failure: $name"
      retryable_leaf=$((retryable_leaf + 1))
    elif is_retryable_shellcheck_download "$log"; then
      notice "allowlisted ShellCheck prerequisite download failure: $name"
      retryable_leaf=$((retryable_leaf + 1))
    elif is_retryable_bounded_stall "$log"; then
      notice "allowlisted bounded package-command stall: $name"
      retryable_leaf=$((retryable_leaf + 1))
    elif is_retryable_step_timeout "$log"; then
      notice "allowlisted network step timeout: $name"
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
