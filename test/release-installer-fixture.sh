# shellcheck shell=bash
# Shared fixture for the release-installer suites: one example consumer and
# schema-faithful release archives. Callers set `tmp` to a private scratch
# directory before calling make_archive. Keeping the release metadata and
# payload layout here means the Linux and real-Termux suites cannot drift from
# the archive contract the installer validates.

# Write the example consumer's release configuration to <consumer>. Suites
# append overrides afterwards to exercise other renderer inputs.
write_fixture_config() {
  cat >"$1/scripts/release.conf" <<'EOF'
# shellcheck shell=bash
# shellcheck disable=SC2034
RELEASE_ENV_PREFIX=EXAMPLE_TOOL
RELEASE_SLUG=example-tool
RELEASE_REPO=example/example-tool
RELEASE_ASSET_NAME=example-tool
RELEASE_BINARY=example-tool
RELEASE_BINARY_DEST=bin/example-tool
RELEASE_PAYLOAD_FILES=(README.md LICENSE man/man1/example-tool.1)
RELEASE_PAYLOAD_DIRS=(examples schemas)
RELEASE_STANDALONE_INSTALLER=true
EOF
}

checksum_file() {
  local archive=$1

  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$(dirname "$archive")" && sha256sum "$(basename "$archive")") \
      >"$archive.sha256"
  else
    (cd "$(dirname "$archive")" && shasum -a 256 "$(basename "$archive")") \
      >"$archive.sha256"
  fi
}

# Build a release archive and its checksum, printing the archive path.
# The fixture binary is a script, so its interpreter line matters: Android
# cannot resolve `/usr/bin/env` without Termux's LD_PRELOAD shim, which the
# installer's `env -i` version probe clears. Real-Termux suites therefore set
# `fixture_shebang` to an absolute interpreter, as native release binaries
# need none.
make_archive() {
  local version=$1 platform=$2 label=$3
  local repo=${4:-example/example-tool}
  local schema=${5:-1}
  local binary_impl=${6:-"printf '%s\\n' '$label'"}
  local commit payload archive

  # shellcheck disable=SC2154 # The sourcing suite owns tmp (see header).
  : "${tmp:?release-installer-fixture: set tmp before make_archive}"
  commit=${version##*-}11111111111111111111111111111111
  payload=$(mktemp -d "$tmp/payload.XXXXXX")
  mkdir -p "$payload/bin" "$payload/man/man1" \
    "$payload/examples" "$payload/schemas"
  {
    printf '%s\n' "${fixture_shebang:-#!/usr/bin/env bash}"
    printf '%s\n' "$binary_impl"
  } >"$payload/bin/example-tool"
  chmod 0755 "$payload/bin/example-tool"
  printf 'readme %s\n' "$label" >"$payload/README.md"
  printf 'license\n' >"$payload/LICENSE"
  printf '.TH EXAMPLE 1\n' >"$payload/man/man1/example-tool.1"
  printf 'example %s\n' "$label" >"$payload/examples/example.txt"
  printf '{"label":"%s"}\n' "$label" >"$payload/schemas/schema.json"
  cat >"$payload/.example-tool-install.json" <<EOF
{
  "schema": $schema,
  "method": "release",
  "artifact_platform": "$platform",
  "version": "$version",
  "tag": "$version",
  "commit": "$commit",
  "repo": "$repo"
}
EOF

  archive="$tmp/example-tool-${version}-${platform}.tar.gz"
  tar -C "$payload" -czf "$archive" .
  checksum_file "$archive"
  printf '%s\n' "$archive"
}
