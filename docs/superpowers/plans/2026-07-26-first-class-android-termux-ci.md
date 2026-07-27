# First-Class Android/Termux CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make real Android/Termux CI mandatory inside the Shell and Rust family gates for actions and all 12 consumer repositories.

**Architecture:** Keep `_termux-ci.yml` as the only emulator/runtime worker. Shell CI always composes it, centrally maps existing prerequisite profiles to Termux packages, and reuses `test-command` unless a caller supplies a focused override. Rust CI unconditionally requires caller-owned Android package and Termux runtime commands.

**Tech Stack:** GitHub reusable workflows, Bash, Termux package manager, Android Emulator, Rust Android NDK targets, actionlint, zizmor, GitHub branch protection.

## Global Constraints

- Android/Termux is mandatory; no caller may disable or allow-failure its job.
- Shell coverage is enforced only through `shell / Required`.
- Rust Android package and Termux coverage is enforced only through `rust / Required`.
- `_termux-ci.yml` remains the single owner of emulator, transfer, and sandbox mechanics.
- Existing `profiles` are the authoritative capability vocabulary for ordinary Shell prerequisites.
- Shell reuses `test-command` by default; `termux-command` is only an Android-specific override.
- All callers pin one full 40-character landed actions commit.
- Strict branch protection uses GitHub Actions `app_id: 15368`.
- Existing independent required checks remain protected.
- Work happens in isolated worktrees based on the latest `origin/main`.

---

### Task 1: Make Shell and Rust Termux coverage mandatory

**Files:**

- Modify: `.github/workflows/shell-ci.yml`
- Modify: `.github/workflows/rust-ci.yml`
- Modify: `.github/workflows/_termux-ci.yml`
- Modify: `test/workflow-contract-test`

**Interfaces:**

- Consumes: existing `profiles`, `setup`, `test-command`, Rust Android commands, and `termux-ci.yml`.

- Produces: mandatory `shell / Required` and `rust / Required` results that include Android/Termux.

- [ ] **Step 1: Add failing Shell contract assertions**

Extend `test/workflow-contract-test` to require:

```bash
assert_contains .github/workflows/shell-ci.yml 'termux-command:'
assert_contains .github/workflows/shell-ci.yml 'termux-host-command:'
assert_contains .github/workflows/shell-ci.yml 'needs: [platforms, termux]'
assert_contains .github/workflows/shell-ci.yml \
  'test "$TERMUX_RESULT" = success'
assert_not_contains .github/workflows/shell-ci.yml \
  "if: inputs.termux-command != ''"
```

Add Rust assertions requiring `android-package-smoke-command` and
`termux-command` to declare `required: true`, and rejecting conditional job
guards based on empty command inputs.

- [ ] **Step 2: Run the contract test and verify failure**

Run:

```bash
test/workflow-contract-test
```

Expected: nonzero status identifying the missing mandatory Shell Termux job
and optional Rust inputs.

- [ ] **Step 3: Add mandatory Shell Termux composition**

Add optional override inputs to `shell-ci.yml`:

```yaml
termux-command:
  description: Optional Android-specific override; test-command is used when empty.
  required: false
  type: string
  default: ""
termux-host-command:
  description: Optional host preparation command for Termux artifacts.
  required: false
  type: string
  default: ""
```

Add a `termux` job that always calls `termux-ci.yml`. Pass an effective command
equivalent to:

```yaml
command: ${{ inputs.termux-command != '' && inputs.termux-command || inputs.test-command }}
host-command: ${{ inputs.termux-host-command }}
profiles: ${{ inputs.profiles }}
setup: ${{ inputs.setup }}
```

Change `shell / Required` to need both jobs and require both results to equal
`success`.

- [ ] **Step 4: Centralize Termux prerequisites**

Add `profiles` and `setup` inputs through `termux-ci.yml` into
`_termux-ci.yml`. In the generated Termux runner, install one deduplicated
package list from capability profiles:

```bash
packages=(bash git curl)
has_profile jq && packages+=(jq)
has_profile python && packages+=(python)
has_profile zsh && packages+=(zsh)
has_profile lua && packages+=(lua54)
has_profile neovim && packages+=(neovim)
has_profile tmux && packages+=(tmux)
has_profile openssh-netcat-lsof && packages+=(openssh netcat-openbsd lsof)
has_profile procps && packages+=(procps)
has_profile shellcheck && packages+=(shellcheck)
pkg install -y "${packages[@]}"
```

