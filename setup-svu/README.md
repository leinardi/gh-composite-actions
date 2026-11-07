# setup-svu

Installs [svu](https://github.com/caarlos0/svu), which derives the next version from the
Conventional Commits since the last tag, from its GitHub release archive. The archive is
downloaded over HTTPS only, checked with `sha256sum --check --strict` against a pinned SHA-256,
and only the `svu` binary is unpacked into `$RUNNER_TEMP` and added to `PATH` for the rest of
the job. Its `svu --version` is printed and must report the requested version. No `sudo`, no Go
toolchain. Linux X64 and ARM64 runners only.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `version` | no | `""` | svu version, `X.Y.Z` or `vX.Y.Z`. Empty: the pinned version (3.4.1). |
| `sha256` | no | `""` | SHA-256 of `svu_<version>_linux_<amd64\|arm64>.tar.gz` for the runner's architecture, from the release's `checksums.txt`. Required with any `version` other than the pinned one. |

## Outputs

| Name | Description |
| --- | --- |
| `path` | The directory holding the `svu` binary, as added to `PATH`. |

## Permissions

None beyond the default: the download is a public release asset.

## Usage

```yaml
- uses: leinardi/gh-composite-actions/setup-svu@<sha> # v1.0.0
- run: svu next
```

The pinned version and its per-architecture checksums live in `setup-svu.sh`. Dependabot does
not track a release download, so they are bumped by hand, together.
