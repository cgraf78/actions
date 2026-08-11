# Generated checkout bootstrap installer

This directory owns the reusable bootstrap for source-distributed `cgraf78`
repositories. It preserves checkout-backed installation while making the same
committed top-level `install.sh` usable through a simple curl pipe.

The generated file is self-contained. It never downloads executable helper
code from `cgraf78/actions` at runtime and it does not require a release or a
release asset. `actions` supplies the reviewed template at maintenance time;
the consumer commits the rendered bytes.

## Consumer contract

The consumer keeps its product-specific symlink publication in
`support/install-checkout.sh` and adds `scripts/checkout-installer.conf`:

```bash
# shellcheck shell=bash
# shellcheck disable=SC2034
CHECKOUT_INSTALLER_ENABLED=true
CHECKOUT_INSTALLER_REPO=cgraf78/example-tool
```

`CHECKOUT_INSTALLER_REF` defaults to `main`, and
`CHECKOUT_INSTALLER_DELEGATE` defaults to `support/install-checkout.sh`. Run the
normal synchronization command from a clean Actions checkout:

```bash
consumer-ci/sync.sh /path/to/example-tool
```

For focused provider development, render only the installer:

```bash
checkout-installer/render.sh /path/to/example-tool
```

The renderer refuses to overwrite a consumer-owned `install.sh`. Disabling the
policy removes only a regular file carrying the exact generated-provider
header; custom files and symlinks remain consumer-owned.

## Runtime behavior

From a real checkout, `install.sh` immediately invokes the repository-owned
delegate, preserving its environment, arguments, output, and exit status.

When the script is downloaded or piped to Bash, it clones the repository's
maintained branch into:

```text
${XDG_DATA_HOME:-$HOME/.local/share}/cgraf78/checkouts/<repository>
```

The initial clone is shallow but durable. A rerun validates the exact origin
and branch; refuses a dirty, detached, symlinked, nested, or foreign
destination; and prepares a separate candidate checkout without Git hooks. It
accepts only a candidate that fast-forwards the installed revision and matches
the remote branch exactly. New and updated checkouts are published only after
their tracked delegate and destination identity pass validation. Updates use a
same-parent rename transaction, so a failed publication restores the complete
previous checkout instead of leaving an in-place mixture of revisions. If a
process dies after the validated candidate reaches the stable path, recovery
finishes that committed publication; if it dies before publication, recovery
restores the previous checkout. A per-destination directory lock remains held
through delegation, so an update cannot change the checkout while its installer
is publishing links. The two same-parent renames are individually atomic, but
the stable path can be absent briefly between them. Recovery covers process
termination; it does not claim power-loss durability without filesystem
`fsync`, nor protection from a hostile process running as the same user.
Managed checkouts are disposable source trees: on a revision-changing update,
ignored files, extra Git objects and reflogs, and checkout-local Git
configuration are not preserved. Internal Git operations ignore inherited
repository-selection variables
and system/global Git configuration, allow only HTTPS, SSH, and local-file
transports, and cannot prompt through standard Git, credential-helper, askpass,
or SSH paths. A lock is deliberately fail-closed after an uncatchable process
termination: after confirming that no installer is running, remove the exact
empty lock directory named by the diagnostic with `rmdir` and retry.

The entire executable body is one compound shell command. Bash therefore parses
the final byte before cloning or updating anything; a truncated curl response
cannot partially execute the bootstrap and report a successful install.

The bootstrap then invokes the same checkout-owned delegate as direct mode, so
all product policy and public symlink behavior remains in the consumer.
`PREFIX`, `BIN_DIR`, `MAN_DIR`, other environment variables, and arguments pass
through unchanged.

For hermetic tests, `CGRAF78_CHECKOUT_INSTALL_REPO_URL` overrides the clone URL
and `CGRAF78_CHECKOUT_INSTALL_DIR` overrides the exact checkout path. Production
users normally leave both unset.

## Tests

`test/checkout-installer-test` renders synthetic consumers and uses real local
Git remotes. It covers direct delegation, piped clone and update behavior,
argument and environment forwarding, exit status propagation, renderer drift,
truncated input, dirty and foreign destination refusal, missing and migrating
delegates, concurrent installs, signal forwarding, Git-environment isolation,
hard-link rejection fallback, failed and interrupted update transactions,
publication races, stale-lock recovery, and failed-clone cleanup. CI runs the
suite across the full shared Linux/macOS matrix, real Android/Termux, and macOS
system Bash 3.2.
