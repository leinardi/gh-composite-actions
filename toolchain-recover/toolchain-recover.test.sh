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

# Tests for toolchain-recover.sh. Plain bash, no network: stub rustc, rustup, go, node, uname and
# curl lead a temporary PATH (jq and git are the real ones). The stub rustc answers the newer
# default release unless RUSTUP_TOOLCHAIN is exported to it, and the stub go and node on PATH
# answer the newer default too; only the go and node inside the unpacked tarballs answer the
# recorded version, so a switch counts only when the script selected it in its own process. The
# stub rustup logs what it is asked to install. The stub curl serves Node's tarballs and
# SHASUMS256.txt, and go.dev's release list and Go's tarballs, from a fixture directory.
#
# Run: bash toolchain-recover/toolchain-recover.test.sh

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/toolchain-recover.sh"

# The test must not inherit a switch, or the action's inputs, from the shell that runs it.
unset RUSTUP_TOOLCHAIN GOROOT GOTOOLCHAIN GITHUB_ENV GITHUB_PATH GITHUB_OUTPUT TAG ANNOTATION_FILE \
	INSTALL_DIR RUNNER_TEMP ALLOW_UNRECORDED

default_rust=1.99.0
default_go=go1.99.0
default_node=v24.99.0
recorded_rust=1.98.1
recorded_go=go1.26.1
recorded_node=v24.1.0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir "$work/bin" "$work/fixtures" "$work/fixtures/go"

cat >"$work/bin/rustc" <<'STUB'
#!/usr/bin/env bash
# Stub rustc: `rustc --version` prints RUSTUP_TOOLCHAIN when it is exported (unless
# STUB_RUST_IGNORES_TOOLCHAIN is set, a toolchain switch that does not take), and the default
# release otherwise.
set -euo pipefail
if [ "$*" != "--version" ]; then
	echo "stub rustc: unexpected call: $*" >&2
	exit 98
fi
version=$STUB_RUST_DEFAULT
if [ -n "${RUSTUP_TOOLCHAIN:-}" ] && [ -z "${STUB_RUST_IGNORES_TOOLCHAIN:-}" ]; then
	version=$RUSTUP_TOOLCHAIN
fi
echo "rustc $version (0000000000 2026-01-01)"
STUB

cat >"$work/bin/rustup" <<'STUB'
#!/usr/bin/env bash
# Stub rustup: logs every call to STUB_RUSTUP_LOG, and fails like a failed download when
# STUB_RUSTUP_FAILS is set.
set -euo pipefail
echo "$*" >>"$STUB_RUSTUP_LOG"
if [ -n "${STUB_RUSTUP_FAILS:-}" ]; then
	echo "error: could not download the toolchain" >&2
	exit 1
fi
STUB

cat >"$work/bin/node" <<'STUB'
#!/usr/bin/env bash
# Stub node on the default PATH: the newer default patch.
set -euo pipefail
echo "$STUB_NODE_DEFAULT"
STUB

cat >"$work/bin/go" <<'STUB'
#!/usr/bin/env bash
# Stub go on the default PATH: the newer default release.
set -euo pipefail
if [ "$*" != "env GOVERSION" ]; then
	echo "stub go: unexpected call: $*" >&2
	exit 98
fi
echo "$STUB_GO_DEFAULT"
STUB

cat >"$work/bin/uname" <<'STUB'
#!/usr/bin/env bash
# Stub uname: the machine is STUB_MACHINE, x86_64 by default.
set -euo pipefail
if [ "$*" != "-m" ]; then
	echo "stub uname: unexpected call: $*" >&2
	exit 98
fi
echo "${STUB_MACHINE:-x86_64}"
STUB

cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Stub curl: serves https://nodejs.org/dist/<version>/<file> from STUB_FIXTURES/<version>/<file>,
# https://go.dev/dl/?mode=json&include=all from STUB_FIXTURES/go/releases.json and
# https://go.dev/dl/<file> from STUB_FIXTURES/go/<file>, to the -o path. It logs every URL to
# STUB_LOG, requires the HTTPS-only and retry flags, and fails like curl -f on a missing file.
set -euo pipefail
out=""
url=""
proto=""
retry=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	-o)
		out=$2
		shift 2
		;;
	--proto)
		proto=$2
		shift 2
		;;
	--retry)
		retry=$2
		shift 2
		;;
	--tlsv1.2 | -fsSL)
		shift
		;;
	https://*)
		url=$1
		shift
		;;
	*)
		echo "stub curl: unexpected argument $1" >&2
		exit 98
		;;
	esac
done
if [ "$proto" != "=https" ] || [ "$retry" != 3 ]; then
	echo "stub curl: called without --proto '=https' --retry 3" >&2
	exit 98
fi
echo "$url" >>"$STUB_LOG"
case "$url" in
"https://go.dev/dl/?mode=json&include=all") path=go/releases.json ;;
https://go.dev/dl/*) path=go/${url#https://go.dev/dl/} ;;
https://nodejs.org/dist/*) path=${url#https://nodejs.org/dist/} ;;
*) path="" ;;
esac
if [ -z "$path" ] || [ ! -f "$STUB_FIXTURES/$path" ]; then
	echo "curl: (22) The requested URL returned error: 404" >&2
	exit 22
fi
cp "$STUB_FIXTURES/$path" "$out"
STUB

chmod +x "$work/bin/"*

export PATH="$work/bin:$PATH"
export STUB_LOG="$work/curl.log"
export STUB_FIXTURES="$work/fixtures"
export STUB_RUSTUP_LOG="$work/rustup.log"
export STUB_RUST_DEFAULT="$default_rust"
export STUB_GO_DEFAULT="$default_go"
export STUB_NODE_DEFAULT="$default_node"
# The bitgauge release's shape: Rust and Node, with both musl targets.
export TOOLCHAINS=rust,node
export RUST_TARGETS="x86_64-unknown-linux-musl aarch64-unknown-linux-musl"

# node_release <version> <prints> [arch] builds the fixture of a Node release whose bin/node
# prints <prints>, with a matching SHASUMS256.txt that lists it among other files.
node_release() {
	local version=$1 prints=$2 arch=${3:-x64}
	local name="node-$version-linux-$arch"
	local build="$work/build/$name"
	mkdir -p "$build/bin" "$STUB_FIXTURES/$version"
	printf '#!/usr/bin/env bash\necho %s\n' "$prints" >"$build/bin/node"
	chmod +x "$build/bin/node"
	tar -cJf "$STUB_FIXTURES/$version/$name.tar.xz" -C "$work/build" "$name"
	(
		cd "$STUB_FIXTURES/$version"
		{
			echo "0000000000000000000000000000000000000000000000000000000000000000  $name.tar.gz"
			sha256sum "$name.tar.xz"
			echo "1111111111111111111111111111111111111111111111111111111111111111  node-$version-darwin-$arch.tar.xz"
		} >>SHASUMS256.txt
	)
}

# go_release <version> <prints> [arch] [sha256] builds the fixture of a Go release whose
# go/bin/go prints <prints> for `go env GOVERSION`, and adds it to go.dev's release list, with its
# real sha256 unless one is given.
go_entries="$work/go-entries.jsonl"
: >"$go_entries"
go_release() {
	local version=$1 prints=$2 arch=${3:-amd64} sha=${4:-}
	local name="$version.linux-$arch.tar.gz"
	local build="$work/gobuild/$version-$arch"
	mkdir -p "$build/go/bin"
	printf '#!/usr/bin/env bash\n[ "$*" = "env GOVERSION" ] || exit 98\necho %s\n' "$prints" >"$build/go/bin/go"
	chmod +x "$build/go/bin/go"
	tar -czf "$STUB_FIXTURES/go/$name" -C "$build" go
	if [ -z "$sha" ]; then
		sha=$(sha256sum "$STUB_FIXTURES/go/$name" | cut -d' ' -f1)
	fi
	jq -cn --arg v "$version" --arg f "$name" --arg a "$arch" --arg s "$sha" \
		'{version: $v, files: [{filename: $f, os: "linux", arch: $a, kind: "archive", sha256: $s},
		{filename: ($v + ".src.tar.gz"), os: "", arch: "", kind: "source", sha256: "2222222222222222222222222222222222222222222222222222222222222222"}]}' \
		>>"$go_entries"
}

