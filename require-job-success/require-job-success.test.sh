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
# Tests for require-job-success.sh, against canned GitHub API responses. Plain bash: stub gh, date
# and sleep commands, first on PATH, answer from files in a per-case fixture directory:
#
#   poll-<n>/attempt-<a>-<page>.json  runs/{id}/attempts/{a}/jobs on poll n (page 1 is fetched
#                                     once per poll); a poll with no directory reuses the last
#                                     one. No page-1 file: the jobs of the poll's all-*.json
#                                     files whose run_attempt is a. No later page: an empty list.
#   poll-<n>/all-<page>.json          runs/{id}/jobs?filter=all on poll n (no file: an empty list)
#
# A fixture whose first line is "ERROR <message>" makes gh fail with that message, the way gh
# reports an HTTP error. A missing page is an empty list. date and sleep share a fake clock, so
# the timeout runs out in no real time.
#
# Run: bash require-job-success/require-job-success.test.sh

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/require-job-success.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

repo=leinardi/example
run_id=42

mkdir "${work}/bin"

cat >"${work}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == api ]] || { echo "stub gh: unexpected call $*" >&2; exit 99; }
url="${*: -1}"
echo "${url}" >>"${STUB_DIR}/calls"
poll_dir() {
	local poll n
	poll="$(cat "${STUB_DIR}/poll")"
	for ((n = poll; n >= 1; n--)); do
		if [[ -d "${STUB_DIR}/poll-${n}" ]]; then
			echo "${STUB_DIR}/poll-${n}"
			return
		fi
	done
}
answer() {
	local dir
	dir="$(poll_dir)"
	if [[ -z "${dir}" || ! -f "${dir}/$1" ]]; then
		echo "$2"
		return
	fi
	if [[ "$(head -n1 "${dir}/$1")" == ERROR* ]]; then
		sed -n '1s/^ERROR //p' "${dir}/$1" >&2
		exit 1
	fi
	cat "${dir}/$1"
}
if [[ "${url}" =~ ^repos/[^/]+/[^/]+/actions/runs/([0-9]+)/attempts/([0-9]+)/jobs\?per_page=100\&page=([0-9]+)$ ]]; then
	attempt="${BASH_REMATCH[2]}"
	page="${BASH_REMATCH[3]}"
	if ((page == 1)); then
		echo $(($(cat "${STUB_DIR}/poll") + 1)) >"${STUB_DIR}/poll"
	fi
	fallback='{"total_count":0,"jobs":[]}'
	dir="$(poll_dir)"
	if ((page == 1)) && [[ -n "${dir}" && ! -f "${dir}/attempt-${attempt}-1.json" ]] &&
		compgen -G "${dir}/all-*.json" >/dev/null; then
		fallback="$(cat "${dir}"/all-*.json | jq -cs --argjson a "${attempt}" \
			'[.[].jobs[] | select(.run_attempt == $a)] | {total_count: length, jobs: .}')"
	fi
	answer "attempt-${attempt}-${page}.json" "${fallback}"
elif [[ "${url}" =~ ^repos/[^/]+/[^/]+/actions/runs/([0-9]+)/jobs\?filter=all\&per_page=100\&page=([0-9]+)$ ]]; then
	answer "all-${BASH_REMATCH[2]}.json" '{"total_count":0,"jobs":[]}'
else
	echo "stub gh: unexpected api call ${url}" >&2
	exit 99
fi
STUB

cat >"${work}/bin/date" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == +%s ]] || { echo "stub date: unexpected call $*" >&2; exit 99; }
cat "${STUB_DIR}/clock"
STUB

cat >"${work}/bin/sleep" <<'STUB'
#!/usr/bin/env bash
[[ "$1" =~ ^[0-9]+$ ]] || { echo "stub sleep: unexpected call $*" >&2; exit 99; }
echo $(($(cat "${STUB_DIR}/clock") + $1)) >"${STUB_DIR}/clock"
STUB

chmod +x "${work}/bin/"*

failures=0
case_dir=""

pass() { echo "ok - $1"; }
fail() {
	echo "not ok - $1" >&2
	failures=$((failures + 1))
}

# A fresh fixture directory for the next case.
fixture() {
	case_dir="$(mktemp -d "${work}/case.XXXXXX")"
	echo 0 >"${case_dir}/poll"
	echo 1000000 >"${case_dir}/clock"
}

