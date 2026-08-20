# actions

Reusable GitHub Actions workflows and action helpers for `cgraf78` repos.

Public CI workflows expose a stable `Required` job for branch protection.
Require `<caller job> / Required` rather than internal platform jobs so matrix
membership can evolve here without protection changes in every caller. The
detailed result contract is documented in
[`docs/workflow-api.md`](docs/workflow-api.md).

Consumer repositories make one version decision in
`.github/cgraf78-actions.lock`; `consumer-ci/sync.sh` generates the literal
workflow refs GitHub requires and, when configured, refreshes vendored release
scripts and generates either release-backed or checkout-backed installers from
that same commit. See
[`consumer-ci/README.md`](consumer-ci/README.md) for the update and verification
contract.

[`examples/`](examples/) contains tested, copyable Mise refresh, shell CI, Rust
CI/release, infrastructure retry, Dependabot, ShellCheck inventory, and
release-policy templates. The examples are staged as real consumer repositories
in tests and must pass the production synchronizer and verifier.

## Workflows

For the full caller-facing API, see
[`docs/workflow-api.md`](docs/workflow-api.md). The README gives quick-start
examples; the docs file is the source of truth for inputs, secrets, matrix
policy, and command-hook contracts.

### `mise-lock-refresh.yml`

Regenerates one tracked Mise lockfile on a caller-owned weekly schedule, opens
or updates a dedicated pull request, and enables squash auto-merge. The shared
workflow never pushes the default branch directly. It uses a repository-scoped
deploy key for the final PR synchronization so the caller's normal protected
`pull_request` checks attach to the exact commit that auto-merge will land.

```yaml
jobs:
  refresh:
    permissions:
      contents: write
      pull-requests: write
    uses: cgraf78/actions/.github/workflows/mise-lock-refresh.yml@FULL_COMMIT_SHA
    with:
      project_name: Example
      mise_config_file: .github/mise/example.toml
      mise_lock_file: .github/mise/mise.lock
    secrets:
      deploy_key: ${{ secrets.MISE_REFRESH_DEPLOY_KEY }}
```

The caller owns the `schedule` and `workflow_dispatch` triggers. Configure the
deploy key with write access to only that repository, enable auto-merge, and
require the ordinary CI contexts on the default branch. An optional
`verify_command` can run repository-specific lock validation before any write
permission is available.

### `shell-ci.yml`

Runs shell-tool test suites across the shared platform matrix. Push and pull
request runs cover the high-signal subset; scheduled and manual runs cover the
full matrix.

Callers should pin a reviewed full commit SHA so an unchanged caller commit
always executes the same workflow code. Enable weekly GitHub Actions Dependabot
updates in the caller repository so shared fixes arrive as ordinary dependency
PRs and run through the caller's CI before merge. `FULL_COMMIT_SHA` is a drafting
placeholder in the examples below. Before committing a consumer change, run
`consumer-ci/sync.sh` from the reviewed `actions` checkout; it writes the one
lock value and substitutes every runtime placeholder or older ref together.

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
`dotfiles-provider: true` separately opts the owning repository into its full
configured Dot dependency provider. The default is false so repositories that
reuse dotfiles setup install only their declared CI profiles. Full-provider
mode uses the caller's read token for public GitHub release metadata; an
explicit dependency token still takes precedence for private repositories.
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
running formatting, Clippy, and docs redundantly on every OS. By default,
every event also performs the shared RustSec audit; its result flows through the
same `Required` aggregate rather than creating another branch-protection
context. Callers can disable it with an empty `audit-command`.

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

The docs default checks missing public documentation and, like the other Cargo
defaults, uses the committed lockfile. Repos with genuinely different policies
can override quality-gate commands or pass an empty string to disable one.
Repos with a declared MSRV can set `msrv-toolchain`; the shared quality gate
runs the locked all-targets/all-features check last so it cannot change the
compiler used by the stable checks. Repos that need generated files, extra
tooling, or a nested crate path can use `setup-command` and
`working-directory` without forking the shared workflow. Binary repos can use
`build-command`, `package-smoke-musl-target`, and `package-smoke-command` to
validate release artifacts while keeping package layout and smoke assertions in
the product repository. Native-code crates can additionally opt into
`package-smoke-install-musl-tools`; pure-Rust crates should not pay for that
host package. `package-smoke-setup-command` remains available for unrelated
product prerequisites. `termux-command` overrides the mandatory Shell
Android runtime command when needed. Shell callers can use `termux-profiles` to
override Android prerequisites without changing conventional platforms. Start
with `base` when tests need Git or curl, or `runtime` for lightweight commands
that only need Bash and `termux-exec`, then add capability profiles such as
`shellcheck`. Rust callers can pair it with `termux-host-command` to cross-build
an x86_64 Android artifact on Ubuntu and then execute that artifact under
Android/Bionic in Termux. This complements the release's exact-architecture
AArch64 cross-build rather than replacing it.