node_release "$recorded_node" "$recorded_node"
node_release "$recorded_node" "$recorded_node" arm64
# A release whose binary reports another version than the one it was published as.
node_release v24.2.0 v24.0.0
# A release whose tarball does not match its SHASUMS256.txt.
node_release v24.3.0 v24.3.0
sed -i -E 's/^[0-9a-f]{64}(  node-v24\.3\.0-linux-x64\.tar\.xz)$/2222222222222222222222222222222222222222222222222222222222222222\1/' \
	"$STUB_FIXTURES/v24.3.0/SHASUMS256.txt"

go_release "$recorded_go" "$recorded_go"
go_release "$recorded_go" "$recorded_go" arm64
# A release whose binary reports another version than the one it was published as.
go_release go1.26.2 go1.26.0
# A release whose tarball does not match go.dev's list.
go_release go1.26.3 go1.26.3 amd64 3333333333333333333333333333333333333333333333333333333333333333
jq -s . "$go_entries" >"$STUB_FIXTURES/go/releases.json"

failures=0

pass() {
	echo "ok - $1"
}

fail_case() {
	echo "not ok - $1: $2"
	failures=$((failures + 1))
}

# invoke runs the script on a fresh install directory and fresh GITHUB_ENV, GITHUB_PATH and
# GITHUB_OUTPUT files, with whatever TAG or ANNOTATION_FILE the caller set, and sets status, out
# (stdout and stderr), the persisted contents and the outputs.
invoke() {
	rm -rf "$work/install"
	: >"$work/github_env"
	: >"$work/github_path"
	: >"$work/github_output"
	: >"$STUB_LOG"
	: >"$STUB_RUSTUP_LOG"
	status=0
	out=$(GITHUB_ENV="$work/github_env" GITHUB_PATH="$work/github_path" \
		GITHUB_OUTPUT="$work/github_output" INSTALL_DIR="$work/install" \
		"$script" 2>&1) || status=$?
	persisted_env=$(cat "$work/github_env")
	persisted_path=$(cat "$work/github_path")
	outputs=$(cat "$work/github_output")
}

# run <annotation> invokes the script on that annotation, passed as ANNOTATION_FILE.
run() {
	printf '%s' "$1" >"$work/annotation"
	ANNOTATION_FILE="$work/annotation" invoke
}

# expect_nothing_persisted <name> checks that neither file was written.
expect_nothing_persisted() {
	if [ -n "$persisted_env" ] || [ -n "$persisted_path" ]; then
		fail_case "$1" "persisted GITHUB_ENV [$persisted_env] GITHUB_PATH [$persisted_path]"
		return
	fi
	pass "$1"
}

# expect_failure <name> <message> checks a non-zero exit whose output holds <message>, and that
# nothing was persisted.
expect_failure() {
	if [ "$status" -ne 0 ] && grep -qF -- "$2" <<<"$out"; then
		pass "$1"
	else
		fail_case "$1" "exit $status, output [$out]"
	fi
	expect_nothing_persisted "$1 persists nothing"
}

# expect_output <name> <line> checks that GITHUB_OUTPUT holds <line>.
expect_output() {
	if grep -qxF -- "$2" <<<"$outputs"; then
		pass "$1"
	else
		fail_case "$1" "outputs [$outputs]"
	fi
}

annotation() {
	printf 'bitgauge v1.2.3\n\nRust: %s\nNode: %s\n' "$1" "$2"
}

full_annotation() {
	printf 'project v1.2.3\n\nRust: %s\nGo: %s\nNode: %s\n' "$1" "$2" "$3"
}

# --- Kept from bitgauge's recover-toolchains.test.sh (Rust and Node). -------------------------

# A fresh release: no annotation, nothing fetched, nothing persisted.
run ""
if [ "$status" -eq 0 ] && [ ! -s "$STUB_LOG" ]; then
	pass "an empty annotation is a no-op"
