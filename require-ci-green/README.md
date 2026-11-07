# require-ci-green

Waits until CI has passed on one exact commit, and fails otherwise. Use it to gate a tag or a
release on the CI run of the very commit being released.

A check run name alone is never trusted, because any workflow in any file can create a job named
`ci-result`. Instead, the action passes only when all of these hold:

- **Source:** a workflow run whose `path` is the `workflow` file (default
  `.github/workflows/ci.yaml`). It is found with `actions/runs?head_sha=<sha>`, every page read,
  and the run's `head_sha` must equal `sha` exactly. Runs from a fork are ignored.
- **Event:** the run's `event` and `head_branch` match an `accepted-events` entry.
- **Result:** the newest matching run (highest `run_number`, then latest `created_at`) decides,
  through its newest `run_attempt`. That run must have concluded `success`. Its jobs, read from
  `runs/{id}/attempts/{n}/jobs` for that attempt, must contain exactly one job named `job`
  (default `ci-result`), concluded `success`.

The jobs come from the attempt-specific endpoint rather than `runs/{id}/jobs?filter=latest`. The
attempt number is read together with the run's status and conclusion, so the verdict is about
that one attempt. `filter=latest` is evaluated at the time of the second call, so a rerun that
starts in between could mix a newer attempt's jobs into the verdict on the older attempt.

**Waiting:** if no matching run exists yet, or the run or job is `queued`, `in_progress`,
`waiting`, `pending` or `requested`, the action polls every `interval` seconds for up to
`timeout` minutes, then fails.

Once the job has passed, the action reads the run again. If a newer attempt has started since the
first read (for example "re-run all jobs"), the pass on the older attempt does not count: the
action keeps waiting and judges the new attempt, within the same timeout. If the same attempt no
longer reads `completed` and `success`, or the run is no longer on the same SHA and workflow
file, the action fails.

**Failing:** any other conclusion fails at once: `failure`, `cancelled`, `skipped`, `timed_out`,
`action_required`, `neutral`, `stale` or `startup_failure`. So does a missing or duplicated job,
any API error (403, 404, 5xx) and any malformed response. The message says which.

## `accepted-events` syntax

Entries are separated by spaces or newlines. Each entry is `event` or `event:branch`:

- A bare `event` means that event on `default-branch`. For example, the default `push` means a
  push to the default branch.
- `event:branch` names the branch in full. Branches are compared exactly, with no patterns.

For example, `push workflow_dispatch:release/v1.2.3` accepts a push to the default branch or a
dispatch on `release/v1.2.3`.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `sha` | `${{ github.sha }}` | The full 40-hex commit SHA CI must have passed on. |
| `workflow` | `.github/workflows/ci.yaml` | The CI workflow file, matched against the run's `path`. |
| `job` | `ci-result` | The job that must have concluded `success`. |
| `accepted-events` | `push` | The accepted `event` or `event:branch` entries (see above). |
| `default-branch` | `${{ github.event.repository.default_branch }}` | The branch a bare `accepted-events` entry stands for. |
| `interval` | `20` | Seconds between polls. |
| `timeout` | `30` | Minutes to wait for a finished run before failing (0: once). |
| `github-token` | `${{ github.token }}` | The token that reads runs and jobs. |

## Outputs

| Output | Description |
| --- | --- |
| `run-id` | The id of the workflow run that passed. |
| `run-url` | The web URL of the workflow run that passed. |
| `run-attempt` | The attempt of that run whose job passed. |

## Permissions

`actions: read`, to list workflow runs and read their jobs.

## Usage

```yaml
permissions:
  actions: read
  contents: read

steps:
  - uses: leinardi/gh-composite-actions/require-ci-green@<sha> # v1.x.y
    with:
      sha: ${{ steps.merge.outputs.sha }}
      accepted-events: push workflow_dispatch:release/${{ steps.version.outputs.tag }}
```

The logic is in `require-ci-green.sh`, which reads its settings from the environment, and its
tests are in `require-ci-green.test.sh`. They run with stub `gh`, `date` and `sleep` commands and
never touch the network.
