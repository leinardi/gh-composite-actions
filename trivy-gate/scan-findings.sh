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
# Scans an image with Trivy and fails on its findings, or, given the base it was built on, only on
# what the image adds to that base:
#
#   scan-findings.sh IMAGE [BASE]
#
# The scan looks for vulnerabilities of the SEVERITY levels (default HIGH,CRITICAL), leaves out the
# ones with no fix upstream unless IGNORE_UNFIXED is false, and applies the exceptions in IGNOREFILE
# (default .trivyignore.yaml) when that file exists; with PLATFORMS set, it scans that one platform
# of a multi-platform image.
#
# With IMAGE alone, any finding fails the scan (exit 1).
#
# With a BASE, both are scanned the same way, on the one platform PLATFORMS must name. A finding in
# IMAGE that BASE carries too is upstream's, which nothing here can fix: it is reported as a warning
# (and in $GITHUB_STEP_SUMMARY when set), and a rebuild on upstream's next digest ships the fix. A
# finding BASE does not carry fails the scan (exit 1). A finding is the same when its package,
# version, vulnerability, severity and place agree; an OS package is placed by its distribution,
# not by the scan target's name, which differs between the two images.
#
# Either way, IMAGE's full report is written to REPORT (default $RUNNER_TEMP/trivy-report.<ext>) in
# FORMAT (json, the default, or table, sarif, cyclonedx, spdx-json, github), and REPORT and the
# number of failing findings are written to $GITHUB_OUTPUT as report and findings when it is set.
#
# Environment: PLATFORMS, SEVERITY, IGNORE_UNFIXED, IGNOREFILE, FORMAT, REPORT, and TRIVY (the
# trivy command). An unset variable takes its default; SEVERITY, IGNORE_UNFIXED and FORMAT set to
# an empty string are refused rather than defaulted, so a blank input never silently means
# "the default". An empty PLATFORMS, IGNOREFILE or REPORT means none (the runner's platform, no
# exceptions, the default path). Exit status: 0 when nothing fails the gate, 1 when something does or a scan
# fails, 2 on a bad argument.

set -euo pipefail

usage_error() {
	echo "::error::$1" >&2
	exit 2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
	echo "usage: $0 IMAGE [BASE]" >&2
	exit 2
fi
image="$1"
base="${2:-}"
severity="${SEVERITY-HIGH,CRITICAL}"
ignore_unfixed="${IGNORE_UNFIXED-true}"
ignorefile="${IGNOREFILE-.trivyignore.yaml}"
format="${FORMAT-json}"
trivy="${TRIVY:-trivy}"

valid_reference() {
	[[ -n $1 && $1 != -* && $1 != *[[:space:]]* ]]
}
valid_reference "${image}" || usage_error "IMAGE must be an image reference, got '${image}'"
if [[ $# -eq 2 ]]; then
	valid_reference "${base}" || usage_error "BASE must be an image reference, got '${base}'"
fi
if [[ -n ${base} || -n ${PLATFORMS:-} ]]; then
	# A base comparison only makes sense on one platform: the same platform of both images.
	[[ -n ${PLATFORMS:-} && ${PLATFORMS} != *,* ]] || usage_error \
		"PLATFORMS must name exactly one platform, got '${PLATFORMS:-}'"
	[[ ${PLATFORMS} =~ ^[a-z0-9]+/[a-z0-9_]+(/[a-z0-9]+)?$ ]] || usage_error \
		"PLATFORMS must be one os/arch[/variant] platform, got '${PLATFORMS}'"
fi
[[ ${severity} =~ ^(UNKNOWN|LOW|MEDIUM|HIGH|CRITICAL)(,(UNKNOWN|LOW|MEDIUM|HIGH|CRITICAL))*$ ]] ||
	usage_error "SEVERITY must be a comma-separated list of UNKNOWN, LOW, MEDIUM, HIGH and CRITICAL, got '${severity}'"
[[ ${ignore_unfixed} == true || ${ignore_unfixed} == false ]] ||
	usage_error "IGNORE_UNFIXED must be true or false, got '${ignore_unfixed}'"
case "${format}" in
json | table | sarif | cyclonedx | spdx-json | github) ;;
*) usage_error "FORMAT must be json, table, sarif, cyclonedx, spdx-json or github, got '${format}'" ;;
esac
case "${format}" in
json | sarif | cyclonedx | spdx-json | github) extension=json ;;
*) extension=txt ;;
esac
[[ ${format} == sarif ]] && extension=sarif
report="${REPORT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/trivy-report.${extension}}"
command -v jq >/dev/null || {
	echo "::error::jq is not on PATH. Nothing was scanned." >&2
	exit 1
}

# What the gate looks for, in words: "fixable HIGH or CRITICAL" by default.
levels="${severity//,/, }"
if [[ ${levels} == *", "* ]]; then
	levels="${levels%, *} or ${levels##*, }"
