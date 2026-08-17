# Consumer CI synchronization

GitHub Actions requires `uses:` references to contain literal refs. It does not
allow a repository variable, environment variable, or expression to supply the
commit after `@`, and YAML anchors cannot be shared between workflow files.
Without an additional contract, a repository that calls several workflows and
actions therefore accumulates several independently editable SHA literals.

Each `cgraf78` consumer keeps one authoritative value in:

```text
.github/cgraf78-actions.lock
```

The literal refs in workflow YAML are generated copies of that value. They are
committed because GitHub must resolve reusable workflows before any job can run;
they are not separate version choices.

## Updating a consumer

Check out `cgraf78/actions` at the reviewed commit the consumer should use. The
checkout must be clean so its commit describes the exact scripts being copied.
Then run:

```bash
consumer-ci/sync.sh ~/git/hive-memory
```

The command writes the lock, rewrites every tracked `cgraf78/actions` use in a
GitHub workflow or composite action (including actions outside `.github/`), and
refreshes vendored release scripts when the consumer has
`scripts/release.conf`. When that policy sets
`RELEASE_STANDALONE_INSTALLER=true`, it also regenerates the self-contained
top-level `install.sh`. Independently, a tracked
`scripts/checkout-installer.conf` regenerates the checkout bootstrap described
in [`../checkout-installer/README.md`](../checkout-installer/README.md). Both
installer types use the same Actions lock; source-only repositories do not need
a release or release asset. Because both generated installer policies own
top-level `install.sh`, `RELEASE_STANDALONE_INSTALLER=true` and
`CHECKOUT_INSTALLER_ENABLED=true` are mutually exclusive. The synchronizer
rejects that conflict before changing consumer files. Commit all derived
changes together.

The `verify-consumer-sync` action checks the inverse contract in CI: its own ref
and every other `cgraf78/actions` ref must agree with the lock. A tracked
`scripts/release.conf` automatically includes the vendored scripts in that same
contract; the sync command creates the paired managed manifest, and CI rejects
deletion of only one marker. An opted-in generated installer is rendered again
from the locked provider and compared byte-for-byte, including its regular-file,
executable, and tracked-file contract. A tracked checkout-installer config gets
the same render-and-compare treatment, including its repository-owned delegate.
Repositories with neither installer policy get only the universal version-lock
check.
Run the verifier in a dedicated job named `cgraf78/actions sync`, and require
that check on the consumer's protected default branch. Keeping one stable name
across repositories makes the protection rule recognizable, while keeping the
job separate from product CI makes its narrow ownership clear: it checks only
that generated references still match the reviewed lock. The job must check out
the consumer before invoking the action:

```yaml
jobs:
  actions-sync:
    name: cgraf78/actions sync
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    steps:
      # GitHub cannot read the lock before resolving `uses:`, so this action
      # proves every cgraf78/actions literal still matches the reviewed lock.
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: cgraf78/actions/.github/actions/verify-consumer-sync@FULL_COMMIT_SHA
```

Dependabot cannot update the custom lock or vendored files, so an ordinary
Dependabot SHA bump is expected to fail with the synchronization command until
a maintainer regenerates the consumer. This is deliberate fail-closed behavior,
not a bot failure to ignore.

The actions repository also uses this command on itself. A commit cannot
contain its own hash, so first commit the provider changes, then run
`consumer-ci/sync.sh .` from that clean commit and commit the resulting lock
and internal refs as a small follow-up. Consumer repositories do not have that
cycle and pin the final reviewed commit directly.
