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

The clone is shallow but durable. A rerun validates the exact origin and branch,
refuses a dirty, detached, symlinked, nested, or foreign destination, fetches
without Git hooks, and accepts only a fast-forward whose final commit exactly
matches the fetched branch. New clones are staged beside the destination and
published only after their tracked delegate and destination identity pass
validation. A per-repository directory lock remains held through delegation,
so an update cannot change the checkout while its installer is publishing
links. Internal Git operations ignore inherited repository-selection variables
and cannot prompt through standard Git, credential-helper, askpass, or SSH
paths.

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

`test/checkout-installer-test` renders a synthetic consumer and uses a real
local Git remote. It covers direct delegation, piped clone and update behavior,
argument and environment forwarding, exit status propagation, renderer drift,
truncated input, dirty and foreign destination refusal, missing delegates,
concurrent installs, signal forwarding, Git-environment isolation, publication
races, and failed-clone cleanup. The suite is portable to macOS system Bash
3.2.
