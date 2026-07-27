# Reusable Required CI Gates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace duplicated per-platform branch-protection requirements with stable, reusable-family gates owned and tested by `cgraf78/actions`.

**Architecture:** The public shell, Rust, and Termux reusable workflows each add one fail-closed `Required` job. The actions repository dogfoods those workflows and asserts the matrix selector contract; callers only converge their immutable workflow pins, then branch protection switches atomically to the new stable contexts.

**Tech Stack:** GitHub Actions reusable workflows, composite actions, Bash, jq, actionlint, zizmor, shellcheck, GitHub CLI.

## Global Constraints

- Callers must not add local aggregate jobs.
- Every caller must pin the same landed 40-character actions commit.
- Required checks remain strict and bound to GitHub Actions app ID `15368`.
- Shell and Termux mandatory dependencies accept only `success`.
- Rust Platforms and Quality accept only `success`.
- Rust Android package and Termux accept `success` when enabled and `skipped` only when their enabling input is empty.
- Hive Memory and Grafhome CA enable Android package and Termux, so both become mandatory through `rust / Required`.
- Preserve every caller input, command, profile, setup, secret, permission, schedule, and bespoke required check not explicitly replaced by a family gate.
- Land each PR only after every check on its exact head commit is green.

---

### Task 1: Add failing gate and matrix contract checks

**Files:**

- Modify: `.github/workflows/ci.yml`
- Create: `test/workflow-contract-test`

**Interfaces:**

- Consumes: public reusable workflow files and `.github/actions/platform-matrix/action.yml`

- Produces: executable contract test `test/workflow-contract-test`

- [ ] **Step 1: Create a static gate-contract test**

Create `test/workflow-contract-test` as a Bash test that uses `yq -e` to query
YAML structure and fails until:

- `shell-ci.yml` contains a `required` job named `Required`, using
  `if: ${{ always() }}` and `needs: platforms`
- `termux-ci.yml` contains the same contract with `needs: runtime`
- `rust-ci.yml` contains `needs: [platforms, quality, android-package, termux]`
- all three gate jobs print dependency results and reject disallowed results

The test must also ensure no caller-facing gate is added to internal worker
workflows.

- [ ] **Step 2: Run the static test and verify red**

Run: `test/workflow-contract-test`

Expected: nonzero, reporting the missing `Required` jobs.

- [ ] **Step 3: Add matrix action contract steps to actions CI**

Add a `matrix-contract` job to `.github/workflows/ci.yml` that checks out the
repository and invokes the local `platform-matrix` action three times:

```yaml
  matrix-contract:
    name: Matrix contract
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd
        with:
          persist-credentials: false
      - id: core
        uses: ./.github/actions/platform-matrix
        with:
          matrix-set: core
      - id: full
        uses: ./.github/actions/platform-matrix
        with:
          matrix-set: full
      - id: invalid
        continue-on-error: true
        uses: ./.github/actions/platform-matrix
        with:
          matrix-set: unsupported
```

Add a Bash assertion step that uses jq to compare exact ordered names:

```bash
test "$(jq -c '[.include[].name]' <<<"$CORE_MATRIX")" = \
  '["macOS","CentOS Stream","Arch","Debian","Ubuntu"]'
test "$(jq -c '[.include[].name]' <<<"$FULL_MATRIX")" = \
  '["macOS","CentOS Stream","Arch","Debian","Ubuntu","WSL","Fedora","Alpine"]'
test "$INVALID_OUTCOME" = failure
```

- [ ] **Step 4: Wire the static contract test into Quality**

Add a `Check workflow contracts` step to the existing `Quality / Ubuntu` job:

```yaml
      - name: Check workflow contracts
        shell: bash
        run: test/workflow-contract-test
```

- [ ] **Step 5: Validate the red test remains focused**

Run: `test/workflow-contract-test`

Expected: still fails only because the three gates are missing.

### Task 2: Implement reusable gates

**Files:**

- Modify: `.github/workflows/shell-ci.yml`
- Modify: `.github/workflows/rust-ci.yml`
- Modify: `.github/workflows/termux-ci.yml`
- Test: `test/workflow-contract-test`

**Interfaces:**

- Produces: caller contexts `<caller job> / Required`

- [ ] **Step 1: Add the Shell `Required` job**

Append:

```yaml
  required:
    name: Required
    if: ${{ always() }}
    needs: platforms
    runs-on: ubuntu-24.04
    env:
      PLATFORMS_RESULT: ${{ needs.platforms.result }}
    steps:
      - name: Require successful shell platforms
        shell: bash
        run: |
          printf 'Platforms: %s\n' "$PLATFORMS_RESULT"
          test "$PLATFORMS_RESULT" = success
```