else
	fail_case "an empty annotation is a no-op" "exit $status, curl calls [$(cat "$STUB_LOG")], output [$out]"
fi
expect_nothing_persisted "an empty annotation persists nothing"
expect_output "an empty annotation reports mode fresh" "mode=fresh"

invoke
if [ "$status" -eq 0 ] && [ ! -s "$STUB_LOG" ] && grep -qxF "mode=fresh" <<<"$outputs"; then
	pass "neither TAG nor ANNOTATION_FILE is a fresh no-op"
else
	fail_case "neither TAG nor ANNOTATION_FILE is a fresh no-op" "exit $status, output [$out]"
fi
expect_nothing_persisted "neither TAG nor ANNOTATION_FILE persists nothing"

# A tag made before the toolchains were recorded: a warning and no switch when allowed...
ALLOW_UNRECORDED=true run "bitgauge v1.2.3"
if [ "$status" -eq 0 ] && grep -qF '::warning::' <<<"$out" && [ ! -s "$STUB_LOG" ]; then
	pass "an annotation without versions warns and switches nothing when allowed"
else
	fail_case "an annotation without versions warns and switches nothing when allowed" "exit $status, output [$out]"
fi
expect_nothing_persisted "an allowed annotation without versions persists nothing"
expect_output "an allowed annotation without versions reports mode unrecorded" "mode=unrecorded"

# ...and a failure by default.
run "bitgauge v1.2.3"
expect_failure "an annotation without versions fails by default" "records none of the requested toolchains (Rust Node)"

# The recorded versions are already the current ones: nothing to switch.
STUB_RUST_DEFAULT=$recorded_rust STUB_NODE_DEFAULT=$recorded_node run "$(annotation "$recorded_rust" "$recorded_node")"
if [ "$status" -eq 0 ] && [ ! -s "$STUB_LOG" ] && [ ! -s "$STUB_RUSTUP_LOG" ]; then
	pass "recorded versions already current is a no-op"
else
	fail_case "recorded versions already current is a no-op" "exit $status, output [$out]"
fi
expect_nothing_persisted "recorded versions already current persist nothing"
expect_output "recorded versions already current report mode matched" "mode=matched"

# The newer patch is the default; the recorded versions are selected, checked and persisted.
run "$(annotation "$recorded_rust" "$recorded_node")"
if [ "$status" -eq 0 ]; then
	pass "a newer default patch is switched to the recorded versions"
else
	fail_case "a newer default patch is switched to the recorded versions" "exit $status, output [$out]"
fi
if grep -qF "Rust: recorded $recorded_rust, current $default_rust." <<<"$out" &&
	grep -qF "Node: recorded $recorded_node, current $default_node." <<<"$out"; then
	pass "the annotation is parsed"
else
	fail_case "the annotation is parsed" "output [$out]"
fi
if [ "$persisted_env" = "RUSTUP_TOOLCHAIN=$recorded_rust" ]; then
	pass "GITHUB_ENV holds exactly RUSTUP_TOOLCHAIN=$recorded_rust"
else
	fail_case "GITHUB_ENV holds exactly RUSTUP_TOOLCHAIN=$recorded_rust" "got [$persisted_env]"
fi
want_rustup="toolchain install $recorded_rust --profile minimal --target x86_64-unknown-linux-musl --target aarch64-unknown-linux-musl"
if [ "$(cat "$STUB_RUSTUP_LOG")" = "$want_rustup" ]; then
	pass "rustup installs the recorded release with both musl targets"
else
	fail_case "rustup installs the recorded release with both musl targets" "calls [$(cat "$STUB_RUSTUP_LOG")]"
fi
want_path="$work/install/node-$recorded_node-linux-x64/bin"
if [ "$persisted_path" = "$want_path" ] && [ "$("$persisted_path/node")" = "$recorded_node" ]; then
	pass "GITHUB_PATH holds exactly the unpacked Node bin directory"
else
	fail_case "GITHUB_PATH holds exactly the unpacked Node bin directory" "got [$persisted_path], want [$want_path]"
