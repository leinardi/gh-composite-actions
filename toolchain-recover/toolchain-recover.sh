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

# Usage: TOOLCHAINS=<list> [TAG=<tag> | ANNOTATION_FILE=<file>] [INSTALL_DIR=<dir>] \
#        [RUST_TARGETS=<list>] [ALLOW_UNRECORDED=true|false] toolchain-recover.sh
#
# A recovery's switch to the toolchains a release tag records. toolchain-record writes them into
# the tag's annotation when the tag is created,
#
#   Rust: 1.98.1
#   Go: go1.26.1
#   Node: v24.1.0
#
# while on a later day the Node major resolves to a newer patch, a `check-latest` Go to a newer
# release, and rust-toolchain.toml may have moved on since the tag. A recovery rebuilds with
# exactly the recorded versions, so its binaries are byte-identical to the first attempt's and the
# published assets can be checked by SHA-256.
#
# Inputs (environment):
#   TOOLCHAINS        a comma- or space-separated subset of rust, go and node: the toolchains the
#                     annotation must record and the job must end up with. Required.
#   TAG               an existing annotated tag whose annotation is read with git, or
#   ANNOTATION_FILE   a file holding the annotation as `git tag -l --format='%(contents)'` prints
#                     it. At most one of the two. With neither, or an empty file, the run is a
#                     fresh release with nothing to recover, and the script is a no-op.
#   INSTALL_DIR       where Go and Node releases are unpacked; defaults to RUNNER_TEMP.
#   RUST_TARGETS      comma- or space-separated targets rustup installs with a recorded Rust.
#   ALLOW_UNRECORDED  true lets an annotation that records none of the requested toolchains (a tag
#                     made before they were recorded) pass with a warning and no switch; false,
#                     the default, fails on it.
#
# For each requested toolchain whose current version differs from the recorded one, the script
# first selects the recorded version in its own process:
#   - Rust: RUSTUP_TOOLCHAIN=<version> is exported, which outranks rust-toolchain.toml, and rustup
#     installs that release (profile minimal, plus RUST_TARGETS);
#   - Go: <version>.linux-<arch>.tar.gz is downloaded from https://go.dev/dl/, checked against the
#     sha256 that go.dev's own release list (?mode=json&include=all) gives it, unpacked under
#     INSTALL_DIR, its bin directory put at the front of PATH, GOROOT set to it, and
#     GOTOOLCHAIN=local exported so a go.mod toolchain line cannot switch to another release;
#   - Node: node-<version>-linux-<arch>.tar.xz is downloaded from https://nodejs.org/dist/<version>/,
#     checked against that release's SHASUMS256.txt, unpacked under INSTALL_DIR, and its bin
#     directory put at the front of PATH.
# actions/setup-go and setup-node cannot be driven from a script, and running them a second time
# from the workflow (an `if:` on their outputs) leaves nothing that checks the switch took. Here
# the same process then checks that `rustc --version`, `go env GOVERSION` and `node --version`
# print the recorded versions, and only then persists the switch for the later steps of the job:
# RUSTUP_TOOLCHAIN, GOROOT and GOTOOLCHAIN to the file named by GITHUB_ENV, the Go and Node bin
# directories to the file named by GITHUB_PATH.
#
# Outputs (to GITHUB_OUTPUT when it is set): `mode`, one of fresh, unrecorded, matched (already the
# recorded versions) or switched, and `rust-version`, `go-version` and `node-version`, the
# verified active version of each requested toolchain (empty for fresh and unrecorded).
#
# Fails closed, persisting nothing: a malformed annotation (a requested toolchain without a line,
# a line twice, a line whose version does not parse), a missing or lightweight tag, a download or
# checksum failure, or a version that does not match after the switch exits non-zero.

set -euo pipefail

usage() {
	echo "::error::toolchain-recover: $*. Nothing was switched." >&2
	echo "usage: TOOLCHAINS=<list> [TAG=<tag> | ANNOTATION_FILE=<file>] [INSTALL_DIR=<dir>] [RUST_TARGETS=<list>] [ALLOW_UNRECORDED=true|false] $0" >&2
	exit 2
}

fail() {
	echo "::error::toolchain-recover: $*. Nothing was switched." >&2
	exit 1
}

if [ "$#" -ne 0 ]; then
	usage "takes no arguments, only environment variables"
fi

# split <list> prints the comma- or whitespace-separated words of a list, one per line.
split() {
	local -a words=()
	IFS=$' \t\n' read -r -d '' -a words <<<"${1//,/ }" || true
	if [ "${#words[@]}" -gt 0 ]; then
		printf '%s\n' "${words[@]}"
	fi
}

