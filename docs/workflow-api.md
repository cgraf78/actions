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

Examples use `FULL_COMMIT_SHA` as a placeholder. Callers must substitute a
reviewed commit whose `actions` CI suite passed.

## Required Check Contract

The public `shell-ci.yml`, `rust-ci.yml`, and `termux-ci.yml` workflows each
expose a job named `Required`. GitHub combines that name with the caller's job
key, producing a stable context such as `shell / Required`.

Branch protection should require this aggregate context instead of selector,
platform, quality, or runtime implementation contexts. The aggregate fails
closed when a mandatory child job fails, is cancelled, or is unexpectedly
skipped.

The Shell aggregate always requires its conventional Platforms and real Termux
runtime. When `shellcheck-inventory-path` is configured, it also requires the
single Ubuntu ShellCheck job; that leaf may be skipped only when the input is
empty. The Rust aggregate always requires Platforms, Quality, Android package,
and real Termux runtime. Neither family accepts a skipped Android/Termux result.

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

## Infrastructure Retry Action

The `infra-retry` composite action lets a caller smooth over a small allowlist
of failures caused before repository code runs. It recognizes GitHub runner
job-container pulls that exhausted the runner's own retries due to transient
registry transport failures, and Termux APK launches whose bootstrap never
became ready before the caller command ran. It does not retry test, lint, build,
package-manager, authentication, or mixed infrastructure/application failures.

The action inspects failed leaf-job logs and ignores only derived `Required`
aggregates. It reruns failed jobs through GitHub's API when every failed leaf is
allowlisted and `run_attempt` is exactly `1`. A failed second attempt remains a
hard failure, which prevents retry loops and preserves a visible reliability
signal.

Callers opt in with a controller on their default branch. Pin the action to a
reviewed 40-character commit, substitute the caller's workflow name, and do not
make the controller itself a required check:

```yaml
name: Retry CI infrastructure failures

on:
  workflow_run:
    workflows: [Tests]
    types: [completed]

permissions: {}

jobs:
  retry:
    if: >-
      github.event.workflow_run.conclusion == 'failure' &&
      github.event.workflow_run.run_attempt == 1
    runs-on: ubuntu-24.04
    permissions:
      actions: write
      contents: read
    steps:
      - uses: cgraf78/actions/.github/actions/infra-retry@FULL_COMMIT_SHA
        with:
          github-token: ${{ github.token }}
          repository: ${{ github.repository }}
          run-id: ${{ github.event.workflow_run.id }}
          run-attempt: ${{ github.event.workflow_run.run_attempt }}
          conclusion: ${{ github.event.workflow_run.conclusion }}
```

`workflow_run` uses the controller from the default branch. It does not execute
or check out code from the failed branch, and its token is scoped to Actions
reruns plus read-only repository contents.

## ShellCheck Inventory Action

The `shellcheck-inventory` composite action validates a repository-owned list of
shell programs and fixtures, then lints every program. The caller must check out
one repository at the `GITHUB_WORKSPACE` root and install `bash`, `git`, and
`shellcheck` before invoking the action. The shared Shell CI workflow owns those
prerequisites for its callers; the narrow composite action intentionally uses
the caller-provided ShellCheck version.

Pin the action to a reviewed 40-character commit and pass a tracked, nonsymlink
inventory:

```yaml
- uses: cgraf78/actions/.github/actions/shellcheck-inventory@FULL_COMMIT_SHA
  with:
    inventory-path: .github/shellcheck-files.txt
    exclude-codes: SC1091
```

The inventory is line-oriented. Blank lines and comments beginning in column
one are ignored; records use a literal tab:

```text
# type<TAB>repository-relative path
program<TAB>bin/tool
fixture<TAB>test/fixtures/intentionally-invalid.sh
```

Replace each `<TAB>` marker with one literal tab. `program` rows are linted.
`fixture` rows are explicit, visible exclusions for shell-shaped test data that
should not pass as standalone programs.

