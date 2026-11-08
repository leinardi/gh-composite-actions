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
# Tests for check-pinned-bases.sh, against the Dockerfiles in fixtures/. Plain bash, no network:
# each case runs the check from this directory and compares its stdout (the findings, one
# "FILE:LINE: message" each) and its exit status with what the case expects.
#
# The synthetic fixtures each exercise one rule. The others are copies of the real Dockerfiles from
# the default branches of awtrix-controller, swarm-rootless-docker, herdquay and bitgauge (taken
# when this check was written; bitgauge's GPL header swapped for this repository's MIT one, by the
# same author), which do not pin their bases yet: their expected findings are
# recorded here, and their *.pinned.Dockerfile variants (each external base given a made-up digest)
# show what passes once they do. herdquay's fetch stage downloads Docker's apt key with curl and
# checks its fingerprint, not a checksum, so its pinned variant still has that one finding;
# herdquay.pinned-verified.Dockerfile adds the sha256 check and passes.
#
# Run: bash check-pinned-bases/check-pinned-bases.test.sh

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/check-pinned-bases.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

failures=0
digest="$(printf 'e5%.0s' {1..32})"

# check NAME WANT_STATUS [VAR=VALUE...] [-- ARGUMENT...]: runs the check, with the environment
# assignments (GITHUB_ACTIONS unset unless one sets it) and the arguments, and compares its stdout
# with the expected findings read from stdin.
check() {
	local name="$1" want_status="$2" want got status=0
	shift 2
	local assignments=()
	while [[ $# -gt 0 && $1 != -- ]]; do
		assignments+=("$1")
		shift
	done
	[[ $# -gt 0 ]] && shift
	want="$(cat)"
	got="$(cd "${here}" && env -u GITHUB_ACTIONS -u DOCKERFILES -u BUILD_ARGS -u TAG_ONLY_IMAGES "${assignments[@]}" \
		bash "${script}" "$@" 2>"${work}/stderr")" || status=$?
	if [[ ${status} -ne ${want_status} ]]; then
		echo "not ok - ${name}: exit ${status}, want ${want_status}" >&2
		cat "${work}/stderr" >&2
		failures=$((failures + 1))
	elif [[ ${got} != "${want}" ]]; then
		echo "not ok - ${name}: unexpected output" >&2
		diff <(echo "${want}") <(echo "${got}") >&2 || true
		failures=$((failures + 1))
	else
		echo "ok - ${name}"
	fi
}

# check_stderr NAME WANT_STATUS TEXT [VAR=VALUE...]: runs the check with no arguments, with the
# environment assignments, and wants that status and TEXT in its stderr.
check_stderr() {
	local name="$1" want_status="$2" want_text="$3" status=0 err
	shift 3
	err="$(cd "${here}" && env -u GITHUB_ACTIONS -u DOCKERFILES -u BUILD_ARGS -u TAG_ONLY_IMAGES "$@" bash "${script}" 2>&1 >/dev/null)" || status=$?
	if [[ ${status} -ne ${want_status} ]]; then
		echo "not ok - ${name}: exit ${status}, want ${want_status}: ${err}" >&2
		failures=$((failures + 1))
	elif [[ ${err} != *"${want_text}"* ]]; then
		echo "not ok - ${name}: want '${want_text}' in: ${err}" >&2
		failures=$((failures + 1))
	else
		echo "ok - ${name}"
	fi
}

unpinned() {
	echo "$1: $2 is an external image that is not pinned by digest: pin it as $3@sha256:<digest>"
}

download() {
	echo "$1: $2 downloads in ${3:-a RUN} with no checksum verification after it: add \`sha256sum --check\` of the file after the download, in the same instruction"
}

ineffective() {
	echo "$1: $2 downloads in ${3:-a RUN} whose checksum verification is not on a path whose failure fails the instruction: chain it with && to the end, or run it under set -e"
}

exec_form() {
	echo "$1: RUN [...] runs $2 with no checksum verification after it (the exec form cannot verify it: use a shell RUN with sha256sum --check)"
}

# --- The synthetic fixtures -----------------------------------------------------------------

check "internal stages by name in any case and by index, scratch, platform flags and verified downloads pass" 0 \
	-- fixtures/multi-stage.Dockerfile </dev/null

check "a global ARG default built from another ARG resolves, and is not pinned" 1 \
	-- fixtures/args.Dockerfile <<'EOF'
fixtures/args.Dockerfile:6: FROM $BASE (= docker.io/library/alpine:3.23) is an external image that is not pinned by digest: pin it where its value comes from (the ARG default or the build arg) as docker.io/library/alpine:3.23@sha256:<digest>
EOF

check "a --build-arg overrides the global ARG default" 0 \
	-- --build-arg "BASE=docker.io/library/alpine:3.23@sha256:${digest}" fixtures/args.Dockerfile </dev/null

check "a --build-arg overrides an ARG with no default, in place of the \${NAME:-default}" 1 \
	-- --build-arg "BASE=docker.io/library/alpine:3.23@sha256:${digest}" --build-arg TOOLS_IMAGE=busybox:latest \
	fixtures/args.Dockerfile <<'EOF'
fixtures/args.Dockerfile:7: FROM ${TOOLS_IMAGE:-docker.io/library/busybox:1.37@sha256:d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4} (= busybox:latest) is an external image that is not pinned by digest: pin it where its value comes from (the ARG default or the build arg) as busybox:latest@sha256:<digest>
EOF

check "BUILD_ARGS from the environment, one per line, with blank and comment lines" 0 \
	DOCKERFILES=fixtures/args.Dockerfile \
	"BUILD_ARGS=$(printf '\n# the base\nBASE=docker.io/library/alpine:3.23@sha256:%s\n\n' "${digest}")" </dev/null

check "an ARG that cannot be resolved is an error at its FROM" 1 \
	-- fixtures/unresolvable.Dockerfile <<'EOF'
fixtures/unresolvable.Dockerfile:4: FROM ${NO_DEFAULT}: cannot resolve the image: ARG NO_DEFAULT has no default before the first FROM and no build arg sets it
fixtures/unresolvable.Dockerfile:5: FROM $UNDECLARED: cannot resolve the image: UNDECLARED is not declared before the first FROM
fixtures/unresolvable.Dockerfile:8: FROM ${IN_STAGE}: cannot resolve the image: IN_STAGE is not declared before the first FROM
fixtures/unresolvable.Dockerfile:9: FROM ${TARGETPLATFORM}: cannot resolve the image: TARGETPLATFORM is a platform ARG that only the builder knows
fixtures/unresolvable.Dockerfile:10: FROM ${FROM_UNDECLARED}: cannot resolve the image: the default of ARG FROM_UNDECLARED: NOWHERE is not declared before the first FROM
fixtures/unresolvable.Dockerfile:11: FROM ${NO_DEFAULT%:*}: cannot resolve the image: ${NO_DEFAULT%:*} is not a substitution this check understands
EOF

check "a --build-arg for an undeclared ARG does not resolve a FROM, as in docker build" 1 \
	-- --build-arg UNDECLARED=alpine@sha256:"${digest}" --build-arg NO_DEFAULT=alpine@sha256:"${digest}" \
	fixtures/unresolvable.Dockerfile <<'EOF'
fixtures/unresolvable.Dockerfile:5: FROM $UNDECLARED: cannot resolve the image: UNDECLARED is not declared before the first FROM
fixtures/unresolvable.Dockerfile:8: FROM ${IN_STAGE}: cannot resolve the image: IN_STAGE is not declared before the first FROM
fixtures/unresolvable.Dockerfile:9: FROM ${TARGETPLATFORM}: cannot resolve the image: TARGETPLATFORM is a platform ARG that only the builder knows
fixtures/unresolvable.Dockerfile:10: FROM ${FROM_UNDECLARED}: cannot resolve the image: the default of ARG FROM_UNDECLARED: NOWHERE is not declared before the first FROM
fixtures/unresolvable.Dockerfile:11: FROM ${NO_DEFAULT%:*}: cannot resolve the image: ${NO_DEFAULT%:*} is not a substitution this check understands
EOF

check "an unpinned external base fails, a malformed digest too, a digest with or without a tag passes" 1 \
	-- fixtures/unpinned.Dockerfile <<EOF
$(unpinned fixtures/unpinned.Dockerfile:2 "FROM alpine:3.23" alpine:3.23)
$(unpinned fixtures/unpinned.Dockerfile:3 "FROM ubuntu" ubuntu)
fixtures/unpinned.Dockerfile:4: FROM ghcr.io/example/tool@sha256:abc123 has a malformed digest: want @sha256: and 64 lowercase hex digits
EOF

check "COPY --from and RUN --mount from= an image must be pinned; a stage must be an earlier one" 1 \
	-- fixtures/copy-from.Dockerfile <<EOF
$(unpinned fixtures/copy-from.Dockerfile:3 "COPY --from=docker.io/library/busybox:1.37" docker.io/library/busybox:1.37)
$(unpinned fixtures/copy-from.Dockerfile:5 "COPY --from=later" later)
$(unpinned fixtures/copy-from.Dockerfile:6 "RUN --mount=...from=docker.io/library/golang:1.26" docker.io/library/golang:1.26)
fixtures/copy-from.Dockerfile:9: COPY --from=0 refers to stage 0, which is not an earlier stage
fixtures/copy-from.Dockerfile:13: COPY --from=1 refers to stage 1, which is not an earlier stage
fixtures/copy-from.Dockerfile:14: COPY --from=7 refers to stage 7, which is not an earlier stage
EOF

check "curl, wget and ADD of a URL with no checksum verification in the same instruction fail" 1 \
	-- fixtures/downloads.Dockerfile <<EOF
$(download fixtures/downloads.Dockerfile:3 curl)
$(download fixtures/downloads.Dockerfile:5 wget)
$(download fixtures/downloads.Dockerfile:6 curl)
fixtures/downloads.Dockerfile:7: ADD https://example.com/c.tar.gz downloads with no checksum: add --checksum=sha256:<hash>
fixtures/downloads.Dockerfile:9: ADD https://example.com/e downloads with no checksum: add --checksum=sha256:<hash>
$(exec_form fixtures/downloads.Dockerfile:10 curl)
$(download fixtures/downloads.Dockerfile:13 wget)
$(download fixtures/downloads.Dockerfile:15 curl)
$(download fixtures/downloads.Dockerfile:16 curl)
$(exec_form fixtures/downloads.Dockerfile:23 curl)
$(download fixtures/downloads.Dockerfile:24 curl)
EOF

check "the escape directive moves line continuation to the backtick" 1 \
	-- fixtures/escape-backtick.Dockerfile <<EOF
$(download fixtures/escape-backtick.Dockerfile:4 curl)
$(unpinned fixtures/escape-backtick.Dockerfile:6 "FROM mcr.microsoft.com/windows/nanoserver:ltsc2025" mcr.microsoft.com/windows/nanoserver:ltsc2025)
EOF

check "a heredoc that is never closed cannot be checked" 2 \
	-- fixtures/unterminated-heredoc.Dockerfile </dev/null

check "findings are also GitHub annotations in Actions" 1 GITHUB_ACTIONS=true \
	-- fixtures/unpinned.Dockerfile <<EOF
$(unpinned fixtures/unpinned.Dockerfile:2 "FROM alpine:3.23" alpine:3.23)
::error file=fixtures/unpinned.Dockerfile,line=2::FROM alpine:3.23 is an external image that is not pinned by digest: pin it as alpine:3.23@sha256:<digest>
$(unpinned fixtures/unpinned.Dockerfile:3 "FROM ubuntu" ubuntu)
::error file=fixtures/unpinned.Dockerfile,line=3::FROM ubuntu is an external image that is not pinned by digest: pin it as ubuntu@sha256:<digest>
fixtures/unpinned.Dockerfile:4: FROM ghcr.io/example/tool@sha256:abc123 has a malformed digest: want @sha256: and 64 lowercase hex digits
::error file=fixtures/unpinned.Dockerfile,line=4::FROM ghcr.io/example/tool@sha256:abc123 has a malformed digest: want @sha256: and 64 lowercase hex digits
EOF

check "downloads behind wrappers, nested shells, ARGs, strings, masked checks and COPY heredocs are found" 1 \
	-- fixtures/bypasses.Dockerfile <<EOF
$(download fixtures/bypasses.Dockerfile:4 curl)
$(download fixtures/bypasses.Dockerfile:5 wget)
$(download fixtures/bypasses.Dockerfile:6 curl)
$(download fixtures/bypasses.Dockerfile:7 curl)
$(download fixtures/bypasses.Dockerfile:8 curl)
$(download fixtures/bypasses.Dockerfile:9 curl)
$(download fixtures/bypasses.Dockerfile:10 curl)
fixtures/bypasses.Dockerfile:12: ADD \$URL (= https://example.com/g) downloads with no checksum: add --checksum=sha256:<hash>
$(download fixtures/bypasses.Dockerfile:13 curl)
$(download fixtures/bypasses.Dockerfile:14 curl)
$(ineffective fixtures/bypasses.Dockerfile:15 curl)
$(ineffective fixtures/bypasses.Dockerfile:16 curl)
$(download fixtures/bypasses.Dockerfile:19 curl "a COPY heredoc")
$(download fixtures/bypasses.Dockerfile:22 wget)
$(download fixtures/bypasses.Dockerfile:23 curl)
fixtures/bypasses.Dockerfile:24: ADD \${UNDECLARED_URL}: cannot resolve the source, which may be a URL downloaded with no checksum: UNDECLARED_URL is not declared before the first FROM
$(download fixtures/bypasses.Dockerfile:25 curl)
EOF

check "downloads verified after them, through wrappers, nested shells and heredoc files, pass" 0 \
	-- fixtures/verified.Dockerfile </dev/null

# Line by line, errexit.Dockerfile's RUNs that pass: 8 (pipefail), 10 (set -e), 12 (&& to the
# end), 13 (the last command), 14 (a propagated { } group), 15 (|| exit 1), 18 (sh -ec, itself
# propagated), 20 (a function whose every call is propagated), 23 (a propagated ( ) group), 28
# and 29 (SHELL with -e and pipefail), 32 (that SHELL inherited by FROM strict), 39 (SHELL -ec),
# and 67 to 70 (set -euxo pipefail, set -o errexit -o pipefail, { set -e; }, and set -e first in
# its && list, which always runs). 45 to 65 each make errexit unknown or off before the check: a
# set -e that may not run (after && or ||, in if/for/case), undone in a { } group, a function or
# with +o errexit / +eu, set -- -e, set -e as an argument or in a child shell, subshell, pipeline
# or background, . and eval, command set +e, set +o pipefail, and a negated group.
check "a verification whose failure would not fail the RUN does not count" 1 \
	-- fixtures/errexit.Dockerfile <<EOF
$(ineffective fixtures/errexit.Dockerfile:3 curl)
$(ineffective fixtures/errexit.Dockerfile:4 curl)
$(ineffective fixtures/errexit.Dockerfile:5 curl)
$(ineffective fixtures/errexit.Dockerfile:6 curl)
$(ineffective fixtures/errexit.Dockerfile:7 curl)
$(ineffective fixtures/errexit.Dockerfile:9 curl)
$(ineffective fixtures/errexit.Dockerfile:11 curl)
$(ineffective fixtures/errexit.Dockerfile:16 curl)
$(ineffective fixtures/errexit.Dockerfile:17 curl)
$(ineffective fixtures/errexit.Dockerfile:19 curl)
$(ineffective fixtures/errexit.Dockerfile:21 curl)
$(ineffective fixtures/errexit.Dockerfile:22 curl)
$(ineffective fixtures/errexit.Dockerfile:24 curl)
$(ineffective fixtures/errexit.Dockerfile:35 curl)
$(ineffective fixtures/errexit.Dockerfile:41 curl)
$(ineffective fixtures/errexit.Dockerfile:45 curl)
$(ineffective fixtures/errexit.Dockerfile:46 curl)
$(ineffective fixtures/errexit.Dockerfile:47 curl)
$(ineffective fixtures/errexit.Dockerfile:48 curl)
$(ineffective fixtures/errexit.Dockerfile:49 curl)
$(ineffective fixtures/errexit.Dockerfile:50 curl)
$(ineffective fixtures/errexit.Dockerfile:51 curl)
$(ineffective fixtures/errexit.Dockerfile:52 curl)
$(ineffective fixtures/errexit.Dockerfile:53 curl)
$(ineffective fixtures/errexit.Dockerfile:54 curl)
$(ineffective fixtures/errexit.Dockerfile:55 curl)
$(ineffective fixtures/errexit.Dockerfile:56 curl)
$(ineffective fixtures/errexit.Dockerfile:57 curl)
$(ineffective fixtures/errexit.Dockerfile:58 curl)
$(ineffective fixtures/errexit.Dockerfile:59 curl)
$(ineffective fixtures/errexit.Dockerfile:60 curl)
$(ineffective fixtures/errexit.Dockerfile:61 curl)
$(ineffective fixtures/errexit.Dockerfile:62 curl)
$(ineffective fixtures/errexit.Dockerfile:63 curl)
$(ineffective fixtures/errexit.Dockerfile:64 curl)
$(ineffective fixtures/errexit.Dockerfile:65 curl)
EOF

# --- The real Dockerfiles -------------------------------------------------------------------

check "awtrix-controller: both bases float" 1 \
	-- fixtures/awtrix-controller.Dockerfile <<EOF
$(unpinned fixtures/awtrix-controller.Dockerfile:43 "FROM dhi.io/rust:1.98.1-debian13-dev" dhi.io/rust:1.98.1-debian13-dev)
$(unpinned fixtures/awtrix-controller.Dockerfile:118 "FROM dhi.io/static:20250419" dhi.io/static:20250419)
EOF

check "awtrix-controller, pinned: passes" 0 -- fixtures/awtrix-controller.pinned.Dockerfile </dev/null

check "swarm-rootless-docker: both bases float" 1 \
	-- fixtures/swarm-rootless-docker.Dockerfile <<EOF
$(unpinned fixtures/swarm-rootless-docker.Dockerfile:44 "FROM dhi.io/rust:1.98.1-debian13-dev" dhi.io/rust:1.98.1-debian13-dev)
$(unpinned fixtures/swarm-rootless-docker.Dockerfile:124 "FROM docker:29-dind-rootless" docker:29-dind-rootless)
EOF

check "swarm-rootless-docker, pinned: passes" 0 -- fixtures/swarm-rootless-docker.pinned.Dockerfile </dev/null

check "bitgauge: all three bases float" 1 \
	-- fixtures/bitgauge.Dockerfile <<EOF
$(unpinned fixtures/bitgauge.Dockerfile:46 "FROM dhi.io/node:24-alpine3.23-dev" dhi.io/node:24-alpine3.23-dev)
$(unpinned fixtures/bitgauge.Dockerfile:67 "FROM dhi.io/rust:1.98.1-debian13-dev" dhi.io/rust:1.98.1-debian13-dev)
$(unpinned fixtures/bitgauge.Dockerfile:166 "FROM dhi.io/static:20250419" dhi.io/static:20250419)
EOF

check "bitgauge, pinned: passes" 0 -- fixtures/bitgauge.pinned.Dockerfile </dev/null

check "bitgauge's test tools image already pins both bases" 0 -- fixtures/bitgauge-tools.Dockerfile </dev/null

check "herdquay: the BASE_IMAGE default floats, and Docker's apt key is checked by fingerprint only" 1 \
	-- fixtures/herdquay.Dockerfile <<'EOF'
fixtures/herdquay.Dockerfile:34: FROM ${BASE_IMAGE} (= ubuntu:26.04) is an external image that is not pinned by digest: pin it where its value comes from (the ARG default or the build arg) as ubuntu:26.04@sha256:<digest>
fixtures/herdquay.Dockerfile:192: curl downloads in a RUN with no checksum verification after it: add `sha256sum --check` of the file after the download, in the same instruction
fixtures/herdquay.Dockerfile:200: FROM ${BASE_IMAGE} (= ubuntu:26.04) is an external image that is not pinned by digest: pin it where its value comes from (the ARG default or the build arg) as ubuntu:26.04@sha256:<digest>
EOF

check "herdquay with a pinned BASE_IMAGE build arg: only the apt key download is left" 1 \
	-- --build-arg "BASE_IMAGE=ubuntu:26.04@sha256:${digest}" fixtures/herdquay.Dockerfile <<EOF
$(download fixtures/herdquay.Dockerfile:192 curl)
EOF

check "herdquay, pinned: only the apt key download is left" 1 \
	-- fixtures/herdquay.pinned.Dockerfile <<EOF
$(download fixtures/herdquay.pinned.Dockerfile:192 curl)
EOF

check "herdquay, pinned and the apt key verified by sha256: passes" 0 \
	-- fixtures/herdquay.pinned-verified.Dockerfile </dev/null

# --- Tag-only images --------------------------------------------------------------------------

tag_only() {
	echo "$1: $2 may be pinned by tag only ($3 is in tag-only-images), but needs an explicit tag other than latest"
}

check "without --tag-only, every tag-only fixture image needs a digest" 1 \
	-- fixtures/tag-only.Dockerfile <<EOF
$(unpinned fixtures/tag-only.Dockerfile:2 "FROM dhi.io/rust:1.98.1-debian13-dev" dhi.io/rust:1.98.1-debian13-dev)
$(unpinned fixtures/tag-only.Dockerfile:4 "FROM dhi.io/static" dhi.io/static)
$(unpinned fixtures/tag-only.Dockerfile:5 "FROM dhi.io/static:latest" dhi.io/static:latest)
$(unpinned fixtures/tag-only.Dockerfile:6 "FROM dhi.io.example.com/static:1" dhi.io.example.com/static:1)
$(unpinned fixtures/tag-only.Dockerfile:7 "FROM docker.io/library/alpine:3.23" docker.io/library/alpine:3.23)
$(unpinned fixtures/tag-only.Dockerfile:8 "FROM dhi.io/static:20250419" dhi.io/static:20250419)
EOF

check "--tag-only dhi.io: a dhi.io tag passes, untagged and latest do not, other registries need a digest" 1 \
	-- --tag-only dhi.io/ fixtures/tag-only.Dockerfile <<EOF
$(tag_only fixtures/tag-only.Dockerfile:4 "FROM dhi.io/static" dhi.io/static)
$(tag_only fixtures/tag-only.Dockerfile:5 "FROM dhi.io/static:latest" dhi.io/static)
$(unpinned fixtures/tag-only.Dockerfile:6 "FROM dhi.io.example.com/static:1" dhi.io.example.com/static:1)
$(unpinned fixtures/tag-only.Dockerfile:7 "FROM docker.io/library/alpine:3.23" docker.io/library/alpine:3.23)
EOF

check "--tag-only names one repository: the others under its registry still need a digest" 1 \
	-- --tag-only dhi.io/rust fixtures/tag-only.Dockerfile <<EOF
$(unpinned fixtures/tag-only.Dockerfile:4 "FROM dhi.io/static" dhi.io/static)
$(unpinned fixtures/tag-only.Dockerfile:5 "FROM dhi.io/static:latest" dhi.io/static:latest)
$(unpinned fixtures/tag-only.Dockerfile:6 "FROM dhi.io.example.com/static:1" dhi.io.example.com/static:1)
$(unpinned fixtures/tag-only.Dockerfile:7 "FROM docker.io/library/alpine:3.23" docker.io/library/alpine:3.23)
$(unpinned fixtures/tag-only.Dockerfile:8 "FROM dhi.io/static:20250419" dhi.io/static:20250419)
EOF

check "awtrix-controller with TAG_ONLY_IMAGES=dhi.io: passes as it is" 0 \
	DOCKERFILES=fixtures/awtrix-controller.Dockerfile "TAG_ONLY_IMAGES=$(printf '# DHI\n  dhi.io  \n\n')" </dev/null

check_stderr "a tag-only entry with a tag fails" 2 "--tag-only 'dhi.io/static:1' is not a registry or repository" \
	DOCKERFILES=fixtures/tag-only.Dockerfile TAG_ONLY_IMAGES=dhi.io/static:1

# --- The wrapper's inputs -------------------------------------------------------------------

check "DOCKERFILES takes globs and plain paths, one per line, and checks each file once" 1 \
	"DOCKERFILES=$(printf 'fixtures/*.pinned.Dockerfile\n  fixtures/**/bitgauge-tools.Dockerfile  \nfixtures/awtrix-controller.pinned.Dockerfile\n')" <<EOF
$(download fixtures/herdquay.pinned.Dockerfile:192 curl)
EOF

check_stderr "the default is ./Dockerfile, which must exist" 2 "'Dockerfile' is not a file"
check_stderr "a glob that matches no file fails" 2 "the glob 'fixtures/none-*.Dockerfile' matches no file" \
	DOCKERFILES=fixtures/none-*.Dockerfile
check_stderr "a missing file fails" 2 "'fixtures/missing.Dockerfile' is not a file" \
	DOCKERFILES=fixtures/missing.Dockerfile
check_stderr "a build arg that is not NAME=VALUE fails" 2 "the build arg '1BASE=x' is not NAME=VALUE" \
	DOCKERFILES=fixtures/args.Dockerfile BUILD_ARGS=1BASE=x
check_stderr "a blank DOCKERFILES list fails" 2 "no Dockerfile given" "DOCKERFILES= "
check_stderr "an empty DOCKERFILES is refused, not defaulted to ./Dockerfile" 2 "no Dockerfile given" "DOCKERFILES="

if [[ ${failures} -ne 0 ]]; then
	echo "${failures} check(s) failed" >&2
	exit 1
fi
echo "every check passed"
