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
# Tests prune-caches.sh. `gh` is replaced by a stub (below) that serves a fixed cache list
# through the real jq, records every call, and fails the way the GitHub API does when asked to.
# The cases are those of gh-reusable-workflows' scripts/test-pre-commit-warmup.sh, plus the
# input checks this action adds.
#
# Needs: bash, jq.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/prune-caches.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The gh stub. State lives under $GH_STUB_DIR:
#   caches     the JSON array `gh cache list --json id` returns, newest first
#   list_fail  if present, `gh cache list` fails with its content on stderr
#   del_fail   if present, `gh cache delete` fails with its content on stderr
#   calls      one line per invocation
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$GH_STUB_DIR/calls"
case "$1 $2" in
"cache list")
	if [ -e "$GH_STUB_DIR/list_fail" ]; then
		cat "$GH_STUB_DIR/list_fail" >&2
		exit 1
	fi
	expr=""
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--jq) expr=$2; shift 2 ;;
		*) shift ;;
		esac
	done
	jq -r "$expr" "$GH_STUB_DIR/caches"
	;;
"cache delete")
	if [ -e "$GH_STUB_DIR/del_fail" ]; then
		cat "$GH_STUB_DIR/del_fail" >&2
		exit 1
	fi
	;;
*) echo "unexpected gh $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/gh"
PATH="$WORK/bin:$PATH"

PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	echo "ok - $1"
}
not_ok() {
	FAIL=$((FAIL + 1))
	echo "not ok - $1"
	printf '%s\n' "$2" | sed 's/^/       /'
}

# A fresh stub state with caches 5 (newest) down to 1 (oldest).
reset() {
	export GH_STUB_DIR="$WORK/state"
	rm -rf "$GH_STUB_DIR"
	mkdir -p "$GH_STUB_DIR"
	echo '[{"id":5},{"id":4},{"id":3},{"id":2},{"id":1}]' >"$GH_STUB_DIR/caches"
	: >"$GH_STUB_DIR/calls"
}

# prune KEEP [ENV=VALUE...]: runs the script as the action would; sets STATUS and LOG.
prune() {
	local keep=$1
	shift
	STATUS=0
	LOG=$(env GH_REPO=owner/repo CACHE_REF=refs/heads/main KEY_PREFIX="pre-commit|" KEEP="$keep" "$@" \
		bash "$SCRIPT" 2>&1) || STATUS=$?
}
deleted() { sed -n 's/^cache delete //p' "$GH_STUB_DIR/calls" | tr '\n' ' '; }
fails() {
	not_ok "$1" "status=$STATUS deleted=[$(deleted)]
$LOG
$(cat "$GH_STUB_DIR/calls")"
}

reset
prune 2
if [ "$STATUS" -eq 0 ] && [ "$(deleted)" = "3 2 1 " ]; then
	ok "keeps the newest two and deletes the rest"
else
	fails "keeps the newest two and deletes the rest"
fi
if grep -q -- "--ref refs/heads/main --key pre-commit| --sort created_at --order desc" "$GH_STUB_DIR/calls"; then
	ok "lists only the given ref, under the key prefix as given"
else
	fails "lists only the given ref, under the key prefix as given"
fi

reset
prune 5
if [ "$STATUS" -eq 0 ] && [ -z "$(deleted)" ] && grep -q "Nothing to prune" <<<"$LOG"; then
	ok "deletes nothing when there are no more caches than it keeps"
else
	fails "deletes nothing when there are no more caches than it keeps"
fi

reset
prune 1
if [ "$STATUS" -eq 0 ] && [ "$(deleted)" = "4 3 2 1 " ]; then
	ok "keep 1 keeps only the newest"
else
	fails "keep 1 keeps only the newest"
fi

reset
prune 01
if [ "$STATUS" -eq 0 ] && [ "$(deleted)" = "4 3 2 1 " ]; then
	ok "keep with a leading zero is read as decimal"
else
	fails "keep with a leading zero is read as decimal"
fi

for bad in 0 -1 abc 1.5 "" " 2"; do
	reset
	prune "$bad"
	if [ "$STATUS" -ne 0 ] && [ ! -s "$GH_STUB_DIR/calls" ] && grep -q "::error" <<<"$LOG"; then
		ok "keep '$bad' fails before calling gh"
	else
		fails "keep '$bad' fails before calling gh"
	fi
