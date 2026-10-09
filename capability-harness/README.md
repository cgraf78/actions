# Shared capability test harness

Single source of truth for the test-harness helpers that standalone Dot overlay
repositories (`dotfiles-nvim`, `dotfiles-dev`) use to prove their payload
converges through a no-base Dot client. Each overlay keeps its own runner
(`test/run`), suite inventory, command allowlist, and overlay-specific fixtures;
only the mechanics every overlay needs identically live here.

## Why vendored instead of fetched

Overlay runners execute locally as well as in CI, and their capability lane
must work on every shell-CI platform without a bootstrap step that reaches
this repository. Consumers therefore vendor these files into `test/lib/`,
exactly like the shared release scripts. `verify-consumer-sync` compares the
vendored bytes, modes, and managed filename set against the locked actions
commit, so a local edit or a partial update fails the consumer's CI with the
resync command.

## Files

| File | Role |
| --- | --- |
| `capability-fixture.sh` | `capability_fixture_create HOME OVERLAY NN-name.conf` writes the minimal Dot client config, an empty owner-only extension root, and one `sync=none` overlay descriptor. Executable for `--self-test`. |
| `dot-release.sh` | `capability_dot_release_install DEST` resolves, downloads, checksum-verifies, and extracts one Dot release. Sourced, not executed. |
| `suite-inventory.sh` | `validate_suite_inventory ROOT INVENTORY SOURCE_ROOT` proves the declared suite list and the executable suites match, printing suite names. Executable for `--self-test`. |
| `wait-github-state.sh` | `wait_github_state TIMEOUT INTERVAL COMMAND...` polls a GitHub-state predicate with a bounded deadline. Executable as a command or for `--self-test`. |
| `workflow-contract.sh` | Repository-contract helpers for `test/workflow-test`: `fail`, `workflow_contract_init REPO` (repository identity), `workflow_contract_check_files` (canonical MIT `LICENSE`, `.gitignore`), `workflow_contract_check_inventory_programs` (no unlinted `fixture` rows), the remote public/MIT/default-branch predicate with its `--remote-predicate` dispatch and bounded poll, and the `test/run` invocation counter. Sourced, not executed. |

Sourcing any file defines functions only; the caller keeps its own shell
options. A direct run enables strict mode for its entry point.

`workflow-contract.sh` intentionally omits two checks overlays used to carry:
the `cgraf78/actions sync` job (`verify-consumer-sync`) owns the actions lock
and every literal ref, and shell CI's `shellcheck-inventory` owns the typed
ShellCheck inventory. Each overlay keeps its own workflow-shape assertions.

`capability_dot_release_install` reads `DOT_TEST_DOT_RELEASE_TAG` (default
`latest`, resolved once through the anonymous `releases/latest` redirect) and
`DOT_TEST_DOT_RELEASE_REPO` (default `cgraf78/dot`). Capability CI floats to
the newest release because the matrix images carry no Rust toolchain to build
Dot from source; an explicit tag still selects that exact release.

## Adopting

Track an opt-in marker beside the vendored copies, then synchronize from the
reviewed actions checkout:

```bash
printf '# Opt in to cgraf78/actions capability-harness vendoring.\n' \
  >test/lib/capability-harness.conf
consumer-ci/sync.sh <overlay-checkout>
```

The marker carries no settings. It and the generated
`test/lib/.capability-harness.manifest` must be tracked together; CI rejects
either one alone so deleting a single marker cannot silently place the
vendored files outside drift checks. Add each vendored file to the consumer's
ShellCheck inventory (adding a file to this family therefore needs that
consumer edit alongside the lock bump), then source the libraries from the
scripts that use
them (normally `test/run`, and `test/workflow-test` for the repository
contract).