fi
want_urls="https://nodejs.org/dist/$recorded_node/SHASUMS256.txt
https://nodejs.org/dist/$recorded_node/node-$recorded_node-linux-x64.tar.xz"
if [ "$(cat "$STUB_LOG")" = "$want_urls" ]; then
	pass "Node and its checksums come from the recorded release on nodejs.org"
else
	fail_case "Node and its checksums come from the recorded release on nodejs.org" "calls [$(cat "$STUB_LOG")]"
fi
expect_output "a switch reports mode switched" "mode=switched"
expect_output "a switch reports the verified Rust version" "rust-version=$recorded_rust"
expect_output "a switch reports the verified Node version" "node-version=$recorded_node"
expect_output "a switch reports no Go version when Go is not requested" "go-version="

# The stubs prove what the script relies on: none answers the recorded version by itself.
if [ "$(rustc --version | awk '{print $2}')" = "$default_rust" ] && [ "$(node --version)" = "$default_node" ] &&
	[ "$(go env GOVERSION)" = "$default_go" ]; then
	pass "without the switch, rustc, go and node answer the newer default"
else
	fail_case "without the switch, rustc, go and node answer the newer default" "the stubs answer the recorded version unasked"
fi

# The annotation records more than one version of a tool, or one requested tool only: malformed.
run "$(annotation "$recorded_rust" "$recorded_node")
Rust: 1.98.2"
expect_failure "two Rust versions fail" "more than one version for Rust"

run "$(printf 'bitgauge v1.2.3\n\nRust: %s\n' "$recorded_rust")"
expect_failure "a Rust version without a Node version fails" "records no Node version"

# A recorded Rust release rustup cannot install.
STUB_RUSTUP_FAILS=1 run "$(annotation "$recorded_rust" "$recorded_node")"
expect_failure "a failed Rust install fails" "rustup could not install Rust $recorded_rust"

# The tarball does not match SHASUMS256.txt.
run "$(annotation "$recorded_rust" v24.3.0)"
expect_failure "a Node checksum mismatch fails" "but SHASUMS256.txt of Node v24.3.0 lists 2222"

# A release that cannot be downloaded.
run "$(annotation "$recorded_rust" v24.4.0)"
expect_failure "a failed Node download fails" "could not download https://nodejs.org/dist/v24.4.0/SHASUMS256.txt"

# Installed, but node prints another version than the recorded one.
run "$(annotation "$recorded_rust" v24.2.0)"
expect_failure "a Node version mismatch after installation fails" "node --version prints v24.0.0, not the recorded v24.2.0"

# The Rust toolchain switch does not take.
STUB_RUST_IGNORES_TOOLCHAIN=1 run "$(annotation "$recorded_rust" "$recorded_node")"
expect_failure "a Rust version mismatch after the switch fails" "rustc --version prints $default_rust, not the recorded $recorded_rust"

# A missing annotation file.
ANNOTATION_FILE="$work/no-such-file" invoke
if [ "$status" -eq 1 ]; then
	pass "a missing annotation file fails"
else
	fail_case "a missing annotation file fails" "exit $status, output [$out]"
fi

# --- Rust alone. -------------------------------------------------------------------------------

TOOLCHAINS=rust STUB_RUST_DEFAULT=$recorded_rust run "$(full_annotation "$recorded_rust" "$recorded_go" "$recorded_node")"
if [ "$status" -eq 0 ] && [ ! -s "$STUB_RUSTUP_LOG" ] && grep -qxF "mode=matched" <<<"$outputs"; then
	pass "a matching Rust passes and switches nothing"
else
	fail_case "a matching Rust passes and switches nothing" "exit $status, output [$out]"
fi

TOOLCHAINS=rust RUST_TARGETS="" run "$(full_annotation "$recorded_rust" "$recorded_go" "$recorded_node")"
if [ "$status" -eq 0 ] && [ "$persisted_env" = "RUSTUP_TOOLCHAIN=$recorded_rust" ] && [ -z "$persisted_path" ] &&
	[ "$(cat "$STUB_RUSTUP_LOG")" = "toolchain install $recorded_rust --profile minimal" ] && [ ! -s "$STUB_LOG" ]; then
	pass "a mismatching Rust alone is switched, with no targets and no download"
