# actions

Reusable GitHub Actions workflows and action helpers for `cgraf78` repos.

## Workflows

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
      test-command: cargo test
```

Repos with stricter policies can override the quality-gate commands, or pass an
empty string to disable a command. Repos that need generated files, extra
tooling, or a nested crate path can use `setup-command` and
`working-directory` without forking the shared workflow.

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
