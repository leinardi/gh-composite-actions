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

# release-mode.sh decides what a release run does, before anything is built or pushed, and
# writes that decision down as a plan. It never publishes: it reads the git tag, the images on the
# registry, the GitHub release and its assets, verifies every published artifact, downloads the
# published binaries and extracts the ones inside published images into the output directory, and
# leaves the pushing, signing, attesting and uploading to the caller's later steps.
#
# The rule is "nothing published: rebuild; anything published: reuse it, never replace it", and it
# is decided per binary and platform, so the binary inside an image and the release asset of the
# same name can never diverge:
#
#   published for binary B on platform P   source    what the caller does
#   image and asset                        image     nothing: the two must be the same bytes
#   image only                             image     upload the extracted file as the asset
#   asset only                             asset     build the image (prebuilt target) with it
#   neither                                rebuild   build B for P, upload it as the asset
#
# A published image is never rebuilt: missing assets always come from it, and an image that lacks
# a platform the release ships fails closed, because a manifest list cannot gain a platform
# without changing its digest. An image that is not published yet is built from the mix of
# published and rebuilt binaries the table gives.
#
# "Published" means the image tag <image>:<image-tag> exists on the registry, or the release (draft
# or not) carries the asset. Every published artifact must be attested by the signer workflow for
# the source ref and the head commit (gh attestation verify), and every published image must also
# carry the signer workflow's keyless cosign signature. Anything else that holds the version
# (unattested, attested by another workflow, unsigned, a byte that differs, a checksums.txt that
# disagrees, an asset nobody expects) needs a human, and the plan says stop.
#
# The overall mode, from the git tag and what is published:
#
#   git tag          published                                  mode
#   absent           nothing                                    fresh
#   absent           an image or a release                      stop (the version is held)
#   on another commit                                           stop (tags are immutable)
#   on HEAD          every image, and no binary to rebuild      reuse
#   on HEAD          anything less                              publish
#
# A tag on HEAD must be annotated, and its annotation must carry every expected toolchain line
# exactly (RM_EXPECTED_TOOLCHAINS): a recovery must build with the toolchains the tag recorded, or
# its bytes would differ from what the first run published.
#
# Inputs, all from the environment (the release-mode action maps its inputs onto them):
#   RM_REPO                 owner/name of the repository (required)
#   RM_TAG                  the git tag being released, e.g. v1.2.3 (required)
#   RM_TAG_REGEX            what a release tag looks like (default: strict vMAJOR.MINOR.PATCH)
#   RM_IMAGE_TAG            the image tag of the version (default: RM_TAG; bitgauge drops the v)
#   RM_HEAD_SHA             the commit being released, 40 hex characters (required)
#   RM_SOURCE_REF           the ref the signer workflow runs on, e.g. refs/heads/main (required)
#   RM_SIGNER_WORKFLOW      owner/name/.github/workflows/<file>, or .github/workflows/<file>
#                           relative to RM_REPO (default .github/workflows/release.yaml)
#   RM_SIGNER_ISSUER        the cosign OIDC issuer (default the GitHub Actions one)
#   RM_IMAGE                one image reference without tag, e.g. ghcr.io/owner/name; it holds
#                           every binary in RM_BINARIES
#   RM_IMAGES               instead of RM_IMAGE, one image per line: "<ref> [binary[=path]]...",
#                           naming the binaries that image holds (runhold: binaries map to images)
#   RM_BINARIES             the binaries, separated by whitespace or commas (may be empty: an
#                           image-only release)
#   RM_IMAGE_BINARY_PATHS   one "binary=/path/in/image" per line (default /usr/local/bin/<binary>)
#   RM_PLATFORMS            the shipped platforms, e.g. linux/amd64,linux/arm64 (required)
#   RM_ASSET_PATTERN        the asset name of a binary on a platform, with {binary}, {os}, {arch}
#                           and {variant} ("-<variant>" or nothing); default
#                           {binary}-{os}-{arch}{variant}
#   RM_CHECKSUMS_NAME       the checksums asset (default checksums.txt; none when no binaries)
#   RM_EXPECTED_TOOLCHAINS  "Name: version" lines a tag on HEAD must carry (optional)
#   RM_REQUIRED_RESULTS     job results that must all be success, e.g. the audit job's (optional)
#   RM_DRY_RUN              true or false (default false): a dry run rehearses a build whatever
#                           the mode, so build is true
#   RM_OUT_DIR              where the plan and the fetched binaries go (default
#                           $RUNNER_TEMP/release-mode)
#
# Outputs: $RM_OUT_DIR/plan.json (the schema is in README.md), $RM_OUT_DIR/assets/<asset> for
# every binary whose source is image or asset, and $RM_OUT_DIR/published-<checksums> when one is
# published. The same decision goes to $GITHUB_OUTPUT when it is set: mode, reason, build,
# tag-exists, release-state, build-images, reuse-images, rebuild, upload-files (multi-line),
# checksums, move-pointers and plan-file.
#
# Exit status: 0 for fresh, publish and reuse; 1 for stop (the plan and the outputs are still
# written, with the reason); 2 for an invalid input, with nothing looked up.
#
# Commands it runs, every one read-only: git (ls-remote, rev-parse, cat-file, rev-list, tag -l),
# docker (buildx imagetools inspect; create, cp and rm to extract a binary from an image), gh
# (release view, release download, attestation verify, api .../releases/latest) and cosign verify.
# Only "not found" answers count as absent; every other failure stops the run.

set -euo pipefail

# --- Inputs ------------------------------------------------------------------------------------

usage_error() {
	echo "::error::release-mode: $*. Nothing was looked up or changed." >&2
	exit 2
}

# split prints the words of $1, split on whitespace and commas, one per line.
split() {
	tr ',' ' ' <<<"$1" | tr -s '[:space:]' '\n' | sed '/^$/d'
}

