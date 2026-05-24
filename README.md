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

## Layout

The reusable workflow is intentionally small orchestration glue. The reusable
steps are split into first-party composite actions:

- `.github/workflows/shell-ci.yml` owns shell CI event policy. This is the
  public workflow shell-tool repos call.
- `.github/workflows/_shell-platforms.yml` is the internal shell worker. GitHub
  requires reusable workflows to live under `.github/workflows`, so this cannot
  live beside the composite actions under `.github/actions`.
- `.github/actions/platform-matrix/` owns the shared OS matrix. Shell CI uses it
  today; future Rust, C++, or other language-specific reusable workflows should
  consume the same action instead of copying platform JSON.
- `.github/actions/portable-shell-prereqs/` owns pre-checkout OS package
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
