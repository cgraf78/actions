# Retry-Safe Release Asset Uploads

## Goal

Make Rust release asset uploads tolerate workflow reruns and ambiguous GitHub
API failures without hiding genuine missing or mismatched assets.

## Design

Add a Bash helper owned by `cgraf78/actions` that expands the caller-owned
asset glob and uploads each regular file independently. For each file, it
queries the draft release for an exact-name asset. An existing asset with the
same byte size is already complete and is skipped. A missing or size-mismatched
asset is uploaded with `--clobber` and bounded backoff.

If `gh release upload` exits unsuccessfully, the helper immediately queries
the release again. A now-present exact-name asset with the expected byte size
proves the API operation completed despite the client error, so the helper
continues. Otherwise it retries and ultimately fails after three attempts.

The reusable Rust release workflow calls this helper instead of passing the
whole glob to one `gh release upload` invocation. The publish job remains
unchanged and therefore cannot publish until every matrix upload job proves
that all of its assets exist.

## Boundaries

- Compare exact asset names and byte sizes; do not parse display output.
- Keep the caller-owned shell glob contract.
- Reject an empty glob and non-regular matches.
- Retry at most three upload attempts per asset with bounded backoff.
- Do not sync consumer release scripts because the behavior is wholly owned
  by the reusable workflow repository.

## Verification

Shell tests cover clean upload, an idempotent rerun, partial prior completion,
an ambiguous successful upload, a mismatched remote asset, retry exhaustion,
an empty glob, and a multi-file batch. Existing workflow-contract and full
repository tests must remain green.
