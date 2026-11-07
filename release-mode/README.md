# release-mode

Decides what a release run does, before anything is built or pushed, and writes the decision down
as a plan: step outputs plus a JSON file. It reads the git tag, the images on the registry, the
GitHub release and its assets, verifies every published artifact, and fetches the published
binaries. It never publishes, signs, attests or uploads anything: the caller's later steps do that,
following the plan.

## The rule

Nothing published: rebuild. Anything published: reuse it, never replace it. The rule is decided per
binary and platform, so the binary inside an image and the release asset of the same name never
diverge.

| Published for binary B on platform P | `source` | What the caller does |
| --- | --- | --- |
| Image and asset | `image` | Nothing: the action has checked that they are the same bytes |
| Image only | `image` | Upload the extracted file as the asset, after attesting it |
| Asset only | `asset` | Build the image (its `prebuilt` target) with the downloaded asset |
| Neither | `rebuild` | Build B for P, attest it and upload it |

- A published image is never rebuilt, and missing assets always come from it.
- An image that is not published yet is built from the mix the table gives.
- A published image that lacks a shipped platform stops the release: a manifest list cannot gain a
  platform without changing its digest.
- Platforms are compared the way containerd's `platforms.Normalize` does, so `linux/arm64` matches
  a published `linux/arm64/v8`, `aarch64` matches `arm64`, and `linux/arm` matches
  `linux/arm/v7`. Two published images that are the same platform stop the release. Asset names,
  `platform_digests` keys and `rebuild` entries keep the spelling given in `platforms`.
- With several images (`images`), every published image that holds a binary must hold the same
  bytes, and an image that is not published is built with them.

"Published" means the image tag exists on the registry, or the release, draft or not, carries the
asset. Each published artifact must be attested by the signer workflow for the source ref and the
head commit (`gh attestation verify`). Each published image must also carry the signer workflow's
keyless cosign signature.

## Modes

| Git tag | Published | `mode` |
| --- | --- | --- |
| absent | nothing | `fresh` |
| absent | an image, or a release | `stop` (`image-without-tag`, `release-without-tag`) |
| on another commit |  | `stop` (`tag-on-other-commit`) |
| on HEAD | every image, and no binary to rebuild | `reuse` |
| on HEAD | anything less | `publish` |

A tag on HEAD must be in the clone (`fetch-tags: true`) and annotated. Its annotation must carry
every `expected-toolchains` line exactly.

`stop` exits 1 after writing the outputs and the plan. Its `reason` is one of:

- `required-job-failed`
- `lookup-failed`
- `tag-on-other-commit`, `tag-not-fetched`, `tag-not-annotated`
- `annotation-missing-toolchain`, `toolchain-mismatch`
- `image-without-tag`, `release-without-tag`
- `image-unattested`, `image-unsigned`, `image-missing-platform`, `image-binary-missing`,
  `image-binary-symlink`, `image-duplicate-platform`,
  `image-binaries-differ`
- `asset-unattested`, `asset-differs-from-image`, `unexpected-asset`
- `checksums-conflict`

Any lookup that fails for a reason other than "not found" also stops the release, with
`lookup-failed`.

**Moving pointers.** `move-pointers` is true only when this tag is the highest release tag on the
remote. When the release is already published, the action warns if GitHub's Latest release or an
image's `:latest` disagrees with that. It moves nothing: the pointer steps of the highest version's
run repoint them, as the source workflows do.

**Dry runs.** `build` is always true in a dry run, so the run rehearses a build whatever the mode.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `tag` | yes |  | The git tag being released |
| `platforms` | yes |  | e.g. `linux/amd64,linux/arm64` |
| `image` | no | `""` | `ghcr.io/owner/name`, holding every binary |
| `images` | no | `""` | Instead of `image`: lines `<ref> [binary[=/path]]...` |
| `binaries` | no | `""` | The release binaries (empty: image-only release) |
| `image-binary-paths` | no | `""` | Lines `<binary>=/path/in/image` (default `/usr/local/bin/<binary>`) |
| `asset-pattern` | no | `{binary}-{os}-{arch}{variant}` | The asset name; `{variant}` is `-<variant>` or nothing |
| `checksums-name` | no | `checksums.txt` | The checksums asset |
| `image-tag` | no | the tag | The image tag of the version, e.g. `1.2.3` |
| `tag-regex` | no | strict `vX.Y.Z` | What a release tag looks like |
| `expected-toolchains` | no | `""` | `Name: version` lines the tag annotation must carry |
| `required-results` | no | `""` | Job results that must all be `success`, e.g. the audit job's |
| `dry-run` | no | `false` | Whether this is a dry run |
| `repo` | no | `github.repository` | `owner/name` |
| `head-sha` | no | `github.sha` | The commit being released |
| `source-ref` | no | `github.ref` | The ref the signer workflow runs on |
| `signer-workflow` | no | `.github/workflows/release.yaml` | Relative to `repo`, or `owner/name/.github/workflows/<file>` |
| `signer-issuer` | no | GitHub Actions OIDC | The cosign certificate issuer |
| `out-dir` | no | `$RUNNER_TEMP/release-mode` | Where the plan and the fetched binaries go |
| `install-cosign` | no | `true` | Install cosign v3 (pinned `sigstore/cosign-installer`) |
| `github-token` | no | `github.token` | The token gh uses |

