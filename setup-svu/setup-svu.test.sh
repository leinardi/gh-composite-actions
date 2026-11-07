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
# Tests setup-svu.sh with a curl stub that serves locally built archives, so no network is
# used. The archives hold a fake svu that prints a `--version` block like the real one; the real
# download and its pinned checksum are exercised by the CI self-test.
#
# Needs: bash, coreutils, tar, gzip.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/setup-svu.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The curl stub: `curl ... -o FILE URL` copies $CURL_STUB_ARCHIVE to FILE, or fails like curl -f
# when $CURL_STUB_ARCHIVE is empty. Every URL is recorded in $CURL_STUB_CALLS.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
out="" url=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	-o) out=$2; shift 2 ;;
	--proto | --retry) shift 2 ;;
	-*) shift ;;
	*) url=$1; shift ;;
	esac
done
echo "$url" >>"$CURL_STUB_CALLS"
if [ -z "${CURL_STUB_ARCHIVE:-}" ]; then
	echo "curl: (22) The requested URL returned error: 404" >&2
	exit 22
fi
cp "$CURL_STUB_ARCHIVE" "$out"
STUB
chmod +x "$WORK/bin/curl"
PATH="$WORK/bin:$PATH"

# make_archive NAME REPORTED_VERSION: an archive holding a fake svu; prints its path.
make_archive() {
	local dir="$WORK/archive-$1"
	mkdir -p "$dir"
	cat >"$dir/svu" <<EOF
#!/usr/bin/env bash
printf 'svu: Semantic Version Utility\n\nGitVersion:    %s\nPlatform:      linux/amd64\n' "$2"
EOF
	chmod +x "$dir/svu"
	echo "readme" >"$dir/README.md"
	tar -czf "$WORK/$1.tar.gz" -C "$dir" svu README.md
	echo "$WORK/$1.tar.gz"
}
sha() { sha256sum "$1" | awk '{print $1}'; }

GOOD=$(make_archive good 3.9.0)
GOOD_SHA=$(sha "$GOOD")
LIAR=$(make_archive liar 3.4.1)
LIAR_SHA=$(sha "$LIAR")

PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	echo "ok - $1"
}
not_ok() {
	FAIL=$((FAIL + 1))
	echo "not ok - $1"
	if [[ -n "${2:-}" ]]; then
		while IFS= read -r line; do printf '       %s\n' "$line"; done <<<"$2"
	fi
}

# install [ENV=VALUE...]: runs the script on a fresh runner. Sets STATUS, LOG, GH_PATH (the
# $GITHUB_PATH contents), OUTPUT and CALLS.
N=0
install() {
	N=$((N + 1))
	local temp="$WORK/runner-$N"
	mkdir -p "$temp"
	export CURL_STUB_CALLS="$temp/curl-calls"
	: >"$CURL_STUB_CALLS"
	: >"$temp/path"
	: >"$temp/output"
	STATUS=0
	LOG=$(env RUNNER_OS=Linux RUNNER_ARCH=X64 RUNNER_TEMP="$temp" GITHUB_PATH="$temp/path" \
		GITHUB_OUTPUT="$temp/output" "$@" bash "$SCRIPT" 2>&1) || STATUS=$?
	GH_PATH=$(cat "$temp/path")
	OUTPUT=$(cat "$temp/output")
	CALLS=$(cat "$CURL_STUB_CALLS")
	RUNNER=$temp
}
expect_fail() {
	local name=$1 pattern=$2
	if [[ "$STATUS" -ne 0 ]] && grep -q -- "$pattern" <<<"$LOG" && [[ -z "$GH_PATH" ]] && [[ -z "$OUTPUT" ]]; then
		ok "$name"
	else
		not_ok "$name (want a failure matching '$pattern' and nothing on PATH, status $STATUS)" "$LOG
PATH: $GH_PATH"
	fi
}

install CURL_STUB_ARCHIVE="$GOOD" SVU_VERSION=3.9.0 SVU_SHA256="$GOOD_SHA"
BIN="$RUNNER/setup-svu/3.9.0-amd64"
if [[ "$STATUS" -eq 0 ]] && [[ "$GH_PATH" == "$BIN" ]] && [[ "$OUTPUT" == "path=$BIN" ]] && [[ -x "$BIN/svu" ]] \
	&& [[ "$(ls "$BIN")" == "svu" ]] && grep -q "GitVersion:    3.9.0" <<<"$LOG"; then
	ok "a version with its sha256 installs only the binary onto GITHUB_PATH and prints its version"
else
	not_ok "a version with its sha256 installs only the binary onto GITHUB_PATH and prints its version" "$LOG
PATH: $GH_PATH
OUTPUT: $OUTPUT"
fi
if [[ "$CALLS" == "https://github.com/caarlos0/svu/releases/download/v3.9.0/svu_3.9.0_linux_amd64.tar.gz" ]]; then
	ok "the archive is fetched from the release of that version"