else
	fail_case "a mismatching Rust alone is switched, with no targets and no download" "exit $status, env [$persisted_env], rustup [$(cat "$STUB_RUSTUP_LOG")], output [$out]"
fi

TOOLCHAINS=rust run "$(printf 'p v1\n\nRust: stable\n')"
expect_failure "an unparsable Rust line fails" "Rust line 'Rust: stable' does not parse"

TOOLCHAINS=rust RUST_TARGETS='x86_64;rm' run "$(full_annotation "$recorded_rust" "$recorded_go" "$recorded_node")"
if [ "$status" -eq 2 ] && grep -qF "not a target triple" <<<"$out"; then
	pass "a malformed RUST_TARGETS is a usage error"
else
	fail_case "a malformed RUST_TARGETS is a usage error" "exit $status, output [$out]"
fi

# --- Go. ---------------------------------------------------------------------------------------

TOOLCHAINS=go STUB_GO_DEFAULT=$recorded_go run "$(full_annotation "$recorded_rust" "$recorded_go" "$recorded_node")"
if [ "$status" -eq 0 ] && [ ! -s "$STUB_LOG" ] && grep -qxF "mode=matched" <<<"$outputs" &&
	grep -qxF "go-version=$recorded_go" <<<"$outputs"; then
	pass "a matching Go passes and switches nothing"
else
	fail_case "a matching Go passes and switches nothing" "exit $status, output [$out]"
fi
expect_nothing_persisted "a matching Go persists nothing"

TOOLCHAINS=go run "$(full_annotation "$recorded_rust" "$recorded_go" "$recorded_node")"
want_root="$work/install/$recorded_go.linux-amd64/go"
if [ "$status" -eq 0 ] && grep -qxF "mode=switched" <<<"$outputs" && grep -qxF "go-version=$recorded_go" <<<"$outputs"; then
	pass "a mismatching Go is switched to the recorded release"
else
	fail_case "a mismatching Go is switched to the recorded release" "exit $status, output [$out]"