## Outputs

| Output | Description |
| --- | --- |
| `mode` | `fresh`, `publish`, `reuse` or `stop` |
| `reason` | The stop reason (empty otherwise) |
| `build` | Whether anything must be built (or this is a dry run) |
| `tag-exists` | Whether the tag already exists on this commit |
| `release-state` | `absent`, `draft` or `published` |
| `build-images` / `reuse-images` | Image references, space-separated |
| `rebuild` | `binary@os/arch` entries to build, space-separated |
| `upload-files` | Fetched binaries (from images) to upload, one path per line |
| `checksums` | `upload`, `verify` (regenerate it; it must equal `published-<name>` in `out-dir`) or `none` |
| `move-pointers` | Whether this version is the highest release tag |
| `plan-file` | The JSON plan |

## Plan file

`out-dir` also holds:

- `assets/<asset>`, for every binary whose source is `image` or `asset`. Copy these into the
  directory the image's `prebuilt` target reads, after building the `rebuild` entries, so the
  published bytes win.
- `published-<checksums-name>`, when one is published.

```jsonc
{
  "schema_version": 1,
  "mode": "fresh | publish | reuse | stop",
  "reason": "",                 // stop only, see Modes
  "message": "",                // stop only, human-readable
  "repo": "owner/name",
  "tag": "v1.2.3",
  "image_tag": "v1.2.3",
  "head_sha": "<40 hex>",
  "tag_exists": true,
  "dry_run": false,
  "build": false,
  "release": { "state": "absent | draft | published | unknown", "assets": ["<name>"] },
  "checksums": { "name": "checksums.txt", "action": "upload | verify | none" },
  "pointers": { "highest_tag": "v1.2.3", "move": true },
  "images": [
    {
      "ref": "ghcr.io/owner/name",
      "state": "published | absent | unknown",
      "digest": "sha256:… or empty",
      "action": "reuse | build | empty (stopped before it)",
      "binaries": ["name"],
      "binary_paths": { "name": "/usr/local/bin/name" },
      "platform_digests": { "linux/amd64": "sha256:…" }
    }
  ],
  "binaries": [
    {
      "binary": "name",
      "platform": "linux/amd64",
      "asset": "name-linux-amd64",
      "source": "image | asset | rebuild",
      "image": "the image it was extracted from, or empty",
      "asset_published": false,
      "sha256": "the published bytes' sha256, or empty for rebuild",
      "checksums_sha256": "the published checksums entry, or empty",
      "file": "<out-dir>/assets/name-linux-amd64, or empty for rebuild",
      "upload": true
    }
  ],
  "upload": ["<out-dir>/assets/name-linux-arm64"],
  "rebuild": ["name@linux/arm64"],
  "warnings": []
}
```

On `stop`, `images` and `binaries` hold only what was decided before the stop.

## Requirements and permissions

- **Checkout:** `fetch-depth: 0` and `fetch-tags: true`, with an `origin` remote. The tag check
  uses `git ls-remote origin`.
- **Tools:** docker with buildx (`imagetools inspect`, plus `create`/`cp` to extract a binary
  without running the image), `gh` and `jq`. All are on GitHub's Ubuntu runners.
- **Registry:** log in first (`docker/login-action`) when the images are private.
- **Permissions:** `contents: read`. Seeing a **draft** release needs push access, so a release job
  runs this with the `contents: write` it already holds. Private repositories also need
  `packages: read` and `attestations: read`.

## Example

```yaml
- name: Decide the release mode
  id: mode
  uses: leinardi/gh-composite-actions/release-mode@<sha> # v1.x.y
  with:
    tag: ${{ steps.version.outputs.tag }}
    image-tag: ${{ steps.version.outputs.version }}
    image: ghcr.io/leinardi/example
    binaries: example
    platforms: linux/amd64,linux/arm64
    dry-run: ${{ inputs.dry_run }}
    expected-toolchains: |
      Rust: ${{ steps.toolchains.outputs.rust }}
```