Use the same comma-delimited exact-match logic as the conventional profile
installer. Named `dotfiles` and `checkrun` setup modes receive only the base
packages; their caller overrides own product-specific preparation.

- [ ] **Step 5: Make Rust Android and Termux unconditional**

In `rust-ci.yml`:

- mark `android-package-smoke-command` and `termux-command` required;

- remove their empty defaults;

- remove job-level empty-input conditions;

- simplify `rust / Required` to unconditionally test Platforms, Quality,
  Android package, and Termux results for `success`.

- [ ] **Step 6: Run focused validation**

Run:

```bash
test/workflow-contract-test
test/shell-ci-prereqs-test
actionlint .github/workflows/*.yml
zizmor --offline .github/workflows/*.yml
git diff --check
```

Expected: all commands pass.

- [ ] **Step 7: Commit the mandatory shared contract**

Commit the workflows and contract tests with title:

```text
Require Android/Termux in CI families
```

The commit body records the focused contract, prerequisite, actionlint, and
zizmor results.

---

### Task 2: Dogfood both mandatory family paths

**Files:**

- Modify: `.github/workflows/ci.yml`
- Modify: `test/fixtures/rust-smoke/src/lib.rs`
- Modify: `test/workflow-contract-test`
- Modify: `docs/workflow-api.md`
- Modify: `.github/workflows/README.md`

**Interfaces:**

- Consumes: mandatory Shell and Rust workflow inputs from Task 1.

- Produces: actions CI that proves both family-level real-Termux paths and the Android package path.

- [ ] **Step 1: Add failing dogfood assertions**

Require `shell-smoke` to provide a Termux command, `rust-smoke` to provide
Android package, Termux host, and Termux runtime commands, and reject the old
top-level `termux-runtime` job.

- [ ] **Step 2: Run the contract test and verify failure**

Run `test/workflow-contract-test`.

Expected: failure naming missing dogfood inputs and the obsolete standalone
job.

- [ ] **Step 3: Route Shell smoke through its family**

Give `shell-smoke` an override that checks:

```bash
test "$(uname -o)" = Android
test "$PREFIX" = /data/data/com.termux/files/usr
test -x "$PREFIX/bin/bash"
test -f .github/workflows/shell-ci.yml
```

Remove the standalone `termux-runtime` top-level job.

- [ ] **Step 4: Route Rust smoke through its family**

Give `rust-smoke`:

- an aarch64 Android package command that cross-builds the fixture and checks
  ELF machine plus `/system/bin/linker64`;
- a host command that builds the fixture for `x86_64-linux-android` into
  `.termux-ci/`;
- a Termux command that executes the fixture and checks its stable output.

Keep the fixture minimal and deterministic.

- [ ] **Step 5: Update public documentation**

Document:

- Shell always runs Termux and defaults to `test-command`;

- Rust Android package and Termux inputs are mandatory;

- family gates accept no skipped Android/Termux state;

- callers should use existing profiles and add overrides only when platform
  behavior genuinely differs;

- branch protection requires family gates, not `termux / Required`.

- [ ] **Step 6: Run the full actions validation**

Run:

```bash
test/workflow-contract-test
test/shell-ci-prereqs-test
test/dotfiles-public-deps-test
actionlint .github/workflows/*.yml
zizmor --offline .github/workflows/*.yml
shellcheck -x -P .github/actions/shell-ci-prereqs \
  .github/actions/shell-ci-prereqs/*.sh \
  test/dotfiles-public-deps-test \
  test/shell-ci-prereqs-test
git diff --check
```

Expected: all commands pass.

- [ ] **Step 7: Commit dogfooding and documentation**

Commit with title:

```text
Dogfood first-class Android/Termux CI
```

---

### Task 3: Land the shared actions revision

**Files:**

- Review all actions branch changes.

**Interfaces:**

- Consumes: Tasks 1 and 2.

- Produces: one immutable green actions commit for all consumers.

