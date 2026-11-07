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
# Resolves the version to release and its tag, and checks that it may be released.
#
# Run it from the root of a checkout with the full history and every tag (actions/checkout with
# fetch-depth: 0 and fetch-tags: true): the version is derived from the tags reachable from HEAD
# and the commits since the last one, and checked against every tag. It reads git and writes
# nothing but its outputs.
#
# Inputs (environment):
#   INPUT_VERSION  optional. X.Y.Z, vX.Y.Z or <prefix>X.Y.Z. Empty: derive the next version from
#                  the Conventional Commits since the last release, with svu (which must then be
#                  on PATH; the setup-svu action installs it).
#   TAG_PREFIX     the text before X.Y.Z in a release tag (default `v`). A plugin of a repository
#                  that releases several things tags `<plugin>--vX.Y.Z`, so its prefix is
#                  `<plugin>--v`. Letters, digits and `.`, `_`, `/`, `-` only.
#   FLOOR_VERSION  optional. X.Y.Z or vX.Y.Z: the lowest version that may be released, for
#                  example the version a manifest (Cargo.toml, plugin.json) already carries.
#
# Outputs (to $GITHUB_OUTPUT when set, and printed):
#   version   X.Y.Z, with no prefix
#   tag       <prefix>X.Y.Z
#   previous  the highest release tag before this one in this branch's history, or empty
#   explicit  true when INPUT_VERSION was given
#   recovery  true when the tag already points at HEAD: a re-run of a release that created the
#             tag and failed afterwards
#   major     <prefix>MAJOR, the moving major tag (v1, <plugin>--v1)
#
# A release tag is <prefix>MAJOR.MINOR.PATCH, strict SemVer core with no leading zeros, no
# pre-release and no build metadata. Every tag lookup filters through that one regex, never
# through a glob, so `latest`, `v1`, `v1.9.0-rc.1` and another prefix's tags are never releases.
#
# The version must be higher than every release already tagged, except on a recovery, and not
# lower than FLOOR_VERSION. Any check that fails exits non-zero with the reason; nothing is
# changed either way.

set -euo pipefail

INPUT_VERSION="${INPUT_VERSION:-}"
TAG_PREFIX="${TAG_PREFIX-v}"
FLOOR_VERSION="${FLOOR_VERSION:-}"

fail() {
	echo "::error title=release-version::$*" >&2
	exit 1
}

# The prefix becomes part of a regex and of svu's --tag.pattern, which is a glob: with only these
# characters it is literal in both, once its dots are escaped for the regex. An empty prefix is
# refused too, so a caller that forgets to pass one does not silently match bare X.Y.Z tags.
if [[ -z "$TAG_PREFIX" ]]; then
	fail "tag-prefix is empty. Pass the text before X.Y.Z in a release tag, such as 'v'. Nothing was changed."
fi
if ! [[ "$TAG_PREFIX" =~ ^[A-Za-z0-9._/-]+$ ]]; then
	fail "tag-prefix '$TAG_PREFIX' may hold only letters, digits and '.', '_', '/', '-'. Nothing was changed."
fi

CORE_REGEX='(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
VERSION_REGEX="^${CORE_REGEX}\$"
# shellcheck disable=SC2001 # a character class, not a fixed string: sed is the clearer tool.
PREFIX_REGEX=$(sed 's/[][\.^$*+?(){}|/]/\\&/g' <<<"$TAG_PREFIX")
RELEASE_TAG_REGEX="^${PREFIX_REGEX}${CORE_REGEX}\$"

# Strips the tag prefix, or a bare leading v, from a version input.
bare() {
	local raw=$1
	if [[ "$raw" == "$TAG_PREFIX"* ]]; then
		printf '%s' "${raw#"$TAG_PREFIX"}"
	else
		printf '%s' "${raw#v}"
	fi
}

