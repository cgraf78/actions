# Shared release scripts

Single source of truth for the release identity, packaging, and smoke-test
logic used by `cgraf78` Rust repositories (`hive-memory`, `shdeps`,
`grafhome-ca`).

Consumers vendor these files verbatim into their own `scripts/` directory and
describe only what genuinely differs between projects in `scripts/release.conf`.

## Why vendored instead of fetched

`release.sh` is a local maintainer tool that never runs in CI, and the packaging
and smoke scripts run on release runners before any dependency bootstrap. Both
argue against pulling this code over the network on the release path.

Vendoring keeps the release path self-contained while the
`verify-consumer-sync` action makes the copies a derived artifact rather than
three independently maintained forks: any divergence fails the consumer's CI
with the resync command. The managed manifest also detects scripts removed or
renamed upstream; comparing only current filenames would leave an obsolete
executable behind forever. A submodule would avoid the duplicated
bytes but adds `--recurse-submodules` friction to every clone, worktree, and
checkout step for release-critical tooling.

## Files

| File | Role |
| --- | --- |
| `release-lib.sh` | All shared logic. Sourced, not executed. |
| `release-version.sh` | Prints the computed release version. |
| `release-tag.sh` | Prints the release version, validated as asset-name safe. |
| `release.sh` | Local release cutter: validates state, creates and pushes the tag. |
| `package-release.sh` | Builds the archive and checksum for one Rust target. |
| `smoke-release.sh` | Extracts and validates a packaged archive. |
| `.release-scripts.manifest` | Consumer-generated list of files owned by the sync contract; it is not a source file here. |
| `sync.sh` | Low-level maintainer tool used by consumer synchronization. Not vendored. |

## Release identity

The public version is `YYYYMMDD-HHMMSS-<8hex>`: the UTC committer timestamp of
the release commit plus an 8-character commit suffix. `Cargo.toml` is
deliberately not the source of truth — the same commit must always map to the
same release version, and the hash suffix keeps source-only installs and
published assets traceable to exact git history.

Resolution order, highest priority first:

1. `<PREFIX>_BUILD_VERSION` — must agree with the build commit.
2. A tag ref (`GITHUB_REF_TYPE=tag`) — must agree with the build commit.
3. `<PREFIX>_BUILD_TIMESTAMP`, else the commit's UTC committer date, else now.

`<PREFIX>` is `RELEASE_ENV_PREFIX` from `release.conf`.

## Consumer setup

Add a config, then synchronize the repository from a clean `actions` checkout
at the reviewed commit it should pin:

```bash
consumer-ci/sync.sh ~/git/hive-memory
```

`scripts/release.conf`:

```bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # consumed by release-lib.sh after sourcing
RELEASE_ENV_PREFIX=HIVE_MEMORY          # env namespace: HIVE_MEMORY_BUILD_COMMIT, ...
RELEASE_SLUG=hive-memory                # repo name; names the breadcrumb and install metadata
RELEASE_REPO=cgraf78/hive-memory        # optional, defaults to cgraf78/<slug>
RELEASE_ASSET_NAME=hm                   # archive filename prefix
RELEASE_BINARY=hm                       # cargo binary name
RELEASE_BINARY_DEST=hm                  # path inside the archive; use bin/<name> for a bin layout
RELEASE_PAYLOAD_FILES=(README.md LICENSE man/man1/hm.1)
RELEASE_PAYLOAD_DIRS=(completions schemas)
```

`RELEASE_PAYLOAD_FILES` entries are required: a missing one fails the release,
because a silently omitted file ships a broken archive.
`RELEASE_PAYLOAD_DIRS` entries are optional and skipped when absent, because
repos gain and lose generated asset trees over time.

Every archive also gets `.<slug>-install.json` describing the release identity,
so an extracted archive can be identified without guessing from filesystem
shape.

`release.conf` only ever assigns; the library reads it after sourcing, which
ShellCheck cannot see. Keep the file-level `SC2034` disable, and register the
file as a `program` row in the repo's ShellCheck inventory alongside
`release-lib.sh` and any `release-smoke-hook.sh`.

### Repo-specific smoke assertions

Generic smoke coverage is packaging-focused: executable bit, declared payload
presence, archive naming, and the ELF machine/loader check for cross-built
Android artifacts.

For runtime coverage, add `scripts/release-smoke-hook.sh` defining
`release_smoke_check <extract-dir> <asset-platform>`. It is skipped for
`android-*` platforms, which are cross-built and cannot execute on the runner.

```bash
# shellcheck shell=bash
release_smoke_check() {
  local root=$1
  "$root/hm" --version || return 1
}
```

Check return codes explicitly. The hook is sourced, so its result would
otherwise depend on the caller's `set -e` and on which command happens to run
last — a hook can report success after a command it ran has already failed.

### CI wiring

Add the drift gate to the consumer's normal CI so divergence is caught on every
pull request rather than at release time:

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  with:
    persist-credentials: false
- uses: cgraf78/actions/.github/actions/verify-consumer-sync@FULL_COMMIT_SHA
```

## Changing the shared scripts

1. Edit here, extend `test/release-scripts-test`, and land the change.
2. Check out that commit and run `consumer-ci/sync.sh <consumer-repo>` for each
   consumer. Commit the lock, generated workflow refs, manifest, and scripts
   together.

Dependabot bumps the pinned SHA but cannot resync the vendored files, so its
pull requests fail the drift gate until step 2 is applied. That failure is the
intended signal, not a bug.
