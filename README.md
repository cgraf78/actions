# actions

Reusable GitHub Actions workflows and action helpers for `cgraf78` repos.

## Workflows

### `portable-shell-ci.yml`

Runs shell-tool test suites across a shared portability matrix. Push and pull
request runs cover the high-signal subset; scheduled and manual runs cover the
full matrix.

Callers should reference `main` so shared CI fixes roll out immediately:

```yaml
jobs:
  test:
    uses: cgraf78/actions/.github/workflows/portable-shell-ci.yml@main
    with:
      profiles: base,jq,python
      test-command: test/example-test
```

## Layout

The reusable workflow is intentionally small orchestration glue. The longer
bootstrap logic lives in helper scripts next to the workflow:

- `.github/workflows/portable-shell-ci.yml` owns the shared matrix, checkout,
  caches, setup mode selection, and final test command.
- `.github/actions/portable-shell-prereqs/install-prereqs.sh` owns distro package names and
  dependency profiles for normal shell-tool repos. It also contains the exact
  dotfiles bootstrap package list, because dotfiles CI intentionally tests that
  `dot update` and `shdeps` install the real toolchain.
- `.github/actions/checkrun-setup/setup.sh` owns checkrun's mise, Python, and
  Rust test tool bootstrap.
- `.github/actions/dotfiles-setup/` owns dotfiles' private dependency
  deploy-key setup, `dot update`, `mise install`, and `dot doctor` smoke check.

The workflow checks out `cgraf78/actions` into `.shared-actions` and runs those
scripts by path. This keeps caller workflows declarative, avoids a large inline
YAML script, and keeps each setup path readable and testable as a shell script.
