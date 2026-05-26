#!/usr/bin/env bash
set -euo pipefail

# Dotfiles still bootstraps some private dependency checkouts during CI. Keep
# those deploy keys isolated from the public shdeps bootstrap path so shdeps
# installs exercise the same release/HTTPS flow that fleet machines use.
missing=()
[[ -n "${DS_DEPLOY_KEY:-}" ]] || missing+=(DS_DEPLOY_KEY)
if [[ "${#missing[@]}" -gt 0 ]]; then
  printf '::error::Missing Actions secret(s): %s\n' "${missing[*]}"
  exit 1
fi

ssh_dir="${RUNNER_TEMP:-/tmp}/dotfiles-private-deps-ssh"
# Keep deploy keys out of the workspace so they are never picked up by test
# fixtures, caches, or artifact-like file scans.
rm -rf "$ssh_dir"
mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"

printf '%s\n' "$DS_DEPLOY_KEY" >"$ssh_dir/ds"
chmod 600 "$ssh_dir/ds"

known_hosts="$ssh_dir/known_hosts"
# Prefer dotfiles' checked-in GitHub host key if present. Falling back to
# ssh-keyscan preserves the old workflow behavior for fresh CI images.
if [[ -f "$GITHUB_WORKSPACE/.ssh/known_hosts" ]]; then
  grep -E '^github\.com[[:space:]]' \
    "$GITHUB_WORKSPACE/.ssh/known_hosts" >"$known_hosts" || true
fi
if [[ ! -s "$known_hosts" ]] && command -v ssh-keyscan >/dev/null 2>&1; then
  ssh-keyscan github.com >"$known_hosts"
fi
if [[ ! -s "$known_hosts" ]]; then
  echo "::error::Unable to configure GitHub SSH known_hosts" >&2
  exit 1
fi
chmod 600 "$known_hosts"

ssh_config="$ssh_dir/config"
# Private dependencies use normal SSH clone URLs. The host alias lets Git route
# the private ds checkout through its deploy key without changing the
# higher-level dotfiles/shdeps config format.
cat >"$ssh_config" <<EOF
Host github.com-ds
  HostName github.com
  User git
  IdentityFile $ssh_dir/ds
  IdentitiesOnly yes
  UserKnownHostsFile $known_hosts
  StrictHostKeyChecking yes
EOF
chmod 600 "$ssh_config"

{
  # These environment variables are part of dotfiles' bootstrap contract:
  # dot update exposes the ds override to shdeps during CI dependency install.
  echo "GIT_SSH_COMMAND=ssh -F $ssh_config"
  echo "SHDEPS_DS_REPO=git@github.com-ds:cgraf78/ds.git"
} >>"$GITHUB_ENV"
