# Composite Actions

This directory contains reusable composite actions consumed by the workflows in
this repo and by other `cgraf78` repositories.

## Actions

- `platform-matrix` emits the shared OS/container matrix.
- `shell-ci-prereqs` installs shell test dependencies by profile and setup mode.
- `rust-ci-prereqs` installs Rust CI prerequisites that are not handled by
  `actions-rust-lang/setup-rust-toolchain`.
- `checkrun-dev-tools` installs checkrun's formatter/linter toolchain for CI.
- `dotfiles-private-deps` configures access to private dotfiles dependencies.
- `dotfiles-bootstrap` runs the dotfiles bootstrap/update/doctor flow in CI.

Keep composite actions narrow and reusable. If behavior is only needed by a
single reusable workflow, prefer keeping it in that workflow until a second
consumer appears.