want_rust=false
want_go=false
want_node=false
requested=0
while IFS= read -r name; do
	case "$name" in
	rust | go | node) ;;
	*) usage "unknown toolchain '$name' in TOOLCHAINS '${TOOLCHAINS:-}' (want a subset of rust, go and node)" ;;
	esac
	var="want_$name"
	if [ "${!var}" = true ]; then
		usage "toolchain '$name' is listed twice in TOOLCHAINS '${TOOLCHAINS:-}'"
	fi
	printf -v "$var" '%s' true
	requested=$((requested + 1))
done < <(split "${TOOLCHAINS:-}")
if [ "$requested" -eq 0 ]; then
	usage "TOOLCHAINS is empty (want a subset of rust, go and node)"
fi

rust_targets=()
while IFS= read -r target; do
	if ! [[ "$target" =~ ^[A-Za-z0-9_.-]+$ ]]; then
		usage "RUST_TARGETS holds '$target', not a target triple"
	fi
	rust_targets+=(--target "$target")
done < <(split "${RUST_TARGETS:-}")

allow_unrecorded=${ALLOW_UNRECORDED:-false}
case "$allow_unrecorded" in
true | false) ;;
*) usage "ALLOW_UNRECORDED is '$allow_unrecorded', want true or false" ;;
esac

if [ -n "${TAG:-}" ] && [ -n "${ANNOTATION_FILE:-}" ]; then
	usage "set TAG or ANNOTATION_FILE, not both"
fi