Discovery recognizes common shell extensions, supported shebangs, and leading
`# shellcheck shell=...` directives, including BusyBox. An extensionless sourced
library without a shebang needs a supported directive to opt into coverage.
Direct action users need ShellCheck 0.11 or newer for the BusyBox dialect; the
shared Shell CI workflow provides the reviewed version for its callers.
`exclude-codes` applies a validated, repository-wide exception list for this
action invocation without changing direct ShellCheck behavior elsewhere.
Discovery also examines nonignored, untracked files; run the action before
generating scripts or add intentional build output to `.gitignore`.

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

### Concurrency Scope

The public shell and Rust workflows cancel an older run only when its
repository, event, pull request or ref, CI family, and `concurrency-scope` all
match a newer run. The optional scope defaults to `default`, which is
appropriate when a caller invokes a CI family once.

Callers that invoke the same family more than once in one workflow must pass a
distinct, stable scope for each call. The scope only needs to be unique within
that caller repository and CI family:

```yaml
jobs:
  shell:
    uses: cgraf78/actions/.github/workflows/shell-ci.yml@FULL_COMMIT_SHA
    with:
      concurrency-scope: shell
      test-command: tests/shell-test

  shellcheck:
    uses: cgraf78/actions/.github/workflows/shell-ci.yml@FULL_COMMIT_SHA
    with:
      concurrency-scope: shellcheck
      test-command: tests/shellcheck-test
```

## `shell-ci.yml`

`shell-ci.yml` runs shell-tool tests across the shared platform matrix.

### Inputs

