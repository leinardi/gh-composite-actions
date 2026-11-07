# toolchain-record

Prints the exact toolchain versions a release is about to be built with, as the lines a release
tag's annotation records them with, one per requested toolchain, in the order Rust, Go, Node:

```text
Rust: 1.98.1
Go: go1.26.1
Node: v24.1.0
```

The versions come from `rustc --version`, `go env GOVERSION` and `node --version`, not from the
setup inputs: a Node major or a `check-latest` Go names a line, not a release, and only what the
build runs can be rebuilt byte-identically later. [`toolchain-recover`](../toolchain-recover)
reads the same lines back. Fails closed on an unknown toolchain, a missing tool, or a version of
an unexpected shape (a nightly Rust, a devel Go).

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `toolchains` | yes |  | Comma- or space-separated subset of `rust`, `go`, `node`, each already set up. |
| `annotation-file` | no | `""` | A file the lines are appended to, e.g. the tag message before `git tag -a -F`. |
| `working-directory` | no | `.` | Where the versions are read, so `rust-toolchain.toml` and `go.mod` apply. |

## Outputs

| Name | Description |
| --- | --- |
| `lines` | The annotation lines (multi-line). |
| `rust-version` | e.g. `1.98.1`; empty when `rust` is not requested. |
| `go-version` | e.g. `go1.26.1`; empty when `go` is not requested. |
| `node-version` | e.g. `v24.1.0`; empty when `node` is not requested. |

## Permissions

None.

## Usage

```yaml
- run: printf '%s %s\n\n' "$PROJECT" "$TAG" > "$RUNNER_TEMP/tag-message.txt"
- uses: leinardi/gh-composite-actions/toolchain-record@<sha> # v1.0.0
  with:
    toolchains: rust,node
    annotation-file: ${{ runner.temp }}/tag-message.txt
- run: git tag -a "$TAG" -F "$RUNNER_TEMP/tag-message.txt"
```
