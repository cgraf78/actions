# Reusable Workflow API

This document is the caller contract for the public reusable workflows in this
repository. The workflows intentionally own CI/release orchestration only:
checkout policy, platform selection, Rust/tool setup, secret handoff, release
drafting, asset upload, and publishing. Caller repositories own product
contracts such as package layout, installer behavior, generated metadata,
signing, and smoke-test assertions.

Callers should reference workflows at `@main` so fixes to shared CI behavior roll
out consistently across `cgraf78` repositories.

## Common Contracts

### Command Inputs

Inputs ending in `-command` are shell snippets evaluated with Bash after checkout
and after the workflow has changed into `working-directory` when that input is
available.

Command snippets are caller-owned. Keep them small and prefer invoking scripts
checked into the caller repository:

```yaml
with:
  package-smoke-command: |
    scripts/package-release.sh "$RUST_TARGET" "$ASSET_PLATFORM"
    scripts/smoke-release.sh "$ASSET_PLATFORM"
```

The shared workflows pass commands through environment variables before
`eval`-ing them. That keeps GitHub expression interpolation out of the script
body and gives the caller one explicit boundary for custom behavior.

### Matrix Sets

Public CI workflows accept `matrix-set`:

| Value  | Behavior                                                                                            |
| ------ | --------------------------------------------------------------------------------------------------- |
| `auto` | Push and pull request runs use the high-signal `core` matrix; scheduled and manual runs use `full`. |
| `core` | Force the high-signal matrix.                                                                       |
| `full` | Force the full platform matrix.                                                                     |

Internal worker workflows accept only concrete `core` or `full` because the
public workflow owns event-policy decisions.

### Dependency Token

Public CI workflows accept optional secret `DEPENDENCY_GH_TOKEN`. When supplied,
caller-owned commands receive it as both `GH_TOKEN` and `GITHUB_TOKEN`.

Use this for private dependency downloads or GitHub API rate-limit avoidance.
Do not use it for release upload permissions; `rust-release.yml` uses
`github.token` only at its write boundaries.

## `shell-ci.yml`

`shell-ci.yml` runs shell-tool tests across the shared platform matrix.

### Inputs

