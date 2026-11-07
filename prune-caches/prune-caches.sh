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
# Deletes the older GitHub Actions cache entries of one ref under one key prefix, keeping the
# newest KEEP. Each change to a cache key saves a new entry, and the old ones sit in the
# repository's cache quota until GitHub evicts them, possibly pushing out entries still in use.
#
# Inputs (environment):
#   GH_TOKEN    a token with `actions: write` on GH_REPO (listing needs `actions: read`)
#   GH_REPO     owner/name
#   CACHE_REF   the ref whose entries are pruned, such as refs/heads/main
#   KEY_PREFIX  the key prefix, matched as a prefix by the API: include the separator that ends
#               it (`pre-commit|`), or `go-` would also match `go-lint-...`
#   KEEP        how many of the newest entries to keep, a whole number >= 1
#
# Without the permission (HTTP 403 "Resource not accessible by integration", on the list or on a
# delete) the prune is skipped with a warning and exits 0, so a caller that does not grant
# `actions: write` keeps working as before. Any other 403, such as a rate limit, fails.
# An entry already gone (another run, or GitHub's eviction) is not an error. Any other error
# fails. At most the 100 newest entries are looked at in one run.

set -euo pipefail

fail() {
	echo "::error title=prune-caches::$*" >&2
	exit 1
}

KEEP="${KEEP:-}"
KEY_PREFIX="${KEY_PREFIX:-}"
CACHE_REF="${CACHE_REF:-}"
GH_REPO="${GH_REPO:-}"

if [[ ! "${KEEP}" =~ ^[0-9]+$ ]] || ((10#${KEEP} < 1)); then
	fail "keep must be a whole number >= 1, got '${KEEP}'. Nothing was deleted."
fi
keep=$((10#${KEEP}))
# An empty prefix matches every entry of the ref, which is never what a caller means.
if [[ -z "${KEY_PREFIX}" ]]; then
	fail "key-prefix is empty, which would match every cache of ${CACHE_REF:-the ref}. Nothing was deleted."
fi
if [[ ! "${CACHE_REF}" =~ ^refs/[^[:space:]]+$ ]]; then
	fail "ref must be a full ref such as refs/heads/main, got '${CACHE_REF}'. Nothing was deleted."
fi
if [[ ! "${GH_REPO}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
	fail "the repository must be owner/name, got '${GH_REPO}'. Nothing was deleted."
fi
export GH_REPO

err="$(mktemp)"
trap 'rm -f "${err}"' EXIT

# gh reports a missing permission as "HTTP 403: Resource not accessible by integration" on
# stderr, for the list (actions: read) and the delete (actions: write) alike. GitHub also answers
# 403 for a rate limit, which is an error to fail on, not a grant to skip for: only the permission
# message counts.
missing_permission() {
	grep -q 'HTTP 403' "${err}" && grep -q 'Resource not accessible by integration' "${err}"
}
skip_without_permission() {
	echo "::warning title=Cache prune skipped::The token does not grant 'actions: write', so the older '${KEY_PREFIX}' caches on ${CACHE_REF} were not deleted. Grant it on the calling job to prune them."
	exit 0
}

if ! ids="$(gh cache list --ref "${CACHE_REF}" --key "${KEY_PREFIX}" --sort created_at --order desc \
	--limit 100 --json id --jq ".[${keep}:][].id" 2>"${err}")"; then
	if missing_permission; then
		skip_without_permission
	fi
	cat "${err}" >&2
	fail "Listing the '${KEY_PREFIX}' caches on ${CACHE_REF} failed. Nothing was deleted."
fi

if [[ -z "${ids}" ]]; then
	echo "Nothing to prune: at most ${keep} '${KEY_PREFIX}' caches on ${CACHE_REF}."
	exit 0
fi

# One id per line; read as lines, so an unexpected entry is never word-split or globbed.
mapfile -t id_list <<<"${ids}"
for id in "${id_list[@]}"; do
	if [[ ! "${id}" =~ ^[0-9]+$ ]]; then
		fail "The cache list returned '${id}', which is not a cache id. Stopped before deleting it."
	fi
	if gh cache delete "${id}" 2>"${err}"; then
		echo "Deleted cache ${id}."
	elif missing_permission; then
		skip_without_permission
	elif grep -q 'Could not find a cache' "${err}"; then
		# Another run, or GitHub's own eviction, got there first.
		echo "Cache ${id} is already gone."
	else
		cat "${err}" >&2
		fail "Deleting cache ${id} failed; the entries listed before it were deleted."
	fi
done