- [ ] **Step 2: Add the Termux `Required` job**

Use the same pattern with `needs: runtime`, `RUNTIME_RESULT`, and an exact
`success` assertion.

- [ ] **Step 3: Add the Rust `Required` job**

Depend on `[platforms, quality, android-package, termux]`. Export all four
results plus the two enabling inputs. The Bash step must:

```bash
test "$PLATFORMS_RESULT" = success
test "$QUALITY_RESULT" = success

if [[ -n "$ANDROID_PACKAGE_COMMAND" ]]; then
  test "$ANDROID_PACKAGE_RESULT" = success
else
  test "$ANDROID_PACKAGE_RESULT" = skipped
fi

if [[ -n "$TERMUX_COMMAND" ]]; then
  test "$TERMUX_RESULT" = success
else
  test "$TERMUX_RESULT" = skipped
fi
```

Print all four results before assertions.

- [ ] **Step 4: Run the contract test and verify green**

Run: `test/workflow-contract-test`

Expected: pass.

- [ ] **Step 5: Validate workflow syntax and security**

Run:

```bash
actionlint .github/workflows/*.yml
zizmor --offline .github/workflows/*.yml
shellcheck test/workflow-contract-test
git diff --check
```

Expected: all pass.

### Task 3: Dogfood public gates and document the API

**Files:**

- Modify: `.github/workflows/ci.yml`
- Create: `test/fixtures/rust-smoke/Cargo.toml`
- Create: `test/fixtures/rust-smoke/Cargo.lock`
- Create: `test/fixtures/rust-smoke/src/lib.rs`
- Modify: `README.md`
- Modify: `.github/workflows/README.md`
- Modify: `docs/workflow-api.md`

**Interfaces:**

- Consumes: the new public `Required` jobs

- Produces: actions CI contexts `shell-smoke / Required`,
  `rust-smoke / Required`, and `termux-runtime / Required`

- [ ] **Step 1: Add a minimal Rust fixture**

Create a library crate with no dependencies:

```toml
[package]
name = "actions-rust-smoke"
version = "0.0.0"
edition = "2021"
publish = false

[lib]
path = "src/lib.rs"
```

Commit the generated lockfile so every smoke invocation can use `--locked`.

```rust
pub fn smoke() -> bool {
    true
}

#[cfg(test)]
mod tests {
    #[test]
    fn smoke_passes() {
        assert!(super::smoke());
    }
}
```

- [ ] **Step 2: Add shell and Rust reusable-workflow smoke jobs**

Add to actions CI:

```yaml
  shell-smoke:
    name: Shell smoke
    uses: ./.github/workflows/shell-ci.yml
    with:
      matrix-set: core
      profiles: base
      test-command: test "$MATRIX_NAME" != ""

  rust-smoke:
    name: Rust smoke
    uses: ./.github/workflows/rust-ci.yml
    with:
      matrix-set: core
      working-directory: test/fixtures/rust-smoke
      test-command: cargo test --locked
```

Do not enable optional Android or Termux inputs in this fixture; this validates
that the Rust gate accepts their intentional skips. The existing
`termux-runtime` job validates the standalone Termux gate.

- [ ] **Step 3: Document stable required contexts**

Document:

- gate context is `<caller job> / Required`

- branch protection should require the gate, not internal matrix contexts

- Rust optional jobs are mandatory when enabled

- caller pins must remain immutable SHAs

- [ ] **Step 4: Run full local actions validation**

Run the Task 2 validation commands plus:

```bash
cargo test --locked --manifest-path test/fixtures/rust-smoke/Cargo.toml
```

Expected: all pass.

- [ ] **Step 5: Review, commit, push, and open the actions PR**

Perform the required fresh-eyes review. Commit with the repository commit
format, push explicitly to `origin ci/reusable-required-gates`, verify the
remote OID, and open a PR whose body lists the stable contexts and test
evidence.

- [ ] **Step 6: Green-gate and land actions**

Wait for every actions check, including all three `Required` contexts. Recheck
the exact head/base, squash-merge, fetch `origin/main`, and record the landed
40-character commit for caller pins.

### Task 4: Create caller worktrees and update immutable pins

**Files:**