fi
kind="${levels}"
[[ ${ignore_unfixed} == true ]] && kind="fixable ${levels}"

# Nothing but these flags decides what the gate sees. Trivy otherwise reads exceptions and settings
# from places the caller never named: ./.trivyignore when --ignorefile is not given, ./trivy.yaml
# when --config is not given, and any TRIVY_* variable (TRIVY_SEVERITY, TRIVY_IGNOREFILE,
# TRIVY_SKIP_*, ...). Both flags are always passed, an empty value disabling the file (Trivy
# 0.75.0's pkg/flag documents "empty string disables loading" for both, and pkg/result's
# ParseIgnoreFile returns no exceptions for an empty path), and every TRIVY_* variable is removed
# from Trivy's environment except the registry credentials, which only decide whether the image
# can be pulled.
ignore_flags=(--config "")
if [[ -n ${ignorefile} && -f ${ignorefile} ]]; then
	ignore_flags+=(--ignorefile "${ignorefile}")
else
	[[ -n ${ignorefile} ]] && echo "No ${ignorefile}: the scan has no exceptions."
	ignore_flags+=(--ignorefile "")
fi
flags=("${ignore_flags[@]}" --scanners vuln --severity "${severity}")
[[ ${ignore_unfixed} == true ]] && flags+=(--ignore-unfixed)
[[ -n ${PLATFORMS:-} ]] && flags+=(--platform "${PLATFORMS}")

trivy_env=(env)
removed=()
while IFS= read -r name; do
	case "${name}" in
	TRIVY_USERNAME | TRIVY_PASSWORD | TRIVY_REGISTRY_TOKEN) ;;
	TRIVY_*)
		trivy_env+=(-u "${name}")
		removed+=("${name}")
		;;
	esac
done < <(compgen -e)
if [[ ${#removed[@]} -gt 0 ]]; then
	echo "::notice::Not passed to Trivy, so they cannot change the gate: ${removed[*]}."
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# scan REFERENCE NAME: the findings of REFERENCE, one sorted line each, in $work/NAME; its report
# in $work/NAME.json.
scan() {
	"${trivy_env[@]}" "${trivy}" image "${flags[@]}" --format json --output "${work}/$2.json" "$1"
	jq -e 'type == "object" and has("SchemaVersion")' "${work}/$2.json" >/dev/null || {
		echo "::error::Trivy's report for $1 is not a Trivy JSON report. Nothing passed the gate." >&2
		exit 1
	}
	jq -r '
		.Results[]? | . as $result | ($result.Vulnerabilities // [])[]
		| [$result.Class, (if $result.Class == "os-pkgs" then $result.Type else $result.Target end),
		   .PkgName, .InstalledVersion, .VulnerabilityID, .Severity] | join(" ")
	' "${work}/$2.json" | sort -u >"${work}/$2"
}

# The image's full report, in the format asked for, where the caller can find it.
write_report() {
	mkdir -p "$(dirname "${report}")"
	if [[ ${format} == json ]]; then
		cp "${work}/image.json" "${report}"
	else
		"${trivy_env[@]}" "${trivy}" convert "${ignore_flags[@]}" --format "${format}" \
			--output "${report}" "${work}/image.json"
	fi
}

outputs() {
	if [[ -n ${GITHUB_OUTPUT:-} ]]; then
		{
			echo "report=${report}"
			echo "findings=$1"
		} >>"${GITHUB_OUTPUT}"
	fi
}

count() {
	if [[ -z $1 ]]; then
		echo 0
	else
		wc -l <<<"$1" | tr -d ' '
	fi
}

if [[ -z ${base} ]]; then
	scan "${image}" image
	write_report
	found="$(cat "${work}/image")"
	outputs "$(count "${found}")"
	if [[ -n ${found} ]]; then
		echo "::error::${image} has $(count "${found}") ${kind} findings:"
		echo "${found}"
		exit 1
	fi
	echo "${image} has no ${kind} finding."
	exit 0
fi

scan "${base}" base
scan "${image}" image
write_report
added="$(comm -23 "${work}/image" "${work}/base")"
inherited="$(comm -12 "${work}/image" "${work}/base")"
outputs "$(count "${added}")"

if [[ -n "${inherited}" ]]; then
	echo "::warning::${image} inherits $(count "${inherited}") ${kind} findings from ${base}; a rebuild on upstream's next digest ships the fixes."
	echo "${inherited}"
	if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
		{
			echo "## Findings ${image} inherits from its base"
			echo
			echo '```text'
			echo "${inherited}"
			echo '```'
		} >>"${GITHUB_STEP_SUMMARY}"
	fi
fi
if [[ -n "${added}" ]]; then
	echo "::error::${image} adds ${kind} findings to ${base}:"
	echo "${added}"
	exit 1
fi
echo "${image} adds no ${kind} finding to ${base}."
