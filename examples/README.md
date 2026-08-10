# Consumer examples

These are drafting templates for the public `cgraf78/actions` interfaces. They
use only synthetic names and least-privilege permissions. `FULL_COMMIT_SHA` is
intentional: do not choose several refs by hand.

## Shell repository

Copy the following files into a shell-tool repository and adapt the test path
and prerequisite profiles:

```text
examples/shell-ci.yml             -> .github/workflows/test.yml
examples/retry-infrastructure.yml -> .github/workflows/retry-infrastructure.yml
examples/dependabot.yml            -> .github/dependabot.yml
examples/shellcheck-files.txt      -> .github/shellcheck-files.txt
```

The inventory format requires a literal tab, as shown in the template. Add
every discovered shell program or explicit fixture before enabling the shared
ShellCheck gate.

## Rust binary repository

Copy and adapt:

```text
examples/rust-ci.yml               -> .github/workflows/test.yml
examples/rust-release.yml          -> .github/workflows/release.yml
examples/retry-infrastructure.yml  -> .github/workflows/retry-infrastructure.yml
examples/dependabot.yml             -> .github/dependabot.yml
examples/release.conf               -> scripts/release.conf
```

Replace `example-tool` with the Cargo binary name. The example opts into the
standard generated top-level installer; remove
`RELEASE_STANDALONE_INSTALLER=true` if the product already owns a specialized
installer. The CI example explicitly
shows both mandatory Android contracts: an aarch64 package smoke and an x86_64
host cross-build executed under Termux. The release config contains only
consumer-specific payload policy; the synchronization command vendors the
shared implementations.

## Pin and verify

After adapting either template, check out `cgraf78/actions` at a reviewed green
commit and run:

```sh
consumer-ci/sync.sh /path/to/consumer
```

That command writes `.github/cgraf78-actions.lock`, replaces every
`FULL_COMMIT_SHA`, vendors release scripts when `scripts/release.conf` exists,
and generates the opted-in top-level installer. Commit all generated changes
together. The dedicated
`cgraf78/actions sync` job then verifies the inverse contract in CI.

The infrastructure retry controller is optional. Keep its `workflows: [Tests]`
entry aligned with the primary workflow's displayed name, and do not make the
controller a required check. It retries only the provider's narrow allowlist of
pre-application infrastructure failures once.

Repo tests run `actionlint` over every workflow, assert the security-sensitive
permissions and required inputs, stage both templates as real Git consumers,
run the production synchronizer, and run the production verifier. This keeps
the examples coupled to the actual adoption path rather than to a parallel
documentation-only parser.