REPO=${RM_REPO:-}
TAG=${RM_TAG:-}
TAG_REGEX=${RM_TAG_REGEX:-'^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'}
IMAGE_TAG=${RM_IMAGE_TAG:-$TAG}
HEAD_SHA=${RM_HEAD_SHA:-}
SOURCE_REF=${RM_SOURCE_REF:-}
SIGNER_WORKFLOW=${RM_SIGNER_WORKFLOW:-.github/workflows/release.yaml}
SIGNER_ISSUER=${RM_SIGNER_ISSUER:-https://token.actions.githubusercontent.com}
ASSET_PATTERN=${RM_ASSET_PATTERN:-'{binary}-{os}-{arch}{variant}'}
CHECKSUMS_NAME=${RM_CHECKSUMS_NAME:-checksums.txt}
DRY_RUN=${RM_DRY_RUN:-false}
OUT_DIR=${RM_OUT_DIR:-${RUNNER_TEMP:-}/release-mode}

[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || usage_error "repo must be owner/name (got '$REPO')"
[[ "$TAG" =~ $TAG_REGEX ]] || usage_error "tag '$TAG' is not a release tag (it must match $TAG_REGEX)"
[[ "$IMAGE_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || usage_error "image-tag '$IMAGE_TAG' is not a valid image tag"
[[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || usage_error "head-sha must be a 40-character commit SHA (got '$HEAD_SHA')"
[[ "$SOURCE_REF" =~ ^refs/(heads|tags)/[^[:space:]]+$ ]] || usage_error "source-ref must be a full ref such as refs/heads/main (got '$SOURCE_REF')"
if [[ "$SIGNER_WORKFLOW" == .github/workflows/* ]]; then
	SIGNER_WORKFLOW="$REPO/$SIGNER_WORKFLOW"
fi
[[ "$SIGNER_WORKFLOW" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$ ]] ||
	usage_error "signer-workflow must be owner/name/.github/workflows/<file>.y(a)ml (got '$SIGNER_WORKFLOW')"
# The keyless identity a cosign sign in the signer workflow on the source ref produces.
SIGNER_IDENTITY="https://github.com/$SIGNER_WORKFLOW@$SOURCE_REF"
[[ "$SIGNER_ISSUER" =~ ^https://[^[:space:]]+$ ]] || usage_error "signer-issuer must be an https URL (got '$SIGNER_ISSUER')"
case "$DRY_RUN" in
true | false) ;;
*) usage_error "dry-run must be true or false (got '$DRY_RUN')" ;;
esac
[[ "$CHECKSUMS_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage_error "checksums-name '$CHECKSUMS_NAME' is not a plain file name"
[ -n "${RM_OUT_DIR:-}${RUNNER_TEMP:-}" ] || usage_error "out-dir is not set and neither is RUNNER_TEMP"

# normalize_platform <os/arch[/variant]> prints the platform the way containerd's
# platforms.Normalize does, so two spellings of one platform compare equal: linux/arm64 and
# linux/arm64/v8 (buildx and most upstream indexes publish arm64 with variant v8), aarch64 and
# arm64, x86_64 and amd64 (whose v1 is the default), linux/arm and linux/arm/v7. Only the
# comparison uses it; every name and key in the plan keeps the caller's spelling.
normalize_platform() {
	local os arch variant
	IFS=/ read -r os arch variant <<<"$1"
	os=${os,,}
	arch=${arch,,}
	variant=${variant,,}
	[ "$os" != macos ] || os=darwin
	case "$arch" in
	i386)
		arch=386
		variant=""
		;;
	x86_64 | x86-64 | amd64)
		arch=amd64
		[ "$variant" != v1 ] || variant=""
		;;
	aarch64 | arm64)
		arch=arm64
		case "$variant" in
		8 | v8 | v8.0) variant="" ;;
		9 | 9.0 | v9.0) variant=v9 ;;
		8.[1-9]) variant="v$variant" ;;
		esac
		;;
	armhf)
		arch=arm
		variant=v7
		;;
	armel)
		arch=arm
		variant=v6
		;;
	arm)
		case "$variant" in
		"" | 7) variant=v7 ;;
		5 | 6 | 8) variant="v$variant" ;;
		esac
		;;
	esac
	echo "$os/$arch${variant:+/$variant}"
}

# Platforms: os/arch or os/arch/variant, each once (also once after normalization).
PLATFORM_LIST=()
declare -A PLATFORM_NORMAL=()
while IFS= read -r platform; do
	[[ "$platform" =~ ^[a-z0-9]+/[a-z0-9_-]+(/[a-z0-9.]+)?$ ]] || usage_error "platform '$platform' is not os/arch or os/arch/variant"
	normal=$(normalize_platform "$platform")
	for seen in "${PLATFORM_LIST[@]}"; do
		[ "${PLATFORM_NORMAL[$seen]}" != "$normal" ] || usage_error "platform '$platform' is listed twice (as '$seen')"
	done
	PLATFORM_LIST+=("$platform")
	PLATFORM_NORMAL[$platform]=$normal
done < <(split "${RM_PLATFORMS:-}")
[ "${#PLATFORM_LIST[@]}" -gt 0 ] || usage_error "platforms is empty"

# Binaries, each once.
BINARY_LIST=()
while IFS= read -r binary; do
	[[ "$binary" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage_error "binary '$binary' is not a plain file name"
	for seen in "${BINARY_LIST[@]}"; do
		[ "$seen" != "$binary" ] || usage_error "binary '$binary' is listed twice"
	done
	BINARY_LIST+=("$binary")
done < <(split "${RM_BINARIES:-}")

is_binary() {
	local binary
	for binary in "${BINARY_LIST[@]}"; do
		[ "$binary" != "$1" ] || return 0
	done
	return 1
}

# Where each binary sits inside an image: RM_IMAGE_BINARY_PATHS, or /usr/local/bin/<binary>.
declare -A DEFAULT_PATH=()
for binary in "${BINARY_LIST[@]}"; do
	DEFAULT_PATH[$binary]="/usr/local/bin/$binary"
done
while IFS= read -r line; do
	line=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$line")
	[ -n "$line" ] || continue
	binary=${line%%=*}
	path=${line#*=}
	if [[ "$line" != *=* ]] || ! is_binary "$binary"; then
		usage_error "image-binary-paths line '$line' is not <binary>=<path> for a listed binary"
	fi
	[[ "$path" =~ ^/[^[:space:]]+$ ]] || usage_error "image-binary-paths: '$path' is not an absolute path"
	DEFAULT_PATH[$binary]=$path
done <<<"${RM_IMAGE_BINARY_PATHS:-}"

valid_image_ref() {
	[[ "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]+)?(/[a-z0-9]+([._-]+[a-z0-9]+)*)+$ ]]
}

# Images: IMAGE_REFS[i] holds IMAGE_BINARIES[i] (space-separated), each at IMAGE_PATH[i|binary].
IMAGE_REFS=()
IMAGE_BINARIES=()
declare -A IMAGE_PATH=()
if [ -n "${RM_IMAGE:-}" ] && [ -n "$(split "${RM_IMAGES:-}")" ]; then
	usage_error "set image or images, not both"
fi
if [ -n "${RM_IMAGE:-}" ]; then
	valid_image_ref "$RM_IMAGE" || usage_error "image '$RM_IMAGE' is not a reference without tag or digest, e.g. ghcr.io/owner/name"
	IMAGE_REFS+=("$RM_IMAGE")
	IMAGE_BINARIES+=("${BINARY_LIST[*]}")
	for binary in "${BINARY_LIST[@]}"; do
		IMAGE_PATH["0|$binary"]=${DEFAULT_PATH[$binary]}
	done
else
	while IFS= read -r line; do
		read -r -a words <<<"$line" || true
		[ "${#words[@]}" -gt 0 ] || continue
		ref=${words[0]}
		valid_image_ref "$ref" || usage_error "images: '$ref' is not a reference without tag or digest"
		for seen in "${IMAGE_REFS[@]}"; do
			[ "$seen" != "$ref" ] || usage_error "images: '$ref' is listed twice"
		done
		index=${#IMAGE_REFS[@]}
		held=()
		for item in "${words[@]:1}"; do
			binary=${item%%=*}
			is_binary "$binary" || usage_error "images: '$ref' holds '$binary', which is not in binaries"
			if [[ "$item" == *=* ]]; then
				path=${item#*=}
				[[ "$path" =~ ^/[^[:space:]]+$ ]] || usage_error "images: '$path' is not an absolute path"
			else
				path=${DEFAULT_PATH[$binary]}
			fi
			IMAGE_PATH["$index|$binary"]=$path
			held+=("$binary")
		done
		IMAGE_REFS+=("$ref")
		IMAGE_BINARIES+=("${held[*]}")
	done <<<"${RM_IMAGES:-}"
fi
if [ "${#IMAGE_REFS[@]}" -eq 0 ] && [ "${#BINARY_LIST[@]}" -eq 0 ]; then
	usage_error "there is nothing to release: set image (or images), binaries, or both"
fi

# Expected toolchain lines, "Name: version".
TOOLCHAIN_LINES=()
while IFS= read -r line; do
	line=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$line")
	[ -n "$line" ] || continue
	[[ "$line" =~ ^[A-Za-z][A-Za-z0-9._-]*:\ [^[:space:]].*$ ]] || usage_error "expected-toolchains line '$line' is not 'Name: version'"
	TOOLCHAIN_LINES+=("$line")
done <<<"${RM_EXPECTED_TOOLCHAINS:-}"

REQUIRED_LIST=()
while IFS= read -r result; do
	REQUIRED_LIST+=("$result")
done < <(split "${RM_REQUIRED_RESULTS:-}")

# asset_name <binary> <platform> renders RM_ASSET_PATTERN.
asset_name() {
	local binary=$1 platform=$2 os arch variant=""
	os=${platform%%/*}
	arch=${platform#*/}
	if [[ "$arch" == */* ]]; then
		variant="-${arch#*/}"
		arch=${arch%%/*}
	fi
	local name=$ASSET_PATTERN
	name=${name//\{binary\}/$binary}
	name=${name//\{os\}/$os}
	name=${name//\{arch\}/$arch}
	name=${name//\{variant\}/$variant}
	echo "$name"
}

# Every binary and platform gets its own asset name, none of them the checksums file.
declare -A ASSET_OWNER=()
EXPECTED_ASSETS=()
for binary in "${BINARY_LIST[@]}"; do
	for platform in "${PLATFORM_LIST[@]}"; do
		name=$(asset_name "$binary" "$platform")
		[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage_error "asset-pattern gives '$name' for $binary on $platform, which is not a plain file name"
		[ "$name" != "$CHECKSUMS_NAME" ] || usage_error "asset-pattern gives the checksums name '$name' for $binary on $platform"
		[ -z "${ASSET_OWNER[$name]:-}" ] || usage_error "asset-pattern gives '$name' to both ${ASSET_OWNER[$name]} and $binary@$platform"
		ASSET_OWNER[$name]="$binary@$platform"
		EXPECTED_ASSETS+=("$name")
	done
done
if [ "${#BINARY_LIST[@]}" -gt 0 ]; then
	EXPECTED_ASSETS+=("$CHECKSUMS_NAME")
fi

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/assets" "$OUT_DIR/extract" "$OUT_DIR/download" "$OUT_DIR/published-$CHECKSUMS_NAME"
mkdir -p "$OUT_DIR/assets" "$OUT_DIR/extract" "$OUT_DIR/download"
PLAN_FILE="$OUT_DIR/plan.json"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# --- State gathered along the way, written out by emit -----------------------------------------

MODE=""
REASON=""
MESSAGE=""
TAG_EXISTS=false
RELEASE_STATE=unknown
RELEASE_ASSETS=()
HIGHEST_TAG=""
MOVE_POINTERS=false
WARNINGS=()
declare -A IMAGE_STATE=() IMAGE_DIGEST=() PLATFORM_DIGESTS=()
# Per binary and platform, keyed "binary@platform".
declare -A SOURCE=() SOURCE_IMAGE=() ASSET_PUBLISHED=() SHA=() FILE=() UPLOAD=() LISTED_SHA=()
CHECKSUMS_ACTION=none

json_strings() {
	if [ "$#" -eq 0 ]; then
		echo '[]'
	else
		printf '%s\n' "$@" | jq -R . | jq -sc .
	fi
}

# emit writes the plan file and the step outputs from the state above.
emit() {
	local images_json="[]" binaries_json="[]" i binary platform key
	local build_images=() reuse_images=() rebuild=() upload_files=()

	for i in "${!IMAGE_REFS[@]}"; do
		# An image a stop came before is left without an action.
		local action=""
		case "${IMAGE_STATE[$i]:-unknown}" in
		published)
			action=reuse
			reuse_images+=("${IMAGE_REFS[$i]}")
			;;
		absent)
			action=build
			build_images+=("${IMAGE_REFS[$i]}")
			;;
		esac
		local held=()
		read -r -a held <<<"${IMAGE_BINARIES[$i]}" || true
		local paths="{}"
		for binary in "${held[@]}"; do
			paths=$(jq -c --arg b "$binary" --arg p "${IMAGE_PATH[$i|$binary]}" '. + {($b): $p}' <<<"$paths")
		done
		images_json=$(jq -c \
			--arg ref "${IMAGE_REFS[$i]}" \
			--arg state "${IMAGE_STATE[$i]:-unknown}" \
			--arg digest "${IMAGE_DIGEST[$i]:-}" \
			--arg action "$action" \
			--argjson binaries "$(json_strings "${held[@]}")" \
			--argjson paths "$paths" \
			--argjson platforms "${PLATFORM_DIGESTS[$i]:-"{}"}" \
			'. + [{ref: $ref, state: $state, digest: $digest, action: $action, binaries: $binaries,
				binary_paths: $paths, platform_digests: $platforms}]' <<<"$images_json")
	done

	for binary in "${BINARY_LIST[@]}"; do
		for platform in "${PLATFORM_LIST[@]}"; do
			key="$binary@$platform"
			local name
			name=$(asset_name "$binary" "$platform")
			if [ "${SOURCE[$key]:-}" = rebuild ]; then
				rebuild+=("$key")
			fi
			if [ "${UPLOAD[$key]:-false}" = true ] && [ -n "${FILE[$key]:-}" ]; then
				upload_files+=("${FILE[$key]}")
			fi
			binaries_json=$(jq -c \
				--arg binary "$binary" \
				--arg platform "$platform" \
				--arg asset "$name" \
				--arg source "${SOURCE[$key]:-}" \
				--arg image "${SOURCE_IMAGE[$key]:-}" \
				--argjson published "${ASSET_PUBLISHED[$key]:-false}" \
				--arg sha "${SHA[$key]:-}" \
				--arg listed "${LISTED_SHA[$key]:-}" \
				--arg file "${FILE[$key]:-}" \
				--argjson upload "${UPLOAD[$key]:-false}" \
				'. + [{binary: $binary, platform: $platform, asset: $asset, source: $source,
					image: $image, asset_published: $published, sha256: $sha,
					checksums_sha256: $listed, file: $file, upload: $upload}]' <<<"$binaries_json")
		done
	done

	local build=false
	if [ "$MODE" != stop ] && { [ "${#build_images[@]}" -gt 0 ] || [ "${#rebuild[@]}" -gt 0 ] || [ "$DRY_RUN" = true ]; }; then
		build=true
	fi

	jq -n \
		--arg mode "$MODE" \
		--arg reason "$REASON" \
		--arg message "$MESSAGE" \
		--arg repo "$REPO" \
		--arg tag "$TAG" \
		--arg image_tag "$IMAGE_TAG" \
		--arg head_sha "$HEAD_SHA" \
		--argjson tag_exists "$TAG_EXISTS" \
		--argjson dry_run "$DRY_RUN" \
		--argjson build "$build" \
		--arg release_state "$RELEASE_STATE" \
		--argjson release_assets "$(json_strings "${RELEASE_ASSETS[@]}")" \
		--arg checksums_name "$CHECKSUMS_NAME" \
		--arg checksums_action "$CHECKSUMS_ACTION" \
		--arg highest "$HIGHEST_TAG" \
		--argjson move "$MOVE_POINTERS" \
		--argjson images "$images_json" \
		--argjson binaries "$binaries_json" \
		--argjson upload "$(json_strings "${upload_files[@]}")" \
		--argjson rebuild "$(json_strings "${rebuild[@]}")" \
		--argjson warnings "$(json_strings "${WARNINGS[@]}")" \
		'{schema_version: 1, mode: $mode, reason: $reason, message: $message, repo: $repo,
			tag: $tag, image_tag: $image_tag, head_sha: $head_sha, tag_exists: $tag_exists,
			dry_run: $dry_run, build: $build,
			release: {state: $release_state, assets: $release_assets},
			checksums: {name: $checksums_name, action: $checksums_action},
			pointers: {highest_tag: $highest, move: $move},
			images: $images, binaries: $binaries, upload: $upload, rebuild: $rebuild,
			warnings: $warnings}' >"$PLAN_FILE"

	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		local delimiter
		delimiter="EOF_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
		{
			echo "mode=$MODE"
			echo "reason=$REASON"
			echo "build=$build"
			echo "tag-exists=$TAG_EXISTS"
			echo "release-state=$RELEASE_STATE"
			echo "build-images=${build_images[*]}"
			echo "reuse-images=${reuse_images[*]}"
			echo "rebuild=${rebuild[*]}"
			echo "checksums=$CHECKSUMS_ACTION"
			echo "move-pointers=$MOVE_POINTERS"
			echo "plan-file=$PLAN_FILE"
			echo "upload-files<<$delimiter"
			if [ "${#upload_files[@]}" -gt 0 ]; then
				printf '%s\n' "${upload_files[@]}"
			fi
			echo "$delimiter"
		} >>"$GITHUB_OUTPUT"
	fi
}

# stop records why the run must not go on, writes the plan, and exits 1.
stop() {
	MODE=stop
	REASON=$1
	MESSAGE="$2 Nothing was pushed or changed."
	emit
	echo "::error::release-mode: $MESSAGE" >&2
	exit 1
}

warn() {
	WARNINGS+=("$1")
	echo "::warning::release-mode: $1" >&2
}

# --- 1. Required job results (the audit, for example) ------------------------------------------

for result in "${REQUIRED_LIST[@]}"; do
	if [ "$result" != success ]; then
		stop required-job-failed "A job this release depends on ended '$result', not success (required results: ${REQUIRED_LIST[*]})."
	fi
done

# Docker reads the registry. Checked up front, because a missing docker or buildx would otherwise
# fail every lookup with an error text that is easy to misread as "image not found".
if [ "${#IMAGE_REFS[@]}" -gt 0 ]; then
	if ! command -v docker >/dev/null 2>&1; then
		stop lookup-failed "docker is not installed, so the images cannot be looked up."
	fi
	if ! docker buildx version >/dev/null 2>"$SCRATCH/stderr"; then
		stop lookup-failed "docker buildx is not available, so the images cannot be looked up: $(cat "$SCRATCH/stderr")"
	fi
fi

# registry_absent <ref:tag> <output> reports whether a failed imagetools inspect is the registry's
# own "no such tag" answer: "manifest unknown", or "<ref:tag>: not found" naming exactly that
# reference. Anything else (a missing executable, a credential helper "not found in $PATH", a
# 401) is not an answer about the image, and the caller stops.
registry_absent() {
	local ref=$1 out=$2
	grep -qiF 'manifest unknown' <<<"$out" && return 0
	awk -v want="$ref: not found" '{sub(/^ERROR: /, "")} $0 == want {found = 1} END {exit !found}' <<<"$out"
}

# --- 2. The git tag ----------------------------------------------------------------------------

# The remote answers first: a tag pushed by another run is visible there before it is in this
# clone. The peeled line names the commit of an annotated tag; a lightweight tag has none.
if ! REMOTE=$(git ls-remote origin "refs/tags/$TAG" "refs/tags/$TAG^{}" 2>"$SCRATCH/stderr"); then
	stop lookup-failed "Could not list the remote tag $TAG: $(cat "$SCRATCH/stderr")"
fi
DIRECT=$(awk -v ref="refs/tags/$TAG" '$2 == ref {print $1}' <<<"$REMOTE")
PEELED=$(awk -v ref="refs/tags/$TAG^{}" '$2 == ref {print $1}' <<<"$REMOTE")
POINTS_AT=${PEELED:-$DIRECT}

if [ -n "$POINTS_AT" ]; then
	if [ "$POINTS_AT" != "$HEAD_SHA" ]; then
		stop tag-on-other-commit "$TAG already exists and points at $POINTS_AT, not at $HEAD_SHA. Tags are immutable: release a new version instead."
	fi
	TAG_EXISTS=true

	# The annotation is read from the clone, which must hold the same tag.
	if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
		stop tag-not-fetched "$TAG exists on the remote but not in this clone: check out with fetch-tags (and fetch-depth: 0)."
	fi
	LOCAL=$(git rev-list -n1 "refs/tags/$TAG")
	if [ "$LOCAL" != "$HEAD_SHA" ]; then
		stop tag-on-other-commit "The local tag $TAG points at $LOCAL, not at $HEAD_SHA."
	fi
	# A release tag is always annotated by the release workflow; a lightweight one was made by
	# hand, and its %(contents) would be the commit message, not a toolchain record.
	if [ "$(git cat-file -t "refs/tags/$TAG")" != tag ]; then
		stop tag-not-annotated "$TAG is a lightweight tag: the release workflow only creates annotated tags, so a human made it."
	fi
	ANNOTATION=$(git tag -l --format='%(contents)' "$TAG")
	for line in "${TOOLCHAIN_LINES[@]}"; do
		name=${line%%: *}
		recorded=$(awk -v prefix="$name: " 'index($0, prefix) == 1' <<<"$ANNOTATION")
		if [ -z "$recorded" ]; then
			stop annotation-missing-toolchain "The annotation of $TAG does not record '$name:', so the toolchain the release was made with is unknown."
		fi
		if [ "$recorded" != "$line" ]; then
			stop toolchain-mismatch "The annotation of $TAG records '$(head -n1 <<<"$recorded")', but this job has '$line'. Switch to the tag's toolchains (toolchain-recover) before deciding."
		fi
	done
elif git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
	# Not pushed yet, but already in the clone: it must be the one the release would push.
	LOCAL=$(git rev-list -n1 "refs/tags/$TAG")
	if [ "$LOCAL" != "$HEAD_SHA" ]; then
		stop tag-on-other-commit "The local tag $TAG points at $LOCAL, not at $HEAD_SHA."
	fi
fi

# --- 3. The images -----------------------------------------------------------------------------

# inspect_image <index> looks the version's tag up, and records absent, or published with the
# index digest and one digest per shipped platform.
inspect_image() {
	local i=$1 ref=${IMAGE_REFS[$1]} out
	if out=$(docker buildx imagetools inspect "$ref:$IMAGE_TAG" --format '{{json .Manifest}}' 2>&1); then
		:
	elif registry_absent "$ref:$IMAGE_TAG" "$out"; then
		IMAGE_STATE[$i]=absent
		return
	else
		stop lookup-failed "Could not tell whether $ref:$IMAGE_TAG exists: $out"
	fi

	local digest
	digest=$(jq -r '.digest // empty' <<<"$out" 2>/dev/null) || digest=""
	if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
		stop lookup-failed "Could not read the digest of $ref:$IMAGE_TAG: $(head -c 512 <<<"$out")"
	fi
	IMAGE_STATE[$i]=published
	IMAGE_DIGEST[$i]=$digest

	# Every platform descriptor of the index, normalized. The attestation manifests buildx adds
	# (unknown/unknown) describe no platform and are skipped.
	local descriptors line d dos darch dvariant
	if ! descriptors=$(jq -r '(.manifests // [])[] | select(.platform != null)
		| [.digest, .platform.os // "", .platform.architecture // "", .platform.variant // ""]
		| join("|")' <<<"$out" 2>/dev/null); then
		stop lookup-failed "Could not read the platforms of $ref:$IMAGE_TAG: $(head -c 512 <<<"$out")"
	fi
	local -A matches=() found=()
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		IFS='|' read -r d dos darch dvariant <<<"$line"
		[ "$dos/$darch" != unknown/unknown ] || continue
		local normal
		normal=$(normalize_platform "$dos/$darch${dvariant:+/$dvariant}")
		matches[$normal]=$((${matches[$normal]:-0} + 1))
		found[$normal]=$d
	done <<<"$descriptors"

	local platforms="{}" platform pdigest
	for platform in "${PLATFORM_LIST[@]}"; do
		normal=${PLATFORM_NORMAL[$platform]}
		if [ "${matches[$normal]:-0}" -gt 1 ]; then
			PLATFORM_DIGESTS[$i]=$platforms
			stop image-duplicate-platform "The published $ref:$IMAGE_TAG ($digest) has ${matches[$normal]} images that are all $platform ($normal), so which one ships is ambiguous."
		fi
		pdigest=${found[$normal]:-}
		if ! [[ "$pdigest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
			PLATFORM_DIGESTS[$i]=$platforms
			stop image-missing-platform "The published $ref:$IMAGE_TAG ($digest) has no single $platform image, and the release ships $platform. A published index cannot gain a platform without a new digest, and it is never replaced."
		fi
		platforms=$(jq -c --arg p "$platform" --arg d "$pdigest" '. + {($p): $d}' <<<"$platforms")
	done
	PLATFORM_DIGESTS[$i]=$platforms
}

for i in "${!IMAGE_REFS[@]}"; do
	inspect_image "$i"
done

# --- 4. The GitHub release ---------------------------------------------------------------------

if OUT=$(gh release view "$TAG" --repo "$REPO" --json isDraft,assets 2>&1); then
	if ! IS_DRAFT=$(jq -er '.isDraft | if type == "boolean" then tostring else error("no isDraft") end' <<<"$OUT" 2>/dev/null) ||
		! NAMES=$(jq -r '.assets | if type == "array" then .[].name else error("no assets") end' <<<"$OUT" 2>/dev/null); then
		stop lookup-failed "Could not read the release $TAG: $(head -c 512 <<<"$OUT")"
	fi
	if [ "$IS_DRAFT" = true ]; then
		RELEASE_STATE=draft
	else
		RELEASE_STATE=published
	fi
	if [ -n "$NAMES" ]; then
		mapfile -t RELEASE_ASSETS <<<"$NAMES"
	fi
elif grep -qi 'release not found' <<<"$OUT"; then
	RELEASE_STATE=absent
else
	stop lookup-failed "Could not tell whether the release $TAG exists: $OUT"
fi

release_has() {
	local name
	for name in "${RELEASE_ASSETS[@]}"; do
		[ "$name" != "$1" ] || return 0
	done
	return 1
}

# --- 5. Nothing may hold a version whose tag does not exist ------------------------------------

if [ "$TAG_EXISTS" != true ]; then
	for i in "${!IMAGE_REFS[@]}"; do
		if [ "${IMAGE_STATE[$i]}" = published ]; then
			stop image-without-tag "${IMAGE_REFS[$i]}:$IMAGE_TAG already exists (${IMAGE_DIGEST[$i]}), but the tag $TAG does not. The version is held by an image, so it cannot be tagged: release a higher version."
		fi
	done
	if [ "$RELEASE_STATE" != absent ]; then
		stop release-without-tag "A $RELEASE_STATE release $TAG exists, but the tag does not. The release workflow pushes the tag before it drafts a release, so something else made it: it needs a human."
	fi
fi

# --- 6. Verify everything published ------------------------------------------------------------

attestation_args=(--repo "$REPO" --signer-workflow "$SIGNER_WORKFLOW" --source-ref "$SOURCE_REF" --source-digest "$HEAD_SHA")

for i in "${!IMAGE_REFS[@]}"; do
	[ "${IMAGE_STATE[$i]}" = published ] || continue
	ref=${IMAGE_REFS[$i]}
	digest=${IMAGE_DIGEST[$i]}
	# Verified by digest, not by tag, so what is checked is what is reused.
	if ! gh attestation verify "oci://$ref@$digest" "${attestation_args[@]}" >"$SCRATCH/stdout" 2>"$SCRATCH/stderr"; then
		stop image-unattested "$ref:$IMAGE_TAG ($digest) carries no provenance from $SIGNER_WORKFLOW on $SOURCE_REF for $HEAD_SHA: something outside this workflow holds the version. $(cat "$SCRATCH/stderr")"
	fi
	if ! cosign verify --certificate-identity "$SIGNER_IDENTITY" --certificate-oidc-issuer "$SIGNER_ISSUER" \
		"$ref@$digest" >"$SCRATCH/stdout" 2>"$SCRATCH/stderr"; then
		stop image-unsigned "$ref:$IMAGE_TAG ($digest) is attested but carries no cosign signature from $SIGNER_IDENTITY. $(cat "$SCRATCH/stderr")"
	fi
done

for name in "${RELEASE_ASSETS[@]}"; do
	expected=false
	for want in "${EXPECTED_ASSETS[@]}"; do
		[ "$want" != "$name" ] || expected=true
	done
	if [ "$expected" != true ]; then
		stop unexpected-asset "The release $TAG carries an unexpected asset '$name'."
	fi
done

# download <asset> fetches a published asset into $OUT_DIR/download, and fails closed when gh
# reports success but leaves no file behind (a confined gh that cannot write there, say).
download() {
	if ! gh release download "$TAG" --repo "$REPO" --pattern "$1" --dir "$OUT_DIR/download" 2>"$SCRATCH/stderr"; then
		stop lookup-failed "Could not download the published $1 of $TAG: $(cat "$SCRATCH/stderr")"
	fi
	if [ ! -f "$OUT_DIR/download/$1" ]; then
		stop lookup-failed "gh downloaded the published $1 of $TAG, but $OUT_DIR/download/$1 is not there. $(cat "$SCRATCH/stderr")"
	fi
}

sha_of() {
	sha256sum "$1" | cut -d' ' -f1
}

# The published checksums file, parsed into LISTED[asset].
declare -A LISTED=()
if [ "${#BINARY_LIST[@]}" -gt 0 ]; then
	CHECKSUMS_ACTION=upload
	if release_has "$CHECKSUMS_NAME"; then
		CHECKSUMS_ACTION=verify
		download "$CHECKSUMS_NAME"
		cp "$OUT_DIR/download/$CHECKSUMS_NAME" "$OUT_DIR/published-$CHECKSUMS_NAME"
		while IFS= read -r line || [ -n "$line" ]; do
			[ -n "$line" ] || continue
			if ! [[ "$line" =~ ^([0-9a-f]{64})\ [\ *]([^[:space:]]+)$ ]]; then
				stop checksums-conflict "The published $CHECKSUMS_NAME has a line that is not '<sha256>  <name>': '$line'."
			fi
			listed_name=${BASH_REMATCH[2]}
			if [ -z "${ASSET_OWNER[$listed_name]:-}" ]; then
				stop checksums-conflict "The published $CHECKSUMS_NAME lists '$listed_name', which is not a binary this release ships."
			fi
			if [ -n "${LISTED[$listed_name]:-}" ]; then
				stop checksums-conflict "The published $CHECKSUMS_NAME lists '$listed_name' twice."
			fi
			LISTED[$listed_name]=${BASH_REMATCH[1]}
		done <"$OUT_DIR/published-$CHECKSUMS_NAME"
		for binary in "${BINARY_LIST[@]}"; do
			for platform in "${PLATFORM_LIST[@]}"; do
				name=$(asset_name "$binary" "$platform")
				if [ -z "${LISTED[$name]:-}" ]; then
					stop checksums-conflict "The published $CHECKSUMS_NAME does not list $name, so it cannot equal the one this release regenerates."
				fi
				LISTED_SHA["$binary@$platform"]=${LISTED[$name]}
			done
		done
	fi
fi

# extract <index> <binary> <platform> <dest> copies the binary out of the published image's
# platform manifest, without running anything from it.
extract() {
	local i=$1 binary=$2 platform=$3 dest=$4 ref pdigest path cid
	ref=${IMAGE_REFS[$i]}
	pdigest=$(jq -r --arg p "$platform" '.[$p]' <<<"${PLATFORM_DIGESTS[$i]}")
	path=${IMAGE_PATH[$i|$binary]}
	if ! cid=$(docker create --platform "$platform" "$ref@$pdigest" /release-mode-extract 2>"$SCRATCH/stderr"); then
		stop lookup-failed "Could not create a container from $ref@$pdigest ($platform) to read $path: $(cat "$SCRATCH/stderr")"
	fi
	if ! docker cp "$cid:$path" "$dest" >/dev/null 2>"$SCRATCH/stderr"; then
		local why
		why=$(cat "$SCRATCH/stderr")
		docker rm "$cid" >/dev/null 2>&1 || true
		stop image-binary-missing "Could not copy $path out of $ref@$pdigest ($platform), which should hold $binary: $why"
	fi
	docker rm "$cid" >/dev/null 2>&1 || true
	# docker cp copies a symlink as a symlink: following it would hash and hand over a file of
	# this runner, not of the image.
	if [ -L "$dest" ]; then
		stop image-binary-symlink "$path in $ref@$pdigest ($platform) is a symlink, not the binary itself."
	fi
	if [ ! -f "$dest" ]; then
		stop image-binary-missing "$path in $ref@$pdigest ($platform) is not a regular file."
	fi
}

for binary in "${BINARY_LIST[@]}"; do
	for platform in "${PLATFORM_LIST[@]}"; do
		key="$binary@$platform"
		name=$(asset_name "$binary" "$platform")
		asset_sha=""
		ASSET_PUBLISHED[$key]=false

		# The published asset: downloaded, attested by the signer workflow, and listed with the
		# same sha256 in the published checksums file when there is one.
		if release_has "$name"; then
			ASSET_PUBLISHED[$key]=true
			download "$name"
			asset_sha=$(sha_of "$OUT_DIR/download/$name")
			if [ -n "${LISTED[$name]:-}" ] && [ "${LISTED[$name]}" != "$asset_sha" ]; then
				stop checksums-conflict "The published $name ($asset_sha) does not match the published $CHECKSUMS_NAME (${LISTED[$name]})."
			fi
			if ! gh attestation verify "$OUT_DIR/download/$name" "${attestation_args[@]}" >"$SCRATCH/stdout" 2>"$SCRATCH/stderr"; then
				stop asset-unattested "The published $name (sha256:$asset_sha) carries no provenance from $SIGNER_WORKFLOW on $SOURCE_REF for $HEAD_SHA. $(cat "$SCRATCH/stderr")"
			fi
		fi

		# Every published image holding the binary: extracted, and all of them the same bytes.
		image_sha=""
		for i in "${!IMAGE_REFS[@]}"; do
			[ "${IMAGE_STATE[$i]}" = published ] || continue
			[[ " ${IMAGE_BINARIES[$i]} " == *" $binary "* ]] || continue
			dest="$OUT_DIR/extract/$i/$name"
			mkdir -p "$OUT_DIR/extract/$i"
			extract "$i" "$binary" "$platform" "$dest"
			got=$(sha_of "$dest")
			if [ -z "$image_sha" ]; then
				image_sha=$got
				SOURCE_IMAGE[$key]=${IMAGE_REFS[$i]}
				cp "$dest" "$OUT_DIR/assets/$name"
			elif [ "$got" != "$image_sha" ]; then
				stop image-binaries-differ "$binary for $platform is $image_sha in ${SOURCE_IMAGE[$key]} but $got in ${IMAGE_REFS[$i]}. Published images are never replaced."
			fi
		done

		if [ -n "$image_sha" ]; then
			SOURCE[$key]=image
			SHA[$key]=$image_sha
			FILE[$key]="$OUT_DIR/assets/$name"
			if [ "${ASSET_PUBLISHED[$key]}" = true ]; then
				if [ "$asset_sha" != "$image_sha" ]; then
					stop asset-differs-from-image "The published $name (sha256:$asset_sha) is not the $binary inside ${SOURCE_IMAGE[$key]} for $platform (sha256:$image_sha). Neither is replaced."
				fi
				UPLOAD[$key]=false
			else
				UPLOAD[$key]=true
			fi
		elif [ "${ASSET_PUBLISHED[$key]}" = true ]; then
			SOURCE[$key]=asset
			SHA[$key]=$asset_sha
			FILE[$key]="$OUT_DIR/assets/$name"
			cp "$OUT_DIR/download/$name" "$OUT_DIR/assets/$name"
			UPLOAD[$key]=false
		else
			SOURCE[$key]=rebuild
			UPLOAD[$key]=true
		fi

		if [ -n "${LISTED[$name]:-}" ] && [ -n "${SHA[$key]:-}" ] && [ "${LISTED[$name]}" != "${SHA[$key]}" ]; then
			stop checksums-conflict "The $name this release reuses (sha256:${SHA[$key]}) does not match the published $CHECKSUMS_NAME (${LISTED[$name]})."
		fi
	done
done

# --- 7. Mode -----------------------------------------------------------------------------------

if [ "$TAG_EXISTS" != true ]; then
	MODE=fresh
else
	MODE=reuse
	for i in "${!IMAGE_REFS[@]}"; do
		[ "${IMAGE_STATE[$i]}" = published ] || MODE=publish
	done
	for key in "${!SOURCE[@]}"; do
		[ "${SOURCE[$key]}" != rebuild ] || MODE=publish
	done
fi

# --- 8. The moving pointers --------------------------------------------------------------------

# They follow the highest release tag on the remote. This run moves them only when its own tag
# is that one; a published release whose pointers disagree is reported, and the run of the
# highest version is what repoints them, as the pointer steps of the release workflows say.
if ! REMOTE_TAGS=$(git ls-remote --tags --refs origin 2>"$SCRATCH/stderr"); then
	stop lookup-failed "Could not list the remote tags: $(cat "$SCRATCH/stderr")"
fi
HIGHEST_TAG=$({
	awk '{sub(/^refs\/tags\//, "", $2); print $2}' <<<"$REMOTE_TAGS" | { grep -E "$TAG_REGEX" || [ "$?" -eq 1 ]; }
	echo "$TAG"
} | sort -V | tail -n1)
if [ "$HIGHEST_TAG" = "$TAG" ]; then
	MOVE_POINTERS=true
fi

if [ "$RELEASE_STATE" = published ]; then
	if OUT=$(gh api "repos/$REPO/releases/latest" --jq .tag_name 2>&1); then
		LATEST_RELEASE=$OUT
	elif grep -qF 'HTTP 404' <<<"$OUT"; then
		LATEST_RELEASE=""
	else
		stop lookup-failed "Could not read the latest release of $REPO: $OUT"
	fi
	if [ "$LATEST_RELEASE" != "$HIGHEST_TAG" ]; then
		warn "GitHub marks ${LATEST_RELEASE:-no release} as Latest, but the highest release tag is $HIGHEST_TAG."
	fi
	if [ "$MOVE_POINTERS" = true ]; then
		for i in "${!IMAGE_REFS[@]}"; do
			[ "${IMAGE_STATE[$i]}" = published ] || continue
			ref=${IMAGE_REFS[$i]}
			if OUT=$(docker buildx imagetools inspect "$ref:latest" --format '{{json .Manifest}}' 2>&1); then
				latest_digest=$(jq -r '.digest // empty' <<<"$OUT" 2>/dev/null) || latest_digest=""
			elif registry_absent "$ref:latest" "$OUT"; then
				latest_digest=""
			else
				stop lookup-failed "Could not tell where $ref:latest points: $OUT"
			fi
			if [ "$latest_digest" != "${IMAGE_DIGEST[$i]}" ]; then
				warn "$ref:latest is ${latest_digest:-absent}, not $TAG's ${IMAGE_DIGEST[$i]}; this run moves it."
			fi
		done
	fi
fi

emit
echo "release-mode: $TAG: mode $MODE (tag on HEAD: $TAG_EXISTS, release: $RELEASE_STATE)."
jq -r '.images[] | "  image   \(.ref): \(.state) -> \(.action)"' "$PLAN_FILE"
jq -r '.binaries[] | "  binary  \(.binary) \(.platform): \(.source)\(if .upload then ", upload" else "" end)"' "$PLAN_FILE"