fi
if [ "$persisted_env" = "GOROOT=$want_root
GOTOOLCHAIN=local" ]; then
	pass "GITHUB_ENV holds exactly GOROOT and GOTOOLCHAIN=local"
else
	fail_case "GITHUB_ENV holds exactly GOROOT and GOTOOLCHAIN=local" "got [$persisted_env]"
fi
if [ "$persisted_path" = "$want_root/bin" ] && [ "$("$persisted_path/go" env GOVERSION)" = "$recorded_go" ]; then
	pass "GITHUB_PATH holds exactly the unpacked Go bin directory"
else
	fail_case "GITHUB_PATH holds exactly the unpacked Go bin directory" "got [$persisted_path]"
fi
want_urls="https://go.dev/dl/?mode=json&include=all
https://go.dev/dl/$recorded_go.linux-amd64.tar.gz"
if [ "$(cat "$STUB_LOG")" = "$want_urls" ]; then
	pass "Go and its checksum come from go.dev"
else
	fail_case "Go and its checksum come from go.dev" "calls [$(cat "$STUB_LOG")]"
fi

TOOLCHAINS=go STUB_MACHINE=aarch64 run "$(full_annotation "$recorded_rust" "$recorded_go" "$recorded_node")"
if [ "$status" -eq 0 ] && [ "$persisted_path" = "$work/install/$recorded_go.linux-arm64/go/bin" ]; then
	pass "an arm64 runner gets the linux-arm64 Go archive"
else
	fail_case "an arm64 runner gets the linux-arm64 Go archive" "exit $status, path [$persisted_path], output [$out]"
fi

TOOLCHAINS=go STUB_MACHINE=riscv64 run "$(full_annotation "$recorded_rust" "$recorded_go" "$recorded_node")"
expect_failure "an unknown machine fails" "no Go or Node release is known for the machine riscv64"

TOOLCHAINS=go run "$(full_annotation "$recorded_rust" go1.26.3 "$recorded_node")"
expect_failure "a Go checksum mismatch fails" "but go.dev's release list for go1.26.3 lists 3333"

TOOLCHAINS=go run "$(full_annotation "$recorded_rust" go1.26.9 "$recorded_node")"
expect_failure "a Go release go.dev does not list fails" "does not list exactly one linux/amd64 archive of go1.26.9"

TOOLCHAINS=go run "$(full_annotation "$recorded_rust" go1.26.2 "$recorded_node")"
expect_failure "a Go version mismatch after installation fails" "go env GOVERSION prints go1.26.0, not the recorded go1.26.2"

TOOLCHAINS=go run "$(printf 'p v1\n\nGo: 1.26.1\nNode: %s\n' "$recorded_node")"
expect_failure "an unparsable Go line fails" "Go line 'Go: 1.26.1' does not parse"

TOOLCHAINS=go,node run "$(annotation "$recorded_rust" "$recorded_node")"
expect_failure "a requested Go without a Go line fails" "records no Go version"

cp "$STUB_FIXTURES/go/releases.json" "$work/releases.json.bak"
echo "<html>not json</html>" >"$STUB_FIXTURES/go/releases.json"
TOOLCHAINS=go run "$(full_annotation "$recorded_rust" "$recorded_go" "$recorded_node")"
expect_failure "an unreadable go.dev release list fails" "go.dev's release list is not the JSON this script reads"
cp "$work/releases.json.bak" "$STUB_FIXTURES/go/releases.json"

# --- Node alone. -------------------------------------------------------------------------------

TOOLCHAINS=node STUB_NODE_DEFAULT=$recorded_node run "$(full_annotation "$recorded_rust" "$recorded_go" "$recorded_node")"
if [ "$status" -eq 0 ] && [ ! -s "$STUB_LOG" ] && grep -qxF "mode=matched" <<<"$outputs"; then
	pass "a matching Node passes and switches nothing"
else
	fail_case "a matching Node passes and switches nothing" "exit $status, output [$out]"
fi

TOOLCHAINS=node STUB_MACHINE=aarch64 run "$(full_annotation "$recorded_rust" "$recorded_go" "$recorded_node")"
if [ "$status" -eq 0 ] && [ -z "$persisted_env" ] && [ "$persisted_path" = "$work/install/node-$recorded_node-linux-arm64/bin" ]; then
	pass "a mismatching Node on arm64 is switched to the linux-arm64 release"
else
	fail_case "a mismatching Node on arm64 is switched to the linux-arm64 release" "exit $status, path [$persisted_path], output [$out]"
fi

TOOLCHAINS=node run "$(printf 'p v1\n\nNode: 24.1.0\n')"
expect_failure "an unparsable Node line fails" "Node line 'Node: 24.1.0' does not parse"

# --- All three. --------------------------------------------------------------------------------

TOOLCHAINS="rust go node" run "$(full_annotation "$recorded_rust" "$recorded_go" "$recorded_node")"
if [ "$status" -eq 0 ] && [ "$persisted_env" = "RUSTUP_TOOLCHAIN=$recorded_rust
GOROOT=$work/install/$recorded_go.linux-amd64/go
GOTOOLCHAIN=local" ] && [ "$persisted_path" = "$work/install/$recorded_go.linux-amd64/go/bin
$work/install/node-$recorded_node-linux-x64/bin" ]; then
	pass "all three toolchains are switched and persisted together"
else
	fail_case "all three toolchains are switched and persisted together" "exit $status, env [$persisted_env], path [$persisted_path], output [$out]"
fi

# One toolchain that fails after the others were selected persists nothing at all.
TOOLCHAINS="rust go node" run "$(full_annotation "$recorded_rust" "$recorded_go" v24.2.0)"
expect_failure "a late Node mismatch after Rust and Go were selected fails" "node --version prints v24.0.0"

# A switch that cannot be persisted fails before anything is fetched.
printf '%s' "$(annotation "$recorded_rust" "$recorded_node")" >"$work/annotation"
status=0
: >"$STUB_LOG"
out=$(ANNOTATION_FILE="$work/annotation" INSTALL_DIR="$work/install" "$script" 2>&1) || status=$?
if [ "$status" -ne 0 ] && grep -qF "GITHUB_ENV and GITHUB_PATH must name" <<<"$out" && [ ! -s "$STUB_LOG" ]; then
	pass "a switch without GITHUB_ENV and GITHUB_PATH fails before any download"
else
	fail_case "a switch without GITHUB_ENV and GITHUB_PATH fails before any download" "exit $status, output [$out]"
fi

# --- Reading the annotation from a tag. --------------------------------------------------------

repo="$work/repo"
git init -q "$repo"
git -C "$repo" -c user.name=t -c user.email=t@example.com -c commit.gpgSign=false -c tag.gpgSign=false commit -q --allow-empty -m "the release commit"
full_annotation "$recorded_rust" "$recorded_go" "$recorded_node" |
	git -C "$repo" -c user.name=t -c user.email=t@example.com -c commit.gpgSign=false -c tag.gpgSign=false tag -a v1.2.3 -F -
git -C "$repo" tag v1.2.4
git -C "$repo" -c user.name=t -c user.email=t@example.com -c commit.gpgSign=false -c tag.gpgSign=false tag -a v1.2.5 -m "project v1.2.5"

(cd "$repo" && TAG=v1.2.3 TOOLCHAINS="go,node" invoke && declare -p status out persisted_env persisted_path) >"$work/tag-result"
# shellcheck source=/dev/null
. "$work/tag-result"
if [ "$status" -eq 0 ] && grep -qF "Go: recorded $recorded_go" <<<"$out" && [ -n "$persisted_path" ]; then
	pass "an annotated tag's toolchains are read and switched to"
else
	fail_case "an annotated tag's toolchains are read and switched to" "exit $status, output [$out]"
fi

(cd "$repo" && TAG=v1.2.4 invoke && declare -p status out persisted_env persisted_path) >"$work/tag-result"
# shellcheck source=/dev/null
. "$work/tag-result"
expect_failure "a lightweight tag fails" "v1.2.4 is a lightweight tag"

(cd "$repo" && TAG=v9.9.9 invoke && declare -p status out persisted_env persisted_path) >"$work/tag-result"
# shellcheck source=/dev/null
. "$work/tag-result"
expect_failure "a missing tag fails" "the tag v9.9.9 does not exist"

(cd "$repo" && TAG=v1.2.5 invoke && declare -p status out persisted_env persisted_path) >"$work/tag-result"
# shellcheck source=/dev/null
. "$work/tag-result"
expect_failure "an annotated tag without versions fails" "records none of the requested toolchains"

# --- Usage errors. -----------------------------------------------------------------------------

# usage_error <name> <message> <command...> checks exit 2 with <message>.
usage_error() {
	local name=$1 message=$2 code=0 output
	shift 2
	output=$("$@" 2>&1) || code=$?
	if [ "$code" -eq 2 ] && grep -qF -- "$message" <<<"$output"; then
		pass "$name"
	else
		fail_case "$name" "exit $code, output [$output]"
	fi
}

usage_error "an argument is a usage error" "takes no arguments" "$script" "$work/annotation"
usage_error "an empty TOOLCHAINS is a usage error" "TOOLCHAINS is empty" env TOOLCHAINS=" , " "$script"
usage_error "an unknown toolchain is a usage error" "unknown toolchain 'python'" env TOOLCHAINS=rust,python "$script"
usage_error "a toolchain listed twice is a usage error" "'rust' is listed twice" env TOOLCHAINS="rust node rust" "$script"
usage_error "TAG and ANNOTATION_FILE together are a usage error" "not both" env TAG=v1.2.3 ANNOTATION_FILE="$work/annotation" "$script"
usage_error "a malformed ALLOW_UNRECORDED is a usage error" "ALLOW_UNRECORDED is 'yes'" env ALLOW_UNRECORDED=yes "$script"

if [ "$failures" -ne 0 ]; then
	echo "$failures case(s) failed" >&2
	exit 1
fi

echo "all cases passed"
