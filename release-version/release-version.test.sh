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
# Tests release-version.sh against throwaway git repositories.
#
# svu is replaced by a stub (below) that applies svu's default bump rules to the commits since
# the exact tag it is given, so the tests need no network and no svu. To run them against a real
# svu instead (the CI self-test does, after setup-svu), set RELEASE_VERSION_TEST_SVU to its path.
# The cases ported from gh-reusable-workflows' scripts/test-simple-tag-and-release.sh keep their
# names; the ones about the deprecated `semver` input are gone with the input.
#
# Needs: bash, git, coreutils.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/release-version.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Only svu lives in this directory, so a case can drop it from PATH and keep git.
mkdir -p "$WORK/svu-bin"
if [[ -n "${RELEASE_VERSION_TEST_SVU:-}" ]]; then
	ln -s "$RELEASE_VERSION_TEST_SVU" "$WORK/svu-bin/svu"
	echo "# using the real svu at $RELEASE_VERSION_TEST_SVU"
else
	# The svu stub: `svu next --config F --tag.prefix P --tag.pattern T`, nothing else. T must be
	# an existing tag, never a glob. The rules are svu 3.4.1's defaults (internal/svu/svu.go):
	# a `type!:` title or a BREAKING CHANGE body is major, `feat:` minor, `fix:` patch, else none.
	# Every call is recorded in $RV_STUB_CALLS, and the environment it ran in (what the script
	# isolates svu from) in $RV_STUB_ENV.
	cat >"$WORK/svu-bin/svu" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$RV_STUB_CALLS"
config=""
prev=""
for arg in "$@"; do
	[ "$prev" = --config ] && config=$arg
	prev=$arg
done
{
	echo "HOME=${HOME:-}"
	echo "XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-}"
	echo "GIT_CONFIG_GLOBAL=${GIT_CONFIG_GLOBAL:-}"
	echo "config_dir=$(dirname "$config")"
	echo "config_size=$(stat -c %s "$config" 2>/dev/null || echo missing)"
	echo "config_dir_files=$(ls -A "$(dirname "$config")" | paste -sd ' ')"
	echo "svu_vars=$(compgen -e | grep '^SVU_' | paste -sd ' ' || true)"
} >"$RV_STUB_ENV"
[ "${1:-}" = next ] || { echo "svu stub: unexpected svu $*" >&2; exit 1; }
shift
prefix=v pattern=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	--config) shift 2 ;;
	--tag.prefix) prefix=$2; shift 2 ;;
	--tag.pattern) pattern=$2; shift 2 ;;
	*) echo "svu stub: unexpected flag $1" >&2; exit 1 ;;
	esac
done
case "$pattern" in
"" | *[\*\?\[\]\{\}\\]*) echo "svu stub: pattern '$pattern' is not an exact tag" >&2; exit 1 ;;
esac
git rev-parse -q --verify "refs/tags/$pattern" >/dev/null || { echo "no tags match '$pattern'" >&2; exit 1; }
IFS=. read -r major minor patch <<<"${pattern#"$prefix"}"
bump=none
for sha in $(git log --format=%H "tags/$pattern..HEAD"); do
	title=$(git log -1 --format=%s "$sha")
	body=$(git log -1 --format=%b "$sha")
	if grep -qE 'BREAKING[ -]CHANGE:' <<<"$body" || grep -qiE '[[:alnum:]_]+(\(.*\))?!:' <<<"$title"; then
		bump=major
		break
	fi
	if grep -qiE 'feat(\(.*\))?:' <<<"$title"; then
		bump=minor
	elif [ "$bump" = none ] && grep -qiE 'fix(\(.*\))?:' <<<"$title"; then
		bump=patch
	fi
done
case "$bump" in
major) major=$((major + 1)) minor=0 patch=0 ;;
minor) minor=$((minor + 1)) patch=0 ;;
patch) patch=$((patch + 1)) ;;
esac
echo "${prefix}${major}.${minor}.${patch}"
STUB
	chmod +x "$WORK/svu-bin/svu"
fi
export RV_STUB_CALLS="$WORK/svu-calls" RV_STUB_ENV="$WORK/svu-env"
BASE_PATH="$PATH"

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

