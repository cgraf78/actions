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