- [ ] **Step 1: Perform the required fresh-eyes review**

Review the final diff for mandatory semantics, input propagation, profile
matching, shell quoting, docs drift, and unrelated changes. Fix findings and
rerun affected tests.

- [ ] **Step 2: Push and open the actions pull request**

Push explicitly:

```bash
git push origin HEAD:refs/heads/ci/first-class-termux
```

Verify the remote head equals local `HEAD`, then create a PR whose description
states that Android/Termux is mandatory and family-owned.

- [ ] **Step 3: Require complete actions CI**

Before merge, verify:

- `Shell smoke / Required` succeeds after its real Termux child;

- `Rust smoke / Required` succeeds;

- Rust Android aarch64 and real Termux jobs succeed;

- all conventional matrices, quality, contract, and audit checks succeed.

- [ ] **Step 4: Squash-merge the exact reviewed head**

Revalidate the PR base, head OID, mergeability, and every check. Squash-merge
with the exact head match and record the landed commit SHA.

---

### Task 4: Migrate all Shell consumers

**Files:**

- Modify: `dotfiles/.github/workflows/test.yml`
- Modify: `agentguard/.github/workflows/test.yml`
- Modify: `checkrun/.github/workflows/test.yml`
- Modify: `cmdblocks/.github/workflows/test.yml`
- Modify: `ds/.github/workflows/ci.yml`
- Modify: `git-tools/.github/workflows/test.yml`
- Modify: `hive-memory/.github/workflows/ci.yml`
- Modify: `sley/.github/workflows/test.yml`
- Modify: `termnav/.github/workflows/test.yml`
- Modify: `tmux-tools/.github/workflows/test.yml`
- Modify: `grafhome-ca/.github/workflows/ci.yml`
- Modify: `shdeps/.github/workflows/test.yml`
- Move: `dotfiles/docs/superpowers/plans/2026-07-26-full-pr-platform-matrix.md` to `dotfiles/.local/share/doc/dot/superpowers/plans/2026-07-26-full-pr-platform-matrix.md`
- Move: `dotfiles/docs/superpowers/plans/2026-07-26-termux-ci.md` to `dotfiles/.local/share/doc/dot/superpowers/plans/2026-07-26-termux-ci.md`
- Move: `dotfiles/docs/superpowers/specs/2026-07-26-full-pr-platform-matrix-design.md` to `dotfiles/.local/share/doc/dot/superpowers/specs/2026-07-26-full-pr-platform-matrix-design.md`
- Move: `dotfiles/docs/superpowers/specs/2026-07-26-termux-ci-design.md` to `dotfiles/.local/share/doc/dot/superpowers/specs/2026-07-26-termux-ci-design.md`
- Create only when needed: focused repository-owned `test/termux-test` or
  `tests/shell/termux-test` entry points.

**Interfaces:**

- Consumes: landed actions SHA from Task 3.

- Produces: mandatory real-Termux Shell coverage in every consumer.

- [ ] **Step 1: Create one fresh worktree per consumer**

Fetch each repository and create `ci/first-class-termux` from its latest
`origin/main`. Preserve unrelated worktrees and changes.

- [ ] **Step 2: Pin every test workflow to the landed actions SHA**

Update all Shell, Rust, Termux, and Bash 3.2 calls in the affected test workflow
to the same landed 40-character SHA. Do not update release workflows in these
CI-only PRs.

- [ ] **Step 3: Fold dotfiles Termux into Shell**

Remove the top-level `termux` job. Pass its existing Android smoke command as
`shell.with.termux-command`:

```bash
pkg install -y git
bash .local/lib/dot/tests/android-ci-smoke
```

- [ ] **Step 4: Move dotfiles Superpowers documents under dot documentation**

Use `git mv` for the four tracked July 26 dotfiles design and plan documents,
moving them from `docs/superpowers/{plans,specs}` into
`.local/share/doc/dot/superpowers/{plans,specs}`. Search code, docs, tests,
configuration, CI, and hooks for old paths and update any references. Preserve
the existing filenames and history.

- [ ] **Step 5: Use shared profile defaults for portable repositories**

