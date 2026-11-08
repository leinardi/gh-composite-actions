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
# Requires every external image in the given Dockerfiles to be pinned by digest, and every download
# in them to be verified by checksum. The checks themselves are check_pinned_bases.py, next to this
# script (its header says what passes and what does not); this wrapper turns the action's newline
# lists into its arguments.
#
#   check-pinned-bases.sh                  reads DOCKERFILES and BUILD_ARGS from the environment
#   check-pinned-bases.sh ARGUMENT...      passes the arguments to check_pinned_bases.py as they are
#
# Environment:
#   DOCKERFILES  newline-separated Dockerfile paths or globs (bash globs, ** included), relative to
#                the working directory; default "Dockerfile" when unset. Every entry must match at
#                least one file, so a renamed Dockerfile fails the check instead of silently leaving
#                it; set but blank is an error, never the default.
#   BUILD_ARGS   newline-separated NAME=VALUE pairs, as docker build --build-arg; blank lines and
#                lines starting with # are skipped.
#   TAG_ONLY_IMAGES  newline-separated registries or repositories (dhi.io, docker.io/library/docker)
#                whose images may be pinned by an explicit tag instead of a digest; blank lines and
#                lines starting with # are skipped.
#
# Exit status: 0 when every file passes, 1 on any finding, 2 when an entry matches no file, a file
# cannot be read or parsed, or a build arg is not NAME=VALUE.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="${here}/check_pinned_bases.py"

if ! command -v python3 >/dev/null; then
	echo "::error::check-pinned-bases: python3 is not on PATH. Nothing was checked." >&2
	exit 2
fi

if [[ $# -gt 0 ]]; then
	exec python3 -I "${checker}" "$@"
fi

shopt -s globstar nullglob extglob

arguments=()
files=()
declare -A seen=()

while IFS= read -r entry; do
	entry="${entry##+([[:space:]])}"
	entry="${entry%%+([[:space:]])}"
	[[ -z ${entry} ]] && continue
	if [[ ${entry} == *[\*\?\[]* ]]; then
		# Unquoted on purpose, so the entry is expanded as a glob; IFS is empty while it is, so a
		# path with spaces is never word-split.
		saved_ifs="${IFS}"
		IFS=''
		# shellcheck disable=SC2206
		matches=(${entry})
		IFS="${saved_ifs}"
		filtered=()
		for match in "${matches[@]}"; do
			[[ -f ${match} ]] && filtered+=("${match}")
		done
		if [[ ${#filtered[@]} -eq 0 ]]; then
			echo "::error::check-pinned-bases: the glob '${entry}' matches no file. Nothing was checked." >&2
			exit 2
		fi
	elif [[ -f ${entry} ]]; then
		filtered=("${entry}")
	else
		echo "::error::check-pinned-bases: '${entry}' is not a file. Nothing was checked." >&2
		exit 2
	fi
	for match in "${filtered[@]}"; do
		if [[ -z ${seen[${match}]:-} ]]; then
			seen[${match}]=1
			files+=("${match}")
		fi
	done
done <<<"${DOCKERFILES-Dockerfile}"

if [[ ${#files[@]} -eq 0 ]]; then
	echo "::error::check-pinned-bases: no Dockerfile given (DOCKERFILES is set but blank). Nothing was checked." >&2
	exit 2
fi

while IFS= read -r pair; do
	pair="${pair##+([[:space:]])}"
	pair="${pair%%+([[:space:]])}"
	[[ -z ${pair} || ${pair} == \#* ]] && continue
	if [[ ! ${pair} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
		echo "::error::check-pinned-bases: the build arg '${pair}' is not NAME=VALUE. Nothing was checked." >&2
		exit 2
	fi
	arguments+=(--build-arg "${pair}")
done <<<"${BUILD_ARGS:-}"

while IFS= read -r prefix; do
	prefix="${prefix##+([[:space:]])}"
	prefix="${prefix%%+([[:space:]])}"
	[[ -z ${prefix} || ${prefix} == \#* ]] && continue
	arguments+=(--tag-only "${prefix}")
done <<<"${TAG_ONLY_IMAGES:-}"

exec python3 -I "${checker}" "${arguments[@]}" -- "${files[@]}"