- Modify: dotfiles `.github/workflows/test.yml`
- Modify: agentguard `.github/workflows/test.yml`
- Modify: checkrun `.github/workflows/test.yml`
- Modify: cmdblocks `.github/workflows/test.yml`
- Modify: ds `.github/workflows/ci.yml`
- Modify: git-tools `.github/workflows/test.yml`
- Modify: hive-memory `.github/workflows/ci.yml`
- Modify: sley `.github/workflows/test.yml`
- Modify: termnav `.github/workflows/test.yml`
- Modify: tmux-tools `.github/workflows/test.yml`
- Modify: grafhome-ca `.github/workflows/ci.yml`

**Interfaces:**

- Consumes: landed actions commit from Task 3

- Produces: identical immutable pins across all affected workflow calls

- [ ] **Step 1: Create one isolated worktree per caller**

Fetch each repository and create branch `ci/reusable-required-gates` from its
latest `origin/main`. For the bare dotfiles repository, follow the dotfiles
worktree playbook and preserve the home work tree.

- [ ] **Step 2: Replace affected workflow SHAs only**

Update every `shell-ci.yml`, `rust-ci.yml`, and `termux-ci.yml` reference in
scope to the landed actions SHA. Do not change inputs or other YAML.

- [ ] **Step 3: Prove pin convergence and narrow diffs**

Run a portfolio script that asserts:

- every affected ref equals the landed SHA

- each diff changes only workflow `uses:` lines

- `matrix-set: full` remains on every shell caller

- Hive and Grafhome retain both Rust Android and Termux inputs

- [ ] **Step 4: Run caller-local validation**

Run `actionlint` and `git diff --check` in every caller, plus the repository
test commands recorded in the preceding full-matrix rollout. For Hive and
Grafhome run locked Cargo tests and shell release tests; for dotfiles run the
dotfiles testing playbook commands.

- [ ] **Step 5: Review and commit each caller**

Perform a portfolio fresh-eyes review, then commit each repository separately
with its own Summary and Testing sections.

### Task 5: Publish and land caller PRs

**Files:** no additional source files

- [ ] **Step 1: Push exact heads and open separate PRs**

Push each branch with:

```bash
git push origin HEAD:refs/heads/ci/reusable-required-gates
```

Verify remote and PR head OIDs before monitoring.

- [ ] **Step 2: Verify new gate semantics on every PR**

Require all PR checks to complete. Explicitly confirm:

- dotfiles: `shell / Required`, `termux / Required`

- checkrun: `shell / Required`, `shellcheck / Required`

- Hive and Grafhome: `shell / Required`, `rust / Required`, with successful
  Android package and Termux runtime children

- other callers: `shell / Required`

- [ ] **Step 3: Land each independently when green**

For each green PR, verify exact head/base and no failing or pending checks,
squash-merge, and delete the remote feature branch.

### Task 6: Replace duplicated branch-protection contexts

**Files:** GitHub branch-protection configuration

- [ ] **Step 1: Read current protection before mutation**

Capture strict mode, checks, and app IDs for all eleven repositories.

- [ ] **Step 2: Update required checks atomically**

Set strict mode true and app ID `15368` for:

- dotfiles: `shell / Required`, `termux / Required`

- checkrun: `shell / Required`, `shellcheck / Required`

- Hive Memory: `shell / Required`, `rust / Required`,
  `Cloud sync simulation`, `Performance budget`

- Grafhome CA: `shell / Required`, `rust / Required`,
  `Step CA Integration / Ubuntu`

- every other caller: `shell / Required`

- [ ] **Step 3: Verify protection readback**

Sort and compare exact contexts against the approved sets. Fail on an extra,
missing, null-app, wrong-app, or non-strict entry.

### Task 7: Final portfolio verification and cleanup

**Files:** no source changes

- [ ] **Step 1: Verify merged-main checks**

Query check runs on each current `main` commit. Require zero pending and zero
failed/cancelled/timed-out checks; allow only explicitly skipped optional jobs.
For Hive and Grafhome, Android and Termux must be successful, not skipped.

- [ ] **Step 2: Verify source and configuration state**

Assert all callers pin the same landed actions SHA, gate contexts exist,
protection matches Task 6, and all PRs are merged.

- [ ] **Step 3: Synchronize and clean completed worktrees**

For each repository, fetch `origin/main`, verify feature-tree equality with the
squash-merged main tree, fast-forward a clean primary checkout, remove only the
completed worktree, and delete only the completed local branch.

- [ ] **Step 4: Run final clean-state audit**

Require primary branch `main`, clean status, `HEAD == origin/main`, no completed
worktree path, and no completed local or remote feature branch in every repo.
