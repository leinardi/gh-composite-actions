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
# Tests for require-ci-green.sh, against canned GitHub API responses. Plain bash: stub gh, date
# and sleep commands, first on PATH, answer from files in a per-case fixture directory:
#
#   poll-<n>/runs-<page>.json          the workflow runs list on poll n (page 1 is fetched once
#                                      per poll); a poll with no directory reuses the last one
#   poll-<n>/jobs-<id>-<attempt>.json  the jobs of that run attempt on poll n
#   poll-<n>/run-<id>.json             run id as re-read after its jobs passed on poll n (no
#                                      file: the run as that poll's runs list shows it)
#
# A fixture whose first line is "ERROR <message>" makes gh fail with that message, the way gh
# reports an HTTP error; a first line "ONCE <message>" does so once, and is then dropped. A missing runs page is an empty list; a missing jobs file is a 404.
# date and sleep share a fake clock, so the timeout runs out in no real time.
#
# Run: bash require-ci-green/require-ci-green.test.sh

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/require-ci-green.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

repo=leinardi/example
sha="$(printf 'a%.0s' {1..40})"
other_sha="$(printf 'b%.0s' {1..40})"

mkdir "${work}/bin"

cat >"${work}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == api ]] || { echo "stub gh: unexpected call $*" >&2; exit 99; }
url="${*: -1}"
echo "${url}" >>"${STUB_DIR}/calls"
answer() {
	local poll dir
	poll="$(cat "${STUB_DIR}/poll")"
	dir=""
	for ((n = poll; n >= 1; n--)); do
		if [[ -d "${STUB_DIR}/poll-${n}" ]]; then
			dir="${STUB_DIR}/poll-${n}"
			break
		fi
	done
	if [[ -z "${dir}" || ! -f "${dir}/$1" ]]; then
		[[ -n "$2" ]] && { echo "$2"; return; }
		echo "gh: Not Found (HTTP 404)" >&2
		exit 1
	fi
	if [[ "$(head -n1 "${dir}/$1")" == ERROR* ]]; then
		sed -n '1s/^ERROR //p' "${dir}/$1" >&2
		exit 1
	fi
	if [[ "$(head -n1 "${dir}/$1")" == ONCE* ]]; then
		sed -n '1s/^ONCE //p' "${dir}/$1" >&2
		sed -i 1d "${dir}/$1"
		exit 1
	fi
	cat "${dir}/$1"
}
if [[ "${url}" =~ ^repos/[^/]+/[^/]+/actions/runs\?head_sha=([0-9a-f]{40})\&exclude_pull_requests=true\&per_page=100\&page=([0-9]+)$ ]]; then
	page="${BASH_REMATCH[2]}"
	if ((page == 1)); then
		echo $(($(cat "${STUB_DIR}/poll") + 1)) >"${STUB_DIR}/poll"
	fi
	answer "runs-${page}.json" '{"total_count":0,"workflow_runs":[]}'
