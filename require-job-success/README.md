# require-job-success

Waits until one job of the current workflow run has concluded `success`, and fails otherwise. Use
it right before a job's first publishing step, so a check that runs beside it in the same run (an
`audit` job running cargo-deny, say) gates the publish without a `needs:` that keeps the check on
the critical path: the job builds and tests at once, and waits only where it must.

## Which job decides

Only the job's execution in **this attempt** (`github.run_attempt`). The action reads this
attempt's jobs from `runs/{run_id}/attempts/{attempt}/jobs`, every page, and keeps the jobs whose
`name` equals `job` exactly, whose `run_id` is this run and whose `run_attempt` equals this
attempt. There must be **exactly one**, and it decides. A job of an earlier or a later attempt, or
of another run, never decides, even when the list carries it.

### Why an earlier attempt's pass never counts

GitHub does not guarantee that a sibling job of the current attempt is already listed when this
action runs. After "Re-run all jobs", the new `audit` may simply not be visible yet; letting an
earlier attempt's pass stand in for it could publish on an audit that then fails. The API has no
field that says positively that a job was carried over rather than re-run, so a missing job is
never read as "not re-run": the action waits for this attempt's own execution.

### Re-runs

- **Re-run all jobs:** the job runs again in this attempt, and that execution decides.
- **Re-run failed jobs:** a job that passed is not re-run, so this attempt has no execution of it.
  The action waits until `timeout` and fails, and its message names the earlier attempts that have
  the job. Re-run the run with "Re-run all jobs", or re-run that job too, so the gate sees it in
  this attempt.

**Waiting:** while this attempt has no job of that name yet, or that job is `queued`,
`in_progress`, `waiting`, `pending` or `requested`, the action polls every `interval` seconds for
up to `timeout` minutes, then fails. Waiting for the job the action runs in can only time out.

**Failing:** any other conclusion fails at once: `failure`, `cancelled`, `skipped`, `timed_out`,
`action_required`, `neutral`, `stale` or `startup_failure`. So do several jobs of that name in this
attempt, an unknown status, a job of that name without a numeric `run_id` or `run_attempt`, any API
error (403, 404, a 5xx that persists) and any malformed response. The message says which, and the
action never changes anything. A 5xx answer, or an empty error body, is tried again first: three
tries in all, 5 s apart, since GitHub's job lists answer 502 now and then.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `job` | (required) | The exact name of the job that must conclude `success`: its `name:`, or its key when it has none. |
| `interval` | `10` | Seconds between polls. |
| `timeout` | `30` | Minutes to wait for the job before failing (0: once). |
| `github-token` | `${{ github.token }}` | The token that reads the run's jobs. |

The repository, run id and run attempt come from `github.repository`, `github.run_id` and
`github.run_attempt`.

## Outputs

| Output | Description |
| --- | --- |
| `job-id` | The id of the job that passed. |
| `job-url` | The web URL of the job that passed. |
| `job-attempt` | The run attempt whose job passed: always the current one. |

## Permissions

`actions: read`, to list the run's jobs.

## Usage

```yaml
jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - run: cargo deny check advisories

  release:
    runs-on: ubuntu-latest
    permissions:
      actions: read
      contents: write
    steps:
      # build and test, with no needs: audit
      - uses: leinardi/gh-composite-actions/require-job-success@<sha> # v1.x.y
        with:
          job: audit
      # publish
```

The logic is in `require-job-success.sh`, which reads its settings from the environment, and its
tests are in `require-job-success.test.sh`. They run with stub `gh`, `date` and `sleep` commands
and never touch the network.
