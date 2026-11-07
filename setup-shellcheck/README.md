# setup-shellcheck

Installs a [ShellCheck](https://github.com/koalaman/shellcheck) release binary for the tools that
run the `shellcheck` they find on `PATH`: actionlint's `-shellcheck` over the workflows' `run:`
scripts, and droast's ShellCheck bridge. The archive is downloaded over HTTPS only, checked with
`sha256sum --check --strict`, unpacked under `$RUNNER_TEMP` and added to `PATH`, ahead of the
runner image's own `shellcheck`. No `sudo`. Linux X64 runners only.

Keep `version` in step with the `shellcheck-py` rev in the caller's `.pre-commit-config.yaml`, so
local hooks and CI run the same release.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `version` | no | `v0.11.0` | ShellCheck release tag, `vX.Y.Z`. |
| `sha256` | no | `8c3be12b…7198` | SHA-256 of `shellcheck-<version>.linux.x86_64.tar.xz`, from `gh api repos/koalaman/shellcheck/releases/tags/<version>`. Override together with `version`: a version without its own digest fails the check. |

## Outputs

| Name | Description |
| --- | --- |
| `path` | The directory holding `shellcheck`, as added to `PATH`. |

## Permissions

None beyond the default: the download is a public release asset.

## Usage

```yaml
- uses: leinardi/gh-composite-actions/setup-shellcheck@<sha> # v1.0.0
- run: actionlint -shellcheck shellcheck
```
