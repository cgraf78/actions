# Reusable Workflows

This directory owns the public reusable workflow API for `cgraf78` repositories.
The detailed contract lives in `docs/workflow-api.md`; this file documents the
local organization.

## Public Workflows

- `mise-lock-refresh.yml` regenerates one caller lockfile and maintains a
  protected, auto-merging update pull request.
- `shell-ci.yml` runs shell project tests across the shared platform matrix
  and in the official Termux app.
- `bash32-ci.yml` runs Bash 3.2 compatibility checks.
- `rust-ci.yml` runs Rust checks, tests, docs, Clippy, builds, optional MSRV
  validation, an Android package smoke, a real Termux runtime smoke, and a
  default-on RustSec audit on every CI event.
- `termux-ci.yml` is the stable caller contract for running commands inside the
  official Termux app on an Android emulator.
- `rust-release.yml` builds, attests, and publishes Rust release artifacts.

The `infra-retry` composite action is an opt-in companion for caller
`workflow_run` controllers. It reruns failed jobs once only when every failed
leaf job matches a narrowly allowlisted infrastructure signature. See
`docs/workflow-api.md` for the caller and security contract.

Pull requests unit-test its classifier and workflow contract. GitHub loads
`workflow_run` only from the default branch, so `Tests` also exposes an explicit
`retry_canary` dispatch input for live post-merge validation; normal runs leave
it at `none`.

The public shell, Rust, and Termux CI workflows expose a `Required`
aggregation job. Shell and Rust always require their Android/Termux work;
caller branch protection should require `<caller job> / Required`. Internal
worker and matrix job names are diagnostic details rather than stable API.

## Internal Workflows

- `_shell-platforms.yml` and `_rust-platforms.yml` are shared implementation
  workflows for the public platform CI entrypoints.
- `_termux-ci.yml` owns emulator provisioning, sandbox transport, and runtime
  execution for the public Termux entrypoint.
- `test.yml` validates this repository's workflow and action definitions.

Keep input names and behavior backward compatible for public reusable
workflows. Implementation workflows may change more freely, but callers should
continue to go through the public files above.

The July 2026 public-dotfiles migration deliberately removes the obsolete
dotfiles-only deploy-key secret after `cgraf78/ds` became public. Existing
immutable workflow pins retain the old contract; advancing the dotfiles caller
pin must remove that secret in the same change.
