# shellcheck shell=bash

# Stable provider-owned tokens consumed by the infrastructure retry classifier.
#
# The runner echoes every `run:` script, `with:` input, and `env:` value into
# the job log before the step executes, so a token is a runtime signal only if
# no workflow or action YAML spells it out. Producers therefore print these
# through variables sourced from this file (or, for the POSIX package-manager
# library, which cannot locate this file, a literal in a sourced script).
# Never export them through GITHUB_ENV either: the runner lists those values
# under every later step's `env:` in the log. test/workflow-contract-test
# rejects any YAML file that contains a token.
# shellcheck disable=SC2034 # This file is sourced by independent actions.
PACKAGE_COMMAND_STALL_MARKER='infra-stall: package command exhausted bounded retries'
TERMUX_ADB_SETUP_TIMEOUT_MARKER='infra-stall: termux-adb-setup-timeout-v1'
TERMUX_PACKAGE_SERVICE_MARKER='infra-stall: termux-package-service-v1'
TERMUX_BOOTSTRAP_TIMEOUT_MARKER='infra-stall: termux-bootstrap-v1'
TERMUX_PACKAGE_COMMAND_MARKER='infra-stall: termux-package-command-v1'
ANDROID_SDK_INSTALL_MARKER='infra-stall: android-sdk-install-v1'

# Every token above, in the order `infra-retry` checks them. A marker that is
# defined but missing here would be printed yet never retried.
INFRA_STALL_MARKERS=(
  "$PACKAGE_COMMAND_STALL_MARKER"
  "$TERMUX_ADB_SETUP_TIMEOUT_MARKER"
  "$TERMUX_PACKAGE_SERVICE_MARKER"
  "$TERMUX_BOOTSTRAP_TIMEOUT_MARKER"
  "$TERMUX_PACKAGE_COMMAND_MARKER"
  "$ANDROID_SDK_INSTALL_MARKER"
)
