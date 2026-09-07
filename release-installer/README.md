# Generated standalone release installer

This directory owns the reusable implementation of the small, standalone
installer used by release-producing `cgraf78` repositories. Consumers continue
to own product policy in `scripts/release.conf`; `render.sh` combines that
policy with `install.sh.in` and writes one self-contained top-level `install.sh`.

The generated file is committed. A user can download only `install.sh`, so it
must not source this repository or fetch executable helper code at runtime.
`verify-consumer-sync` renders it again from the same locked Actions commit and
fails if bytes, file type, executable mode, or tracking state drift.

## Opting in

Add this assignment to a consumer that wants the standard installer:

```bash
RELEASE_STANDALONE_INSTALLER=true
```

Then run the normal fleet synchronization command from a clean, reviewed
Actions checkout:

```bash
consumer-ci/sync.sh /path/to/consumer
```

That command is the normal consumer-facing generation command: it advances the
Actions lock, rewrites workflow refs, refreshes release scripts, and generates
`install.sh` from one commit. For focused provider development, the narrow
equivalent is:

```bash
release-installer/render.sh /path/to/consumer
```

Repositories with a specialized existing installer leave the flag unset. This
is intentionally opt-in: merely having `scripts/release.conf` must never replace
a product-owned `install.sh` such as Shdeps' bootstrap and uninstall surface.
If a repository later disables the flag, synchronization removes only a regular
`install.sh` carrying the exact generated-provider header; a custom file or
symlink remains consumer-owned and untouched. The check mode fails until that
generated orphan is retired, so disabling policy cannot silently disable drift
coverage while leaving provider bytes behind.

The renderer derives these values from existing release policy:

- `RELEASE_REPO` (default `cgraf78/$RELEASE_SLUG`)
- `RELEASE_SLUG`
- `RELEASE_ASSET_NAME`
- `RELEASE_BINARY` and `RELEASE_BINARY_DEST`
- `RELEASE_BINARY_VERSION_STYLE` (`version` by default, or `commit`)
- optional `RELEASE_INSTALL_INIT_SUBCOMMAND`, one safe argument enabling the
  post-install `--init` interface
- an optional `man/man1/$RELEASE_BINARY.1` link when that file is a required
  `RELEASE_PAYLOAD_FILES` entry

No second installer-specific layout manifest is needed.

## User interface

```text
install.sh [--version TAG]
install.sh --archive PATH [--checksum PATH]

  --data-home PATH
  --bin-dir PATH
  --man-dir PATH
  --init [ARGS...]  # configured consumers only; must be last
```

Without `--version`, online installation follows the repository's GitHub
`releases/latest` redirect, validates the resulting release tag, and downloads
the matching archive and `.sha256` sidecar. Each of those three download
requests has bounded connection, total-transfer, low-speed, and retry windows,
with a combined worst-case budget below ten minutes. The subsequent GitHub CLI
attestation lookup is a separate required trust check. `--archive` is the
first-class offline/test path; its checksum defaults to `PATH.sha256` and does
not perform an online attestation lookup.

Linux and macOS default to:

```text
archive root:  ${XDG_DATA_HOME:-$HOME/.local/share}/cgraf78/<slug>
command:       $HOME/.local/bin/<binary>
manual page:   ${XDG_DATA_HOME:-$HOME/.local/share}/man/man1/<binary>.1
```

Android/Termux uses the same XDG archive root and publishes commands/manuals
under `$PREFIX/bin` and `$PREFIX/share/man/man1`. The published platform set is
`linux-x86_64-musl`, `linux-aarch64-musl`, `macos-x86_64`, `macos-aarch64`, and
`android-aarch64`. Android is detected before Linux, and an Android x86_64 host
fails explicitly instead of downloading an incompatible Linux archive.

## Ownership and updates

The installer stores complete extracted archive roots under a private,
marker-owned control directory:

```text
$DATA_HOME/cgraf78/.<slug>-standalone/
  owner
  releases/<tag>-<platform>/
  current -> releases/<tag>-<platform>

$DATA_HOME/cgraf78/<slug> -> .<slug>-standalone/current
```

