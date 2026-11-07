# release-version

Resolves the version and tag to release, and checks that it may be released. Nothing is
written: the outputs are for the steps that tag and publish.

- **Explicit:** `version` is `X.Y.Z`, `vX.Y.Z` or `<tag-prefix>X.Y.Z`.
- **Derived:** with no `version`, svu computes the next version from the Conventional Commits
  since the highest release tag reachable from `HEAD`. svu is given that exact tag, never a
  glob, so a stray tag such as `v1.9.0-rc.1` cannot become the base. Only `feat`, `fix` and
  breaking changes bump; with none since the last release, the run fails with "nothing to
  bump". A `.svu.yml` in the repository is ignored, so it cannot change those rules.

A release tag is `<tag-prefix>MAJOR.MINOR.PATCH`, strict SemVer core: no leading zeros, no
pre-release, no build metadata. Every lookup filters through that one regex, so `latest`, `v1`
and other prefixes' tags (`v1.2.3` when the prefix is `foo--v`, and the other way round) are
never releases. The version must be:

- higher than every release tag of the prefix, except on a **recovery**: the tag already points
  at `HEAD`, so this re-runs a release that created it and failed afterwards. When the highest
  release is tagged on a commit outside the branch, the failure says so;
- not lower than `floor-version`, when given. The floor is inclusive, applies to explicit,
  derived and recovered versions alike, and never raises a derived version: a derived version
  below it fails and asks for an explicit one.

Needs a checkout with the full history and every tag (`fetch-depth: 0`, `fetch-tags: true`; a
shallow clone fails), and svu on `PATH` when `version` is empty: run
[`setup-svu`](../setup-svu/README.md) first. This action does not install it.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `version` | no | `""` | Version to release. Empty: derive it with svu. |
| `tag-prefix` | no | `v` | Text before `X.Y.Z` in a release tag, such as `v` or `<plugin>--v`. Letters, digits and `.`, `_`, `/`, `-` only. |
| `floor-version` | no | `""` | Lowest version that may be released, `X.Y.Z` or `vX.Y.Z`, such as the version a manifest already carries. |

## Outputs

| Name | Description |
| --- | --- |
| `version` | `X.Y.Z`, with no prefix. |
| `tag` | `<tag-prefix>X.Y.Z`. |
| `previous` | Highest release tag before this one in the branch's history, or empty. |
| `explicit` | `true` when `version` was given. |
| `recovery` | `true` when the tag already points at `HEAD`. |
| `major` | The moving major tag, `<tag-prefix>MAJOR` (`v1`, `<plugin>--v1`). |

## Permissions

`contents: read`, for the checkout.

## Usage

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  with:
    fetch-depth: 0
    fetch-tags: true
- uses: leinardi/gh-composite-actions/setup-svu@<sha> # v1.0.0
- id: version
  uses: leinardi/gh-composite-actions/release-version@<sha> # v1.0.0
  with:
    version: ${{ inputs.version }}
    tag-prefix: gtk-rs-skills--v
    floor-version: ${{ steps.manifest.outputs.version }}
- run: echo "Releasing $TAG"
  env:
    TAG: ${{ steps.version.outputs.tag }}
```

The logic is `release-version.sh`; `release-version.test.sh` runs it against throwaway
repositories with an svu stub, or with a real svu when `RELEASE_VERSION_TEST_SVU` names one.