# A job: the defaults (audit, succeeded, id 100, attempt 1 of run $run_id), with the JSON object
# $1 merged over them. The html_url follows the merged id.
job() {
	jq -cn --arg repo "${repo}" --argjson run "${run_id}" --argjson over "${1:-null}" '
		{id: 100, name: "audit", run_id: $run, run_attempt: 1, status: "completed", conclusion: "success"}
		+ ($over // {})
		| .html_url = (.html_url // "https://github.com/\($repo)/actions/runs/\($run)/job/\(.id)")
	'
}

# jobs FILE POLL JOB...: a jobs list fixture (all-<page>.json or attempt-<a>-<page>.json) on poll POLL.
jobs() {
	local file="$1" poll="$2"
	shift 2
	mkdir -p "${case_dir}/poll-${poll}"
	if (($# == 0)); then
		echo '{"total_count":0,"jobs":[]}' >"${case_dir}/poll-${poll}/${file}"
	else
		printf '%s\n' "$@" | jq -cs '{total_count: length, jobs: .}' >"${case_dir}/poll-${poll}/${file}"
	fi
}

# all POLL JOB...: the one filter=all page on poll POLL; each attempt's list follows from it.
all() {
	local poll="$1"
	shift
	jobs all-1.json "${poll}" "$@"
}

# raw POLL FILE CONTENT: a fixture file as given (an ERROR line, or a broken body).
raw() {
	mkdir -p "${case_dir}/poll-$1"
	printf '%s\n' "$3" >"${case_dir}/poll-$1/$2"
}

# The script against the current fixture, with extra VAR=value settings. Sets status, err, out.
invoke() {
	out_file="${case_dir}/output"
	: >"${out_file}"
	set +e
	err="$(env PATH="${work}/bin:${PATH}" STUB_DIR="${case_dir}" GITHUB_OUTPUT="${out_file}" \
		REPOSITORY="${repo}" RUN_ID="${run_id}" RUN_ATTEMPT=1 JOB=audit INTERVAL=10 TIMEOUT=30 \
		"$@" bash "${script}" 2>&1 >/dev/null)"
	status=$?
	set -e
	out="$(cat "${out_file}")"
}

# expect_pass NAME JOB_ID ATTEMPT [VAR=value...]
expect_pass() {
	local name="$1" id="$2" attempt="$3"
	shift 3
	invoke "$@"
	if ((status == 0)) && grep -qx "job-id=${id}" <<<"${out}" && grep -qx "job-attempt=${attempt}" <<<"${out}" &&
		grep -qx "job-url=https://github.com/${repo}/actions/runs/${run_id}/job/${id}" <<<"${out}"; then
		pass "${name}"
	else
		fail "${name}: status ${status}, outputs [${out}], stderr: ${err}"
	fi
}

# expect_fail NAME MESSAGE [VAR=value...]: a non-zero exit, MESSAGE in stderr, no outputs.
expect_fail() {
	local name="$1" message="$2"
	shift 2
	invoke "$@"
	if ((status != 0)) && [[ "${err}" == *"${message}"* && "${err}" == *"nothing was changed"* && -z "${out}" ]]; then
		pass "${name}"
	else
		fail "${name}: status ${status}, outputs [${out}], want '${message}' in stderr: ${err}"
	fi
}

polls() { cat "${case_dir}/poll"; }

# expect_polls NAME N: the last case read the current attempt's list exactly N times.
expect_polls() {
	if [[ "$(polls)" == "$2" ]]; then
		pass "$1"
	else
		fail "$1: $(polls) polls, want $2"
	fi
}

# expect_true NAME COMMAND...: COMMAND succeeds.
expect_true() {
	local name="$1"
	shift
	if "$@"; then
		pass "${name}"
	else
		fail "${name}"
	fi
}

release_running() { job '{"id":200,"name":"release","status":"in_progress","conclusion":null}'; }
hint="only this attempt's execution counts: \"Re-run failed jobs\" does not re-run a job that passed, so re-run the run with \"Re-run all jobs\", or re-run 'audit' too"

# expect_err NAME TEXT: the last case's stderr holds TEXT.
expect_err() {
	if [[ "${err}" == *"$2"* ]]; then
		pass "$1"
	else
		fail "$1: want '$2' in stderr: ${err}"
	fi
}

# expect_no_call NAME PATTERN: the last case made no API call matching PATTERN.
expect_no_call() {
	if ! grep -q -- "$2" "${case_dir}/calls" 2>/dev/null; then
		pass "$1"
	else
		fail "$1: a call matched '$2'"
	fi
}

# --- the plain verdicts -----------------------------------------------------------------------

fixture
all 1 "$(release_running)" "$(job)"
expect_pass "a passed job passes at once" 100 1
expect_polls "a passed job: one poll" 1
expect_no_call "a passed job: no filter=all call" "filter=all"

fixture
all 1 "$(job '{"conclusion":"failure"}')"
expect_fail "a failed job fails" "concluded 'failure', not success"

for conclusion in cancelled skipped timed_out action_required neutral stale startup_failure; do
	fixture
	all 1 "$(job "{\"conclusion\":\"${conclusion}\"}")"
	expect_fail "a ${conclusion} job fails" "concluded '${conclusion}', not success"
done

fixture
all 1 "$(job '{"conclusion":null}')"
expect_fail "a completed job without a conclusion fails" "concluded 'none', not success"

fixture
all 1 "$(job '{"status":"weird"}')"
expect_fail "an unknown status fails closed" "unknown status 'weird'"

fixture
all 1 "$(job)" "$(job '{"id":101}')"
expect_fail "two jobs of that name in one attempt fail" "attempt 1 has 2 jobs named 'audit'"

fixture
all 1 "$(job)" "$(job '{"id":101,"conclusion":"failure"}')"
expect_fail "a failed twin does not hide behind a passed one" "has 2 jobs named 'audit'"

fixture
all 1 "$(job)" "$(job)"
expect_pass "the same job listed twice counts once" 100 1

fixture
all 1 "$(job '{"id":101,"name":"audit / extra","conclusion":"failure"}')" "$(job '{"name":"Audit","conclusion":"failure","id":102}')" "$(job)"
expect_pass "only the exact name counts" 100 1

fixture
all 1 "$(job '{"name":"cargo-deny"}')"
expect_pass "the job input names the job" 100 1 JOB=cargo-deny

fixture
all 1 "$(job '{"id":"100"}')"
expect_fail "a job without a numeric id fails closed" "has no usable id"

fixture
jobs attempt-1-1.json 1 "$(job '{"run_attempt":"1"}')"
expect_fail "a job of that name without a numeric run_attempt fails closed" "could not parse the jobs of run ${run_id} attempt 1"

fixture
jobs attempt-1-1.json 1 "$(job '{"run_attempt":0}')"
expect_fail "a job of that name with run_attempt 0 fails closed" "could not parse the jobs"

fixture
jobs attempt-1-1.json 1 "$(job '{"run_attempt":1.5}')"
expect_fail "a job of that name with a fractional run_attempt fails closed" "could not parse the jobs"

fixture
jobs attempt-1-1.json 1 "$(job '{"run_id":null}')"
expect_fail "a job of that name without a run_id fails closed" "could not parse the jobs"

# --- waiting ----------------------------------------------------------------------------------

fixture
all 1 "$(release_running)" "$(job '{"status":"queued","conclusion":null}')"
all 2 "$(release_running)" "$(job '{"status":"in_progress","conclusion":null}')"
all 3 "$(release_running)" "$(job)"
expect_pass "a queued job is waited for, then passes" 100 1
expect_polls "queued, running, passed: three polls" 3

fixture
all 1 "$(release_running)"
all 2 "$(release_running)" "$(job '{"status":"queued","conclusion":null}')"
all 3 "$(release_running)" "$(job)"
expect_pass "a job not listed yet is waited for, then passes" 100 1

fixture
all 1 "$(release_running)" "$(job '{"status":"in_progress","conclusion":null}')"
all 2 "$(release_running)" "$(job '{"conclusion":"failure"}')"
expect_fail "a running job that then fails fails" "concluded 'failure'"

for status in queued in_progress waiting pending requested; do
	fixture
	all 1 "$(job "{\"status\":\"${status}\",\"conclusion\":null}")"
	expect_fail "a job ${status} until the timeout fails" \
		"gave up after 1 min: the 'audit' job of run ${run_id} attempt 1 (https://github.com/${repo}/actions/runs/${run_id}/job/100) is ${status}" \
		TIMEOUT=1 INTERVAL=30
done

fixture
all 1 "$(job '{"status":"in_progress","conclusion":null}')"
invoke env -u INTERVAL -u TIMEOUT
expect_true "the defaults: 30 min, polled every 10 s, then fail" \
	test "${status}" != 0 -a "$(polls)" = 181
expect_err "the defaults: the timeout message" "gave up after 30 min"

fixture
all 1 "$(release_running)"
expect_fail "a job that never appears fails at the timeout" "gave up after 30 min: run ${run_id} attempt 1 has no job named 'audit' yet; nothing"
expect_no_call "attempt 1 has no earlier attempts to look up" "filter=all"

fixture
all 1 "$(job '{"status":"queued","conclusion":null}')"
expect_fail "timeout 0 checks once" "gave up after 0 min" TIMEOUT=0
expect_polls "timeout 0: one poll" 1

fixture
all 1 "$(job '{"status":"queued","conclusion":null}')"
expect_fail "a short timeout with a long interval gives up" "gave up after 1 min" TIMEOUT=1 INTERVAL=45
expect_polls "timeout 1 at 45 s: three polls" 3

# --- only the current attempt decides ---------------------------------------------------------

# Re-run failed jobs: audit passed in attempt 1 and is not re-run, so attempt 2 has no execution
# of it. The gate waits and times out, and says how to make it pass.
fixture
all 1 "$(job)" "$(job '{"id":200,"name":"release","conclusion":"failure"}')" \
	"$(job '{"id":300,"name":"release","run_attempt":2,"status":"in_progress","conclusion":null}')"
expect_fail "re-run failed jobs: an attempt-1 pass not listed in attempt 2 never passes" \
	"gave up after 0 min: run ${run_id} attempt 2 has no job named 'audit' yet (attempt(s) 1 of this run have one, but ${hint})" \
	RUN_ATTEMPT=2 TIMEOUT=0
expect_true "re-run failed jobs: filter=all was read for the hint" grep -q "filter=all" "${case_dir}/calls"
echo 0 >"${case_dir}/poll"
echo 1000000 >"${case_dir}/clock"
expect_fail "re-run failed jobs: the default timeout runs out with the hint" "gave up after 30 min: run ${run_id} attempt 2 has no job named 'audit' yet (attempt(s) 1" RUN_ATTEMPT=2
expect_polls "re-run failed jobs: polled until the timeout" 181

fixture
jobs attempt-2-1.json 1 "$(job)" "$(job '{"id":300,"name":"release","run_attempt":2,"status":"in_progress","conclusion":null}')"
expect_fail "re-run failed jobs: an attempt-1 pass the attempt-2 list carries over never passes" \
	"run ${run_id} attempt 2 has no job named 'audit' yet (attempt(s) 1 of this run have one, but ${hint})" \
	RUN_ATTEMPT=2 TIMEOUT=0
expect_no_call "a carried-over job gives the hint without filter=all" "filter=all"

fixture
all 1 "$(job)" "$(job '{"id":101,"run_attempt":2}')" "$(job '{"id":102,"run_attempt":3,"status":"in_progress","conclusion":null}')"
expect_fail "the hint names every earlier attempt" "(attempt(s) 1, 2, 3 of this run have one" RUN_ATTEMPT=4 TIMEOUT=0

fixture
all 1 "$(release_running)"
expect_fail "attempt 2 with no audit anywhere gives no hint" "attempt 2 has no job named 'audit' yet; nothing" RUN_ATTEMPT=2 TIMEOUT=0

# The finding this rule exists for: re-run all jobs, and the new audit not listed yet anywhere.
fixture
all 1 "$(job)"
all 2 "$(job)" "$(job '{"id":101,"run_attempt":2,"status":"in_progress","conclusion":null}')"
all 3 "$(job)" "$(job '{"id":101,"run_attempt":2,"conclusion":"failure"}')"
expect_fail "re-run all jobs: an audit not listed yet is waited for, never passed on attempt 1" \
	"the 'audit' job of run ${run_id} attempt 2 (https://github.com/${repo}/actions/runs/${run_id}/job/101) concluded 'failure'" RUN_ATTEMPT=2
expect_polls "re-run all jobs, audit listed late: three polls" 3

fixture
all 1 "$(job)"
all 2 "$(job)" "$(job '{"id":101,"run_attempt":2}')"
expect_pass "re-run all jobs: an audit listed late that passes passes" 101 2 RUN_ATTEMPT=2

fixture
all 1 "$(job)"
expect_fail "re-run all jobs: an audit never listed times out, never passes" "gave up after 0 min: run ${run_id} attempt 2 has no job named 'audit' yet" RUN_ATTEMPT=2 TIMEOUT=0

fixture
all 1 "$(job '{"conclusion":"failure"}')" "$(job '{"id":101,"run_attempt":2}')"
expect_pass "an attempt-1 failure and an attempt-2 pass passes" 101 2 RUN_ATTEMPT=2

fixture
all 1 "$(job)" "$(job '{"id":101,"run_attempt":2,"conclusion":"failure"}')"
expect_fail "an attempt-1 pass and an attempt-2 failure fails" \
	"the 'audit' job of run ${run_id} attempt 2 (https://github.com/${repo}/actions/runs/${run_id}/job/101) concluded 'failure'" RUN_ATTEMPT=2

fixture
jobs attempt-2-1.json 1 "$(job)" "$(job '{"id":101,"run_attempt":2,"conclusion":"failure"}')"
expect_fail "a carried-over pass in the attempt list does not outvote the current failure" "attempt 2 (" RUN_ATTEMPT=2

for status in queued in_progress waiting pending requested; do
	fixture
	all 1 "$(job)" "$(job "{\"id\":101,\"run_attempt\":2,\"status\":\"${status}\",\"conclusion\":null}")"
	expect_fail "re-run all jobs: attempt 2's ${status} audit is waited for, not passed on attempt 1" \
		"gave up after 0 min: the 'audit' job of run ${run_id} attempt 2" RUN_ATTEMPT=2 TIMEOUT=0
done

fixture
all 1 "$(job)" "$(job '{"id":101,"run_attempt":2}')" "$(job '{"id":102,"run_attempt":2,"conclusion":"failure"}')"
expect_fail "two audits in the current attempt fail" "attempt 2 has 2 jobs named 'audit'" RUN_ATTEMPT=2

fixture
all 1 "$(job)"
raw 1 all-1.json "ERROR gh: HTTP 502"
jobs attempt-2-1.json 1
expect_fail "an API error while looking up earlier attempts fails closed" "HTTP 502" RUN_ATTEMPT=2

fixture
jobs attempt-2-1.json 1
raw 1 all-1.json '{"message":"odd"}'
expect_fail "a filter=all body without jobs fails closed" "has no jobs array" RUN_ATTEMPT=2

fixture
jobs attempt-2-1.json 1
jobs all-1.json 1 "$(job '{"run_attempt":"1"}')"
expect_fail "a malformed earlier job fails closed" "could not parse the jobs of run ${run_id}" RUN_ATTEMPT=2

# --- other attempts and runs ------------------------------------------------------------------

fixture
jobs attempt-1-1.json 1 "$(job)" "$(job '{"id":101,"run_attempt":2,"conclusion":"failure"}')"
expect_pass "a job from an attempt newer than the current one is ignored (pass)" 100 1

fixture
jobs attempt-1-1.json 1 "$(job '{"conclusion":"failure"}')" "$(job '{"id":101,"run_attempt":2}')"
expect_fail "a job from an attempt newer than the current one is ignored (fail)" "attempt 1 (" RUN_ATTEMPT=1

fixture
jobs attempt-1-1.json 1 "$(job '{"id":101,"run_attempt":2}')"
expect_fail "only a newer attempt's job: none yet" "attempt 1 has no job named 'audit' yet" TIMEOUT=0

fixture
jobs attempt-1-1.json 1 "$(job '{"run_id":99}')"
expect_fail "another run's job is ignored" "no job named 'audit'" TIMEOUT=0

fixture
jobs attempt-1-1.json 1 "$(job '{"id":101,"run_id":99,"conclusion":"failure"}')" "$(job)"
expect_pass "another run's failed job does not count as a duplicate" 100 1

fixture
jobs attempt-2-1.json 1 "$(job '{"id":101,"run_id":99,"run_attempt":2}')"
expect_fail "another run's pass in the current attempt does not count" "attempt 2 has no job named 'audit' yet" RUN_ATTEMPT=2 TIMEOUT=0

# --- the API failing --------------------------------------------------------------------------

fixture
raw 1 attempt-1-1.json "ERROR gh: Resource not accessible by integration (HTTP 403)"
expect_fail "HTTP 403 on the jobs list fails closed" "(HTTP 403)"

fixture
raw 1 attempt-1-1.json "ERROR gh: Not Found (HTTP 404)"
expect_fail "HTTP 404 on the jobs list fails closed" "(HTTP 404)"

fixture
all 1 "$(job '{"status":"queued","conclusion":null}')"
raw 2 attempt-1-1.json "ERROR gh: HTTP 500"
expect_fail "an API error while waiting fails closed at once" "HTTP 500"

fixture
raw 1 attempt-1-1.json '{"jobs": ['
expect_fail "a malformed body fails closed" "returned malformed JSON"

fixture
raw 1 attempt-1-1.json '[]'
expect_fail "a body that is not an object fails closed" "returned malformed JSON"

fixture
raw 1 attempt-1-1.json '{"message":"odd"}'
expect_fail "a body without a jobs array fails closed" "has no jobs array"

fixture
raw 1 attempt-1-1.json '{"jobs":{"name":"audit"}}'
expect_fail "a jobs field that is not an array fails closed" "has no jobs array"

# --- pagination -------------------------------------------------------------------------------

mapfile -t filler < <(for i in $(seq 1000 1099); do job "{\"id\":${i},\"name\":\"build-${i}\"}"; done)

fixture
jobs attempt-1-1.json 1 "${filler[@]}"
jobs attempt-1-2.json 1 "$(job)"
expect_pass "a job on page 2 is found" 100 1
expect_true "pagination: page 2 was read" grep -q 'page=2$' "${case_dir}/calls"

# Real jobs carry their steps and are several KiB each, so a full page is larger than one
# command-line argument may be (128 KiB): the pages must be joined without passing one as an
# argument.
pad="$(printf 'x%.0s' {1..2000})"
mapfile -t big < <(for i in $(seq 1000 1099); do job "{\"id\":${i},\"name\":\"build-${i}\",\"pad\":\"${pad}\"}"; done)
fixture
jobs attempt-1-1.json 1 "${big[@]}"
jobs attempt-1-2.json 1 "$(job)"
expect_pass "a page larger than one argument may be is read" 100 1

fixture
jobs attempt-1-1.json 1 "${filler[@]::99}" "$(job)"
jobs attempt-1-2.json 1 "$(job '{"id":101,"conclusion":"failure"}')"
expect_fail "a second audit on page 2 is a duplicate" "attempt 1 has 2 jobs named 'audit'"

fixture
jobs attempt-1-1.json 1 "${filler[@]}"
raw 1 attempt-1-2.json "ERROR gh: HTTP 502"
expect_fail "an error on page 2 fails closed" "HTTP 502"

# --- bad inputs -------------------------------------------------------------------------------

fixture
expect_fail "a bad repository is refused" "is not owner/name" REPOSITORY=nope
expect_fail "an empty repository is refused" "is not owner/name" REPOSITORY=
expect_fail "run id 0 is refused" "run id '0' is not a positive integer" RUN_ID=0
expect_fail "a non-numeric run id is refused" "run id 'x1' is not a positive integer" RUN_ID=x1
expect_fail "an empty run id is refused" "run id '' is not a positive integer" RUN_ID=
expect_fail "run attempt 0 is refused" "run attempt '0' is not a positive integer" RUN_ATTEMPT=0
expect_fail "a non-numeric run attempt is refused" "run attempt '1a'" RUN_ATTEMPT=1a
expect_fail "an empty job is refused" "job is empty" JOB=
invoke env -u JOB
expect_true "an unset job is refused" grep -q "job is empty" <<<"${err}"
expect_fail "a zero interval is refused" "interval '0'" INTERVAL=0
expect_fail "an empty interval is refused" "interval ''" INTERVAL=
expect_fail "a negative timeout is refused" "timeout '-1'" TIMEOUT=-1
expect_fail "a non-numeric timeout is refused" "timeout 'x'" TIMEOUT=x
expect_fail "an empty timeout is refused" "timeout ''" TIMEOUT=
expect_true "bad inputs make no API call" test ! -e "${case_dir}/calls"

if ((failures > 0)); then
	echo "${failures} test(s) failed" >&2
	exit 1
fi
echo "All require-job-success tests passed."