elif [[ "${url}" =~ ^repos/[^/]+/[^/]+/actions/runs/([0-9]+)$ ]]; then
	id="${BASH_REMATCH[1]}"
	run="$(answer "run-${id}.json" "-")"
	if [[ "${run}" == - ]]; then
		# No re-read fixture: the run as the runs list of this poll shows it.
		poll="$(cat "${STUB_DIR}/poll")"
		for ((n = poll; n >= 1; n--)); do
			[[ -d "${STUB_DIR}/poll-${n}" ]] && break
		done
		run="$(cat "${STUB_DIR}/poll-${n}"/runs-*.json | jq -c --argjson id "${id}" 'first(.workflow_runs[] | select(.id == $id)) // empty')"
		[[ -n "${run}" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
	fi
	echo "${run}"
elif [[ "${url}" =~ ^repos/[^/]+/[^/]+/actions/runs/([0-9]+)/attempts/([0-9]+)/jobs\?per_page=100\&page=1$ ]]; then
	answer "jobs-${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json" ""
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

# A workflow run: the defaults (a green push of ci.yaml on main at $sha), with the JSON object
# $1 merged over them.
run() {
	jq -cn --arg sha "${sha}" --arg repo "${repo}" --argjson over "${1:-null}" '{
		id: 1, run_number: 1, run_attempt: 1, status: "completed", conclusion: "success",
		path: ".github/workflows/ci.yaml", head_sha: $sha, event: "push", head_branch: "main",
		created_at: "2026-11-01T00:00:00Z", head_repository: {full_name: $repo},
		html_url: "https://github.com/\($repo)/actions/runs/\(($over // {}).id // 1)"
	} + ($over // {})'
}

# A job: the defaults (ci-result, succeeded, attempt 1 on $sha), with $1 merged over them.
job() {
	jq -cn --arg sha "${sha}" --argjson over "${1:-null}" '{
		name: "ci-result", status: "completed", conclusion: "success", head_sha: $sha, run_attempt: 1
	} + ($over // {})'
}

# runs POLL PAGE RUN...: the runs list page PAGE on poll POLL.
runs() {
	local poll="$1" page="$2"
	shift 2
	mkdir -p "${case_dir}/poll-${poll}"
	printf '%s\n' "$@" | jq -cs '{total_count: length, workflow_runs: .}' >"${case_dir}/poll-${poll}/runs-${page}.json"
}

# jobs POLL ID ATTEMPT JOB...: the jobs of run ID attempt ATTEMPT on poll POLL.
jobs() {
	local poll="$1" id="$2" attempt="$3"
	shift 3
	mkdir -p "${case_dir}/poll-${poll}"
	printf '%s\n' "$@" | jq -cs '{total_count: length, jobs: .}' >"${case_dir}/poll-${poll}/jobs-${id}-${attempt}.json"
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
		REPOSITORY="${repo}" SHA="${sha}" DEFAULT_BRANCH=main INTERVAL=20 TIMEOUT=30 \
		"$@" bash "${script}" 2>&1 >/dev/null)"
	status=$?
	set -e
	out="$(cat "${out_file}")"
}

# expect_pass NAME RUN_ID ATTEMPT [VAR=value...]
expect_pass() {
	local name="$1" id="$2" attempt="$3"
	shift 3
	invoke "$@"
	if ((status == 0)) && grep -qx "run-id=${id}" <<<"${out}" && grep -qx "run-attempt=${attempt}" <<<"${out}" &&
		grep -qx "run-url=https://github.com/${repo}/actions/runs/${id}" <<<"${out}"; then
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

# expect_polls NAME N: the last case polled the runs list exactly N times.
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

# --- the plain verdicts -----------------------------------------------------------------------

fixture
runs 1 1 "$(run '{"id":7}')"
jobs 1 7 1 "$(job '{"name":"lint"}')" "$(job)"
expect_pass "green: ci-result success on a push to main passes" 7 1

fixture
runs 1 1 "$(run '{"id":7,"conclusion":"failure"}')"
jobs 1 7 1 "$(job '{"conclusion":"failure"}')"
expect_fail "red: a failed run fails" "concluded 'failure', not success"

fixture
runs 1 1 "$(run '{"id":7}')"
jobs 1 7 1 "$(job '{"conclusion":"failure"}')"
expect_fail "red: a failed ci-result in a successful run fails" "'ci-result' job of run 7 attempt 1"

for conclusion in cancelled skipped timed_out action_required neutral stale startup_failure; do
	fixture
	runs 1 1 "$(run "{\"id\":7,\"conclusion\":\"${conclusion}\"}")"
	jobs 1 7 1 "$(job)"
	expect_fail "a ${conclusion} run fails" "concluded '${conclusion}', not success"
done

fixture
runs 1 1 "$(run '{"id":7}')"
jobs 1 7 1 "$(job '{"conclusion":"skipped"}')"
expect_fail "a skipped ci-result job fails" "concluded 'skipped', not success"

fixture
runs 1 1 "$(run '{"id":7}')"
jobs 1 7 1 "$(job '{"name":"lint"}')"
expect_fail "a run without a ci-result job fails" "has no job named 'ci-result'"

fixture
runs 1 1 "$(run '{"id":7}')"
jobs 1 7 1 "$(job)" "$(job)"
expect_fail "duplicate ci-result jobs fail" "has 2 jobs named 'ci-result'"

fixture
runs 1 1 "$(run '{"id":7}')"
jobs 1 7 1 "$(job '{"name":"build / ci-result","conclusion":"failure"}')" "$(job)"
expect_pass "a job only named like ci-result does not count as a duplicate" 7 1

fixture
runs 1 1 "$(run '{"id":7}')"
jobs 1 7 1 "$(job '{"head_sha":"'"${other_sha}"'"}')"
expect_fail "a ci-result job on another SHA fails" "is not on ${sha} attempt 1"

fixture
runs 1 1 "$(run '{"id":7,"job":"tests"}')"
jobs 1 7 1 "$(job '{"name":"tests"}')"
expect_pass "the job input names the job that must succeed" 7 1 JOB=tests

# --- waiting ----------------------------------------------------------------------------------

fixture
runs 1 1 "$(run '{"id":7,"status":"queued","conclusion":null}')"
runs 2 1 "$(run '{"id":7,"status":"in_progress","conclusion":null}')"
runs 3 1 "$(run '{"id":7}')"
jobs 3 7 1 "$(job)"
expect_pass "pending then green: polling waits for the run to finish" 7 1
expect_polls "pending then green: three polls" 3

fixture
runs 1 1 "$(run '{"id":7}')"
jobs 1 7 1 "$(job '{"status":"in_progress","conclusion":null}')"
runs 2 1 "$(run '{"id":7}')"
jobs 2 7 1 "$(job)"
expect_pass "a ci-result job not yet complete is waited for" 7 1

for status in queued in_progress waiting pending; do
	fixture
	runs 1 1 "$(run "{\"id\":7,\"status\":\"${status}\",\"conclusion\":null}")"
	expect_fail "a run ${status} until the timeout fails" "gave up after 1 min: run 7 attempt 1 (https://github.com/${repo}/actions/runs/7) is ${status}" \
		TIMEOUT=1 INTERVAL=30
done

fixture
runs 1 1 "$(run '{"id":7,"status":"in_progress","conclusion":null}')"
expect_fail "the default timeout is 30 min" "gave up after 30 min: run 7 attempt 1"
expect_polls "the timeout polls every interval for 30 min" 91

fixture
expect_fail "a missing run until the timeout fails" "gave up after 30 min: no run of .github/workflows/ci.yaml on ${sha}"

fixture
runs 1 1 "$(run '{"status":"queued","conclusion":null}')"
expect_fail "timeout 0 checks once" "gave up after 0 min" TIMEOUT=0
expect_polls "timeout 0: one poll" 1

fixture
runs 1 1 "$(run '{"status":"queued","conclusion":null}')"
expect_fail "a short timeout with a long interval gives up" "gave up after 1 min" TIMEOUT=1 INTERVAL=45
expect_polls "timeout 1 at 45 s: three polls" 3

# --- which runs count -------------------------------------------------------------------------

fixture
runs 1 1 "$(run '{"id":8,"run_number":9,"path":".github/workflows/other.yaml"}')"
jobs 1 8 1 "$(job)"
expect_fail "a green ci-result in an unrelated workflow is ignored" "gave up after 0 min: no run" TIMEOUT=0

fixture
runs 1 1 "$(run '{"id":8,"run_number":9,"path":".github/workflows/other.yaml","name":"CI"}')" \
	"$(run '{"id":7,"conclusion":"failure"}')"
jobs 1 8 1 "$(job)"
expect_fail "a newer unrelated workflow does not shadow a red CI run" "run 7 attempt 1"

fixture
runs 1 1 "$(run '{"id":7,"path":".github/workflows/ci.yml"}')"
jobs 1 7 1 "$(job)"
expect_pass "the workflow input names the workflow file" 7 1 WORKFLOW=.github/workflows/ci.yml

fixture
runs 1 1 "$(run '{"id":8,"head_sha":"'"${other_sha}"'"}')"
jobs 1 8 1 "$(job)"
expect_fail "a run the API returns for another SHA is ignored" "no run of" TIMEOUT=0

fixture
runs 1 1 "$(run '{"id":8,"event":"pull_request"}')"
jobs 1 8 1 "$(job)"
expect_fail "a run for an event that is not accepted is ignored" "no run of" TIMEOUT=0

fixture
runs 1 1 "$(run '{"id":8,"head_branch":"feature"}')"
jobs 1 8 1 "$(job)"
expect_fail "a push on a branch other than the default is ignored" "no run of" TIMEOUT=0

fixture
runs 1 1 "$(run '{"id":8,"head_repository":{"full_name":"someone/example"}}')"
jobs 1 8 1 "$(job)"
expect_fail "a run from a fork is ignored" "no run of" TIMEOUT=0

fixture
runs 1 1 "$(run '{"id":7,"event":"workflow_dispatch","head_branch":"release/v1.2.3"}')"
jobs 1 7 1 "$(job)"
expect_fail "workflow_dispatch on release/<tag> is ignored by default" "no run of" TIMEOUT=0
expect_pass "workflow_dispatch on release/<tag> passes when listed" 7 1 \
	ACCEPTED_EVENTS="push workflow_dispatch:release/v1.2.3"
expect_pass "accepted-events may be newline separated" 7 1 \
	ACCEPTED_EVENTS=$'push\nworkflow_dispatch:release/v1.2.3'
expect_fail "workflow_dispatch on another release branch is ignored" "no run of" TIMEOUT=0 \
	ACCEPTED_EVENTS="workflow_dispatch:release/v1.2.4"
expect_fail "bare workflow_dispatch means the default branch only" "no run of" TIMEOUT=0 \
	ACCEPTED_EVENTS="workflow_dispatch"

fixture
runs 1 1 "$(run '{"id":7,"head_branch":"master"}')"
jobs 1 7 1 "$(job)"
expect_pass "bare push follows default-branch" 7 1 DEFAULT_BRANCH=master
expect_pass "push:<branch> names the branch" 7 1 DEFAULT_BRANCH=main ACCEPTED_EVENTS="push:master"

fixture
runs 1 1 "$(run '{"id":7,"conclusion":"failure"}')" "$(run '{"id":9,"run_number":2}')"
jobs 1 9 1 "$(job)"
expect_pass "the newest run (highest run_number) decides: green" 9 1

fixture
runs 1 1 "$(run '{"id":9,"run_number":2,"conclusion":"failure"}')" "$(run '{"id":7}')"
jobs 1 7 1 "$(job)"
expect_fail "the newest run (highest run_number) decides: red" "run 9 attempt 1"

fixture
runs 1 1 "$(run '{"id":9,"run_number":2,"created_at":"2026-11-02T00:00:00Z"}')" \
	"$(run '{"id":7,"run_number":2,"conclusion":"failure"}')"
jobs 1 9 1 "$(job)"
expect_pass "on a run_number tie the latest created_at decides" 9 1

# --- reruns -----------------------------------------------------------------------------------

fixture
runs 1 1 "$(run '{"id":7,"run_attempt":2}')"
jobs 1 7 1 "$(job '{"conclusion":"failure"}')"
jobs 1 7 2 "$(job '{"run_attempt":2}')"
expect_pass "a rerun turning red into green passes on the newest attempt" 7 2

fixture
runs 1 1 "$(run '{"id":7,"run_attempt":2,"conclusion":"failure"}')"
jobs 1 7 1 "$(job)"
jobs 1 7 2 "$(job '{"run_attempt":2,"conclusion":"failure"}')"
expect_fail "a rerun turning green into red fails on the newest attempt" "run 7 attempt 2"

fixture
runs 1 1 "$(run '{"id":7,"run_attempt":2}')"
jobs 1 7 2 "$(job)"
expect_fail "a job from an older attempt in the newest attempt's list fails" "is not on ${sha} attempt 2"

fixture
runs 1 1 "$(run '{"id":7}')"
jobs 1 7 1 "$(job)"
runs 2 1 "$(run '{"id":7,"run_attempt":2,"status":"in_progress","conclusion":null}')"
runs 3 1 "$(run '{"id":7,"run_attempt":2,"conclusion":"failure"}')"
jobs 3 7 2 "$(job '{"run_attempt":2,"conclusion":"failure"}')"
expect_pass "a green first poll passes at once" 7 1

# --- a new attempt between the run read and the re-read ---------------------------------------

fixture
runs 1 1 "$(run '{"id":7}')"
jobs 1 7 1 "$(job)"
raw 1 run-7.json "$(run '{"id":7,"run_attempt":2,"status":"in_progress","conclusion":null}')"
runs 2 1 "$(run '{"id":7,"run_attempt":2}')"
jobs 2 7 2 "$(job '{"run_attempt":2}')"
expect_pass "a new attempt after the jobs passed is waited for: then green passes" 7 2
expect_polls "a new attempt after the jobs passed: two polls" 2

fixture
runs 1 1 "$(run '{"id":7}')"
jobs 1 7 1 "$(job)"
raw 1 run-7.json "$(run '{"id":7,"run_attempt":2,"status":"queued","conclusion":null}')"
runs 2 1 "$(run '{"id":7,"run_attempt":2,"conclusion":"failure"}')"
jobs 2 7 2 "$(job '{"run_attempt":2,"conclusion":"failure"}')"
expect_fail "a new attempt after the jobs passed is waited for: then red fails" "run 7 attempt 2"

fixture
runs 1 1 "$(run '{"id":7}')"
jobs 1 7 1 "$(job)"
raw 1 run-7.json "$(run '{"id":7,"run_attempt":2,"status":"in_progress","conclusion":null}')"
runs 2 1 "$(run '{"id":7,"run_attempt":2,"status":"in_progress","conclusion":null}')"
expect_fail "a new attempt still running at the timeout fails" "gave up after 1 min: run 7 attempt 2" TIMEOUT=1 INTERVAL=30

fixture
runs 1 1 "$(run '{"id":7}')"
jobs 1 7 1 "$(job)"
raw 1 run-7.json "$(run '{"id":7,"run_attempt":2,"status":"in_progress","conclusion":null}')"
expect_fail "a new attempt at the last moment is not passed on the old one" "moved from attempt 1 to attempt 2" TIMEOUT=0

fixture
runs 1 1 "$(run '{"id":7}')"
jobs 1 7 1 "$(job)"
raw 1 run-7.json "$(run '{"id":7,"conclusion":"failure"}')"
expect_fail "a re-read of the same attempt that is not success fails" "re-read as completed/failure"

fixture
runs 1 1 "$(run '{"id":7}')"
jobs 1 7 1 "$(job)"
raw 1 run-7.json "$(run '{"id":7,"head_sha":"'"${other_sha}"'"}')"
expect_fail "a re-read on another SHA fails" "is not the same run"

fixture
runs 1 1 "$(run '{"id":7}')"
jobs 1 7 1 "$(job)"
raw 1 run-7.json "ERROR gh: HTTP 502"
expect_fail "HTTP 5xx on the re-read fails closed" "HTTP 502"

# --- the API failing --------------------------------------------------------------------------

fixture
raw 1 runs-1.json "ERROR gh: Resource not accessible by integration (HTTP 403)"
expect_fail "HTTP 403 on the runs list fails closed" "(HTTP 403)"

fixture
raw 1 runs-1.json "ERROR gh: HTTP 502"
expect_fail "HTTP 5xx on the runs list fails closed" "HTTP 502"

fixture
raw 1 runs-1.json "ERROR gh: Not Found (HTTP 404)"
expect_fail "HTTP 404 on the runs list fails closed" "(HTTP 404)"

fixture
runs 1 1 "$(run '{"id":7}')"
raw 1 jobs-7-1.json "ERROR gh: HTTP 503"
expect_fail "HTTP 5xx on the jobs list fails closed" "HTTP 503"

fixture
runs 1 1 "$(run '{"status":"queued","conclusion":null}')"
raw 2 runs-1.json "ERROR gh: HTTP 500"
expect_fail "an API error while waiting fails closed at once" "HTTP 500"

fixture
raw 1 runs-1.json '{"workflow_runs": ['
expect_fail "a malformed runs body fails closed" "returned malformed JSON"

fixture
raw 1 runs-1.json '{"message":"odd"}'
expect_fail "a runs body without workflow_runs fails closed" "has no workflow_runs array"

fixture
runs 1 1 "$(run '{"id":7}')"
raw 1 jobs-7-1.json 'not json'
expect_fail "a malformed jobs body fails closed" "returned malformed JSON"

fixture
runs 1 1 "$(run '{"id":7,"status":"weird"}')"
expect_fail "an unknown run status fails closed" "unknown status 'weird'"

fixture
runs 1 1 "$(run '{"id":"7"}')"
expect_fail "a run without a numeric id fails closed" "no usable id or run_attempt"

# --- pagination -------------------------------------------------------------------------------

fixture
mapfile -t filler < <(for i in $(seq 100 199); do run "{\"id\":${i},\"run_number\":${i},\"path\":\".github/workflows/other.yaml\"}"; done)
runs 1 1 "${filler[@]}"
runs 1 2 "$(run '{"id":7}')"
jobs 1 7 1 "$(job)"
expect_pass "a matching run on page 2 is found" 7 1
expect_true "pagination: page 2 was read" grep -q 'page=2$' "${case_dir}/calls"

fixture
runs 1 1 "${filler[@]}"
raw 1 runs-2.json "ERROR gh: HTTP 502"
expect_fail "an error on page 2 fails closed" "HTTP 502"

# --- retries ----------------------------------------------------------------------------------

# flaky POLL FILE MESSAGE: the fixture FILE of poll POLL fails once with MESSAGE, then answers.
flaky() {
	local file="${case_dir}/poll-$1/$2"
	{ printf 'ONCE %s\n' "$3"; cat "${file}"; } >"${file}.new"
	mv "${file}.new" "${file}"
}

# calls_to PATTERN: how many API calls matched the extended regex PATTERN.
calls_to() {
	grep -cE "$1" "${case_dir}/calls" || true
}

fixture
runs 1 1 "$(run '{"id":7}')"
jobs 1 7 1 "$(job)"
flaky 1 jobs-7-1.json "gh: Server Error (HTTP 502)"
expect_pass "a 502 on the jobs list is tried again" 7 1
expect_true "retry: the jobs list was asked twice" test "$(calls_to '/attempts/1/jobs')" = 2

fixture
runs 1 1 "$(run '{"id":7}')"
jobs 1 7 1 "$(job)"
flaky 1 runs-1.json "unexpected end of JSON input"
expect_pass "an empty error body is tried again" 7 1

fixture
runs 1 1 "$(run '{"id":7}')"
raw 1 jobs-7-1.json "ERROR gh: Server Error (HTTP 503)"
expect_fail "a 5xx on every try fails closed" "HTTP 503"
expect_true "retry: three tries in all" test "$(calls_to '/attempts/1/jobs')" = 3

fixture
runs 1 1 "$(run '{"id":7}')"
raw 1 jobs-7-1.json "ERROR gh: Forbidden (HTTP 403)"
expect_fail "a 4xx is not tried again" "HTTP 403"
expect_true "retry: a 4xx is asked once" test "$(calls_to '/attempts/1/jobs')" = 1

# Real runs are several KiB each, so a full page is larger than one command-line argument may be
# (128 KiB): the pages must be joined without passing one as an argument.
pad="$(printf 'x%.0s' {1..2000})"
mapfile -t big < <(for i in $(seq 100 199); do run "{\"id\":${i},\"run_number\":${i},\"path\":\".github/workflows/other.yaml\",\"pad\":\"${pad}\"}"; done)
fixture
runs 1 1 "${big[@]}"
runs 1 2 "$(run '{"id":7}')"
jobs 1 7 1 "$(job)"
expect_pass "a page larger than one argument may be is read" 7 1

# --- bad inputs -------------------------------------------------------------------------------

fixture
expect_fail "a short SHA is refused" "is not a full 40-hex commit SHA" SHA=abc123
expect_fail "an uppercase SHA is refused" "is not a full 40-hex commit SHA" SHA="$(printf 'A%.0s' {1..40})"
expect_fail "a bad repository is refused" "is not owner/name" REPOSITORY=nope
expect_fail "a zero interval is refused" "interval '0'" INTERVAL=0
expect_fail "a non-numeric timeout is refused" "timeout 'x'" TIMEOUT=x
expect_fail "empty accepted-events are refused" "accepted-events is empty" ACCEPTED_EVENTS=" "
expect_fail "an empty branch is refused" "has an empty branch" ACCEPTED_EVENTS="push:"
expect_fail "a bare event needs default-branch" "default-branch is empty" DEFAULT_BRANCH=
expect_fail "a bad event name is refused" "no valid event name" ACCEPTED_EVENTS="Push"
expect_fail "an empty job is refused" "job is empty" JOB=
expect_true "bad inputs make no API call" test ! -e "${case_dir}/calls"

if ((failures > 0)); then
	echo "${failures} test(s) failed" >&2
	exit 1
fi
echo "All require-ci-green tests passed."