else
	not_ok "the archive is fetched from the release of that version" "$CALLS"
fi
if [[ -z "$(find "$RUNNER" -name '*.tar.gz')" ]]; then ok "the downloaded archive is removed"; else not_ok "the downloaded archive is removed" "$(find "$RUNNER")"; fi

install CURL_STUB_ARCHIVE="$GOOD" SVU_VERSION=v3.9.0 SVU_SHA256="$GOOD_SHA"
if [[ "$STATUS" -eq 0 ]] && [[ "$GH_PATH" == "$RUNNER/setup-svu/3.9.0-amd64" ]]; then ok "a leading v on the version is accepted"; else not_ok "a leading v on the version is accepted" "$LOG"; fi

install CURL_STUB_ARCHIVE="$GOOD" SVU_VERSION=3.9.0 SVU_SHA256="$GOOD_SHA" RUNNER_ARCH=ARM64
if [[ "$STATUS" -eq 0 ]] && grep -q "svu_3.9.0_linux_arm64.tar.gz$" <<<"$CALLS" && [[ "$GH_PATH" == "$RUNNER/setup-svu/3.9.0-arm64" ]]; then
	ok "an ARM64 runner gets the arm64 archive"
else
	not_ok "an ARM64 runner gets the arm64 archive" "$LOG$CALLS"
fi

install CURL_STUB_ARCHIVE="$GOOD"
if [[ "$STATUS" -ne 0 ]] && grep -q "svu_3.4.1_linux_amd64.tar.gz does not match the SHA-256 7ee8c91998c15109130638dc661a912d5f426e2f8642f6f6c04e6502be920770" <<<"$LOG" \
	&& [[ "$CALLS" == "https://github.com/caarlos0/svu/releases/download/v3.4.1/svu_3.4.1_linux_amd64.tar.gz" ]] && [[ -z "$GH_PATH" ]]; then
	ok "the default is the pinned version, checked against the pinned amd64 sha256"
else
	not_ok "the default is the pinned version, checked against the pinned amd64 sha256" "$LOG$CALLS"
fi

install CURL_STUB_ARCHIVE="$GOOD" RUNNER_ARCH=ARM64
expect_fail "an ARM64 runner is checked against the pinned arm64 sha256" "does not match the SHA-256 801f310be2f91df86868a2de1f61fefaf06e3eb773431be7dde9765ecde4d21c"

install CURL_STUB_ARCHIVE="$GOOD" SVU_VERSION=3.9.0
if [[ "$STATUS" -ne 0 ]] && grep -q "pass its sha256 too" <<<"$LOG" && [[ -z "$CALLS" ]] && [[ -z "$GH_PATH" ]]; then
	ok "another version without its sha256 fails before downloading"
else
	not_ok "another version without its sha256 fails before downloading" "$LOG$CALLS"
fi

install CURL_STUB_ARCHIVE="$GOOD" SVU_VERSION=3.9.0 SVU_SHA256="$LIAR_SHA"
expect_fail "an archive that does not match the sha256 fails" "does not match the SHA-256"

install CURL_STUB_ARCHIVE="$LIAR" SVU_VERSION=3.9.0 SVU_SHA256="$LIAR_SHA"
expect_fail "a binary that reports another version fails" "reports a version other than 3.9.0"

install CURL_STUB_ARCHIVE="" SVU_VERSION=3.9.0 SVU_SHA256="$GOOD_SHA"
if [[ "$STATUS" -ne 0 ]] && grep -q "404" <<<"$LOG" && [[ -z "$GH_PATH" ]]; then ok "a failed download fails"; else not_ok "a failed download fails" "$LOG"; fi

for bad in 3.4 v3.4.1-rc.1 03.4.1 latest "3.4.1 "; do
	install CURL_STUB_ARCHIVE="$GOOD" SVU_VERSION="$bad" SVU_SHA256="$GOOD_SHA"
	expect_fail "version '$bad' is refused" "version must be X.Y.Z"
done
for bad in abc "${GOOD_SHA^^}" "${GOOD_SHA:1}" "$GOOD_SHA "; do
	install CURL_STUB_ARCHIVE="$GOOD" SVU_VERSION=3.9.0 SVU_SHA256="$bad"
	expect_fail "sha256 '$bad' is refused" "sha256 must be 64 lowercase hex"
done

install CURL_STUB_ARCHIVE="$GOOD" RUNNER_OS=macOS
expect_fail "a non-Linux runner is refused" "Linux runners only"
install CURL_STUB_ARCHIVE="$GOOD" RUNNER_ARCH=X86
expect_fail "an unsupported architecture is refused" "X64 and ARM64 runners only"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