| Input                 | Default  | Contract                                                                           |
| --------------------- | -------- | ---------------------------------------------------------------------------------- |
| `concurrency-scope`   | `default` | Stable identity for this call. Must differ between multiple shell calls.          |
| `force-dotfiles-update` | `false` | With `setup: dotfiles`, refresh shdeps before conventional-platform dependency resolution. |
| `profiles`            | `""`     | Comma-separated prerequisite profiles used by conventional platforms and Termux.   |
| `shellcheck-inventory-path` | `""` | Repository-relative typed inventory for one Ubuntu ShellCheck gate. Empty disables it. |
| `shellcheck-exclude-codes` | `""` | Validated comma-separated ShellCheck codes excluded from the shared lint invocation. |
| `matrix-set`          | `auto`   | Platform matrix policy. See [Matrix Sets](#matrix-sets).                           |
| `setup`               | `none`   | Named setup mode. Supported values are `none`, `checkrun`, and `dotfiles`.         |
| `test-command`        | required | Caller-owned Bash command run on every conventional platform and, by default, Termux. |
| `termux-command`      | `""`     | Android-specific command override. Empty reuses `test-command`; it never skips CI. |
| `termux-host-command` | `""`     | Optional Ubuntu-host preparation for artifacts copied into Termux.                 |
| `termux-profiles`     | `""`     | Android override. Empty reuses `profiles`, then falls back to `runtime`.            |

Supported generic profiles are `base`, `jq`, `python`, `zsh`, `lua`, `neovim`,
`tmux`, `openssh-netcat-lsof`, `procps`, and `shellcheck`. Termux additionally
supports `runtime` as a lightweight alternative to `base`: both provide Bash
and `termux-exec`, while `base` also provides Git and curl. The `procps`
profile provides a full procps-compatible `ps` on Linux; macOS uses its system
`ps` without an additional Homebrew package.

Termux installs the Android equivalents of generic profile capabilities from
the same profile list, including when a named setup mode is selected. Its job
always runs. Callers use `termux-command` only for genuinely product-specific
preparation or test selection.

The runner also activates Termux's `termux-exec` compatibility layer before
caller code runs. Repository scripts can therefore keep portable Linux
shebangs such as `#!/usr/bin/env bash` instead of embedding an app data path.
Before installing profile capabilities, the runner fully upgrades the pinned
APK's bootstrap packages against the configured repository. This keeps
executables and their shared libraries on one supported Termux package state.

`force-dotfiles-update` maps to the dotfiles `SHDEPS_FORCE=1` API at the
conventional-platform bootstrap boundary. It defaults off so ordinary callers
keep the cache-first bootstrap. Termux starts from a fresh application sandbox
and does not restore or invoke that shared bootstrap action.

When `shellcheck-inventory-path` is nonempty, the workflow installs ShellCheck
once on Ubuntu and invokes the pinned
[`shellcheck-inventory`](#shellcheck-inventory-action) action. The lint leaf is
part of the existing `Required` aggregate, so callers keep the same branch
protection context while gaining consistent static coverage. ShellCheck does
not run redundantly in the platform or Termux matrices. The immutable
prerequisite-action revision pins checksum-verified ShellCheck 0.11.0, so all
callers share the same reviewed CI baseline.

The `checkrun` setup mode requires the caller to commit both
`.github/mise/checkrun-ci.toml` and `.github/mise/mise.lock`. The setup uses
Mise's strict locked mode, so a missing lock or unresolved platform asset fails
before the caller's tests run. Checkrun's suite separately rejects structural
manifest/lock drift.

### Secrets

| Secret                | Contract                                                                    |
| --------------------- | --------------------------------------------------------------------------- |
| `DEPENDENCY_GH_TOKEN` | Optional token exposed to caller commands as `GH_TOKEN` and `GITHUB_TOKEN`. |

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
| `concurrency-scope`           | `default`                                                           | Stable identity for this call. Must differ between multiple Rust calls.                                             |
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
| `android-package-smoke-command` | required                                                          | Caller-owned command that cross-builds and validates the Android aarch64 release artifact.                           |
| `termux-command`              | required                                                            | Command run inside the official Termux app on an Android x86_64 emulator.                                            |
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
| `profiles`          | `runtime` | Termux profiles; `runtime` is lightweight, while `base` adds Git/curl. |
| `rust-toolchain`    | `""`     | Optional toolchain enabling the fixed x86_64 Android NDK host build.   |
| `setup`             | `none`   | Shell setup mode composed with the requested prerequisite profiles.   |
| `working-directory` | `.`      | Checkout-relative directory used by the host and Termux commands.     |

### Secrets

| Secret                | Contract                                                                       |
| --------------------- | ------------------------------------------------------------------------------ |
| `DEPENDENCY_GH_TOKEN` | Optional token exposed only to `host-command` as `GH_TOKEN` and `GITHUB_TOKEN`. |

## `rust-release.yml`

`rust-release.yml` builds and publishes Rust binary release archives for the
standard platform set. Android aarch64 and x86_64 are available through the
explicit `android-aarch64` and `android-x86_64` opt-ins so existing callers
retain their current matrix.

### Release Platform Matrix

The workflow exposes both Rust target triples and public asset labels:

| `RUST_TARGET`                | `ASSET_PLATFORM`     |
| ---------------------------- | -------------------- |
| `x86_64-unknown-linux-musl`  | `linux-x86_64-musl`  |
| `aarch64-unknown-linux-musl` | `linux-aarch64-musl` |
| `aarch64-linux-android`      | `android-aarch64`    |
| `x86_64-linux-android`       | `android-x86_64`     |
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
| `android-x86_64`    | `false`                                                       | Whether to build and publish the Android x86_64 artifact.                                                                           |

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
assets, and publishes the release. Release scripts live in the product
repository so changes to installer or archive contracts review with the product
code.

Their *logic* does not have to be written three times. `release-scripts/` in
this repo holds the shared implementation of release identity, packaging, and
smoke validation; consumers vendor it into `scripts/` and declare only the
per-project payload in `scripts/release.conf`. See
[`release-scripts/README.md`](../release-scripts/README.md).

Consumers that vendor those scripts should add the drift gate to their normal
CI so a divergent copy fails on pull requests rather than at release time:

```yaml
- uses: cgraf78/actions/.github/actions/verify-release-scripts@FULL_COMMIT_SHA
  with:
    scripts-dir: scripts
```
