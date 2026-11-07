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
# Tests for scan-findings.sh. Plain bash: a stub trivy writes, for each reference it is asked to
# scan, the report saved under that reference's name in the scratch directory, and fails for a
# reference with no report. It records the flags of every scan in $work/calls, and "converts" a
# report by writing its format and input to the output.
#
# The base-comparison cases come from swarm-rootless-docker's .github/scripts/scan-findings.test.sh
# and keep its expectations; the single-image, flag and report cases are new here.
#
# Run: bash trivy-gate/scan-findings.test.sh

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/scan-findings.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

cat >"${work}/trivy" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# No TRIVY_* setting of the caller's may reach Trivy, only the registry credentials.
leaked="$(compgen -e | grep '^TRIVY_' | grep -Ev '^TRIVY_(USERNAME|PASSWORD|REGISTRY_TOKEN)$' || true)"
[[ -z "${leaked}" ]] || { echo "stub trivy: leaked ${leaked//$'\n'/ }" >&2; exit 99; }
command="$1"
shift
echo "${command} $*" >>"${STUB_DIR}/calls"
output="" platform="" reference="" format="" config="unset" ignorefile="unset"
while [[ $# -gt 0 ]]; do
	case "$1" in
	--output) output="$2"; shift 2 ;;
	--platform) platform="$2"; shift 2 ;;
	--format) format="$2"; shift 2 ;;
	--config) config="$2"; shift 2 ;;
	--ignorefile) ignorefile="$2"; shift 2 ;;
	--scanners | --severity) shift 2 ;;
	--ignore-unfixed) shift ;;
	*) reference="$1"; shift ;;
	esac
done
# Trivy's own defaults (./trivy.yaml, ./.trivyignore) must never be left to apply.
[[ "${config}" == "" ]] || { echo "stub trivy: --config '${config}', want ''" >&2; exit 99; }
want_ignorefile="$(cat "${STUB_DIR}/want-ignorefile")"
[[ "${ignorefile}" == "${want_ignorefile}" ]] || {
	echo "stub trivy: --ignorefile '${ignorefile}', want '${want_ignorefile}'" >&2
	exit 99
}
if [[ "${command}" == convert ]]; then
	echo "converted ${reference##*/} to ${format}" >"${output}"
	exit 0
fi
[[ "${command}" == image ]] || { echo "stub trivy: unexpected call ${command}" >&2; exit 99; }
[[ -z "${platform}" || "${platform}" == linux/amd64 ]] || { echo "stub trivy: platform '${platform}'" >&2; exit 99; }
report="${STUB_DIR}/$(tr '/:@' '___' <<<"${reference}").json"
[[ -f "${report}" ]] || { echo "stub trivy: cannot scan ${reference}" >&2; exit 1; }
cp "${report}" "${output}"
STUB
# The --ignorefile every call must carry: none (an empty value) unless a case says otherwise.
: >"${work}/want-ignorefile"
chmod +x "${work}/trivy"

failures=0

pass() { echo "ok - $1"; }
fail() {
	echo "not ok - $1" >&2
	failures=$((failures + 1))
}

# report REFERENCE TARGET FINDING...: the report trivy gives for REFERENCE, whose OS packages it
# names TARGET; each FINDING is "class|target|package|version|id|severity" (an os-pkgs finding's
# target is the distribution).
report() {
	local reference="$1" target="$2" finding
	shift 2
	{
		echo '{"Results": ['
		local first=true
		for finding in "$@"; do
			IFS='|' read -r class place package version id severity <<<"${finding}"
			if [[ "${class}" == os-pkgs ]]; then
				result_target="${target}" type="${place}"
			else
				result_target="${place}" type=gobinary
			fi
			${first} || echo ','
			first=false
			printf '{"Target":"%s","Class":"%s","Type":"%s","Vulnerabilities":[{"PkgName":"%s","InstalledVersion":"%s","VulnerabilityID":"%s","Severity":"%s"}]}' \
				"${result_target}" "${class}" "${type}" "${package}" "${version}" "${id}" "${severity}"
		done
		echo '], "SchemaVersion": 2}'
	} >"${work}/$(tr '/:@' '___' <<<"${reference}").json"
}

