# Reusable Required CI Gates

## Goal

Give every reusable CI family one stable required-check context so shared
platform changes do not require branch-protection edits across every caller.
Keep matrix membership, aggregation semantics, and their tests in
`cgraf78/actions`; callers should only select a reusable workflow and pin its
reviewed commit.

## Scope

This rollout covers the public `shell-ci.yml`, `rust-ci.yml`, and
`termux-ci.yml` workflows and these callers:

- dotfiles
- agentguard
- checkrun
- cmdblocks
- ds
- git-tools
- hive-memory
- sley
- termnav
- tmux-tools
- grafhome-ca

Release workflows, Bash 3.2 CI, repository-specific test jobs, and unrelated
workflow cleanup are out of scope.

## Shared Gate Contract

Each public reusable CI workflow will expose a job named `Required`. GitHub
will render it beneath the caller job, producing stable contexts such as
`shell / Required`, `rust / Required`, and `termux / Required`.

The gate job must use `if: always()` so it reaches a terminal result even when
an upstream job fails or is skipped. It must fail closed unless every mandatory
dependency has an accepted result.

### Shell

`shell-ci.yml` will add `Required`, depending on `Platforms`.

- accepted: `Platforms` is `success`
- rejected: `failure`, `cancelled`, `skipped`, or any unexpected result

The internal selector and every expanded matrix job are already contained by
the `Platforms` reusable-workflow call, so its result is the family boundary.

### Termux

`termux-ci.yml` will add `Required`, depending on `Runtime`.

- accepted: `Runtime` is `success`
- rejected: `failure`, `cancelled`, `skipped`, or any unexpected result

### Rust

`rust-ci.yml` will add `Required`, depending on:

- `Platforms`
- `Quality / Ubuntu`
- `Package / Android aarch64`
- `Termux runtime`

`Platforms` and `Quality / Ubuntu` are mandatory and must succeed.

The Android package and Termux jobs are input-controlled. When enabled, each
must succeed. When its enabling input is empty, the corresponding job is
expected to be skipped and the gate accepts that skipped result. A failure,
cancellation, or unexpected skip while enabled fails the gate.

This makes Android packaging and real Android/Termux runtime required for Hive
Memory and Grafhome CA, which enable both paths, while keeping the public Rust
workflow usable by repositories that do not.

## Matrix Contract

The shared `platform-matrix` action remains the only source of platform
membership. Actions-repository CI will exercise its `core` and `full` outputs
and assert their exact ordered platform names:

- core: macOS, CentOS Stream, Arch, Debian, Ubuntu
- full: core plus WSL, Fedora, Alpine

It will also verify that an unsupported matrix set fails. This contract test
replaces platform-name enumeration in branch protection without allowing the
matrix to shrink silently.

## Caller Pin Rollout

After the actions PR is green and merged, every scoped caller will update all
references to the three affected public CI workflows to the same immutable
landed actions commit. Existing workflow inputs, caller job names, commands,
profiles, setup, secrets, permissions, schedules, and repository-specific jobs
remain unchanged.

Each repository gets its own branch and PR. Callers must not implement local
aggregate jobs.

## Branch Protection

All required checks remain strict and bound to the GitHub Actions app.

- dotfiles: `shell / Required`, `termux / Required`
- checkrun: `shell / Required`, `shellcheck / Required`
- Hive Memory: `shell / Required`, `rust / Required`, Cloud sync simulation,
  Performance budget
- Grafhome CA: `shell / Required`, `rust / Required`, Step CA Integration /
  Ubuntu
- all other scoped callers: `shell / Required`

The Rust gate subsumes the previously required Rust platform and quality
contexts. In Hive Memory and Grafhome CA it also makes the enabled Android
package and Termux runtime checks mandatory. Existing bespoke required checks
listed above are preserved; informational repository-specific jobs remain
informational.

Protection changes occur only after the new gate has completed successfully on
the corresponding caller PR. Old matrix contexts are removed in the same
atomic protection update so stale names cannot block future merges.

## Failure Behavior

The gate step will print every dependency result before deciding. A failed gate
therefore identifies which family component failed without hiding the original
job logs.

No retry logic belongs in the gate. Infrastructure failures remain visible and
may be rerun only after their logs establish that they are transient.

## Validation

The actions repository will run:

- `actionlint` across workflows
- `zizmor --offline` across workflows
- `shellcheck` for changed shell helpers
- the matrix contract test
- caller-shaped smoke invocations that expose the new gate contexts

Each caller will run its closest local workflow and repository validations,
followed by its full GitHub check set. A PR is merged only after every check on
its exact head commit is green.

The final portfolio audit will verify:

- every scoped caller pins the same landed actions commit
- every required gate exists and passed on `main`
- protection is strict
- required contexts exactly match this design
- every required context is bound to the GitHub Actions app
- Android and Termux are covered by `rust / Required` where enabled
- primary checkouts are synchronized and clean
- completed feature worktrees and branches are removed
