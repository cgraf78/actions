# First-Class Android/Termux CI Design

## Goal

Make Android/Termux a mandatory platform in the shared Shell and Rust CI
families for `cgraf78/actions` and every repository in the current dotfiles
dependency portfolio.

Android/Termux must behave like macOS, WSL, Fedora, Alpine, and the other
supported platforms:

- every applicable pull request and push runs it;
- an absent, skipped, cancelled, or failed job fails the owning family gate;
- branch protection requires the family gate, not a separate Termux category;
- the individual Android and Termux jobs remain visible for diagnosis.

## Scope

The rollout covers 13 repositories:

- shared workflow owner: `actions`;
- Shell consumers: `dotfiles`, `agentguard`, `checkrun`, `cmdblocks`, `ds`,
  `git-tools`, `hive-memory`, `sley`, `termnav`, `tmux-tools`, `grafhome-ca`,
  and `shdeps`;
- Rust consumers: `hive-memory`, `grafhome-ca`, and `shdeps`.

The actions repository dogfoods both the Shell and Rust contracts. Shell
consumers run repository-owned tests in a real Termux application sandbox.
Rust consumers additionally cross-build and validate an Android/Bionic
package.

## Considered Approaches

### Chosen: mandatory family-owned platform jobs

`shell-ci.yml` and `rust-ci.yml` call the existing Termux worker and include
its result in their own `Required` jobs. Required caller inputs make the
platform impossible to omit accidentally.

This keeps branch protection stable, preserves one semantic gate per test
family, and makes unsupported Termux behavior fail in the same way as any
other unsupported platform.

### Rejected: retain a separate Termux family

Keeping `termux / Required` makes an execution mechanism look like a separate
test category. It also duplicates branch-protection configuration and lets a
caller accidentally update its Shell or Rust workflow without updating the
parallel Termux call.

### Rejected: inject Termux into the ordinary OS matrix

The real Termux job uses an Android emulator and application sandbox rather
than a normal GitHub runner or container. Hiding those mechanics inside the
ordinary matrix would complicate the platform worker and erase a useful
implementation boundary. The result belongs to the family gate even though
the worker remains separate.

## Shared Workflow Contract

### Design Boundaries

The implementation follows the portfolio's shared design principles:

- `_termux-ci.yml` is the single authoritative owner of emulator, application
  sandbox, file-transfer, and runtime mechanics;
- public family workflows compose that worker and expose commands describing
  what callers want tested, without making callers reproduce how Termux is
  launched;
- Shell reuses `test-command` by default and stores the fallback decision in
  the family workflow rather than duplicating it across repositories;
- stable job vocabulary (`Platforms`, `Quality`, `Package`, `Termux runtime`,
  and `Required`) remains owned by the shared workflows;
- caller-owned scripts contain only product-specific setup and assertions;
- branch protection consumes family interfaces and never parses or enumerates
  their implementation jobs.

No consumer receives copied emulator setup, Android SDK selection, transfer
logic, or aggregate-gate logic.

### Shell CI

`shell-ci.yml` gains:

- optional `termux-command` override, defaulting to an empty command;
- optional `termux-host-command`, defaulting to an empty command;
- a `Termux` reusable-workflow job calling `termux-ci.yml`.

The Termux job always runs. Its effective command is `termux-command` when the
caller supplies an override and `test-command` otherwise. An empty override
therefore does not disable coverage; it selects the common command and keeps
portable repositories free of duplicated configuration.

`shell / Required` needs both `Platforms` and `Termux` and requires both
results to equal `success`. There is no accepted skipped state.

The normal `test-command` remains the command for conventional platforms.
Callers add a Termux override only when prerequisites or test selection differ
on Android. Platform-specific behavior remains a product contract, but the
shared interface avoids forcing callers to restate an identical command.

### Rust CI

The existing Android and Termux inputs become mandatory:

- required `android-package-smoke-command`;
- required `termux-command`;
- optional `termux-host-command`.

The Android package and Termux jobs lose their input-controlled job
conditions. `rust / Required` unconditionally requires `Platforms`,
`Quality`, `Package / Android aarch64`, and `Termux runtime` to succeed.
There is no accepted skipped state for Android or Termux.

`working-directory` continues to scope all caller commands. The shared Rust
workflow continues to own toolchain installation and Android NDK wiring;
callers continue to own archive layout, binary selection, and runtime
assertions.

