# Composite Actions

This directory contains reusable composite actions consumed by the workflows in
this repo and by other `cgraf78` repositories.

## Actions

- `platform-matrix` emits the shared OS/container matrix.
- `android-rust-toolchain` configures the runner-provided Android NDK for Rust
  aarch64 and x86_64 cross-builds.
- `shell-ci-prereqs` installs shell test dependencies by profile and setup mode.
- `shellcheck-inventory` validates a repository-owned typed inventory and runs
  ShellCheck over every reviewed program while excluding declared fixtures.
- `rust-ci-prereqs` installs Rust CI prerequisites that are not handled by
  `dtolnay/rust-toolchain`.
- `dotfiles-bootstrap` runs the dotfiles bootstrap/update/doctor flow in CI.
- `verify-release-scripts` fails a consumer repository whose vendored release
  scripts have drifted from the shared copy in `release-scripts/`.

Keep composite actions narrow and reusable. If behavior is only needed by a
single reusable workflow, prefer keeping it in that workflow until a second
consumer appears.

`shellcheck-inventory` expects a tracked, nonsymlink inventory whose records
are `program<TAB>path` or `fixture<TAB>path`. It discovers shell programs from
Git rather than trusting the inventory alone, so new ShellCheck-supported
scripts fail the gate until reviewed. Fixture rows remain visible, discoverable
coverage decisions but are not linted as standalone programs. The caller must
check out one repository at the `GITHUB_WORKSPACE` root and pass a normalized,
repository-relative inventory path. Newline-containing paths cannot be encoded
in the line-oriented inventory and therefore fail closed.
