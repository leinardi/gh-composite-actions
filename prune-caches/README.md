# prune-caches

Deletes the older GitHub Actions cache entries of one ref under one key prefix, keeping the
newest `keep`. Each change to a cache key saves a new entry, and the old ones sit in the
repository's cache quota until GitHub evicts them, possibly pushing out entries still in use.
Run it after the step that saves the cache, typically in a warm-up workflow on the default
branch.

An entry already gone (another run, or GitHub's eviction) is not an error. Any other API error
fails the step. At most the 100 newest matching entries are looked at in one run.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `ref` | no | `${{ github.ref }}` | Ref whose entries are pruned, such as `refs/heads/main`. |
| `key-prefix` | yes |  | Cache key prefix, matched as a plain prefix. Include the separator that ends it (`pre-commit\|`), or a shorter prefix also matches other caches. |
| `keep` | no | `1` | How many of the newest matching entries to keep, a whole number >= 1. |
| `github-token` | no | `${{ github.token }}` | Token for the cache API. |

## Outputs

None.

## Permissions

`actions: write` on the calling job (listing alone needs `actions: read`). Without it the API
answers HTTP 403 "Resource not accessible by integration", and the prune is skipped with a warning
instead of failing, so a caller that does not grant it keeps working as before. Any other 403,
such as a rate limit, fails the step.

## Usage

```yaml
permissions:
  contents: read
  actions: write
steps:
  - uses: leinardi/gh-composite-actions/prune-caches@<sha> # v1.0.0
    with:
      key-prefix: "pre-commit|"
      keep: 2
```
