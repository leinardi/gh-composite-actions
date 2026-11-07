# binary-attestation-status

Lists which release files still need a build-provenance attestation, so a release recovery attests
only the binaries an earlier run did not, and never duplicates one.

For each file, the attestations of its sha256 are looked up with
`gh api repos/<repo>/attestations/sha256:<digest>`:

- **absent** (exactly the GitHub "Not Found" answer, or an empty list): the file is listed;
- **present**: the file must pass `gh attestation verify` for the signer workflow, the source ref and
  the commit, and is not listed. If it does not, it was attested by something else, which needs a
  human, and the step fails;
- **anything else** (401, 403, 429, 5xx, a network error, a body that does not parse): the step
  fails, naming the file.

The logic is in [`binary-attestation-status.sh`](binary-attestation-status.sh), runnable on its own:
`binary-attestation-status.sh <repo> <signer-workflow> <source-ref> <source-digest> <file>...`.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `files` | yes |  | The files to check, separated by whitespace or newlines |
| `repo` | no | `github.repository` | The repository, as `owner/name` |
| `signer-workflow` | no | `.github/workflows/release.yaml` | `owner/name/.github/workflows/<file>`, or a path relative to `repo` |
| `source-ref` | no | `github.ref` | The ref the signer workflow ran on |
| `source-digest` | no | `github.sha` | The commit the files were built from |
| `github-token` | no | `github.token` | The token gh uses |

## Outputs

| Output | Description |
| --- | --- |
| `missing` | The files that still need an attestation, one per line (empty when none) |
| `missing-count` | How many files still need an attestation |

## Permissions

`contents: read`. On a private repository the token also needs `attestations: read`. The step that
then attests the listed files needs `id-token: write` and `attestations: write`.

## Example

```yaml
- name: Check which binaries need an attestation
  id: binattest
  uses: leinardi/gh-composite-actions/binary-attestation-status@<sha> # v1.x.y
  with:
    files: |
      dist/example-linux-amd64
      dist/example-linux-arm64

- name: Attest the release binaries
  if: ${{ !inputs.dry_run && steps.binattest.outputs.missing != '' }}
  uses: actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8 # v4.2.2
  with:
    subject-path: ${{ steps.binattest.outputs.missing }}
```
