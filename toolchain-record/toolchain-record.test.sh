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

# Tests for toolchain-record.sh. Plain bash, no network: stub rustc, go and node lead a temporary
# PATH and print STUB_RUST, STUB_GO and STUB_NODE; a stub that is asked for anything but its
# version, or whose variable is unset, behaves like a missing or broken tool.
#
# Run: bash toolchain-record/toolchain-record.test.sh

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/toolchain-record.sh"

unset GITHUB_OUTPUT ANNOTATION_FILE TOOLCHAINS

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

cat >"$work/bin/rustc" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "--version" ] || exit 98
echo "rustc $STUB_RUST (0000000000 2026-01-01)"
STUB
cat >"$work/bin/go" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "env GOVERSION" ] || exit 98
echo "$STUB_GO"
STUB
cat >"$work/bin/node" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "--version" ] || exit 98
echo "$STUB_NODE"
STUB
chmod +x "$work/bin/"*

export PATH="$work/bin:$PATH"
export STUB_RUST=1.98.1 STUB_GO=go1.26.1 STUB_NODE=v24.1.0

failures=0
pass() { echo "ok - $1"; }
fail_case() {
	echo "not ok - $1: $2"
	failures=$((failures + 1))
}

# run runs the script with a fresh GITHUB_OUTPUT and sets status, out and outputs.
run() {
	: >"$work/github_output"
	status=0
	out=$(GITHUB_OUTPUT="$work/github_output" "$script" 2>&1) || status=$?
	outputs=$(cat "$work/github_output")
}

# expect <name> <stdout> checks a zero exit with exactly that stdout.
expect() {
	if [ "$status" -eq 0 ] && [ "$out" = "$2" ]; then
		pass "$1"
	else
		fail_case "$1" "exit $status, output [$out], want [$2]"
	fi
}

# expect_failure <name> <message> checks a non-zero exit holding <message>, with nothing written to
# GITHUB_OUTPUT.
expect_failure() {
	if [ "$status" -ne 0 ] && grep -qF -- "$2" <<<"$out" && [ -z "$outputs" ]; then
		pass "$1"
	else
		fail_case "$1" "exit $status, outputs [$outputs], output [$out]"
	fi
}

TOOLCHAINS=rust,node run
expect "rust and node print bitgauge's lines" "Rust: 1.98.1
Node: v24.1.0"

TOOLCHAINS="go node" run
expect "go and node print runhold's lines" "Go: go1.26.1
Node: v24.1.0"

TOOLCHAINS="node, go ,rust" run
expect "the lines come in the order Rust, Go, Node whatever the input order" "Rust: 1.98.1
Go: go1.26.1
Node: v24.1.0"
delimiter=$(sed -n 's/^lines<<//p' <<<"$outputs")
if [ -n "$delimiter" ] && [ "$outputs" = "lines<<$delimiter
Rust: 1.98.1
Go: go1.26.1
Node: v24.1.0
$delimiter
rust-version=1.98.1
go-version=go1.26.1
node-version=v24.1.0" ]; then
	pass "GITHUB_OUTPUT holds the lines and each version"
else
	fail_case "GITHUB_OUTPUT holds the lines and each version" "got [$outputs]"
fi

TOOLCHAINS=go STUB_GO=go1.20 run
expect "a two-part Go release is recorded" "Go: go1.20"

printf 'project v1.2.3\n\n' >"$work/annotation"
TOOLCHAINS=rust,node ANNOTATION_FILE="$work/annotation" run
if [ "$status" -eq 0 ] && [ "$(cat "$work/annotation")" = "project v1.2.3

Rust: 1.98.1
Node: v24.1.0" ]; then
	pass "ANNOTATION_FILE has the lines appended"
else
	fail_case "ANNOTATION_FILE has the lines appended" "exit $status, file [$(cat "$work/annotation")]"
fi

# Each line reads back with toolchain-recover's patterns, so what is recorded can be recovered.
recover="$here/../toolchain-recover/toolchain-recover.sh"
if [ -x "$recover" ]; then
	printf 'project v1.2.3\n\n' >"$work/annotation"
	TOOLCHAINS="rust go node" ANNOTATION_FILE="$work/annotation" "$script" >/dev/null
	status=0
	recovered=$(TOOLCHAINS="rust go node" ANNOTATION_FILE="$work/annotation" GITHUB_OUTPUT="$work/recover_output" \
		"$recover" 2>&1) || status=$?
	if [ "$status" -eq 0 ] && grep -qxF "mode=matched" "$work/recover_output"; then
		pass "toolchain-recover reads the recorded lines back as matching"
	else
		fail_case "toolchain-recover reads the recorded lines back as matching" "exit $status, output [$recovered]"
	fi
fi

TOOLCHAINS=rust STUB_RUST=1.99.0-nightly run
expect_failure "a nightly rustc fails" "rustc --version reports '1.99.0-nightly'"

TOOLCHAINS=go STUB_GO=devel run
expect_failure "a devel go fails" "go env GOVERSION reports 'devel'"

TOOLCHAINS=node STUB_NODE=24.1.0 run
expect_failure "a node version without its v fails" "node --version reports '24.1.0'"

TOOLCHAINS=rust,python run
expect_failure "an unknown toolchain fails" "unknown toolchain 'python'"

TOOLCHAINS="go go" run
expect_failure "a toolchain listed twice fails" "'go' is listed twice"

TOOLCHAINS=" , " run
expect_failure "an empty TOOLCHAINS fails" "TOOLCHAINS is empty"

TOOLCHAINS='*' run
expect_failure "a glob in TOOLCHAINS is not expanded" "unknown toolchain '*'"

# The real go may be on the PATH behind the stubs, so a broken one stands in for a missing one.
printf '#!/usr/bin/env bash\nexit 1\n' >"$work/bin/go"
TOOLCHAINS=rust,go run
expect_failure "a failing tool fails" "go env GOVERSION failed"

status=0
"$script" extra >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then
	pass "an argument is a usage error"
else
	fail_case "an argument is a usage error" "exit $status"
fi

if [ "$failures" -ne 0 ]; then
	echo "$failures case(s) failed" >&2
	exit 1
fi

echo "all cases passed"