write_outputs() {
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		{
			echo "mode=$1"
			echo "rust-version=${2:-}"
			echo "go-version=${3:-}"
			echo "node-version=${4:-}"
		} >>"$GITHUB_OUTPUT"
	fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
annotation="$work/annotation"

if [ -n "${TAG:-}" ]; then
	if ! git check-ref-format "refs/tags/$TAG"; then
		fail "'$TAG' is not a valid tag name"
	fi
	if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
		fail "the tag $TAG does not exist in this clone (check out with fetch-tags, or pass the annotation)"
	fi
	tag_type=$(git cat-file -t "refs/tags/$TAG") || fail "git cat-file -t refs/tags/$TAG failed"
	if [ "$tag_type" != tag ]; then
		fail "$TAG is a lightweight tag (it names a $tag_type), so it records no toolchains"
	fi
	git for-each-ref --format='%(contents)' "refs/tags/$TAG" >"$annotation" ||
		fail "could not read the annotation of $TAG"
	if [ ! -s "$annotation" ]; then
		# An annotated tag with an empty message records nothing; it is not a fresh release.
		echo "(empty annotation)" >"$annotation"
	fi
elif [ -n "${ANNOTATION_FILE:-}" ]; then
	if [ ! -f "$ANNOTATION_FILE" ]; then
		fail "ANNOTATION_FILE $ANNOTATION_FILE is not a file"
	fi
	cp "$ANNOTATION_FILE" "$annotation"
else
	: >"$annotation"
fi

if [ ! -s "$annotation" ]; then
	echo "No tag annotation: a fresh release, nothing to recover."
	write_outputs fresh
	exit 0
fi

# recorded <label> <version-regex> prints the one version the annotation records on its
# `<label>: ` line, nothing when it has no such line, and fails when it has more than one or when
# the version does not parse.
recorded() {
	local label=$1 regex=$2 matches count
	matches=$(grep -E "^${label}:" "$annotation" || true)
	count=$(grep -c . <<<"$matches" || true)
	if [ "$count" -gt 1 ]; then
		fail "the annotation records more than one version for ${label}: $(tr '\n' ' ' <<<"$matches")"
	fi
	if [ "$count" -eq 0 ]; then
		return 0
	fi
	if ! [[ "$matches" =~ ^${label}:\ (${regex})$ ]]; then
		fail "the annotation's ${label} line '$matches' does not parse as '${label}: <version>'"
	fi
	echo "${BASH_REMATCH[1]}"
}

rust_regex='[0-9]+\.[0-9]+\.[0-9]+'
go_regex='go[0-9]+\.[0-9]+(\.[0-9]+)?'
node_regex='v[0-9]+\.[0-9]+\.[0-9]+'

rec_rust=""
rec_go=""
rec_node=""
if [ "$want_rust" = true ]; then rec_rust=$(recorded Rust "$rust_regex"); fi
if [ "$want_go" = true ]; then rec_go=$(recorded Go "$go_regex"); fi
if [ "$want_node" = true ]; then rec_node=$(recorded Node "$node_regex"); fi

missing=()
if [ "$want_rust" = true ] && [ -z "$rec_rust" ]; then missing+=(Rust); fi
if [ "$want_go" = true ] && [ -z "$rec_go" ]; then missing+=(Go); fi
if [ "$want_node" = true ] && [ -z "$rec_node" ]; then missing+=(Node); fi

if [ "${#missing[@]}" -eq "$requested" ]; then
	if [ "$allow_unrecorded" = true ]; then
		echo "::warning::The tag annotation records none of ${missing[*]}, so the binaries are rebuilt with the current toolchains. If they differ from the published assets, the release's asset check has to stop the run for a human."
		write_outputs unrecorded
		exit 0
	fi
	fail "the tag annotation records none of the requested toolchains (${missing[*]}), so there is nothing to recover them from; set ALLOW_UNRECORDED=true to rebuild a tag made before they were recorded"
fi
if [ "${#missing[@]}" -gt 0 ]; then
	fail "the annotation records no ${missing[*]} version, but TOOLCHAINS '${TOOLCHAINS}' asks for it"
fi

# The active versions, empty when the tool is not installed at all.
rust_version() { rustc --version 2>/dev/null | awk '{print $2}' || true; }
go_version() { go env GOVERSION 2>/dev/null || true; }
node_version() { node --version 2>/dev/null || true; }

switch_rust=false
switch_go=false
switch_node=false
if [ "$want_rust" = true ]; then
	cur=$(rust_version)
	echo "Rust: recorded $rec_rust, current ${cur:-none}."
	if [ "$cur" != "$rec_rust" ]; then switch_rust=true; fi
fi
if [ "$want_go" = true ]; then
	cur=$(go_version)
	echo "Go: recorded $rec_go, current ${cur:-none}."
	if [ "$cur" != "$rec_go" ]; then switch_go=true; fi
fi
if [ "$want_node" = true ]; then
	cur=$(node_version)
	echo "Node: recorded $rec_node, current ${cur:-none}."
	if [ "$cur" != "$rec_node" ]; then switch_node=true; fi
fi

if [ "$switch_rust" = false ] && [ "$switch_go" = false ] && [ "$switch_node" = false ]; then
	echo "Every requested toolchain is already the recorded one: nothing to switch."
	write_outputs matched "$rec_rust" "$rec_go" "$rec_node"
	exit 0
fi

# Checked before anything is fetched, so a run that could not persist the switch fails up front.
if [ -z "${GITHUB_ENV:-}" ] || [ -z "${GITHUB_PATH:-}" ]; then
	fail "GITHUB_ENV and GITHUB_PATH must name the files the switch is persisted to"
fi

install_dir=${INSTALL_DIR:-${RUNNER_TEMP:-}}
if { [ "$switch_go" = true ] || [ "$switch_node" = true ]; } && [ -z "$install_dir" ]; then
	fail "INSTALL_DIR (or RUNNER_TEMP) must name where Go and Node are unpacked"
fi

go_arch=""
node_arch=""
if [ "$switch_go" = true ] || [ "$switch_node" = true ]; then
	machine=$(uname -m)
	case "$machine" in
	x86_64 | amd64)
		go_arch=amd64
		node_arch=x64
		;;
	aarch64 | arm64)
		go_arch=arm64
		node_arch=arm64
		;;
	*) fail "no Go or Node release is known for the machine $machine" ;;
	esac
fi

# fetch <url> <out> downloads one file, over HTTPS only.
fetch() {
	curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$2" "$1" || fail "could not download $1"
}

# verify_sha256 <dir> <file> <sha256> <source> checks a download against its published digest.
verify_sha256() {
	local dir=$1 file=$2 want=$3 source=$4 got
	if ! (cd "$dir" && printf '%s  %s\n' "$want" "$file" | sha256sum --check --strict --status); then
		got=$(sha256sum "$dir/$file" | cut -d' ' -f1)
		fail "$file has sha256 $got, but $source lists $want"
	fi
}

if [ "$switch_rust" = true ]; then
	command -v rustup >/dev/null || fail "rustup is not on PATH, so Rust $rec_rust cannot be installed"
	rustup toolchain install "$rec_rust" --profile minimal "${rust_targets[@]}" ||
		fail "rustup could not install Rust $rec_rust"
	export RUSTUP_TOOLCHAIN="$rec_rust"
fi

