#!/usr/bin/env bash
#
# MIT License
#
# Copyright (c) 2026 Roberto Leinardi
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# Waits until CI has passed on one exact commit, or fails. Passing means: a workflow run of the
# CI workflow file (matched by the run's path, never by the workflow's display name, which any
# workflow can copy) on exactly that SHA, triggered by an accepted event on an accepted branch,
# whose newest run decides, and whose newest attempt contains exactly one job with the given name
# that concluded success. A check run name alone is never trusted: any workflow, in any file, can
# create a job or check named ci-result.
#
# Environment (all required unless a default is given; a default applies only when unset):
#   REPOSITORY        owner/name of the repository whose runs are read
#   SHA               the 40-hex commit the run must be on (its head_sha, exactly)
#   WORKFLOW          the run's workflow file path (default .github/workflows/ci.yaml)
#   JOB               the job that must succeed inside that run (default ci-result)
#   ACCEPTED_EVENTS   space or newline separated "event" or "event:branch" entries
#                     (default push). A bare "event" means that event on DEFAULT_BRANCH.
#   DEFAULT_BRANCH    the branch a bare event entry stands for (needed when there is one)
#   INTERVAL          seconds between polls (default 20)
#   TIMEOUT           minutes to wait for a finished run before failing (default 30; 0 polls once)
#   GH_TOKEN          the token gh uses; it needs actions: read
#   GITHUB_OUTPUT     when set, run-id, run-url and run-attempt are appended to it
#
# Waiting: no matching run yet, a run that is queued, in progress, waiting, pending or requested,
# the job not yet complete, or a newer attempt of the run started after its jobs were read
# (re-read once they pass). Failing: a run or job concluding anything but success (failure,
# cancelled, skipped, timed_out, action_required, neutral, stale, startup_failure), no such job
# or several in the run, any API error or unreadable response, or the timeout running out.
# The script only reads; it never changes anything.
#
# Time is read with `date +%s` and waited with `sleep`, both looked up on PATH, so a test can
# stub them with a fake clock.

set -euo pipefail
# Command substitutions stop on a failure too, so a die deep inside one stops the whole run.
shopt -s inherit_errexit

die() {
	echo "::error::require-ci-green: $*; nothing was changed" >&2
	exit 1
}

note() {
	echo "require-ci-green: $*" >&2
}

REPOSITORY="${REPOSITORY:-}"
SHA="${SHA:-}"
WORKFLOW="${WORKFLOW-.github/workflows/ci.yaml}"
JOB="${JOB-ci-result}"
ACCEPTED_EVENTS="${ACCEPTED_EVENTS-push}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-}"
INTERVAL="${INTERVAL-20}"
TIMEOUT="${TIMEOUT-30}"

