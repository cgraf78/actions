#!/usr/bin/env bash
set -euo pipefail

# Verify that a consumer repository's vendored release scripts still match the
# shared copy shipped with this action.
#
# The comparison itself belongs to shared/verify-vendored-scripts.sh so every
# vendored family enforces the same content, mode, and managed-set contract;
# this action only names the release family and its consumer directory.

# $GITHUB_ACTION_PATH points at .github/actions/verify-release-scripts inside
# the checked-out actions repo; the shared scripts live at its root.
action_path=$(cd "$GITHUB_ACTION_PATH" && pwd)
shared_dir=$(cd "$action_path/../../.." && pwd)/release-scripts

exec "$action_path/../shared/verify-vendored-scripts.sh" \
  "$shared_dir" "${SCRIPTS_DIR:-scripts}" .release-scripts.manifest \
  verify-release-scripts 'release scripts'
