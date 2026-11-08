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
# Waits until one job of the current workflow run has concluded success in the current attempt,
# or fails. A release job calls it right before its first publishing step, so a check that runs
# beside it in the same run (cargo-deny's audit, say) gates the publish without sitting on the
# critical path.
#
# Which job decides: only an execution of the job in this very attempt. The jobs of the current
# attempt are listed with runs/{id}/attempts/{n}/jobs; of those whose name equals JOB exactly,
# whose run_id is RUN_ID and whose run_attempt equals RUN_ATTEMPT, there must be exactly one, and it
# decides. An execution from an earlier attempt never passes the gate, even if the list carries it.
#
# Why not fall back to an earlier attempt's pass: GitHub does not guarantee that a sibling job of
# the current attempt is listed by the time this script runs. A job missing from the lists is
# therefore never read as "not re-run": after "Re-run all jobs", the new audit may simply not be
# visible yet, and an older pass standing in for it could release on an audit that then fails. No
# field in the API says positively that a job was carried over rather than re-run.
#
# The cost: "Re-run failed jobs" does not re-run a job that passed, so that attempt has no execution
# of it, and the gate waits until the timeout and fails. Re-run the run with "Re-run all jobs" (or
# re-run that job too) so the gate sees it in this attempt. When the current attempt has no such
# job and earlier attempts do (from the current attempt's list or from runs/{id}/jobs?filter=all),
# the waiting and timeout messages say so.
#
# Environment (all required unless a default is given; a default applies only when unset):
#   REPOSITORY    owner/name of the repository (github.repository)
#   RUN_ID        the workflow run (github.run_id)
#   RUN_ATTEMPT   the attempt of that run this script runs in (github.run_attempt)
#   JOB           the exact name of the job that must succeed (its name:, or its key without one)
#   INTERVAL      seconds between polls (default 10)
#   TIMEOUT       minutes to wait before failing (default 30; 0 checks once)
#   GH_TOKEN      the token gh uses; it needs actions: read
#   GITHUB_OUTPUT when set, job-id, job-url and job-attempt are appended to it
#
# Waiting: no job of that name in the current attempt yet, or that job queued, in_progress,
# waiting, pending or requested. Passing: that job completed with conclusion success. Failing: any
# other conclusion (failure, cancelled, skipped, timed_out, action_required, neutral, stale,
# startup_failure), several jobs of that name in the current attempt, a job of that name without a
# numeric run_id or run_attempt, an unknown status, any API error or unreadable response, or the
# timeout running out. Waiting for the job that runs this script can only time out. The script
# only reads; it never changes anything.
#
# Time is read with `date +%s` and waited with `sleep`, both looked up on PATH, so a test can
# stub them with a fake clock.

set -euo pipefail
# Command substitutions stop on a failure too, so a die deep inside one stops the whole run.
shopt -s inherit_errexit

die() {
	echo "::error::require-job-success: $*; nothing was changed" >&2
	exit 1
}

note() {
	echo "require-job-success: $*" >&2
}

REPOSITORY="${REPOSITORY:-}"
RUN_ID="${RUN_ID:-}"
RUN_ATTEMPT="${RUN_ATTEMPT:-}"
JOB="${JOB:-}"
INTERVAL="${INTERVAL-10}"
TIMEOUT="${TIMEOUT-30}"