# run_scan [BASE]: scans "image", against BASE when given ("base" when no argument is given at
# all); leaves status, out and the outputs file.
run_scan() {
	local args=(image base)
	if [[ $# -gt 0 ]]; then
		args=(image "$@")
		[[ -z $1 ]] && args=(image)
	fi
	status=0
	rm -f "${work}/calls" "${work}/outputs"
	out="$(cd "${work}" && STUB_DIR="${work}" TRIVY="${work}/trivy" PLATFORMS="${PLATFORMS-linux/amd64}" \
		GITHUB_STEP_SUMMARY="${work}/summary" GITHUB_OUTPUT="${work}/outputs" RUNNER_TEMP="${work}/tmp" \
		bash "${script}" "${args[@]}" 2>&1)" || status=$?
}

expect() {
	local name="$1" want_status="$2" want_text="$3"
	if [[ "${status}" -ne "${want_status}" ]]; then
		fail "${name}: exit ${status}, want ${want_status}: ${out}"
	elif ! grep -qF -- "${want_text}" <<<"${out}"; then
		fail "${name}: want '${want_text}' in: ${out}"
	else
		pass "${name}"
	fi
}

# expect_file NAME FILE TEXT: FILE contains TEXT.
expect_file() {
	if [[ -f $2 ]] && grep -qF -- "$3" "$2"; then
		pass "$1"
	else
		fail "$1: want '$3' in $2: $(cat "$2" 2>/dev/null || echo '(no file)')"
	fi
}

# expect_no_file_text NAME FILE TEXT: FILE does not contain TEXT.
expect_no_file_text() {
	if [[ -f $2 ]] && ! grep -qF -- "$3" "$2"; then
		pass "$1"
	else
		fail "$1: want no '$3' in $2: $(cat "$2" 2>/dev/null || echo '(no file)')"
	fi
}

curl_finding="os-pkgs|alpine|libcurl|8.22.0-r0|CVE-1|HIGH"
runc_finding="lang-pkgs|usr/local/bin/runc|golang.org/x/net|v0.55.0|CVE-2|HIGH"

# --- Against a base (swarm-rootless-docker's cases) -----------------------------------------

report base "docker:29-dind-rootless (alpine 3.24.3)" "${curl_finding}" "${runc_finding}"
report image "localhost:5000/example@sha256:1 (alpine 3.24.3)" "${curl_finding}" "${runc_finding}"
run_scan
expect "the base's own findings are inherited, not failed" 0 "inherits 2 fixable HIGH or CRITICAL findings"
if grep -qF "golang.org/x/net v0.55.0 CVE-2" "${work}/summary"; then
	pass "the inherited findings are in the summary"
else
	fail "the inherited findings are not in the summary"
fi
expect_file "an inherited-only scan outputs no failing finding" "${work}/outputs" "findings=0"

report image "localhost:5000/example@sha256:1 (alpine 3.24.3)" "${curl_finding}" "${runc_finding}" \
	"lang-pkgs|usr/local/bin/swarm-rootless-docker|tokio|1.0.0|CVE-3|CRITICAL"
run_scan
expect "a finding the base does not carry fails" 1 "lang-pkgs usr/local/bin/swarm-rootless-docker tokio 1.0.0 CVE-3 CRITICAL"
expect_file "only the added finding counts" "${work}/outputs" "findings=1"

report image "localhost:5000/example@sha256:1 (alpine 3.24.3)" "os-pkgs|alpine|libcurl|8.21.0-r0|CVE-1|HIGH"
run_scan
expect "the same vulnerability in another package version fails" 1 "os-pkgs alpine libcurl 8.21.0-r0 CVE-1 HIGH"

report image "localhost:5000/example@sha256:1 (alpine 3.24.3)" "lang-pkgs|usr/local/bin/ctr|golang.org/x/net|v0.55.0|CVE-2|HIGH"
run_scan
expect "the same vulnerability in another binary fails" 1 "lang-pkgs usr/local/bin/ctr golang.org/x/net v0.55.0 CVE-2 HIGH"

report image "localhost:5000/example@sha256:1 (alpine 3.24.3)"
run_scan
expect "an image with no finding passes" 0 "adds no fixable HIGH or CRITICAL finding"

rm "${work}/base.json"
run_scan
expect "a base that cannot be scanned fails" 1 "cannot scan base"

report base "docker:29-dind-rootless (alpine 3.24.3)"
PLATFORMS="linux/amd64,linux/arm64" run_scan
expect "two platforms are refused" 2 "exactly one platform"

PLATFORMS="" run_scan
expect "a base comparison with no platform is refused" 2 "exactly one platform"

PLATFORMS="linux amd64" run_scan
expect "a malformed platform is refused" 2 "one os/arch[/variant] platform"

# --- The image alone ------------------------------------------------------------------------

report image "localhost:5000/example@sha256:1 (alpine 3.24.3)" "${curl_finding}"
PLATFORMS="" run_scan ""
expect "with no base, any finding fails" 1 "image has 1 fixable HIGH or CRITICAL findings:"
expect "with no base, the finding is listed" 1 "os-pkgs alpine libcurl 8.22.0-r0 CVE-1 HIGH"
expect_file "with no base, the failing findings are counted" "${work}/outputs" "findings=1"
expect_no_file_text "with no base and no platform, no --platform is passed" "${work}/calls" "--platform"

report image "localhost:5000/example@sha256:1 (alpine 3.24.3)"
run_scan ""
expect "with no base, an image with no finding passes" 0 "image has no fixable HIGH or CRITICAL finding."
expect_file "the platform is passed through" "${work}/calls" "--platform linux/amd64"
expect_file "the default report is JSON under RUNNER_TEMP" "${work}/outputs" "report=${work}/tmp/trivy-report.json"
expect_file "the JSON report is trivy's own" "${work}/tmp/trivy-report.json" '"SchemaVersion": 2'

rm "${work}/image.json"
run_scan ""
expect "with no base, an image that cannot be scanned fails" 1 "cannot scan image"

echo 'not json' >"${work}/image.json"
run_scan ""
expect "a report that is not Trivy JSON fails" 1 "is not a Trivy JSON report"

# --- Flags, formats and inputs --------------------------------------------------------------

report image "localhost:5000/example@sha256:1 (alpine 3.24.3)"
run_scan ""
expect_file "ignore-unfixed is on by default" "${work}/calls" "--ignore-unfixed"
expect_file "the default severities are HIGH and CRITICAL" "${work}/calls" "--severity HIGH,CRITICAL"
expect_file "a missing ignore file is passed as '', not left to Trivy's default" "${work}/calls" \
	"--config  --ignorefile  --scanners"
expect "a missing ignore file is reported" 0 "No .trivyignore.yaml: the scan has no exceptions."

echo 'vulnerabilities: []' >"${work}/.trivyignore.yaml"
echo .trivyignore.yaml >"${work}/want-ignorefile"
run_scan ""
expect "an existing ignore file is passed, on every call" 0 "image has no fixable HIGH or CRITICAL finding."
FORMAT=table run_scan ""
expect "the ignore file is passed to convert too" 0 "image has no fixable HIGH or CRITICAL finding."
rm "${work}/.trivyignore.yaml"
: >"${work}/want-ignorefile"

# A .trivyignore, Trivy's own default file, must not be loaded when the configured file is absent.
echo 'CVE-1' >"${work}/.trivyignore"
echo 'severity: [LOW]' >"${work}/trivy.yaml"
run_scan ""
expect "with the ignore file absent, --ignorefile '' and --config '' disable Trivy's defaults" 0 \
	"No .trivyignore.yaml: the scan has no exceptions."
IGNOREFILE="" run_scan ""
expect "an empty ignorefile passes --ignorefile ''" 0 "image has no fixable HIGH or CRITICAL finding."
rm "${work}/.trivyignore" "${work}/trivy.yaml"

TRIVY_IGNOREFILE=/dev/null TRIVY_SEVERITY=LOW TRIVY_IGNORE_UNFIXED=true TRIVY_SKIP_DB_UPDATE=true \
	TRIVY_USERNAME=user TRIVY_PASSWORD=secret run_scan ""
expect "no TRIVY_* variable but the registry credentials reaches Trivy" 0 \
	"Not passed to Trivy, so they cannot change the gate: "
expect "the removed variables are named" 0 "TRIVY_SKIP_DB_UPDATE"
if grep -qF TRIVY_USERNAME <<<"${out}"; then
	fail "the registry credentials are kept"
else
	pass "the registry credentials are kept"
fi

IGNORE_UNFIXED=false SEVERITY=MEDIUM,HIGH,CRITICAL run_scan ""
expect_no_file_text "ignore-unfixed false drops the flag" "${work}/calls" "--ignore-unfixed"
expect_file "the severities are passed through" "${work}/calls" "--severity MEDIUM,HIGH,CRITICAL"
expect "the message names the severities, without fixable" 0 "image has no MEDIUM, HIGH or CRITICAL finding."

FORMAT=sarif REPORT="${work}/out/scan.sarif" run_scan ""
expect_file "another format is converted from the JSON report" "${work}/out/scan.sarif" "converted image.json to sarif"
expect_file "the report output is the path asked for" "${work}/outputs" "report=${work}/out/scan.sarif"

FORMAT=table run_scan ""
expect_file "a table report defaults to a .txt file" "${work}/tmp/trivy-report.txt" "converted image.json to table"

FORMAT=xml run_scan ""
expect "an unknown format is refused" 2 "FORMAT must be"
SEVERITY=HIGH,SEVERE run_scan ""
expect "an unknown severity is refused" 2 "SEVERITY must be"
IGNORE_UNFIXED=yes run_scan ""
expect "ignore-unfixed must be true or false" 2 "IGNORE_UNFIXED must be true or false"
SEVERITY="" run_scan ""
expect "an empty severity is refused, not defaulted" 2 "SEVERITY must be"
IGNORE_UNFIXED="" run_scan ""
expect "an empty ignore-unfixed is refused, not defaulted" 2 "IGNORE_UNFIXED must be true or false, got ''"
FORMAT="" run_scan ""
expect "an empty format is refused, not defaulted" 2 "FORMAT must be"
run_scan "--base"
expect "a base that looks like a flag is refused" 2 "BASE must be an image reference"

status=0
out="$(bash "${script}" 2>&1)" || status=$?
expect "no image is a usage error" 2 "usage:"

if [[ "${failures}" -ne 0 ]]; then
	echo "${failures} check(s) failed" >&2
	exit 1
fi
echo "every check passed"
