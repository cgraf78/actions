# actions

Reusable GitHub Actions workflows and action helpers for `cgraf78` repos.

Public CI workflows expose a stable `Required` job for branch protection.
Require `<caller job> / Required` rather than internal platform jobs so matrix
membership can evolve here without protection changes in every caller. The
detailed result contract is documented in
[`docs/workflow-api.md`](docs/workflow-api.md).

## Workflows

For the full caller-facing API, see
[`docs/workflow-api.md`](docs/workflow-api.md). The README gives quick-start
examples; the docs file is the source of truth for inputs, secrets, matrix
policy, and command-hook contracts.

### `shell-ci.yml`

Runs shell-tool test suites across the shared platform matrix. Push and pull
request runs cover the high-signal subset; scheduled and manual runs cover the
full matrix.

Callers should pin a reviewed full commit SHA so an unchanged caller commit
always executes the same workflow code. Enable weekly GitHub Actions Dependabot
updates in the caller repository so shared fixes arrive as ordinary dependency
PRs and run through the caller's CI before merge. Replace `FULL_COMMIT_SHA` in
the examples below with a reviewed `actions` commit that passed its own CI.

Dependabot-triggered workflows receive only Dependabot secrets. After reviewing
the proposed workflow commit, a caller whose CI requires sensitive repository
secrets should recreate the bump on a trusted branch before relying on its CI
result. An equivalent Dependabot secret is appropriate only when it is
least-privileged and safe to expose to the proposed dependency code before
review.

```yaml
jobs:
  test:
    uses: cgraf78/actions/.github/workflows/shell-ci.yml@FULL_COMMIT_SHA
    with:
      profiles: base,jq,python
      shellcheck-inventory-path: .github/shellcheck-files.txt
      test-command: test/example-test
```

Optional `matrix-set` can force `core` or `full`; the default `auto` keeps
push/PR runs on `core` and scheduled/manual runs on `full`.
Dotfiles callers can set `force-dotfiles-update: true` to refresh the shdeps
bootstrap before dependency resolution when validating forced-update behavior.
The default is false, so normal CI consumers retain the cache-first path.
`shellcheck-inventory-path` adds one Ubuntu lint job to the existing required
aggregate without repeating static lint across the runtime matrix.
`shellcheck-exclude-codes` optionally applies a validated repository-wide
suppression list only to that shared lint invocation.

### `bash32-ci.yml`

Runs one explicit macOS job under Apple's stock `/bin/bash` for repos that need
installer or bootstrap compatibility coverage. Keep this separate from
`shell-ci.yml` so ordinary shell repos do not show a skipped Bash 3.2 job.

```yaml
jobs:
  bash32:
    uses: cgraf78/actions/.github/workflows/bash32-ci.yml@FULL_COMMIT_SHA
    with:
      command: /bin/bash scripts/smoke-install-bash32.sh
```

### `rust-ci.yml`

Runs Rust test suites across the same shared platform matrix. Push and pull
request runs cover the high-signal subset; scheduled and manual runs cover the
full matrix. A separate Ubuntu quality gate preserves common Rust checks without
running formatting, clippy, and docs redundantly on every OS.

```yaml
jobs:
  test:
    uses: cgraf78/actions/.github/workflows/rust-ci.yml@FULL_COMMIT_SHA
    with:
      test-command: cargo test --locked
      android-package-smoke-command: |
        cargo build --locked --target "$RUST_TARGET"
        test -x "target/$RUST_TARGET/debug/my-tool"
      termux-host-command: |
        cargo build --locked --target "$RUST_TARGET"
      termux-command: |
        target/x86_64-linux-android/debug/my-tool --version
```

Repos with stricter policies can override the quality-gate commands, or pass an
empty string to disable a command. Repos that need generated files, extra
tooling, or a nested crate path can use `setup-command` and
`working-directory` without forking the shared workflow. Binary repos can use
`build-command`, `package-smoke-setup-command`, and `package-smoke-command` to
validate release artifacts while keeping package layout and smoke assertions in
the product repository. `termux-command` overrides the mandatory Shell
Android runtime command when needed. Shell callers can use `termux-profiles` to
override Android prerequisites without changing conventional platforms. Start
with `base` when tests need Git or curl, or `runtime` for lightweight commands
that only need Bash and `termux-exec`, then add capability profiles such as
`shellcheck`. Rust callers can pair it with `termux-host-command` to cross-build
an x86_64 Android artifact on Ubuntu and then execute that artifact under
Android/Bionic in Termux. This complements the release's exact-architecture
AArch64 cross-build rather than replacing it.

### `termux-ci.yml`

Runs a caller-owned Bash command inside the official Termux application sandbox
on a hardware-accelerated Android x86_64 emulator. The caller checkout is copied
into `$HOME/project`, with Termux's real `HOME`, `PREFIX`, `TMPDIR`, and `PATH`.

