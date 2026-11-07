# toolchain-recover

A release recovery's switch to the exact Rust, Go and Node versions an existing release tag
records (as [`toolchain-record`](../toolchain-record) wrote them), so the rebuilt binaries are
byte-identical to the ones the first attempt published. For each requested toolchain whose active
version differs from the recorded one, it selects the recorded release in its own process:

- **Rust:** `rustup toolchain install <version> --profile minimal` (plus `rust-targets`) and
  `RUSTUP_TOOLCHAIN=<version>`, which outranks `rust-toolchain.toml`;
- **Go:** `<version>.linux-<arch>.tar.gz` from `https://go.dev/dl/`, checked against the sha256
  go.dev's own release list (`?mode=json&include=all`) gives it, with `GOROOT` set to it and
  `GOTOOLCHAIN=local` so a `go.mod` toolchain line cannot switch again;
- **Node:** `node-<version>-linux-<arch>.tar.xz` from `https://nodejs.org/dist/<version>/`,
  checked against that release's `SHASUMS256.txt`.

The same process then checks that `rustc --version`, `go env GOVERSION` and `node --version`
print the recorded versions, and only then persists the switch through `GITHUB_ENV` and
`GITHUB_PATH`. This replaces running `actions/setup-go`/`setup-node` a second time behind an
`if:`, which switches without anything checking that the switch took.

Fails closed, persisting nothing, on: a requested toolchain the annotation has no line for, a line
given twice or that does not parse, a missing or lightweight tag, a download or checksum failure,
or a version that does not match after the switch. With neither `tag` nor `annotation` (or an
empty annotation) it is a fresh release and does nothing, so it can run unconditionally. Linux
X64 and ARM64 runners; needs `curl`, `jq`, `tar`, `sha256sum`, and `rustup` for Rust.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `toolchains` | yes |  | Comma- or space-separated subset of `rust`, `go`, `node` the annotation must record. |
| `tag` | no | `""` | An existing annotated tag in the local clone (check out with `fetch-tags`). |
| `annotation` | no | `""` | The annotation text instead of `tag`. Set at most one of the two. |
| `rust-targets` | no | `""` | Targets rustup installs with a recorded Rust, e.g. `x86_64-unknown-linux-musl aarch64-unknown-linux-musl`. |
| `allow-unrecorded` | no | `false` | `true`: an annotation recording none of the requested toolchains (an older tag) warns and switches nothing. |
| `install-dir` | no | `""` | Where Go and Node are unpacked. Empty: `$RUNNER_TEMP`. |
| `working-directory` | no | `.` | Where the active versions are checked, so `rust-toolchain.toml` and `go.mod` apply. |

## Outputs

| Name | Description |
| --- | --- |
| `mode` | `fresh`, `unrecorded`, `matched` or `switched`. |
| `rust-version` | The verified active Rust version; empty for `fresh`/`unrecorded` or when not requested. |
| `go-version` | The verified active Go version, e.g. `go1.26.1`. |
| `node-version` | The verified active Node version, e.g. `v24.1.0`. |

## Permissions

None beyond `contents: read` for the checkout: the downloads are public.

## Usage

```yaml
- uses: actions/checkout@<sha> # v7.0.1
  with:
    fetch-depth: 0
    fetch-tags: true
- uses: actions/setup-go@<sha> # v7.0.0
  with:
    go-version-file: .go-version
- uses: leinardi/gh-composite-actions/toolchain-recover@<sha> # v1.0.0
  with:
    toolchains: go,node
    # Empty on a fresh release: the step is then a no-op.
    tag: ${{ steps.tag.outputs.exists == 'true' && steps.version.outputs.tag || '' }}
```
