# Composite Actions

This directory contains reusable composite actions consumed by the workflows in
this repo and by other `cgraf78` repositories.

## Actions

- `platform-matrix` emits the shared OS/container matrix.
- `android-rust-toolchain` configures the runner-provided Android NDK for Rust
  aarch64 and x86_64 cross-builds.
- `shell-ci-prereqs` installs shell test dependencies by profile and setup mode.
- `shellcheck-inventory` validates a repository-owned typed inventory and runs
  ShellCheck over every reviewed program while excluding declared fixtures.
- `rust-ci-prereqs` installs Rust CI prerequisites that are not handled by
  `dtolnay/rust-toolchain`.
- `musl-build-prereqs` installs the musl linker toolchain, and optionally adds
  the Rust musl target, for repos whose crates link C code.
- `dotfiles-bootstrap` installs Dot and locked Mise tools, runs doctor when the
  full dependency provider converges, or stages and installs a cutover-locked
  standalone Dot payload for sandbox CI.
- `verify-release-scripts` is the narrow byte, mode, and managed-file-set check
  for vendored release scripts.
- `verify-consumer-sync` is the consumer-facing gate: it requires every
  `cgraf78/actions` ref and the verifier's own ref to match the repository lock,
  then runs `verify-release-scripts` for the same checked-out actions commit
  when the consumer tracks `scripts/release.conf`, and rerenders any generated
  release or checkout installer selected by consumer policy.

Keep composite actions narrow and reusable. If behavior is only needed by a
single reusable workflow, prefer keeping it in that workflow until a second
consumer appears.

`dotfiles-bootstrap` defaults to `mode: full`. `mode: stage` publishes a
private, self-contained payload at `stage-directory`; `mode: install-staged`
validates and installs that payload against the destination client's cutover
lock. The staged modes reuse the lock as the only Dot revision decision and do
not run the full host Mise or doctor steps. Before `full` or `install-staged`
invokes Dot, the action clears inherited XDG path-root overrides so the client
checkout under `HOME` remains the authoritative configuration; other client
environment variables are preserved. When shared CI explicitly suppresses the
client dependency provider, `full` mode also suppresses its workstation-wide
doctor smoke check; the caller's repository tests remain the verifier for that
deliberately smaller dependency surface.

`shellcheck-inventory` expects a tracked, nonsymlink inventory whose records
are `program<TAB>path` or `fixture<TAB>path`. It discovers shell programs from
Git rather than trusting the inventory alone, so new ShellCheck-supported
scripts fail the gate until reviewed. Fixture rows remain visible, discoverable
coverage decisions but are not linted as standalone programs. The caller must
check out one repository at the `GITHUB_WORKSPACE` root and pass a normalized,
repository-relative inventory path. Newline-containing paths cannot be encoded
in the line-oriented inventory and therefore fail closed.

A tracked shell-program symlink is accepted only as an alias to an inventoried,
tracked, regular shell program inside the same repository. The alias itself is
not an inventory row and is not linted twice. Absolute, broken, external,
chained, or untracked targets remain errors.
