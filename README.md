# actions

Reusable GitHub Actions workflows and action helpers for `cgraf78` repos.

## Workflows

For the full caller-facing API, see
[`docs/workflow-api.md`](docs/workflow-api.md). The README gives quick-start
examples; the docs file is the source of truth for inputs, secrets, matrix
policy, and command-hook contracts.

### `shell-ci.yml`

Runs shell-tool test suites across the shared platform matrix. Push and pull
request runs cover the high-signal subset; scheduled and manual runs cover the
full matrix.

Callers should reference `main` so shared CI fixes roll out immediately:

```yaml
jobs:
  test:
    uses: cgraf78/actions/.github/workflows/shell-ci.yml@main
    with:
      profiles: base,jq,python
      test-command: test/example-test
```

Optional `matrix-set` can force `core` or `full`; the default `auto` keeps
push/PR runs on `core` and scheduled/manual runs on `full`. Optional
`bash32-command` adds a macOS system Bash 3.2 smoke job for installer/bootstrap
compatibility checks.

### `rust-ci.yml`

Runs Rust test suites across the same shared platform matrix. Push and pull
request runs cover the high-signal subset; scheduled and manual runs cover the
full matrix. A separate Ubuntu quality gate preserves common Rust checks without
running formatting, clippy, and docs redundantly on every OS.

```yaml
jobs:
  test:
    uses: cgraf78/actions/.github/workflows/rust-ci.yml@main
    with:
      test-command: cargo test --locked
```

Repos with stricter policies can override the quality-gate commands, or pass an
empty string to disable a command. Repos that need generated files, extra
tooling, or a nested crate path can use `setup-command` and
`working-directory` without forking the shared workflow. Binary repos can use
`build-command`, `package-smoke-setup-command`, and `package-smoke-command` to
validate release artifacts while keeping package layout and smoke assertions in
the product repository.

### `rust-release.yml`

Builds and publishes Rust binary archives for the standard release platform
set: Linux x86_64 musl, Linux aarch64 musl, macOS x86_64, and macOS aarch64.
The workflow owns draft creation, tag/version validation, asset upload, and
publishing. The caller owns packaging and smoke-test behavior through scripts,
and can opt out of publishing to leave a draft release.

```yaml
jobs:
  release:
    uses: cgraf78/actions/.github/workflows/rust-release.yml@main
    with:
      version-command: scripts/cargo-version.sh
      package-command: scripts/package-release.sh "$RUST_TARGET" "$ASSET_PLATFORM"
      smoke-command: scripts/smoke-release.sh "$ASSET_PLATFORM"
```

Callers with non-Cargo release identity can provide `tag-command` to print the
exact expected Git tag. The release matrix exposes Rust compiler triples through
`RUST_TARGET` and installer-facing archive labels through `ASSET_PLATFORM`; use
the latter for public asset names.

## Layout

The reusable workflow is intentionally small orchestration glue. The reusable
steps are split into first-party composite actions:

- `.github/workflows/shell-ci.yml` owns shell CI event policy. This is the
  public workflow shell-tool repos call.
- `.github/workflows/_shell-platforms.yml` is the internal shell worker. GitHub
  requires reusable workflows to live under `.github/workflows`, so this cannot
  live beside the composite actions under `.github/actions`.
- `.github/workflows/rust-ci.yml` owns Rust CI event policy. This is the public
  workflow Rust repos call.
- `.github/workflows/_rust-platforms.yml` is the internal Rust worker that runs
  cargo tests across the shared OS matrix.
- `.github/workflows/rust-release.yml` owns standard Rust binary release
  mechanics: draft creation, the release asset matrix, uploads, and publishing.
- `.github/actions/platform-matrix/` owns the shared OS matrix. Shell CI uses it
  today; Rust CI uses it too; future C++ or other language-specific reusable
  workflows should consume the same action instead of copying platform JSON.
- `.github/actions/rust-ci-prereqs/` owns Rust-CI pre-checkout OS package
  installation for cargo builds on each platform.
- `.github/actions/shell-ci-prereqs/` owns shell-CI pre-checkout OS package
  installation. It is split into profile packages, checkrun prereqs, and the
  exact dotfiles bootstrap package list.
- `.github/actions/checkrun-dev-tools/` owns checkrun's mise, Python, and Rust
  test tool bootstrap.
- `.github/actions/dotfiles-private-deps/` owns dotfiles' private dependency
  deploy-key setup.
- `.github/actions/dotfiles-bootstrap/` owns `dot update`, `mise install`, and
  `dot doctor`.

Callers reference the workflow at `@main` so shared CI fixes roll out
immediately. The workflow also references these first-party composite actions at
`@main` for the same reason.

## License

MIT