### `termux-ci.yml`

Runs a caller-owned Bash command with `errexit`, `nounset`, and `pipefail` inside
the official Termux application sandbox on a hardware-accelerated Android x86_64
emulator. The caller checkout is copied into `$HOME/project`, with Termux's real
`HOME`, `PREFIX`, `TMPDIR`, and `PATH`.

With `setup: dotfiles`, the worker stages the standalone Dot revision named by
the caller's cutover lock, transports that exact payload into the sandbox, and
installs it with Termux's trusted Bash before any caller command runs. The
bootstrap still adopts the client and converges its repositories, overlays,
and extensions, but skips the client dependency provider for that invocation
because the workflow has already installed its explicit prerequisite profiles.
The committed provider setting is unchanged and applies to later ordinary Dot
runs.

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
declares only its payload in `scripts/release.conf`. The broader
`verify-consumer-sync` action checks the repository lock, every literal
`cgraf78/actions` ref, the complete managed set of vendored scripts, and any
installer opted in through that release policy. The generated installer itself
is owned by [`release-installer/`](release-installer/README.md).

## Checkout bootstrap installer

Source-distributed repositories keep their command and supporting files in one
version-coupled checkout. [`checkout-installer/`](checkout-installer/README.md)
generates a small top-level bootstrap that delegates directly when run from a
checkout and creates a durable shallow clone when downloaded or piped. It uses
no release workflow or release assets; repository-specific link publication
stays in the consumer's `support/install-checkout.sh`.

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
- `.github/actions/package-manager/` owns the bounded package transport,
  supervision, and retry policy shared by Rust, musl, and shell prerequisites.
- `.github/actions/shell-ci-prereqs/` owns shell-CI pre-checkout OS package
  installation. It is split into profile packages, checkrun prereqs, and the
  exact dotfiles bootstrap package list.
- `.github/actions/shellcheck-inventory/` validates each caller's reviewed
  program/fixture inventory and runs ShellCheck without guessing which fixture
  fragments are standalone programs.
- `.github/actions/dotfiles-bootstrap/` owns Dot bootstrap, locked Mise tools,
  full-provider doctor checks, and cutover-locked payload staging and sandbox
  installation.
- `.github/actions/verify-release-scripts/` fails a consumer whose vendored
  release scripts no longer match `release-scripts/`.
- `.github/actions/verify-consumer-sync/` enforces one consumer lock across all
  workflow/action refs, release tooling, and any generated release or checkout
  installer.
- `consumer-ci/` owns the maintainer command that regenerates a consumer from
  one clean, reviewed `actions` checkout.
- `checkout-installer/` owns the self-contained bootstrap template and renderer
  for repositories that install from durable source checkouts.
- `release-scripts/` owns the shared release identity, packaging, and smoke
  logic. It sits outside `.github/` because consumers vendor it into their own
  repositories rather than calling it as an action.
- `release-installer/` owns the template and renderer for the optional,
  self-contained top-level installer. Consumers commit the generated file so
  direct downloads never depend on this repository at runtime.

Callers pin reusable workflows to reviewed commit SHAs and use dependency PRs
to roll shared fixes across the fleet. Consumer lock verification prevents a
partial bump from mixing revisions. This repository uses the same lock and
synchronizer for its internal self-pins. Because a commit cannot contain its
own hash, the lock names the immediately preceding reviewed implementation
commit and a follow-up commit contains only the synchronized refs. Before
squash-merging, retain that implementation and verify its remote identity:

```bash
consumer-ci/retain-self-pin.sh
consumer-ci/verify-self-pin.sh
```

The deterministic lightweight tag is
`self-pin/<implementation-sha>`. Non-force tooling refuses to
move it, and the repository tag ruleset for `self-pin/**` must
block updates and deletion. This makes squash-only history safe without a
follow-up self-pin repair PR.

## License

MIT
