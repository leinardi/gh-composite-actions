# setup-cargo-deny

Installs a [cargo-deny](https://github.com/EmbarkStudios/cargo-deny) release binary, so every job
that checks the dependency graph (advisories, licenses, bans, sources) runs the same release. The
musl archive is downloaded over HTTPS only, checked with `sha256sum --check --strict`, unpacked
under `$RUNNER_TEMP` and added to `PATH`; `cargo deny` then finds it. No `sudo`, no
`cargo install`. Linux X64 runners only.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `version` | no | `0.20.2` | cargo-deny release, `X.Y.Z`. |
| `sha256` | no | `9f12ed4c…8d5f` | SHA-256 of `cargo-deny-<version>-x86_64-unknown-linux-musl.tar.gz`, from the release asset's `.sha256`. Override together with `version`. |

## Outputs

| Name | Description |
| --- | --- |
| `path` | The directory holding `cargo-deny`, as added to `PATH`. |

## Permissions

None beyond the default: the download is a public release asset.

## Usage

```yaml
- uses: leinardi/gh-composite-actions/setup-cargo-deny@<sha> # v1.0.0
- run: cargo deny check
```
