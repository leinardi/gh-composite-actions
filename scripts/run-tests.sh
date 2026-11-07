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
# Runs every action's script tests: each <action>/*.test.sh, one after the other, and fails if
# any of them fails or if there is none at all. Each test file is self-contained: it stubs the
# commands it needs (gh, git, curl, docker, ...) on PATH and never touches the network.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

mapfile -t tests < <(git ls-files -- '*/*.test.sh' | sort)
if [[ ${#tests[@]} -eq 0 ]]; then
	echo "No */*.test.sh files found: nothing to test." >&2
	exit 1
fi

failed=()
for test in "${tests[@]}"; do
	echo "== ${test}"
	if ! bash "${test}"; then
		failed+=("${test}")
	fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
	echo "Failed:" >&2
	printf '  %s\n' "${failed[@]}" >&2
	exit 1
fi
echo "All ${#tests[@]} test files passed."
