# Reusable Workflow API

This document is the caller contract for the public reusable workflows in this
repository. The workflows intentionally own CI/release orchestration only:
checkout policy, platform selection, Rust/tool setup, secret handoff, release
drafting, asset upload, and publishing. Caller repositories own product
contracts such as package layout, installer behavior, generated metadata,
signing, and smoke-test assertions.

Callers must reference workflows by full 40-character commit SHA. Treat the
workflow ref as a dependency: enable weekly GitHub Actions Dependabot updates,
let each update run the caller's normal CI, and review it before merge. This keeps
shared fixes moving across `cgraf78` repositories without changing the workflow
code executed by an unchanged caller commit.

The examples in this repository pin
`7d88c3afa6e51a83e9cfefb0c12f503155e17952`, which passed the `actions` CI
suite. Callers may pin a newer commit after reviewing it and confirming that its
CI passed.

Dependabot-triggered workflows receive a read-only token and only secrets stored
for Dependabot. After reviewing the proposed workflow commit, callers that
require sensitive repository Actions secrets should recreate the bump on a
trusted branch before treating its CI result as authoritative. An equivalent
Dependabot secret is appropriate only when it is intentionally least-privileged
and safe to expose to the proposed dependency code before review. In particular,
do not expose a private-repository deploy key to an unreviewed reusable-workflow
update. Re-running the bot-authored workflow as another actor does not restore
repository Actions secrets. See GitHub's
[Dependabot workflow restrictions](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-on-actions#restrictions-when-dependabot-triggers-events).

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
caller-owned host commands receive it as both `GH_TOKEN` and `GITHUB_TOKEN`.
Commands executed inside the Termux app sandbox do not receive this token.

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

The `checkrun` setup mode requires the caller to commit both
`.github/mise/checkrun-ci.toml` and `.github/mise/mise.lock`. The setup uses
Mise's strict locked mode, so a missing lock or unresolved platform asset fails
before the caller's tests run. Checkrun's suite separately rejects structural
manifest/lock drift.

### Secrets

| Secret                | Contract                                                                    |
| --------------------- | --------------------------------------------------------------------------- |
| `DEPENDENCY_GH_TOKEN` | Optional token exposed to caller commands as `GH_TOKEN` and `GITHUB_TOKEN`. |
| `DS_DEPLOY_KEY`       | Dotfiles-only deploy key. Preserved for the `dotfiles` setup mode.          |

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
| `android-package-smoke-command` | `""`                                                              | Optional caller-owned command that cross-builds and validates the Android aarch64 release artifact. Empty disables the job. |
| `termux-command`              | `""`                                                                | Optional command run inside the official Termux app on an Android x86_64 emulator. Empty disables the job.           |
| `termux-host-command`         | `""`                                                                | Optional host command that cross-builds artifacts copied into the Termux sandbox.                                    |

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

Use `android-package-smoke-command` to continuously validate the Android/Bionic
archive. The shared workflow installs `aarch64-linux-android`, configures the
runner-provided NDK, and exports `RUST_TARGET=aarch64-linux-android` plus
`ASSET_PLATFORM=android-aarch64`:

```yaml
with:
  android-package-smoke-command: |
    scripts/package-release.sh "$RUST_TARGET" "$ASSET_PLATFORM"
    scripts/smoke-release.sh "$ASSET_PLATFORM"
```

Use `termux-command` for an independent runtime proof in a real Android app
sandbox. Pair it with `termux-host-command` to build an x86_64 Android artifact
on the Ubuntu host; the shared workflow exports `RUST_TARGET=x86_64-linux-android`
and `ASSET_PLATFORM=android-x86_64`, then copies the resulting checkout files
into Termux. Keep the AArch64 package smoke enabled to validate the exact release
architecture.

## `termux-ci.yml`

`termux-ci.yml` is the stable public contract for a real Android/Termux runtime
check. It forwards typed inputs to the internal `_termux-ci.yml` worker, which
installs the checksum-pinned official Termux APK, copies the caller checkout to
`$HOME/project`, and runs the caller's command under Termux Bash. Callers do not
depend on the emulator, bootstrap, or sandbox-transport implementation.

| Input               | Default  | Contract                                                              |
| ------------------- | -------- | --------------------------------------------------------------------- |
| `command`           | required | Bash command executed inside Termux.                                  |
| `host-command`      | `""`     | Optional command that prepares checkout artifacts on the Ubuntu host. |
| `rust-toolchain`    | `""`     | Optional toolchain enabling the fixed x86_64 Android NDK host build.   |
| `working-directory` | `.`      | Checkout-relative directory used by the host and Termux commands.     |

### Secrets

| Secret                | Contract                                                                       |
| --------------------- | ------------------------------------------------------------------------------ |
| `DEPENDENCY_GH_TOKEN` | Optional token exposed only to `host-command` as `GH_TOKEN` and `GITHUB_TOKEN`. |

## `rust-release.yml`

`rust-release.yml` builds and publishes Rust binary release archives for the
standard platform set. Android aarch64 is available through the explicit
`android-aarch64` opt-in so existing callers retain their current matrix.

### Release Platform Matrix

The workflow exposes both Rust target triples and public asset labels:

| `RUST_TARGET`                | `ASSET_PLATFORM`     |
| ---------------------------- | -------------------- |
| `x86_64-unknown-linux-musl`  | `linux-x86_64-musl`  |
| `aarch64-unknown-linux-musl` | `linux-aarch64-musl` |
| `aarch64-linux-android`      | `android-aarch64`    |
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
| `android-aarch64`   | `false`                                                       | Whether to build and publish the Android aarch64 artifact.                                                                          |

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
