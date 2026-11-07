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

# Usage: TOOLCHAINS=<list> [ANNOTATION_FILE=<file>] toolchain-record.sh
#
# Prints the lines a release tag's annotation records its toolchains with, one per requested
# toolchain, in the fixed order Rust, Go, Node:
#
#   Rust: 1.98.1      (the second field of `rustc --version`)
#   Go: go1.26.1      (`go env GOVERSION`)
#   Node: v24.1.0     (`node --version`)
#
# These are the exact versions the binaries are about to be built with, as the setup resolved
# them: a version line such as Node's major or a rust-toolchain.toml channel names a line, not a
# patch, so a recovery days later would build different bytes than the first run published.
# toolchain-recover reads the same lines back from the tag and switches to them.
#
# TOOLCHAINS is a comma- or space-separated subset of rust, go and node (at least one, each at
# most once). ANNOTATION_FILE, when set, has the lines appended to it, so the caller can add them
# under its own first line ("<project> <tag>" and a blank line) before `git tag -a -F`.
#
# Outputs (to GITHUB_OUTPUT when it is set, and on stdout either way): `lines`, the annotation
# lines, and `rust-version`, `go-version` and `node-version`, the version of each requested
# toolchain as it appears on its line.
#
# Fails closed: an unknown toolchain, a missing tool, or a version that does not have the
# expected shape exits non-zero, before anything is appended or written to GITHUB_OUTPUT.

set -euo pipefail

fail() {
	echo "::error::toolchain-record: $*. Nothing was recorded." >&2
	exit 1
}

# parse_toolchains <list> sets want_rust, want_go and want_node to true for each toolchain in the
# list, and fails on an empty list, an unknown name or a name given twice.
want_rust=false
want_go=false
want_node=false
parse_toolchains() {
	local list=$1 name seen=" " count=0
	local -a names=()
	IFS=$' \t\n' read -r -d '' -a names <<<"${list//,/ }" || true
	for name in "${names[@]}"; do
		case "$name" in
		rust | go | node) ;;
		*) fail "unknown toolchain '$name' in TOOLCHAINS '$list' (want a subset of rust, go and node)" ;;
		esac
		if [[ "$seen" == *" $name "* ]]; then
			fail "toolchain '$name' is listed twice in TOOLCHAINS '$list'"
		fi
		seen+="$name "
		count=$((count + 1))
		printf -v "want_$name" '%s' true
	done
	if [ "$count" -eq 0 ]; then
		fail "TOOLCHAINS is empty (want a subset of rust, go and node)"
	fi
}

if [ "$#" -ne 0 ]; then
	echo "usage: TOOLCHAINS=<list> [ANNOTATION_FILE=<file>] $0" >&2
	exit 2
fi

parse_toolchains "${TOOLCHAINS:-}"

lines=""
rust_version=""
go_version=""
node_version=""

if [ "$want_rust" = true ]; then
	command -v rustc >/dev/null || fail "rustc is not on PATH"
	rust_version=$(rustc --version | awk '{print $2}') || fail "rustc --version failed"
	[[ "$rust_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
		fail "rustc --version reports '$rust_version', not a release version X.Y.Z"
	lines+="Rust: $rust_version"$'\n'
fi

if [ "$want_go" = true ]; then
	command -v go >/dev/null || fail "go is not on PATH"
	go_version=$(go env GOVERSION) || fail "go env GOVERSION failed"
	[[ "$go_version" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] ||
		fail "go env GOVERSION reports '$go_version', not a release version goX.Y.Z"
	lines+="Go: $go_version"$'\n'
fi

if [ "$want_node" = true ]; then
	command -v node >/dev/null || fail "node is not on PATH"
	node_version=$(node --version) || fail "node --version failed"
	[[ "$node_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
		fail "node --version reports '$node_version', not a release version vX.Y.Z"
	lines+="Node: $node_version"$'\n'
fi

if [ -n "${ANNOTATION_FILE:-}" ]; then
	printf '%s' "$lines" >>"$ANNOTATION_FILE"
fi

printf '%s' "$lines"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	delimiter="EOF_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
	{
		echo "lines<<$delimiter"
		printf '%s' "$lines"
		echo "$delimiter"
		echo "rust-version=$rust_version"
		echo "go-version=$go_version"
		echo "node-version=$node_version"
	} >>"$GITHUB_OUTPUT"
fi