if [[ -n "$FLOOR_VERSION" ]]; then
	FLOOR="${FLOOR_VERSION#v}"
	if ! [[ "$FLOOR" =~ $VERSION_REGEX ]]; then
		fail "floor-version must be X.Y.Z or vX.Y.Z with no leading zeros, no pre-release and no build metadata (got '$FLOOR_VERSION'). Nothing was changed."
	fi
fi

if [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]]; then
	fail "$(pwd) is not a git checkout. Run this after actions/checkout. Nothing was changed."
fi
# A shallow clone hides the tags and commits the version is derived from and checked against, so
# the result would look right and be wrong.
if [[ "$(git rev-parse --is-shallow-repository)" != "false" ]]; then
	fail "The checkout is shallow. Check out with fetch-depth: 0 and fetch-tags: true, so every tag and commit is there. Nothing was changed."
fi

# Prints the highest strict release tag in its input, or nothing.
highest_release() {
	{ grep -E "$RELEASE_TAG_REGEX" || true; } | sort -V | tail -n1
}
# Whether the release tag $1 sits on HEAD.
on_head() {
	git tag --points-at HEAD | { grep -E "$RELEASE_TAG_REGEX" || true; } | grep -qxF "$1"
}

if [[ -n "$INPUT_VERSION" ]]; then
	VERSION=$(bare "$INPUT_VERSION")
	if ! [[ "$VERSION" =~ $VERSION_REGEX ]]; then
		fail "Version must be X.Y.Z, vX.Y.Z or ${TAG_PREFIX}X.Y.Z with no leading zeros, no pre-release and no build metadata (got '$INPUT_VERSION'). Nothing was changed."
	fi
	TAG="${TAG_PREFIX}${VERSION}"
	EXPLICIT=true
else
	# svu is given the exact tag to count from, never a glob: it matches --tag.pattern against
	# every tag, so a pattern would let a stray tag like v1.9.0-rc.1 become the current version.
	CURRENT=$(git tag --merged HEAD | highest_release)
	if [[ -z "$CURRENT" ]]; then
		fail "No ${TAG_PREFIX}X.Y.Z release tag is reachable from this commit, so there is nothing to derive a version from. Re-run with an explicit version. Nothing was changed."
	fi
	if ! command -v svu >/dev/null 2>&1; then
		fail "svu is not on PATH, and deriving a version needs it. Run the setup-svu action first, or pass an explicit version. Nothing was changed."
	fi
	# The bump rules must be svu's defaults, the ones the commit-message conventions document: a
	# config file (always, v0, log.directory, ...) or an SVU_* variable must not change them.
	# svu 3.4.1 does not open --config as a path: viper takes its basename as a config name and
	# searches its directory, then the git root, the user config directory and $HOME, for that
	# name with or without an extension, and reads SVU_* variables once a file is found. So
	# --config names an empty file in a fresh directory, which is the first one searched and
	# therefore the one read; HOME and XDG_CONFIG_HOME point at that directory too, and every
	# SVU_* variable is dropped. GIT_CONFIG_GLOBAL keeps git, which svu runs, on the real global
	# config (actions/checkout records safe.directory there in container jobs).
	SVU_SANDBOX=$(mktemp -d)
	trap 'rm -rf "$SVU_SANDBOX"' EXIT
	: >"$SVU_SANDBOX/svu-defaults"
	SVU_ENV=()
	while IFS= read -r name; do
		SVU_ENV+=(-u "$name")
	done < <(compgen -e | grep '^SVU_' || true)
	if ! DERIVED=$(env "${SVU_ENV[@]}" GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL:-${HOME:-}/.gitconfig}" \
		HOME="$SVU_SANDBOX" XDG_CONFIG_HOME="$SVU_SANDBOX" \
		svu next --config "$SVU_SANDBOX/svu-defaults" --tag.prefix "$TAG_PREFIX" --tag.pattern "$CURRENT"); then
		fail "svu could not derive the next version from $CURRENT. Nothing was changed."
	fi
	if ! [[ "$DERIVED" =~ $RELEASE_TAG_REGEX ]]; then
		fail "svu derived '$DERIVED' from $CURRENT, which is not a ${TAG_PREFIX}X.Y.Z release tag. Nothing was changed."
	fi
	TAG="$DERIVED"
	VERSION="${TAG#"$TAG_PREFIX"}"
	# svu prints the current version unchanged when no feat/fix/breaking commit exists since the
	# last release. That is not a release, unless the tag is on HEAD itself: then this re-runs
	# one that created the tag and failed afterwards.
	if [[ "$TAG" == "$CURRENT" ]] && ! on_head "$TAG"; then
		fail "No feat/fix or breaking-change commit since ${CURRENT}, so there is nothing to bump. Re-run with an explicit version to force one. Nothing was changed."
	fi
	EXPLICIT=false