### Termux Worker

`termux-ci.yml` and `_termux-ci.yml` remain the single implementation of the
real Android/Termux environment. Shell CI, Rust CI, and direct workflow
dogfooding compose this worker rather than duplicating emulator mechanics.

The public standalone workflow may remain available as a low-level interface,
but consumer branch protection does not require its `Required` context
separately. Its result is consumed by the owning Shell or Rust family.

## Actions Dogfooding

The actions repository exercises both mandatory contracts:

- Shell smoke supplies a Termux command that validates the Android identity,
  Termux prefix, Bash availability, checkout transfer, and representative
  shell execution.
- Rust smoke cross-builds an x86_64 Android fixture for the emulator, runs it
  in Termux, cross-builds an aarch64 Android fixture, and validates the
  Bionic artifact.

These commands flow through `shell-ci.yml` and `rust-ci.yml`; a separate
top-level Termux smoke job is removed once its assertions are represented by
the family dogfood calls.

The actions repository's protection requires the Shell and Rust family smoke
gates so changes to the shared mechanism cannot merge without real Termux
coverage.

## Caller Rollout

Each consumer updates to one immutable actions commit containing the mandatory
contract.

Shell callers:

- remove any standalone top-level `termux-ci.yml` call;
- rely on `test-command` in Termux when the same entry point is portable;
- pass a repository-owned `termux-command` only for a necessary Android
  override;
- optionally pass `termux-host-command` only when checkout artifacts need host
  preparation;
- run meaningful repository tests rather than an environment-only probe.

Rust callers retain or add their Android package and real Termux commands.
Their Rust family gate fails unless both jobs succeed.

The rollout may add narrow Termux compatibility fixes or test entry scripts
inside a consumer repository when its real suite does not yet run on Android.
Those fixes belong in that repository's PR and require its normal local
verification. Tests may skip behavior that is genuinely inapplicable to the
platform, as they already do for other operating systems, but the Termux job
itself may not be optional or skipped.

## Branch Protection

After each new family gate succeeds on a caller pull request, protection is
updated atomically with `strict: true` and GitHub Actions `app_id: 15368`.

- every Shell consumer requires `shell / Required`;
- Rust consumers additionally require `rust / Required`;
- dotfiles no longer requires `termux / Required`;
- existing independent checks such as ShellCheck, Bash 3.2, cloud simulation,
  performance budgets, and Step CA integration remain required;
- Android and Termux implementation contexts are not listed separately because
  their family gate transitively requires them.

## Failure Semantics

Family gates fail closed:

- missing required caller inputs prevent workflow dispatch;
- failed or cancelled Android/Termux jobs fail the family gate;
- unexpectedly skipped Android/Termux jobs fail the family gate;
- emulator or runner infrastructure failures remain visible as platform
  failures and block merging until a successful rerun;
- no repository receives an allow-failure or conditional opt-out.

## Testing

### Actions contract tests

Workflow contract tests assert:

- Shell always runs Termux, falls back to `test-command`, and unconditionally
  gates its result;
- Rust declares required Android and Termux inputs;
- Rust jobs are not conditionally disabled by empty inputs;
- Rust unconditionally gates Android and Termux success;
- actions dogfood calls provide all mandatory inputs;
- the obsolete standalone top-level Termux smoke is absent.

Actionlint and offline workflow auditing validate the resulting YAML.

### Actions integration CI

The actions pull request must pass:

- conventional Shell and Rust matrices;
- Shell real-Termux smoke through `shell / Required`;
- Rust Android aarch64 package smoke;
- Rust real-Termux runtime smoke;
- `rust / Required`;
- existing quality and matrix-contract checks.

### Consumer validation

Every consumer runs its repository-specific local CI-equivalent suite before
publication. Its pull request must show a successful real Termux job and a
successful owning family gate before merge.

After all merges and protection updates, the current `main` commit of all 13
repositories is audited. Completion requires no pending or failing checks and
explicit success for every Android package, Termux runtime, and family gate.

## Landing Order

1. Land and verify the actions contract and dogfood change.
2. Pin each consumer to the landed immutable actions commit and add its real
   Termux command.
3. Land consumer pull requests independently when all required checks pass.
4. Update strict branch protection after the corresponding family contexts
   have succeeded.
5. Re-audit every current `main` commit and clean only completed rollout
   worktrees and branches.