Let `agentguard`, `cmdblocks`, `ds`, `git-tools`, `sley`, `termnav`, and
`tmux-tools` reuse their existing `test-command` in Termux. Add an override
only when CI demonstrates a genuine Android-specific incompatibility; keep
that override in a focused repository-owned test entry point.

- [ ] **Step 6: Give checkrun meaningful Termux coverage**

Because its named Mise setup is not portable to Termux, add a focused Termux
entry point that exercises the sourceable API, ShellCheck inventory, workflow
lint routing, and configuration discovery using Termux-packaged tools. Pass
that entry point as `termux-command` while leaving conventional matrix commands
unchanged.

- [ ] **Step 7: Run local consumer validation**

Run every repository's previously established CI-equivalent suite, plus
actionlint and `git diff --check`. For mixed Rust repositories, run
`cargo test --locked` and their shell suites. For dotfiles, run the complete
`dot-test`.

- [ ] **Step 8: Review and publish separate consumer PRs**

Confirm each diff contains only the workflow pin, necessary Termux wiring, and
any narrowly required compatibility test. Commit and push each repository
separately, verify remote heads, and open one PR per repository.

---

### Task 5: Require and land every consumer

**Files:**

- GitHub PR checks and branch-protection configuration.

**Interfaces:**

- Consumes: consumer PRs from Task 4.

- Produces: landed first-class Android/Termux support and stable protection.

- [ ] **Step 1: Verify every Shell PR**

Each PR must show:

- a successful real `shell / Termux / Runtime / Android / Termux x86_64` job;

- successful conventional Shell platforms;

- successful `shell / Required`;

- all independent repository checks successful.

- [ ] **Step 2: Verify every Rust PR**

For Hive Memory, Grafhome CA, and shdeps, additionally require:

- `rust / Package / Android aarch64` success;
- `rust / Termux runtime / Runtime / Android / Termux x86_64` success;
- `rust / Required` success.

No Android or Termux job may be skipped.

- [ ] **Step 3: Diagnose failures before changing code**

Use job logs to distinguish product incompatibility from emulator, network,
container-registry, or runner failures. Rerun only failures with concrete
infrastructure evidence. Implement compatibility fixes in the owning consumer
PR and rerun local verification for product failures.

- [ ] **Step 4: Land PRs independently when green**

For each repository, revalidate open state, exact head, `main` base,
mergeability, and all checks. Squash-merge the exact reviewed head.

- [ ] **Step 5: Apply strict family-level protection**

Preserve the protection sets from the previous rollout except:

- actions requires its Shell and Rust smoke family gates;
- dotfiles removes `termux / Required` and retains `shell / Required`;
- all Shell consumers require `shell / Required`;
- mixed Rust consumers require both `shell / Required` and `rust / Required`;
- independent checks such as ShellCheck, Bash 3.2, cloud simulation,
  performance budget, and Step CA integration remain required.

Set `strict: true` and `app_id: 15368` for every context.

---

### Task 6: Portfolio verification and cleanup

**Files:**

- Current GitHub state and local worktrees.

**Interfaces:**

- Consumes: all merged actions and consumer PRs.

- Produces: evidence that the rollout is complete and reproducible.

- [ ] **Step 1: Audit every current main commit**

For all 13 repositories, query check runs on the exact current `main` SHA.
Require zero pending checks and zero conclusions outside success, skipped, or
neutral. For every consumer, explicitly require successful Shell Termux and
family contexts. For Rust consumers, explicitly require successful Android
package, Rust Termux, and Rust family contexts.

- [ ] **Step 2: Verify immutable caller pins**

Assert every affected test workflow references the one landed actions SHA and
that no old CI pin remains in those files.

- [ ] **Step 3: Verify branch protection**

Read back each protection object and compare exact sorted contexts, strict
mode, and app IDs with the approved family-level sets.

- [ ] **Step 4: Synchronize and clean**

Fetch and fast-forward clean primary checkouts. Before deleting any completed
feature branch, verify its tree equals `origin/main`. Remove only completed
worktrees and branches, confirm remote feature branches are gone, and preserve
all unrelated worktrees.

- [ ] **Step 5: Report final evidence**

Report PR links, the immutable actions SHA, local validation, current-main
check counts, exact protection sets, Android/Termux success, any proven
transient reruns, and cleanup status.
