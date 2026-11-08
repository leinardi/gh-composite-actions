# trivy-gate

Installs Trivy, its latest release unless `trivy-version` pins one (through
`aquasecurity/setup-trivy`, pinned by SHA), and scans an image for vulnerabilities. The gate fails
on any finding at the given severities (default `HIGH,CRITICAL`), after the findings with no fix
upstream (`ignore-unfixed`, on by default) and the exceptions in `.trivyignore.yaml` (when that file
exists) are left out.

With `baseline-image`, the image the scanned one was built on, both are scanned the same way on
one platform, and only the findings the image **adds** to the baseline fail the gate. A finding
both carry is upstream's, which nothing in the repository can fix: it is reported as a warning and
in the step summary, and a rebuild on upstream's next digest ships the fix. A finding is the same
when its package, version, vulnerability, severity and place agree (an OS package is placed by its
distribution).

`severity`, `ignore-unfixed` and `format` passed as an empty string are refused, not taken as
their defaults; an empty `platform`, `ignorefile` or `report` means none (Trivy's platform choice,
no exceptions, the default path).

Nothing else decides what the gate sees. Trivy would otherwise load `./.trivyignore` when no
`--ignorefile` is given, `./trivy.yaml` when no `--config` is given, and any `TRIVY_*` variable
(`TRIVY_SEVERITY`, `TRIVY_IGNOREFILE`, `TRIVY_SKIP_*`, …). So both flags are always passed (an empty
value disables the file, per Trivy's flag definitions since at least 0.75.0), and every `TRIVY_*`
variable is removed from Trivy's environment except the registry credentials `TRIVY_USERNAME`,
`TRIVY_PASSWORD` and `TRIVY_REGISTRY_TOKEN`; the removed names are listed in a notice. A mirror set
through `TRIVY_DB_REPOSITORY` is removed too.

The scanned image's full report is written in the chosen format to `report`. The gate always
reads Trivy's JSON; other formats are converted from it with `trivy convert`.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `trivy-version` | no | `latest` | The Trivy release: `latest`, so every scan runs the newest checks, or `X.Y.Z`/`vX.Y.Z` to pin one. |
| `image` | yes |  | The image to scan, best by digest (`registry/name@sha256:…`). |
| `platform` | no | `""` | The one platform to scan (`os/arch[/variant]`) of a multi-platform image. Required with `baseline-image`. Empty: Trivy picks the runner's platform. |
| `baseline-image` | no | `""` | The image the scanned one was built on, best by digest. Set: only the findings it does not carry fail. |
| `severity` | no | `HIGH,CRITICAL` | The severities that fail the gate, comma-separated. |
| `ignore-unfixed` | no | `true` | Leave out the vulnerabilities with no fix upstream. |
| `ignorefile` | no | `.trivyignore.yaml` | Trivy's exceptions file. Used only when it exists; empty means none. |
| `format` | no | `json` | The report's format: `json`, `table`, `sarif`, `cyclonedx`, `spdx-json` or `github`. |
| `report` | no | `""` | The report's path. Empty: `trivy-report.<json\|sarif\|txt>` in `RUNNER_TEMP`. |

## Outputs

| Name | Description |
| --- | --- |
| `report` | The path of the scanned image's report. |
| `findings` | How many findings failed the gate (with `baseline-image`, the added ones). |

## Permissions

`contents: read`: setup-trivy checks out Trivy's install script from the public
`aquasecurity/trivy` repository with the job's token. A private image needs the registry login
(`docker login`, or `TRIVY_USERNAME`/`TRIVY_PASSWORD`) in an earlier step. `jq` must be on the
runner (it is on every GitHub-hosted one).

## Caching

setup-trivy's cache stores only the Trivy binary (keyed by version, OS and architecture), never the
vulnerability database, which Trivy downloads on every run. The action keeps that cache off, so a
release job neither reads an entry another ref's run wrote nor writes one: the release keeps its
own cache scope, at the price of a few seconds of download.

## Usage

```yaml
- uses: leinardi/gh-composite-actions/trivy-gate@<sha> # v1.0.0
  with:
    image: ghcr.io/leinardi/example@${{ steps.build.outputs.digest }}
    platform: linux/arm64
```

Against the base, as swarm-rootless-docker gates its image:

```yaml
- uses: leinardi/gh-composite-actions/trivy-gate@<sha> # v1.0.0
  with:
    image: localhost:5000/example@${{ steps.build.outputs.digest }}
    baseline-image: docker.io/library/docker@${{ env.BASE_DIGEST }}
    platform: linux/amd64
```

For an image that is already published, where a finding can only be reported, add
`continue-on-error: true` to the step. The Trivy version is bumped by hand, in `action.yaml`.