fi

# A recovery is this exact tag already on HEAD, nothing wider.
RECOVERY=false
if on_head "$TAG"; then
	RECOVERY=true
fi

if [[ "$RECOVERY" == "true" ]]; then
	PREVIOUS=$({ git tag --merged "HEAD^" 2>/dev/null || true; } | highest_release)
else
	PREVIOUS=$(git tag --merged HEAD | highest_release)
fi

# A version must be higher than every version already released, except on a recovery, which
# reuses the version it failed on.
LATEST=$(git tag --list | highest_release)
# A derived version counts from the highest release reachable from this commit. When the highest
# release overall is tagged on a commit outside this branch, that base is older: name it, so the
# failure explains itself.
off_branch_hint() {
	if [[ "$EXPLICIT" != "true" ]] && ! git merge-base --is-ancestor "$LATEST" HEAD; then
		echo "$LATEST is tagged on a commit that is not in this branch's history, so the version was derived from $CURRENT instead. Re-run with an explicit version higher than $LATEST." >&2
	fi
}
if [[ -n "$LATEST" ]] && [[ "$RECOVERY" != "true" ]]; then
	if [[ "$TAG" == "$LATEST" ]]; then
		off_branch_hint
		fail "$TAG is already released and does not point at this commit. Release a higher version. Nothing was changed."
	fi
	HIGHEST=$(printf '%s\n%s\n' "$TAG" "$LATEST" | sort -V | tail -n1)
	if [[ "$HIGHEST" != "$TAG" ]]; then
		off_branch_hint
		fail "$TAG is lower than the latest release $LATEST. Release tags are immutable, so only a higher version may be published. Nothing was changed."
	fi
fi

# The floor is inclusive: the version a manifest already carries may be released (its tag is
# what is missing), a lower one may not. It is checked on a recovery too, and never raises a
# derived version to meet it: a version the commits did not ask for needs an explicit input.
if [[ -n "${FLOOR:-}" ]]; then
	LOWEST=$(printf '%s\n%s\n' "$VERSION" "$FLOOR" | sort -V | head -n1)
	if [[ "$VERSION" != "$FLOOR" ]] && [[ "$LOWEST" == "$VERSION" ]]; then
		if [[ "$EXPLICIT" == "true" ]]; then
			fail "$VERSION is lower than the floor version $FLOOR. Release $FLOOR or higher. Nothing was changed."
		fi
		fail "$VERSION, derived from ${CURRENT}, is lower than the floor version $FLOOR. Re-run with an explicit version of $FLOOR or higher. Nothing was changed."
	fi
fi

MAJOR="${TAG_PREFIX}${VERSION%%.*}"
echo "Resolved $TAG (version: $VERSION, previous: ${PREVIOUS:-none}, explicit: $EXPLICIT, recovery: $RECOVERY, major: $MAJOR)"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	{
		echo "version=$VERSION"
		echo "tag=$TAG"
		echo "previous=$PREVIOUS"
		echo "explicit=$EXPLICIT"
		echo "recovery=$RECOVERY"
		echo "major=$MAJOR"
	} >>"$GITHUB_OUTPUT"
fi