[[ "${REPOSITORY}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
	die "repository '${REPOSITORY}' is not owner/name"
[[ "${SHA}" =~ ^[0-9a-f]{40}$ ]] || die "sha '${SHA}' is not a full 40-hex commit SHA"
[[ -n "${WORKFLOW}" && "${WORKFLOW}" != *[[:space:]]* ]] ||
	die "workflow '${WORKFLOW}' is not a workflow file path"
[[ -n "${JOB}" ]] || die "job is empty"
[[ "${INTERVAL}" =~ ^[1-9][0-9]*$ ]] || die "interval '${INTERVAL}' is not a positive number of seconds"
[[ "${TIMEOUT}" =~ ^(0|[1-9][0-9]*)$ ]] || die "timeout '${TIMEOUT}' is not a whole number of minutes"

# The accepted (event, branch) pairs, as a JSON array for jq. Branches are compared exactly: a
# release branch is named in full (workflow_dispatch:release/v1.2.3), never by pattern, so no
# other branch's run can stand in for it.
accepted='[]'
read -r -d '' -a entries <<<"${ACCEPTED_EVENTS}" || true
((${#entries[@]} > 0)) || die "accepted-events is empty"
for entry in "${entries[@]}"; do
	event="${entry%%:*}"
	if [[ "${entry}" == *:* ]]; then
		branch="${entry#*:}"
		[[ -n "${branch}" ]] || die "accepted-events entry '${entry}' has an empty branch"
	else
		[[ -n "${DEFAULT_BRANCH}" ]] ||
			die "accepted-events entry '${entry}' means the default branch, but default-branch is empty"
		branch="${DEFAULT_BRANCH}"
	fi
	[[ "${event}" =~ ^[a-z_]+$ ]] || die "accepted-events entry '${entry}' has no valid event name"
	[[ "${branch}" != *[[:space:]]* ]] || die "accepted-events entry '${entry}' has a bad branch"
	accepted="$(jq -c --arg e "${event}" --arg b "${branch}" '. + [{event: $e, branch: $b}]' <<<"${accepted}")"
done

# One API call. Prints the response; stops the run on any error, with gh's own message (which
# carries the HTTP status) and on any body that is not JSON.
api() {
	local out err
	err="$(mktemp)"
	if ! out="$(gh api -H 'Accept: application/vnd.github+json' "$1" 2>"${err}")"; then
		local msg
		msg="$(tr '\n' ' ' <"${err}")"
		rm -f "${err}"
		die "the GitHub API call $1 failed: ${msg:-no message}"
	fi
	rm -f "${err}"
	jq -e 'type == "object"' >/dev/null 2>&1 <<<"${out}" || die "the GitHub API call $1 returned malformed JSON"
	printf '%s\n' "${out}"
}

# Every item of the array field $2 across all pages of the list endpoint $1, as one JSON array.
# Pages are walked by hand rather than with `gh api --paginate`, so a short page (fewer than
# per_page items) is the explicit end and a missing or non-array field fails instead of being
# skipped. The cap is far above what the API serves for one SHA.
list_all() {
	local url="$1" field="$2" page=1 body items all='[]' count sep='?'
	[[ "${url}" != *\?* ]] || sep='&'
	while :; do
		body="$(api "${url}${sep}per_page=100&page=${page}")"
		items="$(jq -c --arg f "${field}" '.[$f] | if type == "array" then . else error("no array") end' \
			<<<"${body}" 2>/dev/null)" || die "the GitHub API call ${url} (page ${page}) has no ${field} array"
		# Both arrays go through stdin: a page of runs or jobs can be larger than the 128 KiB a
		# single command-line argument may hold, which --argjson would need.
		all="$(jq -cs '.[0] + .[1]' <<<"${all}"$'\n'"${items}")"
		count="$(jq 'length' <<<"${items}")"
		((count == 100)) || break
		page=$((page + 1))
		((page <= 50)) || die "the GitHub API call ${url} returned more than 50 pages"
	done
	printf '%s\n' "${all}"
}

# The newest matching run on SHA, or nothing. Matching: the CI workflow file, the exact head
# SHA (the query filters on it, and the response is checked again rather than trusted), a run
# of this repository rather than a fork, and an accepted event on its accepted branch. Newest:
# the highest run_number, then the latest created_at.
newest_run() {
	local runs
	runs="$(list_all "repos/${REPOSITORY}/actions/runs?head_sha=${SHA}&exclude_pull_requests=true" workflow_runs)"
	jq -c --arg path "${WORKFLOW}" --arg sha "${SHA}" --arg repo "${REPOSITORY}" --argjson accepted "${accepted}" '
		[.[] | select(
			.path == $path
			and .head_sha == $sha
			and ((.head_repository.full_name // "") | ascii_downcase) == ($repo | ascii_downcase)
			and (.event as $e | .head_branch as $b | any($accepted[]; .event == $e and .branch == $b))
		)]
		| sort_by([.run_number, .created_at]) | last // empty
	' <<<"${runs}" 2>/dev/null || die "could not parse the workflow runs of ${SHA}"
}

# The verdict on the current state, in WAITING: why it must wait, or empty for a pass (with the
# run's outputs written). A failure stops the run with its reason.
verdict() {
	WAITING=""
	local run id attempt url status conclusion jobs count job_status job_conclusion
	run="$(newest_run)"
	if [[ -z "${run}" ]]; then
		WAITING="no run of ${WORKFLOW} on ${SHA} for an accepted event (${ACCEPTED_EVENTS//$'\n'/ }) yet"
		return
	fi
	id="$(jq -r '.id | if type == "number" then tostring else "" end' <<<"${run}")"
	attempt="$(jq -r '.run_attempt | if type == "number" then tostring else "" end' <<<"${run}")"
	url="$(jq -r '.html_url // ""' <<<"${run}")"
	status="$(jq -r '.status // ""' <<<"${run}")"
	conclusion="$(jq -r '.conclusion // ""' <<<"${run}")"
	[[ "${id}" =~ ^[0-9]+$ && "${attempt}" =~ ^[1-9][0-9]*$ ]] ||
		die "the newest run of ${WORKFLOW} on ${SHA} has no usable id or run_attempt"
	local what="run ${id} attempt ${attempt} (${url})"

	case "${status}" in
	queued | in_progress | waiting | pending | requested)
		WAITING="${what} is ${status}"
		return
		;;
	completed) ;;
	*) die "${what} has the unknown status '${status}'" ;;
	esac
	[[ "${conclusion}" == success ]] || die "${what} concluded '${conclusion:-none}', not success"

	# The jobs of exactly the attempt read above. runs/{id}/jobs?filter=latest would answer
	# "the latest jobs" at the moment of this second call, so a rerun started in between could
	# mix a newer attempt's jobs into the verdict on the older one; attempts/{n}/jobs cannot.
	jobs="$(list_all "repos/${REPOSITORY}/actions/runs/${id}/attempts/${attempt}/jobs" jobs)"
	jobs="$(jq -c --arg name "${JOB}" '[.[] | select(.name == $name)]' <<<"${jobs}" 2>/dev/null)" ||
		die "could not parse the jobs of ${what}"
	count="$(jq 'length' <<<"${jobs}")"
	((count != 0)) || die "${what} has no job named '${JOB}'"
	((count == 1)) || die "${what} has ${count} jobs named '${JOB}'; exactly one is trusted"
	jq -e --arg sha "${SHA}" --argjson attempt "${attempt}" \
		'.[0].head_sha == $sha and .[0].run_attempt == $attempt' >/dev/null <<<"${jobs}" ||
		die "the '${JOB}' job of ${what} is not on ${SHA} attempt ${attempt}"
	job_status="$(jq -r '.[0].status // ""' <<<"${jobs}")"
	job_conclusion="$(jq -r '.[0].conclusion // ""' <<<"${jobs}")"
	case "${job_status}" in
	queued | in_progress | waiting | pending | requested)
		WAITING="the '${JOB}' job of ${what} is ${job_status}"
		return
		;;
	completed) ;;
	*) die "the '${JOB}' job of ${what} has the unknown status '${job_status}'" ;;
	esac
	[[ "${job_conclusion}" == success ]] ||
		die "the '${JOB}' job of ${what} concluded '${job_conclusion:-none}', not success"

	# The run again, after its jobs passed. A "re-run all jobs" started after the first read
	# makes a newer attempt the one that decides, so a pass on the attempt read above holds
	# only if that attempt is still the newest: a changed run_attempt means waiting and judging
	# the new attempt, and a run that no longer reads completed and success fails.
	local now now_attempt now_status now_conclusion
	now="$(api "repos/${REPOSITORY}/actions/runs/${id}")"
	now_attempt="$(jq -r '.run_attempt | if type == "number" then tostring else "" end' <<<"${now}")"
	now_status="$(jq -r '.status // ""' <<<"${now}")"
	now_conclusion="$(jq -r '.conclusion // ""' <<<"${now}")"
	[[ "${now_attempt}" =~ ^[1-9][0-9]*$ ]] || die "run ${id} re-read has no usable run_attempt"
	jq -e --arg sha "${SHA}" --arg path "${WORKFLOW}" --argjson id "${id}" \
		'.id == $id and .head_sha == $sha and .path == $path' >/dev/null <<<"${now}" ||
		die "run ${id} re-read is not the same run of ${WORKFLOW} on ${SHA}"
	if ((now_attempt != attempt)); then
		WAITING="run ${id} moved from attempt ${attempt} to attempt ${now_attempt} (${url}), which decides now"
		return
	fi
	[[ "${now_status}" == completed && "${now_conclusion}" == success ]] ||
		die "${what} re-read as ${now_status:-no status}/${now_conclusion:-no conclusion}, not completed/success"

	note "${JOB} succeeded in ${what} on ${SHA}"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		{
			echo "run-id=${id}"
			echo "run-url=${url}"
			echo "run-attempt=${attempt}"
		} >>"${GITHUB_OUTPUT}"
	fi
}

deadline=$(($(date +%s) + TIMEOUT * 60))
while :; do
	verdict
	[[ -n "${WAITING}" ]] || exit 0
	if (($(date +%s) >= deadline)); then
		die "gave up after ${TIMEOUT} min: ${WAITING}"
	fi
	note "${WAITING}: checking again in ${INTERVAL} s"
	sleep "${INTERVAL}"
done