done

for case in "KEY_PREFIX=:key-prefix is empty" "CACHE_REF=main:ref must be a full ref" "CACHE_REF=:ref must be a full ref" \
	"GH_REPO=:owner/name" "GH_REPO=owner/repo/extra:owner/name"; do
	assignment=${case%%:*}
	pattern=${case#*:}
	reset
	prune 2 "$assignment"
	if [ "$STATUS" -ne 0 ] && [ ! -s "$GH_STUB_DIR/calls" ] && grep -q "$pattern" <<<"$LOG"; then
		ok "$assignment fails before calling gh"
	else
		fails "$assignment fails before calling gh"
	fi
done

reset
echo "X Failed to get caches: HTTP 403: Resource not accessible by integration" >"$GH_STUB_DIR/list_fail"
prune 2
if [ "$STATUS" -eq 0 ] && [ -z "$(deleted)" ] && grep -q "^::warning" <<<"$LOG"; then
	ok "a caller without actions permissions gets a warning and a skipped prune"
else
	fails "a caller without actions permissions gets a warning and a skipped prune"
fi

reset
echo "X Failed to delete cache: HTTP 403: Resource not accessible by integration" >"$GH_STUB_DIR/del_fail"
prune 2
if [ "$STATUS" -eq 0 ] && [ "$(deleted)" = "3 " ] && grep -q "^::warning" <<<"$LOG"; then
	ok "a caller with actions: read only gets a warning after the first refused delete"
else
	fails "a caller with actions: read only gets a warning after the first refused delete"
fi

reset
echo "X Failed to get caches: HTTP 403: You have exceeded a secondary rate limit. Please wait a few minutes before you try again." >"$GH_STUB_DIR/list_fail"
prune 2
if [ "$STATUS" -ne 0 ] && grep -q "secondary rate limit" <<<"$LOG" && ! grep -q "^::warning" <<<"$LOG" && [ -z "$(deleted)" ]; then
	ok "a 403 rate limit on the list fails instead of skipping"
else
	fails "a 403 rate limit on the list fails instead of skipping"
fi

reset
echo "X Failed to delete cache: HTTP 403: API rate limit exceeded for installation ID 1." >"$GH_STUB_DIR/del_fail"
prune 2
if [ "$STATUS" -ne 0 ] && grep -q "rate limit exceeded" <<<"$LOG" && ! grep -q "^::warning" <<<"$LOG" && [ "$(deleted)" = "3 " ]; then
	ok "a 403 rate limit on a delete fails instead of skipping"
else
	fails "a 403 rate limit on a delete fails instead of skipping"
fi

reset
echo "X Could not find a cache matching 3 in owner/repo" >"$GH_STUB_DIR/del_fail"
prune 2
if [ "$STATUS" -eq 0 ] && [ "$(deleted)" = "3 2 1 " ]; then
	ok "a cache another run already deleted is not an error"
else
	fails "a cache another run already deleted is not an error"
fi

reset
echo "X Failed to get caches: HTTP 502: Bad Gateway" >"$GH_STUB_DIR/list_fail"
prune 2
if [ "$STATUS" -ne 0 ] && grep -q "HTTP 502" <<<"$LOG" && [ -z "$(deleted)" ]; then
	ok "any other list error fails the job"
else
	fails "any other list error fails the job"
fi

reset
echo "X Failed to delete cache: HTTP 500: Internal Server Error" >"$GH_STUB_DIR/del_fail"
prune 2
if [ "$STATUS" -ne 0 ] && grep -q "HTTP 500" <<<"$LOG" && [ "$(deleted)" = "3 " ]; then
	ok "any other delete error fails the job at once"
else
	fails "any other delete error fails the job at once"
fi

reset
echo '[{"id":5},{"id":4},{"id":"3; rm -rf /"}]' >"$GH_STUB_DIR/caches"
prune 2
if [ "$STATUS" -ne 0 ] && grep -q "not a cache id" <<<"$LOG" && [ -z "$(deleted)" ]; then
	ok "a list entry that is not a numeric id fails before any delete of it"
else
	fails "a list entry that is not a numeric id fails before any delete of it"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
