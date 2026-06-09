# Reusable Workflows

This directory owns the public reusable workflow API for `cgraf78` repositories.
The detailed contract lives in `docs/workflow-api.md`; this file documents the
local organization.

## Public Workflows

- `shell-ci.yml` runs shell project tests across the shared platform matrix.
- `bash32-ci.yml` runs Bash 3.2 compatibility checks.
- `rust-ci.yml` runs Rust checks, tests, docs, clippy, and builds.
- `rust-release.yml` builds and publishes Rust release artifacts.

## Internal Workflows

- `_shell-platforms.yml` and `_rust-platforms.yml` are shared implementation
  workflows for the public CI entrypoints.
- `ci.yml` validates this repository's workflow and action definitions.

Keep input names and behavior backward compatible for public reusable
workflows. Implementation workflows may change more freely, but callers should
continue to go through the public files above.
