#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=.github/actions/shared/infra-stall-markers.sh
source "${BASH_SOURCE[0]%/*}/../shared/infra-stall-markers.sh"

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

is_derived_aggregate() {
  local name=$1

  # Derived aggregates fail exactly when a job they depend on fails, and
  # carry no failure evidence of their own: `Required` gates on the leaf
  # jobs, and `dotfiles`' `installed-profiles.yml` `Result` job
  # (`if: always()` over the composition legs, also reached by
  # `dotfiles-dev` and `dotfiles-nvim` through that workflow) reports a
  # failed leg. Counting either as a leaf leaves every run with an
  # aggregate red, because the aggregate can never be classified from its
  # own log. A real leaf job that merely ends in one of these words is
  # still ignored here: if it fails alongside a leaf, that leaf is
  # classified on its own; if it fails alone, the run stays red for a
  # human to inspect rather than gaining a retry on no evidence.
  [[ "$name" == Required || "$name" == *' / Required' ||
    "$name" == Result || "$name" == *' / Result' ]]
}

is_retryable_docker_pull() {
  local log=$1

  grep -Fq 'Docker pull failed with exit code' "$log" &&
    grep -Eiq \
      'context deadline exceeded|TLS handshake timeout|i/o timeout|connection reset by peer|unexpected EOF|toomanyrequests|429 Too Many Requests|502 Bad Gateway|503 Service Unavailable|request canceled while waiting for connection' \
      "$log"
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

is_retryable_apt_mirror_failure() {
  local log=$1 final_apt final_fetch final_exit

  # A mirror answering an `apt-get` index or package fetch with a 5xx
  # error page makes `retry_pkg` exit 100 instead of stalling to the 124
  # deadline. On pins predating the library's update-100 stall token,
  # and for installs (whose exit 100 is semantically ambiguous, so the
  # library prints no token for them), this classifier recovers the
  # same outage from the log. Like the ShellCheck classifier, require
  # the prereq action boundary, the shared library's own
  # exhausted-retries diagnostic for an apt command, and a final exit
  # of 100 that agrees with it. The 5xx status must sit on the last
  # `Failed to fetch` line: attempts log in order, so an early transient
  # 525 superseded by a permanent 404 on a later attempt, or a stray 5xx
  # token from another step, must not retry. A permanent fetch failure
  # (404), a held-broken-package install (no fetch failure), and any
  # other exit keep the job red.
  grep -Eq \
    '/\.github/actions/(shell-ci-prereqs|rust-ci-prereqs|musl-build-prereqs)(@|$)' \
    "$log" || return 1
  final_apt=$(grep -E \
    'package command failed after [0-9]+ attempts \(exit 100\): .*apt-get.*( update$| install )' \
    "$log" | tail -n 1) || return 1
  [[ -n "$final_apt" ]] || return 1
  final_fetch=$(grep -F 'Failed to fetch' "$log" | tail -n 1) || return 1
  if ! printf '%s\n' "$final_fetch" | grep -Eq ' 5[0-9][0-9]( |$)'; then
    return 1
  fi
  final_exit=$(grep -E 'Process completed with exit code 100\.' "$log" |
    tail -n 1) || return 1
  [[ -n "$final_exit" ]]
}

is_retryable_termux_apt_network_failure() {
  local log=$1 final_fetch final_exit

  # The Termux worker gives apt two transport retries per supervised
  # attempt and prints a stall marker only on the supervisor's 124
  # deadline. When the emulator loses its network outright, apt fails
  # fast instead: a package fetch exhausts its retries and the install
  # exits 100, or `apt-get update` only warns and the install then
  # cannot locate any package. Exit 100 alone is ambiguous (dependency
  # and conflict errors share it), so mirror the apt mirror classifier:
  # require the runner's `Uses:` line for the Termux reusable workflow
  # (a job-setup line, never echoed step prose), a network-level
  # transport error on the LAST `Failed to fetch` line, apt's own
  # fetch-related error as the LAST `E:` line, and a final step exit of
  # 100. An HTTP status on the last fetch (the mirror answered), a
  # transient `update` error superseded by a later install's 404, and
  # a dependency error with no fetch failure all stay red. The `E:`
  # check ties the exit to apt: the caller command runs in the same
  # step, so a warning-only `update` failure followed by a caller's own
  # exit 100 must not retry. Within one install apt lists its final
  # fetch errors in package order, not failure order, so a mid-transfer
  # read error counts as transport too. The emulator action reports
  # the step's exit as `The process '...' failed`, a plain step as
  # `Process completed`; accept either, last one wins.
  grep -Eq 'Uses: [^ ]+/\.github/workflows/_termux-ci\.yml@' "$log" ||
    return 1
  final_fetch=$(grep -F 'Failed to fetch' "$log" | tail -n 1) || return 1
  printf '%s\n' "$final_fetch" | grep -Eiq \
    'cannot initiate the connection|network is unreachable|something wicked happened resolving|temporary failure resolving|could not resolve|connection timed out|error reading from server' ||
    return 1
  grep -E '(^| )E: ' "$log" | tail -n 1 | grep -Eq \
    'E: (Failed to fetch|Unable to fetch some archives|Unable to locate package)' ||
    return 1
  final_exit=$(grep -E \
    "##\\[error\\](The process '[^']+' failed with exit code|Process completed with exit code) [0-9]+" \
    "$log" | tail -n 1) || return 1
  [[ "$final_exit" =~ exit\ code\ 100\.?$ ]]
}

# Sets `stall_marker` to the matched token so the caller can report it.
is_retryable_bounded_stall() {
  local log=$1 marker

  # Provider-owned wrappers print these tokens only when their supervisor
  # deadline or bounded retries expire. Classification therefore does not
  # depend on third-party package-manager or Android-emulator wording. Match
  # only the tokens, never step prose: the runner echoes each step's script
  # into the log, so any phrase written in a `run:` block appears in every
  # job that reached that step, whether or not the branch executed.
  for marker in "${INFRA_STALL_MARKERS[@]}"; do
    if grep -Fq -- "$marker" "$log"; then
      stall_marker=$marker
      return 0
    fi
  done
  return 1
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
  local job_id name log stall_marker
  while IFS=$'\t' read -r job_id name; do
    if is_derived_aggregate "$name"; then
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
    elif is_retryable_shellcheck_download "$log"; then
      notice "allowlisted ShellCheck prerequisite download failure: $name"
      retryable_leaf=$((retryable_leaf + 1))
    elif is_retryable_apt_mirror_failure "$log"; then
      notice "allowlisted apt mirror failure: $name"
      retryable_leaf=$((retryable_leaf + 1))
    elif is_retryable_termux_apt_network_failure "$log"; then
      notice "allowlisted Termux apt network failure: $name"
      retryable_leaf=$((retryable_leaf + 1))
    elif is_retryable_bounded_stall "$log"; then
      notice "allowlisted bounded infrastructure stall ($stall_marker): $name"
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
