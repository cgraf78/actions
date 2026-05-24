#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=./profiles.sh
. "$SCRIPT_DIR/profiles.sh"
# shellcheck source=./checkrun.sh
. "$SCRIPT_DIR/checkrun.sh"
# shellcheck source=./dotfiles.sh
. "$SCRIPT_DIR/dotfiles.sh"

case "$SETUP" in
  none)
    # Normal shell-tool repos use shared profiles plus one repo-owned test
    # command. This is the default path for termnav, sley, cmdblocks,
    # agentguard, and ds.
    install_profile_prereqs
    ;;
  checkrun)
    # checkrun needs a larger base image before its dev-tool bootstrap can run.
    # Keep it as a named path instead of bloating the generic profiles.
    install_checkrun_prereqs
    ;;
  dotfiles)
    # Dotfiles keeps an exact, intentionally small package list because shdeps
    # installation behavior is what the CI is validating.
    install_dotfiles_bootstrap_prereqs
    ;;
  *)
    echo "unsupported setup mode: $SETUP" >&2
    exit 2
    ;;
esac