go_root=""
if [ "$switch_go" = true ]; then
	file="${rec_go}.linux-${go_arch}.tar.gz"
	fetch "https://go.dev/dl/?mode=json&include=all" "$work/go-releases.json"
	entries=$(jq -r --arg v "$rec_go" --arg a "$go_arch" \
		'.[] | select(.version == $v) | .files[] | select(.os == "linux" and .arch == $a and .kind == "archive") | "\(.sha256) \(.filename)"' \
		"$work/go-releases.json") || fail "go.dev's release list is not the JSON this script reads"
	if [ "$(grep -c . <<<"$entries" || true)" -ne 1 ]; then
		fail "go.dev's release list does not list exactly one linux/$go_arch archive of $rec_go (found: '$(tr '\n' ' ' <<<"$entries")')"
	fi
	read -r go_sha go_file <<<"$entries"
	if [ "$go_file" != "$file" ] || ! [[ "$go_sha" =~ ^[0-9a-f]{64}$ ]]; then
		fail "go.dev's release list gives '$go_file' with sha256 '$go_sha', want $file with a sha256"
	fi
	fetch "https://go.dev/dl/$file" "$work/$file"
	verify_sha256 "$work" "$file" "$go_sha" "go.dev's release list for $rec_go"
	dest="$install_dir/${rec_go}.linux-${go_arch}"
	rm -rf "$dest"
	mkdir -p "$dest"
	tar -xzf "$work/$file" -C "$dest" || fail "could not unpack $file"
	go_root="$dest/go"
	if [ ! -x "$go_root/bin/go" ]; then
		fail "$file has no executable go/bin/go"
	fi
	export GOROOT="$go_root" GOTOOLCHAIN=local
	export PATH="$go_root/bin:$PATH"
	hash -r
fi

node_bin=""
if [ "$switch_node" = true ]; then
	release="node-${rec_node}-linux-${node_arch}"
	tarball="${release}.tar.xz"
	base_url="https://nodejs.org/dist/${rec_node}"
	fetch "$base_url/SHASUMS256.txt" "$work/SHASUMS256.txt"
	fetch "$base_url/$tarball" "$work/$tarball"
	expected=$(awk -v name="$tarball" '$2 == name {print $1}' "$work/SHASUMS256.txt")
	if [ -z "$expected" ] || [ "$(grep -c . <<<"$expected")" -ne 1 ]; then
		fail "SHASUMS256.txt of Node $rec_node does not list $tarball exactly once"
	fi
	verify_sha256 "$work" "$tarball" "$expected" "SHASUMS256.txt of Node $rec_node"
	mkdir -p "$install_dir"
	rm -rf "${install_dir:?}/$release"
	tar -xJf "$work/$tarball" -C "$install_dir" || fail "could not unpack $tarball"
	node_bin="$install_dir/$release/bin"
	if [ ! -x "$node_bin/node" ]; then
		fail "$tarball has no executable bin/node"
	fi
	export PATH="$node_bin:$PATH"
	hash -r
fi

# The same process that selected them must see exactly the recorded versions before anything is
# persisted: a switch that did not take would otherwise reach the build.
if [ "$want_rust" = true ]; then
	got=$(rust_version)
	[ "$got" = "$rec_rust" ] || fail "after the switch, rustc --version prints ${got:-nothing}, not the recorded $rec_rust"
fi
if [ "$want_go" = true ]; then
	got=$(go_version)
	[ "$got" = "$rec_go" ] || fail "after the switch, go env GOVERSION prints ${got:-nothing}, not the recorded $rec_go"
fi
if [ "$want_node" = true ]; then
	got=$(node_version)
	[ "$got" = "$rec_node" ] || fail "after the switch, node --version prints ${got:-nothing}, not the recorded $rec_node"
fi

if [ "$switch_rust" = true ]; then
	echo "RUSTUP_TOOLCHAIN=$rec_rust" >>"$GITHUB_ENV"
fi
if [ "$switch_go" = true ]; then
	{
		echo "GOROOT=$go_root"
		echo "GOTOOLCHAIN=local"
	} >>"$GITHUB_ENV"
	echo "$go_root/bin" >>"$GITHUB_PATH"
fi
if [ "$switch_node" = true ]; then
	echo "$node_bin" >>"$GITHUB_PATH"
fi

switched=()
if [ "$switch_rust" = true ]; then switched+=("Rust $rec_rust"); fi
if [ "$switch_go" = true ]; then switched+=("Go $rec_go"); fi
if [ "$switch_node" = true ]; then switched+=("Node $rec_node"); fi
echo "Switched to ${switched[*]} for the rest of the job; every requested toolchain is the recorded one."
write_outputs switched "$rec_rust" "$rec_go" "$rec_node"