[[ "${REPOSITORY}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
	die "repository '${REPOSITORY}' is not owner/name"
[[ "${RUN_ID}" =~ ^[1-9][0-9]*$ ]] || die "run id '${RUN_ID}' is not a positive integer"
[[ "${RUN_ATTEMPT}" =~ ^[1-9][0-9]*$ ]] || die "run attempt '${RUN_ATTEMPT}' is not a positive integer"
[[ -n "${JOB}" ]] || die "job is empty"
[[ "${INTERVAL}" =~ ^[1-9][0-9]*$ ]] || die "interval '${INTERVAL}' is not a positive number of seconds"
[[ "${TIMEOUT}" =~ ^(0|[1-9][0-9]*)$ ]] || die "timeout '${TIMEOUT}' is not a whole number of minutes"

# One API call. Prints the response; stops the run on any error, with gh's own message (which
# carries the HTTP status) and on any body that is not a JSON object.
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
# skipped. The cap is far above the jobs one run can have.
list_all() {
	local url="$1" field="$2" page=1 body items all='[]' count sep='?'
	[[ "${url}" != *\?* ]] || sep='&'
	while :; do
		body="$(api "${url}${sep}per_page=100&page=${page}")"
		items="$(jq -c --arg f "${field}" '.[$f] | if type == "array" then . else error("no array") end' \
			<<<"${body}" 2>/dev/null)" || die "the GitHub API call ${url} (page ${page}) has no ${field} array"
		all="$(jq -c --argjson more "${items}" '. + $more' <<<"${all}")"
		count="$(jq 'length' <<<"${items}")"
		((count == 100)) || break
		page=$((page + 1))
		((page <= 50)) || die "the GitHub API call ${url} returned more than 50 pages"
	done
	printf '%s\n' "${all}"
}

# The jobs named JOB in the array $1 that belong to this run, of any attempt (exact duplicates, the
# same job listed twice, collapse into one). A job of that name without a numeric run_id or a usable
# run_attempt fails closed rather than being dropped.
named_jobs() {
	jq -c --arg name "${JOB}" --argjson run "${RUN_ID}" '
		[.[] | select(type == "object" and .name == $name)]
		| if any(.[]; (.run_id | type) != "number") then error("bad run_id") else . end
		| [.[] | select(.run_id == $run)]
		| if any(.[]; (.run_attempt | type) != "number" or .run_attempt < 1 or .run_attempt != (.run_attempt | floor))
		then error("bad run_attempt") else . end
		| unique
	' <<<"$1" 2>/dev/null
}

# Why the current attempt has no job of that name, for the waiting message: when earlier attempts
# of this run have one, they are named, with how to make the gate see the job in this attempt. The
# earlier attempts come from the current attempt's list when it carries them, else from
# runs/{id}/jobs?filter=all. They only explain the wait; they never decide.
missing_reason() {
	local named="$1" earlier
	local reason="run ${RUN_ID} attempt ${RUN_ATTEMPT} has no job named '${JOB}' yet"
	if ((RUN_ATTEMPT > 1)); then
		earlier="$(jq -r --argjson attempt "${RUN_ATTEMPT}" \
			'[.[] | select(.run_attempt < $attempt) | .run_attempt] | unique | map(tostring) | join(", ")' <<<"${named}")"
		if [[ -z "${earlier}" ]]; then
			local all
			all="$(list_all "repos/${REPOSITORY}/actions/runs/${RUN_ID}/jobs?filter=all" jobs)"
			all="$(named_jobs "${all}")" || die "could not parse the jobs of run ${RUN_ID}"
			earlier="$(jq -r --argjson attempt "${RUN_ATTEMPT}" \
				'[.[] | select(.run_attempt < $attempt) | .run_attempt] | unique | map(tostring) | join(", ")' <<<"${all}")"
		fi
		if [[ -n "${earlier}" ]]; then
			reason+=" (attempt(s) ${earlier} of this run have one, but only this attempt's execution counts:"
			reason+=" \"Re-run failed jobs\" does not re-run a job that passed, so re-run the run with"
			reason+=" \"Re-run all jobs\", or re-run '${JOB}' too)"
		fi
	fi
	printf '%s\n' "${reason}"
}

# The verdict on the current state, in WAITING: why it must wait, or empty for a pass (with the
# job's outputs written). A failure stops the run with its reason.
verdict() {
	WAITING=""
	local listed named mine count id url status conclusion
	listed="$(list_all "repos/${REPOSITORY}/actions/runs/${RUN_ID}/attempts/${RUN_ATTEMPT}/jobs" jobs)"
	named="$(named_jobs "${listed}")" || die "could not parse the jobs of run ${RUN_ID} attempt ${RUN_ATTEMPT}"
	mine="$(jq -c --argjson attempt "${RUN_ATTEMPT}" '[.[] | select(.run_attempt == $attempt)]' <<<"${named}")"
	count="$(jq 'length' <<<"${mine}")"
	if ((count == 0)); then
		WAITING="$(missing_reason "${named}")"
		return
	fi
	((count == 1)) ||
		die "run ${RUN_ID} attempt ${RUN_ATTEMPT} has ${count} jobs named '${JOB}'; exactly one is trusted"

	id="$(jq -r '.[0].id | if type == "number" then tostring else "" end' <<<"${mine}")"
	url="$(jq -r '.[0].html_url // ""' <<<"${mine}")"
	status="$(jq -r '.[0].status // ""' <<<"${mine}")"
	conclusion="$(jq -r '.[0].conclusion // ""' <<<"${mine}")"
	[[ "${id}" =~ ^[0-9]+$ ]] || die "the '${JOB}' job of run ${RUN_ID} attempt ${RUN_ATTEMPT} has no usable id"
	local what="the '${JOB}' job of run ${RUN_ID} attempt ${RUN_ATTEMPT} (${url:-no url})"

	case "${status}" in
	queued | in_progress | waiting | pending | requested)
		WAITING="${what} is ${status}"
		return
		;;
	completed) ;;
	*) die "${what} has the unknown status '${status}'" ;;
	esac
	[[ "${conclusion}" == success ]] || die "${what} concluded '${conclusion:-none}', not success"

	note "${what} succeeded"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		{
			echo "job-id=${id}"
			echo "job-url=${url}"
			echo "job-attempt=${RUN_ATTEMPT}"
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