# A fresh repository at $REPO, with one commit.
N=0
new_repo() {
	N=$((N + 1))
	REPO="$WORK/repo-$N"
	git init -q -b main "$REPO"
	git -C "$REPO" config user.email test@example.com
	git -C "$REPO" config user.name test
	git -C "$REPO" config commit.gpgsign false
	git -C "$REPO" config tag.gpgsign false
	commit "chore(repo): initial commit"
	: >"$RV_STUB_CALLS"
}
commit() { git -C "$REPO" commit -q --allow-empty -m "$1"; }
release_tag() { git -C "$REPO" tag "$1" "${2:-HEAD}"; }

# Runs the script in $REPO with the given environment. Sets STATUS, OUTPUT (the output file) and
# LOG (stdout and stderr). SVU_ON_PATH=false leaves svu off PATH.
run_script() {
	OUT_FILE="$WORK/output"
	: >"$OUT_FILE"
	local path="$WORK/svu-bin:$BASE_PATH"
	if [[ "${SVU_ON_PATH:-true}" != "true" ]]; then
		# Drop every PATH entry holding an svu, not only the stub's: in CI, setup-svu puts the
		# real one on PATH for the real-svu run.
		path=""
		local dir
		while IFS= read -r -d: dir; do
			if [[ -n "$dir" && ! -x "$dir/svu" ]]; then
				path="${path:+$path:}$dir"
			fi
		done <<<"$BASE_PATH:"
	fi
	STATUS=0
	LOG=$(cd "$REPO" && env PATH="$path" GITHUB_OUTPUT="$OUT_FILE" "$@" bash "$SCRIPT" 2>&1) || STATUS=$?
	OUTPUT=$(cat "$OUT_FILE")
}
out() { sed -n "s/^$1=//p" <<<"$OUTPUT"; }

# resolve VERSION [TAG_PREFIX [FLOOR_VERSION]]
resolve() { run_script INPUT_VERSION="${1:-}" TAG_PREFIX="${2-v}" FLOOR_VERSION="${3:-}"; }
expect_tag() {
	local name=$1 want=$2
	if [[ "$STATUS" -eq 0 ]] && [[ "$(out tag)" == "$want" ]]; then ok "$name"; else not_ok "$name (want $want, status $STATUS, got '$(out tag)')" "$LOG"; fi
}
expect_fail() {
	local name=$1 pattern=$2
	if [[ "$STATUS" -ne 0 ]] && grep -q -- "$pattern" <<<"$LOG" && [[ -z "$OUTPUT" ]]; then
		ok "$name"
	else
		not_ok "$name (want a failure matching '$pattern' and no outputs, status $STATUS)" "$LOG$OUTPUT"
	fi
}
expect_outputs() {
	local name=$1 want=$2
	if [[ "$STATUS" -eq 0 ]] && [[ "$OUTPUT" == "$want" ]]; then ok "$name"; else not_ok "$name" "want:
$want
got (status $STATUS):
$OUTPUT
$LOG"; fi
}

echo "# resolve (ported)"

new_repo
release_tag v1.2.0
commit "fix(core): a fix"
resolve "1.2.1"
expect_tag "a bare version is accepted" v1.2.1
resolve "v1.2.1"
expect_tag "a v-prefixed version normalizes to the same tag" v1.2.1
for bad in 1.2 v01.2.3 1.2.3-rc.1 1.2.3+meta x1.2.3 vv1.2.3 " 1.2.3"; do
	resolve "$bad"
	expect_fail "malformed version '$bad' fails" "must be X.Y.Z"
done
resolve "1.1.9"
expect_fail "a lower version fails" "lower than the latest release"
resolve "1.2.0"
expect_fail "the latest version, not on HEAD, fails" "already released"
resolve ""
expect_tag "fix derives a patch" v1.2.1
expect_outputs "derived outputs" "version=1.2.1
tag=v1.2.1
previous=v1.2.0
explicit=false
recovery=false
major=v1"
if [[ -n "${RELEASE_VERSION_TEST_SVU:-}" ]]; then
	ok "svu is given the prefix and the exact tag to count from # SKIP real svu records no calls"
elif grep -qE -- "^next --config [^ ]+ --tag.prefix v --tag.pattern v1.2.0$" "$RV_STUB_CALLS"; then
	ok "svu is given the prefix and the exact tag to count from"