The public command and optional manpage point through the stable slug root.
Updates stage a complete release, switch `current` with a same-directory
no-follow rename, and only then publish any missing stable links. An activation
failure therefore cannot expose dangling first-install paths. The first public
links are also one logical publication: a later link failure removes only links
created by that invocation, while retaining the complete private release for a
safe retry. Existing releases are kept; v1 intentionally has no automatic prune
policy.

Every public path is preflighted before the new release is copied or activated.
An existing regular file, directory, or arbitrary symlink is user-owned and
causes a refusal. Only the exact links and marker created by this installer are
accepted on a rerun. This also prevents the standalone installer from silently
co-managing a Shdeps-owned tree. Reinstalling the same archive compares every
archived file and executable bit with the retained release before trusting it.
Custom command and manpage directories must be normalized absolute paths. Their
physical ancestry must not overlap the stable release root or private control
tree, so a symlinked parent cannot redirect publication into retained payload.

There is no `--force`, uninstall framework, self-update mode, package-manager
abstraction, or automatic migration of another install method in v1. Those
features would broaden destructive ownership decisions without helping the two
initial standalone consumers.

When a consumer configures `RELEASE_INSTALL_INIT_SUBCOMMAND`, `--init` consumes
every remaining argument verbatim. Installation, atomic activation, and public
link publication complete first. The installer then releases its lock, disables
publication rollback, removes temporary state, and invokes the published
release's exact verified binary path with the configured subcommand. It does
not resolve through the mutable public `current` link. Initialization failure
is returned to the caller without rolling back the installed release.
Consumers without the policy continue to reject `--init` as an unknown option.

## Validation and trust boundary

Before extraction or activation, the generated installer:

- accepts only HTTPS GitHub redirects and downloads;
- validates the exact tag, platform, asset basename, and checksum filename;
- requires GitHub CLI and verifies downloaded archives against the release
  repository and the `cgraf78/actions` signer repository;
- snapshots a caller-provided archive into the private temporary directory
  before hashing, inspecting, or extracting it;
- verifies SHA-256 with `sha256sum` or macOS `shasum`;
- rejects absolute, traversal, duplicate, unsafe-character, symlink, hardlink,
  device, FIFO, and other non-file/non-directory archive entries;
- extracts only into a mode-0700 temporary directory under `umask 077`;
- requires the configured executable and any declared manpage;
- verifies embedded schema, repository, platform, tag/version, method, and commit
  identity;
- executes the staged binary with `--version` and requires one bounded output
  line identifying either the exact release version or, for `commit` style,
  the first 12 characters of the metadata commit;
- holds a per-install-root publication lock while staging and switching.

The checksum sidecar detects corruption, truncation, and the wrong asset.
Online installs additionally use GitHub's artifact attestation verification to
bind the archive to both its release repository and the shared trusted builder.
The explicit local `--archive` path does not query GitHub for an attestation,
so it remains usable for offline installation and locally built artifacts.
It is therefore an explicit caller-trusted executable input. Its checksum
protects against accidental corruption but does not establish publisher
identity.

The staged version probe runs from the private scratch directory with an empty,
fixed environment containing only isolated HOME/XDG/TMPDIR paths, `LC_ALL`, and
a platform system `PATH`. A five-second supervisor first proves ownership of a
dedicated process group, applies a kernel file-size limit to captured output,
then uses bounded group-wide TERM/KILL cleanup if the probe or a descendant
hangs or floods output.

The installer never writes product configuration, user state, credentials,
site policy, enrollment data, private hostnames, or deployment topology. Those
are runtime/consumer concerns and must not enter this public generic provider.

## Tests

`test/release-installer-test` renders a synthetic public consumer and uses real
local tarballs, checksum tools, extraction, filesystem ownership, reruns, and
updates. It covers all five published platform labels, archive attacks, metadata
drift, mutable source-path swaps, reserved-path collisions, publication rollback,
online URL orchestration at the HTTP boundary, and the complete-root contract.
The same suite runs in Ubuntu Quality and through `bash32-ci.yml` under macOS'
stock `/bin/bash`.

`test/consumer-sync-test` and `test/examples-test` cover generation and drift
verification through real temporary Git repositories. `--check` is intended for
that verifier path and never rewrites a consumer.
