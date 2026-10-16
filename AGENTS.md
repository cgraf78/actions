# AGENTS.md

## About

Reusable GitHub Actions workflows, composite actions, and vendored script
families for the `cgraf78` repos. Consumers pin one commit through
`.github/cgraf78-actions.lock`, so every change here reaches them only through
`consumer-ci/sync.sh`. [`docs/workflow-api.md`](docs/workflow-api.md) is the
caller contract and the source of truth for inputs and outputs.

## Layout

- Public reusable workflows: `shell-ci`, `rust-ci`, `bash32-ci`, `termux-ci`,
  `rust-release`, `mise-lock-refresh`, `dependabot-automerge`.
- Internal workers, not caller API: `_shell-platforms`, `_rust-platforms`,
  `_termux-ci`.
- This repo's own controllers: `retry-infrastructure`,
  `dependabot-automerge-self`.
- `.github/actions/*`: composite actions used by the workflows.
- Vendored families that consumers copy into their trees:
  `release-scripts/`, `capability-harness/`, `release-installer/`,
  `checkout-installer/`.
- `consumer-ci/`: `sync.sh`, `vendor-scripts.sh`, and the self-pin scripts.
- `examples/`: copyable caller templates. `docs/superpowers/` holds old
  planning notes; don't add to it.

## Invariants

- Every public workflow exposes a stable `Required` job. Callers require
  `<caller job> / Required`, never an internal platform job.
- Third-party `uses:` are pinned to full commit SHAs
  (`test/uses-pin-policy-test`).
- `test/workflow-contract-test` asserts workflow structure; edit it together
  with any workflow change it covers.
- Dependabot ignores `cgraf78/actions`, here and in the examples.
- `retry-infrastructure.yml` keys on the workflow name `Tests`, here and in
  every consumer; don't rename it.

## Testing

CI's Quality job runs these; run the ones your change touches:

- `actionlint .github/workflows/*.yml` (1.7.12) and
  `zizmor --offline .github/workflows/*.yml` (1.29.0).
- Every `test/*-test` named in `.github/workflows/test.yml`.
- `/bin/bash test/release-installer-test`, `test/checkout-installer-test`, and
  `test/release-asset-upload-test`: CI also runs these under macOS stock
  Bash 3.2.
- `./.github/actions/shellcheck-inventory/run.sh "$PWD" .github/shellcheck-files.txt`:
  fails on any shell program missing from the inventory (untracked files
  included) and on stale rows.
- `bash consumer-ci/verify-self-pin.sh` (needs network).

Not run by CI; run them before touching their area:
`test/examples-test` (for `examples/`), `test/self-pin-retention-test`,
`test/release-asset-selection-test`, and `test/checkout-installer-network-test`.

## Self-pin cycle

The workflows call this repo's composite actions at `@<lock>`, so a change
under `.github/actions/**` is exercised only after a second commit:

1. Commit the implementation.
2. Run `consumer-ci/sync.sh --self` and commit only the lock and the
   regenerated refs.
3. Push, then run `consumer-ci/retain-self-pin.sh` and
   `consumer-ci/verify-self-pin.sh` before squash-merging.

`self-pin/<sha>` tags never move. Quality's `verify-consumer-sync` runs at the
lock, not at HEAD. Changes outside `.github/actions/**` don't need the cycle.

## Release

No releases. After merge, roll a change out by running
`consumer-ci/sync.sh <consumer checkout>` from a clean checkout at the
reviewed commit, one PR per consumer.
