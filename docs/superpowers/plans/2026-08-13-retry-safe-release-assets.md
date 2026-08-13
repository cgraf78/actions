# Retry-Safe Release Assets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make shared Rust release uploads idempotent and resilient to ambiguous GitHub API failures.

**Architecture:** A focused Bash helper owns per-asset remote-state checks,
bounded retries, and post-error verification. The reusable workflow delegates
its upload step to that helper, while shell tests exercise the helper through a
fake `gh` executable and real files.

**Tech Stack:** Bash, GitHub CLI, reusable GitHub Actions workflows, jq, ShellCheck.

## Global Constraints

- Preserve the caller-owned shell glob contract.
- Process assets independently and compare exact names plus byte sizes.
- Retry at most three upload attempts per asset.
- Do not modify or sync consumer release scripts.

---

### Task 1: Retry-safe upload helper

**Files:**

- Create: `.github/actions/upload-release-assets/upload.sh`
- Create: `test/release-asset-upload-test`

**Interfaces:**

- Consumes: `TAG`, `ASSET_GLOB`, `GITHUB_REPOSITORY`, `GH_TOKEN`, and the current working directory.
- Produces: exit zero only when every matched local asset has an exact-name remote asset with the same byte size.

**Steps:**

- [ ] Write fake-`gh` shell cases for clean upload, matching prior asset,
  partial prior upload, ambiguous upload success, mismatched size, exhausted
  retries, empty glob, and multiple assets.
- [ ] Run `test/release-asset-upload-test` and verify it fails because the
  helper does not exist.
- [ ] Implement per-file state checks, three attempts, bounded backoff, and
  post-error verification in `upload.sh`.
- [ ] Run `test/release-asset-upload-test` and verify every case passes.
- [ ] Run ShellCheck and formatting through the repository test entry points.

### Task 2: Reusable workflow integration

**Files:**

- Modify: `.github/workflows/rust-release.yml`
- Modify: `test/workflow-contract-test`

**Interfaces:**

- Consumes: the existing `asset-glob`, tag, working-directory, token, and repository values.
- Produces: one workflow step invoking the tested helper from the checked-out actions repository.

**Steps:**

- [ ] Add a workflow-contract assertion that the upload step invokes
  `.github/actions/upload-release-assets/upload.sh` with the existing values.
- [ ] Run `test/workflow-contract-test` and verify the assertion fails against
  the inline `gh release upload` command.
- [ ] Replace the inline upload command with the helper invocation.
- [ ] Run focused tests, then the full repository test suite and `checkrun lint`.
- [ ] Perform adversarial review focused on ambiguous API outcomes, shell word
  splitting, reruns, and least-privilege workflow permissions.
