# Reusable Workflows

This directory owns the public reusable workflow API for `cgraf78` repositories.
The detailed contract lives in `docs/workflow-api.md`; this file documents the
local organization.

## Public Workflows

- `shell-ci.yml` runs shell project tests across the shared platform matrix.
- `bash32-ci.yml` runs Bash 3.2 compatibility checks.
- `rust-ci.yml` runs Rust checks, tests, docs, clippy, and builds.
- `termux-ci.yml` is the stable caller contract for running commands inside the
  official Termux app on an Android emulator.
- `rust-release.yml` builds and publishes Rust release artifacts.

The public shell, Rust, and Termux CI workflows expose a `Required` aggregation
job. Caller branch protection should require `<caller job> / Required`;
internal worker and matrix job names are diagnostic details rather than stable
API.

## Internal Workflows

- `_shell-platforms.yml` and `_rust-platforms.yml` are shared implementation
  workflows for the public platform CI entrypoints.
- `_termux-ci.yml` owns emulator provisioning, sandbox transport, and runtime
  execution for the public Termux entrypoint.
- `ci.yml` validates this repository's workflow and action definitions.

Keep input names and behavior backward compatible for public reusable
workflows. Implementation workflows may change more freely, but callers should
continue to go through the public files above.

The July 2026 public-dotfiles migration deliberately removes the obsolete
dotfiles-only deploy-key secret after `cgraf78/ds` became public. Existing
immutable workflow pins retain the old contract; advancing the dotfiles caller
pin must remove that secret in the same change.