else
	not_ok "svu is given the prefix and the exact tag to count from" "$(cat "$RV_STUB_CALLS")"
fi

echo "# svu isolation"

# A config file svu could pick up, everywhere it looks, and SVU_* variables: each would turn
# "nothing to bump" into a patch (always) if svu read it. With RELEASE_VERSION_TEST_SVU this is
# proven against the real svu; with the stub, the environment svu ran in is checked instead.
new_repo
release_tag v1.2.0
commit "chore(deps): bump something"
HOSTILE_HOME="$WORK/hostile-home"
mkdir -p "$HOSTILE_HOME/.config"
for dir in "$REPO" "$HOSTILE_HOME" "$HOSTILE_HOME/.config"; do
	for name in .svu.yml .svu.yaml svu-defaults svu-defaults.yaml svu-defaults.yml; do
		printf 'always: true\nv0: true\n' >"$dir/$name"
	done
done
run_script INPUT_VERSION="" TAG_PREFIX=v FLOOR_VERSION="" HOME="$HOSTILE_HOME" \
	XDG_CONFIG_HOME="$HOSTILE_HOME/.config" SVU_ALWAYS=true SVU_V0=true SVU_CONFIG="$REPO/.svu.yml"
expect_fail "config files in the repository and the home, and SVU_* variables, do not change the bump" "nothing to bump"
if [[ -z "${RELEASE_VERSION_TEST_SVU:-}" ]]; then
	ENV_RECORD=$(cat "$RV_STUB_ENV")
	CONFIG_DIR=$(sed -n 's/^config_dir=//p' <<<"$ENV_RECORD")
	if [[ "$ENV_RECORD" == "HOME=$CONFIG_DIR
XDG_CONFIG_HOME=$CONFIG_DIR
GIT_CONFIG_GLOBAL=$HOSTILE_HOME/.gitconfig
config_dir=$CONFIG_DIR
config_size=0
config_dir_files=svu-defaults
svu_vars=" ]] && [[ "$CONFIG_DIR" != "$REPO"* ]] && [[ "$CONFIG_DIR" != "$HOSTILE_HOME"* ]]; then
		ok "svu runs with an empty config alone in its directory, that directory as HOME, and no SVU_* variables"
	else
		not_ok "svu runs with an empty config alone in its directory, that directory as HOME, and no SVU_* variables" "$ENV_RECORD"
	fi
fi
GIT_CONFIG_GLOBAL="$HOSTILE_HOME/custom-gitconfig" run_script INPUT_VERSION="" TAG_PREFIX=v FLOOR_VERSION=""
if [[ -n "${RELEASE_VERSION_TEST_SVU:-}" ]] || grep -qxF "GIT_CONFIG_GLOBAL=$HOSTILE_HOME/custom-gitconfig" "$RV_STUB_ENV"; then
	ok "a GIT_CONFIG_GLOBAL already set is kept"
else
	not_ok "a GIT_CONFIG_GLOBAL already set is kept" "$(cat "$RV_STUB_ENV")"
fi

new_repo
resolve ""
expect_fail "no base tag and no version fails" "nothing to derive a version from"
resolve "0.1.0"
expect_tag "no base tag with an explicit version works" v0.1.0

new_repo
release_tag v1.2.0
commit "feat(api): a feature"
resolve ""
expect_tag "feat derives a minor" v1.3.0
commit "feat(api)!: a breaking change"
resolve ""
expect_tag "a breaking change derives a major" v2.0.0
expect_outputs "a major bump moves the major output" "version=2.0.0
tag=v2.0.0
previous=v1.2.0
explicit=false
recovery=false
major=v2"

new_repo
release_tag v1.2.0
git -C "$REPO" commit -q --allow-empty -m "fix(core): a fix" -m "BREAKING CHANGE: the old flag is gone"
resolve ""
expect_tag "a BREAKING CHANGE footer derives a major" v2.0.0

new_repo
release_tag v1.2.0
commit "chore(deps): bump something"
commit "docs(readme): words"
resolve ""
expect_fail "only chore/docs commits: nothing to bump" "nothing to bump"

new_repo
release_tag v1.2.0
git -C "$REPO" tag v1.9.0-rc.1
git -C "$REPO" tag latest
git -C "$REPO" tag v1
commit "fix(core): a fix"
resolve ""
expect_tag "stray non-release tags are ignored" v1.2.1

new_repo
release_tag v1.2.0
commit "fix(core): a fix"
release_tag v1.2.1
resolve ""
expect_tag "a derived re-run with the tag on HEAD is a recovery" v1.2.1
if [[ "$(out recovery)" == "true" ]] && [[ "$(out previous)" == "v1.2.0" ]]; then ok "recovery outputs"; else not_ok "recovery outputs" "$OUTPUT"; fi
resolve "1.2.1"
expect_tag "an explicit re-run with the tag on HEAD is a recovery" v1.2.1

new_repo
release_tag v0.1.0
resolve "0.1.0"
if [[ "$STATUS" -eq 0 ]] && [[ "$(out recovery)" == "true" ]] && [[ -z "$(out previous)" ]]; then ok "a recovery on the root commit has no previous release"; else not_ok "a recovery on the root commit has no previous release" "$LOG$OUTPUT"; fi

new_repo
release_tag v1.2.0
commit "fix(core): the old fix"
OLD=$(git -C "$REPO" rev-parse HEAD)
release_tag v1.2.1
commit "feat(api): newer"
release_tag v1.3.0
git -C "$REPO" checkout -q "$OLD"
resolve "1.2.1"
expect_tag "recovering an older release on its own commit works" v1.2.1
resolve "1.2.2"
expect_fail "a new lower version is still refused" "lower than the latest release"

new_repo
release_tag v1.5.1
commit "feat(core): the feature"
OFF=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" reset -q --hard HEAD~1
release_tag v1.6.0 "$OFF"
commit "feat(core): the feature, landed again"
resolve ""
expect_fail "a derived version equal to a release tagged off the branch names the cause" "not in this branch's history, so the version was derived from v1.5.1"
git -C "$REPO" reset -q --hard HEAD~1
commit "fix(core): the change, landed again as a fix"
resolve ""
expect_fail "a derived version below a release tagged off the branch names the cause" "not in this branch's history, so the version was derived from v1.5.1"
resolve "1.5.2"
if [[ "$STATUS" -ne 0 ]] && ! grep -q "not in this branch's history" <<<"$LOG"; then ok "an explicit lower version gets no off-branch hint"; else not_ok "an explicit lower version gets no off-branch hint" "$LOG"; fi
resolve "1.6.1"
expect_tag "an explicit version above the off-branch release works" v1.6.1

echo "# environment"

new_repo
release_tag v1.2.0
commit "fix(core): a fix"
SVU_ON_PATH=false resolve ""
expect_fail "deriving without svu on PATH names setup-svu" "Run the setup-svu action first"
SVU_ON_PATH=false resolve "1.2.1"
expect_tag "an explicit version needs no svu" v1.2.1

SHALLOW="$WORK/shallow"
git clone -q --depth 1 "file://$REPO" "$SHALLOW"
SAVED_REPO=$REPO
REPO=$SHALLOW
resolve "1.2.1"
expect_fail "a shallow checkout fails" "The checkout is shallow"
REPO="$WORK/not-a-repo"
mkdir -p "$REPO"
resolve "1.2.1"
expect_fail "a directory that is not a checkout fails" "is not a git checkout"
REPO=$SAVED_REPO

echo "# tag-prefix"

for bad in "" "foo*" "foo bar" "[v]" "v?" "pre{a,b}"; do
	resolve "1.2.1" "$bad"
	expect_fail "tag-prefix '$bad' is refused" "tag-prefix"
done

new_repo
release_tag v1.2.0
release_tag foo--v0.3.0
commit "fix(core): a fix"
resolve "" "foo--v"
expect_outputs "a foo--v prefix counts from its own tags, ignoring v1.2.0" "version=0.3.1
tag=foo--v0.3.1
previous=foo--v0.3.0
explicit=false
recovery=false
major=foo--v0"
resolve "" "v"
expect_tag "the v prefix ignores foo--v tags" v1.2.1
resolve "0.3.0" "foo--v"
expect_fail "the prefix's own latest release, not on HEAD, fails" "foo--v0.3.0 is already released"
resolve "0.2.0" "foo--v"
expect_fail "a version lower than the prefix's latest fails" "lower than the latest release foo--v0.3.0"
resolve "1.0.0" "foo--v"
expect_tag "a foo--v version below the v tags is not refused because of them" foo--v1.0.0
resolve "foo--v0.4.0" "foo--v"
expect_tag "the full tag is accepted as the version" foo--v0.4.0
resolve "v0.4.0" "foo--v"
expect_tag "a vX.Y.Z version is accepted with a foo--v prefix" foo--v0.4.0
resolve "bar--v0.4.0" "foo--v"
expect_fail "another prefix's tag is not a version" "must be X.Y.Z"

new_repo
release_tag v1.2.0
release_tag xfoo--v5.0.0
release_tag foo--v1.0.0-rc.1
commit "fix(core): a fix"
resolve "" "foo--v"
expect_fail "a prefix with only other prefixes' tags has nothing to derive from" "No foo--vX.Y.Z release tag"
resolve "1.0.0" "foo--v"
expect_tag "a longer prefix ending in the same text does not count as a release" foo--v1.0.0

new_repo
release_tag aXb--v9.0.0
release_tag a.b--v1.0.0
commit "feat(core): a feature"
resolve "" "a.b--v"
expect_tag "a dot in the prefix is literal" a.b--v1.1.0

new_repo
release_tag v1.2.0
release_tag foo--v0.3.0
commit "fix(core): a fix"
release_tag foo--v0.3.1
resolve "" "foo--v"
if [[ "$STATUS" -eq 0 ]] && [[ "$(out recovery)" == "true" ]] && [[ "$(out previous)" == "foo--v0.3.0" ]]; then ok "a prefixed recovery"; else not_ok "a prefixed recovery" "$LOG$OUTPUT"; fi
resolve "" "v"
expect_tag "another prefix's tag on HEAD is not a recovery" v1.2.1
if [[ "$(out recovery)" == "false" ]]; then ok "another prefix's tag on HEAD leaves recovery false"; else not_ok "another prefix's tag on HEAD leaves recovery false" "$OUTPUT"; fi

echo "# floor-version"

for bad in 1.2 01.2.3 1.2.3-rc.1 "v 1.2.3" foo--v1.2.3; do
	resolve "1.2.1" "v" "$bad"
	expect_fail "floor-version '$bad' is refused" "floor-version must be X.Y.Z"
done

new_repo
release_tag v1.2.0
commit "fix(core): a fix"
resolve "" "v" "1.3.0"
expect_fail "a derived version below the floor fails, and is not raised to it" "derived from v1.2.0, is lower than the floor version 1.3.0"
resolve "1.2.5" "v" "1.3.0"
expect_fail "an explicit version below the floor fails" "lower than the floor version 1.3.0"
resolve "" "v" "1.2.1"
expect_tag "a derived version at the floor works" v1.2.1
resolve "" "v" "v1.2.1"
expect_tag "a v-prefixed floor works" v1.2.1
resolve "1.3.0" "v" "1.2.1"
expect_tag "an explicit version above the floor works" v1.3.0
resolve "" "v" "1.2.0"
expect_tag "a derived version above the floor works" v1.2.1
resolve "" "v" "1.10.0"
expect_fail "the floor compares versions, not strings" "lower than the floor version 1.10.0"
release_tag v1.2.1
resolve "" "v" "1.2.1"
if [[ "$STATUS" -eq 0 ]] && [[ "$(out recovery)" == "true" ]]; then ok "a recovery at the floor works"; else not_ok "a recovery at the floor works" "$LOG$OUTPUT"; fi
resolve "" "v" "1.3.0"
expect_fail "a recovery below the floor fails" "lower than the floor version 1.3.0"

new_repo
release_tag gtk-rs-skills--v0.4.0
commit "feat(skills): a skill"
resolve "" "gtk-rs-skills--v" "0.5.0"
expect_outputs "a plugin prefix with its manifest floor" "version=0.5.0
tag=gtk-rs-skills--v0.5.0
previous=gtk-rs-skills--v0.4.0
explicit=false
recovery=false
major=gtk-rs-skills--v0"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