| Input          | Default  | Contract                                                                   |
| -------------- | -------- | -------------------------------------------------------------------------- |
| `profiles`     | `""`     | Comma-separated OS prerequisite profiles consumed by `shell-ci-prereqs`.   |
| `matrix-set`   | `auto`   | Platform matrix policy. See [Matrix Sets](#matrix-sets).                   |
| `setup`        | `none`   | Named setup mode. Supported values are `none`, `checkrun`, and `dotfiles`. |
| `test-command` | required | Caller-owned Bash command run on every selected platform.                  |

### Secrets

| Secret                | Contract                                                                    |
| --------------------- | --------------------------------------------------------------------------- |
| `DEPENDENCY_GH_TOKEN` | Optional token exposed to caller commands as `GH_TOKEN` and `GITHUB_TOKEN`. |
| `DS_DEPLOY_KEY`       | Dotfiles-only deploy key. Preserved for the `dotfiles` setup mode.          |
| `SHDEPS_DEPLOY_KEY`   | Dotfiles-only deploy key. Preserved for the `dotfiles` setup mode.          |

## `bash32-ci.yml`

`bash32-ci.yml` runs a single macOS job under Apple's stock `/bin/bash`. Use it
for installer or bootstrap scripts that intentionally support Bash 3.2. Do not
use it for normal shell test suites; those belong in `shell-ci.yml` so they run
across the shared platform matrix.

This workflow is intentionally separate from `shell-ci.yml`. GitHub displays
job-level skips from reusable workflows in every caller, so an optional Bash 3.2
job inside `shell-ci.yml` makes normal repos show irrelevant skipped macOS
checks. Separate opt-in keeps the UI and status surface aligned with what each
repo actually tests.

### Inputs

| Input     | Default  | Contract                                                             |
| --------- | -------- | -------------------------------------------------------------------- |
| `command` | required | Caller-owned command run after checkout with `shell: /bin/bash {0}`. |

### Secrets

| Secret                | Contract                                                                    |
| --------------------- | --------------------------------------------------------------------------- |
| `DEPENDENCY_GH_TOKEN` | Optional token exposed to caller commands as `GH_TOKEN` and `GITHUB_TOKEN`. |

### Bash 3.2 Contract

The workflow prints `/bin/bash --version` before evaluating `command`. Callers
should invoke their script with `/bin/bash` explicitly when the script is not
directly executable or when the test is meant to verify the script under the
stock shell regardless of its shebang.

## `rust-ci.yml`

`rust-ci.yml` runs Rust tests across the shared platform matrix and a separate
Ubuntu quality gate.

### Inputs

| Input                         | Default                                                             | Contract                                                                                                            |
| ----------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `rust-toolchain`              | `stable`                                                            | Toolchain passed to `dtolnay/rust-toolchain`.                                                                       |
| `matrix-set`                  | `auto`                                                              | Platform matrix policy. See [Matrix Sets](#matrix-sets).                                                            |
| `working-directory`           | `.`                                                                 | Directory where command hooks run.                                                                                  |
| `setup-command`               | `""`                                                                | Optional caller-owned setup command run before tests and quality commands.                                          |
| `test-command`                | `cargo test --locked`                                               | Caller-owned test command run on every selected platform.                                                           |
| `fmt-command`                 | `cargo fmt --check`                                                 | Ubuntu quality formatting command. Empty disables the step.                                                         |
| `clippy-command`              | `cargo clippy --locked --all-targets --all-features -- -D warnings` | Ubuntu quality lint command. Empty disables the step.                                                               |
| `build-command`               | `cargo build --release --locked`                                    | Ubuntu quality build command. Empty disables the step.                                                              |
| `doc-command`                 | `cargo doc --locked --no-deps`                                      | Ubuntu quality docs command. Empty disables the step.                                                               |
| `package-smoke-setup-command` | `""`                                                                | Optional setup command run immediately before package smoke.                                                        |
| `package-smoke-command`       | `""`                                                                | Optional caller-owned command that builds and validates a representative release artifact. Empty disables the step. |

### Locked Defaults

Rust defaults use `--locked` because CI should exercise the checked-in dependency
graph. Library repositories or unusual workspaces that intentionally do not
commit `Cargo.lock` must override the relevant commands.

### Package Smoke

`package-smoke-command` is a generic execution point, not a shared packaging
implementation. Release archive names, binary names, metadata, checksums,
signing, install scripts, and smoke assertions belong in the caller repository.

Use `package-smoke-setup-command` for prerequisites such as extra Rust targets,
system linkers, or signing tools:

```yaml
with:
  package-smoke-setup-command: |
    rustup target add x86_64-unknown-linux-musl
    sudo apt-get update
    sudo apt-get install -y musl-tools
  package-smoke-command: |
    scripts/package-release.sh x86_64-unknown-linux-musl linux-x86_64-musl
    scripts/smoke-release.sh linux-x86_64-musl
```

## `rust-release.yml`

`rust-release.yml` builds and publishes Rust binary release archives for the
standard platform set.

### Release Platform Matrix

The workflow exposes both Rust target triples and public asset labels:

| `RUST_TARGET`                | `ASSET_PLATFORM`     |
| ---------------------------- | -------------------- |
| `x86_64-unknown-linux-musl`  | `linux-x86_64-musl`  |
| `aarch64-unknown-linux-musl` | `linux-aarch64-musl` |
| `x86_64-apple-darwin`        | `macos-x86_64`       |
| `aarch64-apple-darwin`       | `macos-aarch64`      |

Use `RUST_TARGET` for compiler/toolchain commands. Use `ASSET_PLATFORM` for
archive names and installer-facing metadata. Public asset names should not
inherit Rust target triples unless a caller deliberately chooses that contract.

### Inputs

| Input               | Default                                                       | Contract                                                                                                                           |
| ------------------- | ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `rust-toolchain`    | `stable`                                                      | Toolchain passed to `dtolnay/rust-toolchain`.                                                                                      |
| `working-directory` | `.`                                                           | Directory where release commands run.                                                                                              |
| `setup-command`     | `""`                                                          | Optional setup command run before validation/package commands.                                                                     |
| `version-command`   | `cargo pkgid \| sed 's/.*@//'`                                | Prints a bare package version. Used with `tag-prefix` when `tag-command` is empty.                                                 |
| `tag-command`       | `""`                                                          | Optional command that prints the exact expected Git tag. When set, it overrides `version-command` and `tag-prefix` for validation. |
| `tag-prefix`        | `v`                                                           | Prefix prepended to `version-command` output when `tag-command` is empty.                                                          |
| `package-command`   | `scripts/package-release.sh "$RUST_TARGET" "$ASSET_PLATFORM"` | Caller-owned command that builds release assets for the current matrix row.                                                        |
| `smoke-command`     | `""`                                                          | Optional caller-owned command that validates the built archive for the current matrix row.                                         |
| `asset-glob`        | `dist/*.tar.gz dist/*.sha256`                                 | Space-separated shell globs uploaded to the GitHub release.                                                                        |
| `release-title`     | `""`                                                          | Draft release title. Empty uses the Git tag.                                                                                       |
| `generate-notes`    | `true`                                                        | Whether GitHub should generate release notes when creating the draft.                                                              |
| `prerelease`        | `false`                                                       | Whether to mark the release as a prerelease.                                                                                       |
| `publish`           | `true`                                                        | Whether to publish the draft release after all matrix builds upload assets.                                                        |
| `latest`            | `true`                                                        | Whether a published release should be marked latest.                                                                               |

### Tag Validation

For normal semver Cargo projects, leave `tag-command` empty and use
`version-command` plus `tag-prefix`.

For projects whose release identity is not a Cargo package version, use
`tag-command`:

```yaml
with:
  tag-command: scripts/release-tag.sh
```

`tag-command` must print exactly one tag string matching `github.ref_name`.

### Caller-Owned Packaging

The release workflow deliberately does not inspect archive contents. It only
passes `RUST_TARGET` and `ASSET_PLATFORM`, runs caller commands, uploads matching
assets, and publishes the release. Keep product-specific release scripts in the
product repository so changes to installer or archive contracts review with the
product code.