```yaml
jobs:
  termux:
    uses: cgraf78/actions/.github/workflows/termux-ci.yml@FULL_COMMIT_SHA
    with:
      rust-toolchain: stable
      host-command: |
        cargo build --release --target "$RUST_TARGET"
      command: |
        target/x86_64-linux-android/release/my-tool --version
```

Use the AArch64 Android cross-build/release jobs to validate the shipped target.
Use this workflow to validate runtime behavior under Android/Bionic and Termux;
cross-building on the host avoids depending on emulator-hosted compiler behavior.

### `rust-release.yml`

Builds and publishes Rust binary archives for the standard release platform
set: Linux x86_64 musl, Linux aarch64 musl, macOS x86_64, and macOS aarch64.
Callers can opt into Android aarch64 and x86_64 without changing their packaging
command.
The workflow owns draft creation, tag/version validation, asset upload, and
publishing. The caller owns packaging and smoke-test behavior through scripts,
and can opt out of publishing to leave a draft release.

```yaml
jobs:
  release:
    uses: cgraf78/actions/.github/workflows/rust-release.yml@FULL_COMMIT_SHA
    with:
      android-aarch64: true
      version-command: scripts/cargo-version.sh
      package-command: scripts/package-release.sh "$RUST_TARGET" "$ASSET_PLATFORM"
      smoke-command: scripts/smoke-release.sh "$ASSET_PLATFORM"
```

Callers with non-Cargo release identity can provide `tag-command` to print the
exact expected Git tag. The release matrix exposes Rust compiler triples through
`RUST_TARGET` and installer-facing archive labels through `ASSET_PLATFORM`; use
the latter for public asset names.

## Release scripts

The workflow owns release mechanics; the scripts it invokes are shared
separately. [`release-scripts/`](release-scripts/README.md) holds the single
implementation of release identity, packaging, and smoke validation that the
`cgraf78` Rust repos vendor into their own `scripts/` directory, so each repo
declares only its payload in `scripts/release.conf`. The
`verify-release-scripts` action keeps those vendored copies from drifting.

## Layout

The public workflows delegate to internal workers, while steps shared by more
than one worker are split into first-party composite actions:

- `.github/workflows/shell-ci.yml` owns shell CI event policy. This is the
  public workflow shell-tool repos call.
- `.github/workflows/bash32-ci.yml` owns the opt-in macOS system Bash smoke
  contract for installer/bootstrap scripts that still support Bash 3.2.
- `.github/workflows/_shell-platforms.yml` is the internal shell worker. GitHub
  requires reusable workflows to live under `.github/workflows`, so this cannot
  live beside the composite actions under `.github/actions`. It also owns
  Checkrun's one-use Mise, Python, and Rust test bootstrap.
- `.github/workflows/rust-ci.yml` owns Rust CI event policy. This is the public
  workflow Rust repos call.
- `.github/workflows/termux-ci.yml` owns the public real Android/Termux caller
  contract.
- `.github/workflows/_termux-ci.yml` is the internal worker that owns emulator
  provisioning, sandbox transport, and runtime execution.
- `.github/workflows/_rust-platforms.yml` is the internal Rust worker that runs
  cargo tests across the shared OS matrix.
- `.github/workflows/rust-release.yml` owns standard Rust binary release
  mechanics: draft creation, the release asset matrix, uploads, and publishing.
- `.github/actions/platform-matrix/` owns the shared OS matrix. Shell CI uses it
  today; Rust CI uses it too; future C++ or other language-specific reusable
  workflows should consume the same action instead of copying platform JSON.
- `.github/actions/rust-ci-prereqs/` owns Rust-CI pre-checkout OS package
  installation for cargo builds on each platform.
- `.github/actions/musl-build-prereqs/` owns the musl linker toolchain install
  shared by Rust CI package smoke and Rust release packaging.
- `.github/actions/shell-ci-prereqs/` owns shell-CI pre-checkout OS package
  installation. It is split into profile packages, checkrun prereqs, and the
  exact dotfiles bootstrap package list.
- `.github/actions/shellcheck-inventory/` validates each caller's reviewed
  program/fixture inventory and runs ShellCheck without guessing which fixture
  fragments are standalone programs.
- `.github/actions/dotfiles-bootstrap/` owns `dot update`, `mise install`, and
  `dot doctor`.
- `.github/actions/verify-release-scripts/` fails a consumer whose vendored
  release scripts no longer match `release-scripts/`.
- `release-scripts/` owns the shared release identity, packaging, and smoke
  logic. It sits outside `.github/` because consumers vendor it into their own
  repositories rather than calling it as an action.

Callers pin reusable workflows to reviewed commit SHAs and use dependency PRs to
roll shared fixes across the fleet. Internal workflows likewise pin first-party
composite actions to reviewed commits so every workflow dependency is explicit
and reproducible.

## License

MIT
