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
`scripts/release.conf`. Commit all of those derived changes together.

The `verify-consumer-sync` action checks the inverse contract in CI: its own ref
and every other `cgraf78/actions` ref must agree with the lock. A tracked
`scripts/release.conf` automatically includes the vendored scripts in that same
contract; the sync command creates the paired managed manifest, and CI rejects
deletion of only one marker. Repositories with neither marker get only the
universal version-lock check.
The verification job must check out the consumer before invoking the action:

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  with:
    persist-credentials: false
- uses: cgraf78/actions/.github/actions/verify-consumer-sync@FULL_COMMIT_SHA
```

Dependabot cannot update the custom lock or vendored files, so an ordinary
Dependabot SHA bump is expected to fail with the synchronization command until
a maintainer regenerates the consumer. This is deliberate fail-closed behavior,
not a bot failure to ignore.

The actions repository's internal self-pins are a bootstrap exception. A commit
cannot contain its own hash, so internal reusable workflows must point to an
earlier reviewed actions commit. Consumer repositories do not have that cycle
and must use the single-lock contract above.
