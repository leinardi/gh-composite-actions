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

# Table tests for release-mode.sh. Plain bash: stub git, docker, gh and cosign, first on PATH,
# answer every call from a per-case fixture directory ($FIX), which the helpers below fill in to
# describe what is published: the remote and local tag, the images on the registry with the files
# inside each platform manifest, the GitHub release and its assets, and which subjects carry an
# attestation or a signature from which identity. Each case then runs the script and checks its
# exit status and fields of the plan it wrote.
#
# Run: bash release-mode/release-mode.test.sh

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/release-mode.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

repo=leinardi/example
head_sha=1111111111111111111111111111111111111111
other_sha=2222222222222222222222222222222222222222
tag_object=3333333333333333333333333333333333333333
signer=leinardi/example/.github/workflows/release.yaml
identity=https://github.com/leinardi/example/.github/workflows/release.yaml@refs/heads/main
image=ghcr.io/leinardi/example

# --- Stubs -------------------------------------------------------------------------------------

# key turns a reference into a file name.
cat >"$work/bin/_key" <<'STUB'
#!/usr/bin/env bash
printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
STUB

cat >"$work/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "git $*" >>"$STUB_LOG"
case "$1" in
ls-remote)
	if [ "$2" = --tags ]; then
		[ ! -f "$FIX/remote-tags.fail" ] || { echo "fatal: unable to access remote" >&2; exit 128; }
		cat "$FIX/remote-tags" 2>/dev/null || true
	else
		[ ! -f "$FIX/remote-tag.fail" ] || { echo "fatal: unable to access remote" >&2; exit 128; }
		cat "$FIX/remote-tag" 2>/dev/null || true
	fi
	;;
rev-parse)
	[ -f "$FIX/local-tag-commit" ]
	;;
rev-list)
	cat "$FIX/local-tag-commit"
	;;
cat-file)
	cat "$FIX/local-tag-type"
	;;
tag)
	cat "$FIX/annotation"
	;;
*)
	echo "stub git: unexpected call: $*" >&2
	exit 98
	;;
esac
STUB

cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "docker $*" >>"$STUB_LOG"
case "$1 ${2:-}" in
"buildx imagetools")
	key=$(_key "$4")
	if [ -f "$FIX/registry/$key.err" ]; then
		cat "$FIX/registry/$key.err" >&2
		exit 1
	elif [ -f "$FIX/registry/$key.json" ]; then
		cat "$FIX/registry/$key.json"
	else
		echo "ERROR: $4: not found" >&2
		exit 1
	fi
	;;
"create --platform")
	digest=${4##*@}
	if [ ! -d "$FIX/fs/$(_key "$digest")" ]; then
		echo "Error response from daemon: manifest unknown" >&2
		exit 1
	fi
	echo "cid-$(_key "$digest")"
	;;
cp*)
	cid=${2%%:*}
	path=${2#*:}
	src="$FIX/fs/${cid#cid-}$path"
	if [ ! -f "$src" ]; then
		echo "Error response from daemon: Could not find the file $path in container $cid" >&2
		exit 1
	fi
	if [ -f "$FIX/cp-symlink" ]; then
		ln -s /bin/ls "$3"
	else
		cp "$src" "$3"
	fi
	;;
rm*) ;;
"buildx version")
	[ ! -f "$FIX/no-buildx" ] || { echo "docker: 'buildx' is not a docker command." >&2; exit 1; }
	echo "github.com/docker/buildx v0.30.0"
	;;
*)
	echo "stub docker: unexpected call: $*" >&2
	exit 98
	;;
esac
STUB

cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >>"$STUB_LOG"
# arg <flag> prints the value after the flag.
arg() {
	local want=$1
	shift
	while [ "$#" -gt 0 ]; do
		if [ "$1" = "$want" ]; then
			echo "$2"
			return
		fi
		shift
	done
}
case "$1 $2" in
"release view")
	if [ -f "$FIX/release.err" ]; then
		cat "$FIX/release.err" >&2
		exit 1
	fi
	if [ ! -f "$FIX/release-state" ]; then
		echo "release not found" >&2
		exit 1
	fi
	draft=false
	[ "$(cat "$FIX/release-state")" != draft ] || draft=true
	names=$(cd "$FIX/assets" && ls -1)
	jq -n --argjson draft "$draft" --arg names "$names" \
		'{isDraft: $draft, assets: [$names | split("\n")[] | select(. != "") | {name: .}]}'
	;;
"release download")
	name=$(arg --pattern "$@")
	dir=$(arg --dir "$@")
	cp "$FIX/assets/$name" "$dir/$name"
	;;
"attestation verify")
	subject=$3
	if [[ "$subject" != oci://* ]]; then
		subject="sha256:$(sha256sum "$subject" | cut -d' ' -f1)"
	fi
	want="$subject $(arg --signer-workflow "$@") $(arg --source-ref "$@") $(arg --source-digest "$@") $(arg --repo "$@")"
	if grep -qxF "$want" "$FIX/attested" 2>/dev/null; then
		exit 0
	fi
	echo "Error: verifying with issuer \"sigstore.dev\": no matching attestations" >&2
	exit 1
	;;
"api repos/"*)
	if [ -f "$FIX/latest-release" ]; then
		cat "$FIX/latest-release"
	else
		echo '{"message":"Not Found","status":"404"}'
		echo "gh: Not Found (HTTP 404)" >&2
		exit 1
	fi
	;;
*)
	echo "stub gh: unexpected call: $*" >&2
	exit 98
	;;
esac
STUB

cat >"$work/bin/cosign" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "cosign $*" >>"$STUB_LOG"
[ "$1" = verify ] || { echo "stub cosign: unexpected call: $*" >&2; exit 98; }
identity=$3
issuer=$5
subject=$6
if grep -qxF "$subject $identity $issuer" "$FIX/signed" 2>/dev/null; then
	echo '[{"critical":{}}]'
	exit 0
fi
echo "Error: no signatures found" >&2
exit 1
STUB

chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"
export STUB_LOG="$work/stub.log"
FIX="$work/fix"
export FIX

# --- Fixture helpers ---------------------------------------------------------------------------

digest_of() {
	printf 'sha256:%s' "$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"
}

# content <binary> <platform> is what the release builds for that binary and platform.
content() {
	printf 'build of %s for %s at %s\n' "$1" "$2" "$head_sha"
}

sum_of_content() {
	content "$1" "$2" | sha256sum | cut -d' ' -f1
}

# new_case resets everything to: no tag of this version, v1.1.0 released earlier, no image, no
# release, and the default inputs.
new_case() {
	rm -rf "$FIX"
	mkdir -p "$FIX/registry" "$FIX/fs" "$FIX/assets"
	printf '%s\trefs/tags/v1.1.0\n' "$other_sha" >"$FIX/remote-tags"
	: >"$FIX/attested"
	: >"$FIX/signed"
	: >"$STUB_LOG"
	export RM_REPO=$repo RM_TAG=v1.2.0 RM_HEAD_SHA=$head_sha RM_SOURCE_REF=refs/heads/main
	export RM_IMAGE=$image RM_IMAGES="" RM_BINARIES=example RM_PLATFORMS=linux/amd64,linux/arm64
	export RM_IMAGE_TAG="" RM_SIGNER_WORKFLOW="" RM_IMAGE_BINARY_PATHS="" RM_ASSET_PATTERN=""
	export RM_EXPECTED_TOOLCHAINS="" RM_REQUIRED_RESULTS="" RM_DRY_RUN=false RM_TAG_REGEX=""
	export RM_OUT_DIR="$work/out"
	rm -rf "$RM_OUT_DIR"
}

# tag_on_head [annotation] pushes an annotated v1.2.0 on HEAD, fetched into the clone.
tag_on_head() {
	local annotation=${1:-$'example v1.2.0\n\nRust: 1.90.0\nNode: v24.1.0'}
	printf '%s\trefs/tags/v1.2.0\n%s\trefs/tags/v1.2.0^{}\n' "$tag_object" "$head_sha" >"$FIX/remote-tag"
	printf '%s\trefs/tags/v1.2.0\n' "$tag_object" >>"$FIX/remote-tags"
	echo "$head_sha" >"$FIX/local-tag-commit"
	echo tag >"$FIX/local-tag-type"
	printf '%s\n' "$annotation" >"$FIX/annotation"
}

# add_remote_tag <tag> adds a release tag on another commit to the remote.
add_remote_tag() {
	printf '%s\trefs/tags/%s\n' "$other_sha" "$1" >>"$FIX/remote-tags"
}

# publish_image <ref> <binaries> <platforms> [path-prefix]: the image tag of the version exists,
# with one manifest per platform holding each binary under path-prefix (default /usr/local/bin),
# attested and signed by the release workflow for HEAD.
publish_image() {
	local ref=$1 binaries=$2 platforms=$3 prefix=${4-/usr/local/bin}
	local tag=${RM_IMAGE_TAG:-$RM_TAG}
	local index manifests="[]" platform binary pdigest
	index=$(digest_of "index $ref:$tag")
	for platform in $platforms; do
		pdigest=$(digest_of "manifest $ref:$tag $platform")
		local os=${platform%%/*} arch=${platform#*/} variant=""
		if [[ "$arch" == */* ]]; then
			variant=${arch#*/}
			arch=${arch%%/*}
		fi
		manifests=$(jq -c --arg d "$pdigest" --arg os "$os" --arg arch "$arch" --arg v "$variant" \
			'. + [{mediaType: "application/vnd.oci.image.manifest.v1+json", digest: $d,
				platform: ({os: $os, architecture: $arch} + (if $v == "" then {} else {variant: $v} end))}]' <<<"$manifests")
		mkdir -p "$FIX/fs/$(_key "$pdigest")$prefix"
		for binary in $binaries; do
			content "$binary" "$platform" >"$FIX/fs/$(_key "$pdigest")$prefix/$binary"
		done
	done
	# The attestation manifests buildx adds are platform unknown/unknown and must be ignored.
	manifests=$(jq -c --arg d "$(digest_of "attestation $ref")" \
		'. + [{mediaType: "application/vnd.oci.image.manifest.v1+json", digest: $d,
			platform: {os: "unknown", architecture: "unknown"},
			annotations: {"vnd.docker.reference.type": "attestation-manifest"}}]' <<<"$manifests")
	jq -n --arg d "$index" --argjson m "$manifests" \
		'{schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json", digest: $d, manifests: $m}' \
		>"$FIX/registry/$(_key "$ref:$tag").json"
	echo "oci://$ref@$index $signer refs/heads/main $head_sha $repo" >>"$FIX/attested"
	echo "$ref@$index $identity https://token.actions.githubusercontent.com" >>"$FIX/signed"
}

image_digest() {
	digest_of "index $1:${RM_IMAGE_TAG:-$RM_TAG}"
}

# set_image_binary <ref> <platform> <path> <content> overwrites a file inside a published image.
set_image_binary() {
	local pdigest
	pdigest=$(digest_of "manifest $1:${RM_IMAGE_TAG:-$RM_TAG} $2")
	printf '%s' "$4" >"$FIX/fs/$(_key "$pdigest")$3"
}

# unattest <subject> and unsign <ref@digest> take an attestation or signature away.
unattest() {
	grep -vF "$1 " "$FIX/attested" >"$FIX/attested.new" || true
	mv "$FIX/attested.new" "$FIX/attested"
}
unsign() {
	grep -vF "$1 " "$FIX/signed" >"$FIX/signed.new" || true
	mv "$FIX/signed.new" "$FIX/signed"
}

# release <draft|published> makes the release exist.
release() {
	echo "$1" >"$FIX/release-state"
}

# publish_asset <name> [content] [attested-by]: a release asset, attested by the release
# workflow (or by attested-by; "none" for no attestation).
publish_asset() {
	local name=$1 body=${2-} by=${3:-$signer}
	local stem=${name#example-}
	if [ "$#" -lt 2 ]; then
		content example "${stem%%-*}/${stem#*-}" >"$FIX/assets/$name"
	else
		printf '%s' "$body" >"$FIX/assets/$name"
	fi
	[ -f "$FIX/release-state" ] || release draft
	if [ "$by" != none ]; then
		echo "sha256:$(sha256sum "$FIX/assets/$name" | cut -d' ' -f1) $by refs/heads/main $head_sha $repo" >>"$FIX/attested"
	fi
}

# publish_checksums [content]: the checksums asset, by default the right one for every binary.
publish_checksums() {
	local body
	if [ "$#" -gt 0 ]; then
		body=$1
	else
		body=$(printf '%s  example-linux-amd64\n%s  example-linux-arm64\n' \
			"$(sum_of_content example linux/amd64)" "$(sum_of_content example linux/arm64)")
	fi
	printf '%s\n' "$body" >"$FIX/assets/checksums.txt"
	[ -f "$FIX/release-state" ] || release draft
}

# --- Runner and checks -------------------------------------------------------------------------

failures=0
status=0

run() {
	export GITHUB_OUTPUT="$work/github-output"
	: >"$GITHUB_OUTPUT"
	status=0
	"$script" >"$work/stdout" 2>"$work/stderr" || status=$?
}

plan() {
	jq -r "$1" "$RM_OUT_DIR/plan.json"
}

# expect <name> <want-status> [<jq filter> <want>]... runs the script and checks the result.
expect() {
	local name=$1 want_status=$2
	shift 2
	run
	local problems=()
	if [ "$status" -ne "$want_status" ]; then
		problems+=("exit $status, want $want_status")
	fi
	while [ "$#" -ge 2 ]; do
		local got
		if ! got=$(plan "$1" 2>&1); then
			got="<no plan: $got>"
		fi
		if [ "$got" != "$2" ]; then
			problems+=("$1 is [$got], want [$2]")
		fi
		shift 2
	done
	if [ "${#problems[@]}" -eq 0 ]; then
		echo "ok - $name"
	else
		echo "not ok - $name: $(printf '%s; ' "${problems[@]}")stderr [$(cat "$work/stderr")]"
		failures=$((failures + 1))
	fi
}

# expect_true <name> <command>... records a check that is not about the plan.
expect_true() {
	local name=$1
	shift
	if "$@"; then
		echo "ok - $name"
	else
		echo "not ok - $name"
		failures=$((failures + 1))
	fi
}

sources='[.binaries[] | "\(.platform)=\(.source)"] | join(" ")'
uploads='[.binaries[] | select(.upload) | .asset] | join(" ")'
actions='[.images[] | "\(.ref)=\(.action)"] | join(" ")'

out_asset() {
	cmp -s "$RM_OUT_DIR/assets/$1" <(content "$2" "$3")
}

# --- The tag -----------------------------------------------------------------------------------

new_case
expect "no tag, nothing published: fresh, everything rebuilt" 0 \
	.mode fresh .tag_exists false .build true "$sources" "linux/amd64=rebuild linux/arm64=rebuild" \
	"$uploads" "example-linux-amd64 example-linux-arm64" "$actions" "$image=build" \
	.checksums.action upload .release.state absent .pointers.move true '.upload | length' 0

new_case
add_remote_tag v1.3.0
expect "no tag, a higher release exists: fresh, the pointers stay" 0 \
	.mode fresh .pointers.highest_tag v1.3.0 .pointers.move false

new_case
tag_on_head
expect "matching tag on HEAD, nothing published: publish, everything rebuilt" 0 \
	.mode publish .tag_exists true .build true "$sources" "linux/amd64=rebuild linux/arm64=rebuild" \
	"$actions" "$image=build"

new_case
tag_on_head
release draft
expect "tag pushed, a draft with no assets and no image: publish" 0 \
	.mode publish .release.state draft "$sources" "linux/amd64=rebuild linux/arm64=rebuild"

new_case
printf '%s\trefs/tags/v1.2.0\n%s\trefs/tags/v1.2.0^{}\n' "$tag_object" "$other_sha" >"$FIX/remote-tag"
expect "tag on another commit: stop" 1 .mode stop .reason tag-on-other-commit

new_case
printf '%s\trefs/tags/v1.2.0\n' "$other_sha" >"$FIX/remote-tag"
expect "lightweight remote tag on another commit: stop" 1 .mode stop .reason tag-on-other-commit

new_case
echo "$other_sha" >"$FIX/local-tag-commit"
expect "no remote tag, but a local one on another commit: stop" 1 .reason tag-on-other-commit

new_case
tag_on_head
rm "$FIX/local-tag-commit"
expect "tag on the remote but not fetched: stop" 1 .reason tag-not-fetched

new_case
tag_on_head
echo commit >"$FIX/local-tag-type"
expect "lightweight tag on HEAD (wrong annotation): stop" 1 .reason tag-not-annotated

new_case
tag_on_head $'example v1.2.0'
RM_EXPECTED_TOOLCHAINS=$'Rust: 1.90.0\nNode: v24.1.0'
expect "annotation without the toolchain lines: stop" 1 .reason annotation-missing-toolchain

new_case
tag_on_head
RM_EXPECTED_TOOLCHAINS=$'Rust: 1.91.0\nNode: v24.1.0'
expect "annotation records another toolchain: stop" 1 .reason toolchain-mismatch

new_case
tag_on_head
RM_EXPECTED_TOOLCHAINS=$'Rust: 1.90.0\nNode: v24.1.0'
expect "annotation records the active toolchains: publish" 0 .mode publish

new_case
touch "$FIX/remote-tag.fail"
expect "the remote tag cannot be listed: stop" 1 .reason lookup-failed

# --- Nothing may hold the version without its tag ---------------------------------------------

new_case
publish_image "$image" example "linux/amd64 linux/arm64"
expect "no tag, but the image exists: stop before tagging" 1 .reason image-without-tag

new_case
release draft
expect "no tag, but a draft release exists: stop" 1 .reason release-without-tag

# --- The image ---------------------------------------------------------------------------------

new_case
tag_on_head
echo "ERROR: unexpected status from HEAD request: 401 Unauthorized" >"$FIX/registry/$(_key "$image:v1.2.0").err"
expect "the image lookup is refused: stop" 1 .reason lookup-failed

new_case
tag_on_head
echo "docker: command not found" >"$FIX/registry/$(_key "$image:v1.2.0").err"
expect "an inspect failing with 'command not found' is not an absent image: stop" 1 .reason lookup-failed

new_case
tag_on_head
# shellcheck disable=SC2016 # the literal text docker prints
echo 'ERROR: error getting credentials - err: exec: "docker-credential-desktop": executable file not found in $PATH, out: ``' >"$FIX/registry/$(_key "$image:v1.2.0").err"
expect "an inspect failing on a missing credential helper is not an absent image: stop" 1 .reason lookup-failed

new_case
tag_on_head
echo "ERROR: ghcr.io/leinardi/other:v1.2.0: not found" >"$FIX/registry/$(_key "$image:v1.2.0").err"
expect "a 'not found' naming another reference is not an absent image: stop" 1 .reason lookup-failed

new_case
tag_on_head
echo "ERROR: failed to resolve: $image:v1.2.0: manifest unknown" >"$FIX/registry/$(_key "$image:v1.2.0").err"
expect "the registry's 'manifest unknown' is an absent image: publish" 0 .mode publish "$actions" "$image=build"

new_case
tag_on_head
touch "$FIX/no-buildx"
expect "docker without buildx: stop" 1 .reason lookup-failed

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
unattest "oci://$image@$(image_digest "$image")"
expect "image present but not attested: stop" 1 .reason image-unattested

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
unattest "oci://$image@$(image_digest "$image")"
echo "oci://$image@$(image_digest "$image") leinardi/example/.github/workflows/other.yaml refs/heads/main $head_sha $repo" >>"$FIX/attested"
expect "image attested by the wrong workflow: stop" 1 .reason image-unattested

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
unattest "oci://$image@$(image_digest "$image")"
echo "oci://$image@$(image_digest "$image") $signer refs/heads/main $other_sha $repo" >>"$FIX/attested"
expect "image attested for another commit: stop" 1 .reason image-unattested

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
unsign "$image@$(image_digest "$image")"
expect "image attested but not signed: stop" 1 .reason image-unsigned

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
unsign "$image@$(image_digest "$image")"
echo "$image@$(image_digest "$image") https://github.com/someone/else/.github/workflows/x.yaml@refs/heads/main https://token.actions.githubusercontent.com" >>"$FIX/signed"
expect "image signed by another identity: stop" 1 .reason image-unsigned

new_case
tag_on_head
publish_image "$image" example "linux/amd64"
expect "image published but missing a shipped platform: stop" 1 .reason image-missing-platform

# --- Per platform: image and assets ------------------------------------------------------------

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
expect "image published, every asset missing: extract them all" 0 \
	.mode reuse .build false "$sources" "linux/amd64=image linux/arm64=image" \
	"$uploads" "example-linux-amd64 example-linux-arm64" "$actions" "$image=reuse" \
	'.binaries[0].image' "$image" '.binaries[0].sha256' "$(sum_of_content example linux/amd64)" \
	'.upload | join(" ")' "$RM_OUT_DIR/assets/example-linux-amd64 $RM_OUT_DIR/assets/example-linux-arm64" \
	.checksums.action upload
expect_true "the extracted binaries are the image's" out_asset example-linux-arm64 example linux/arm64

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
publish_asset example-linux-amd64
expect "image published, amd64 asset present, arm64 missing: extract arm64, amd64 must match" 0 \
	.mode reuse "$sources" "linux/amd64=image linux/arm64=image" "$uploads" "example-linux-arm64" \
	'.binaries[0].asset_published' true '.binaries[1].asset_published' false

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
publish_asset example-linux-amd64 "a different build"
expect "image published, an asset differs from the image's binary: stop" 1 .reason asset-differs-from-image

new_case
tag_on_head
publish_asset example-linux-amd64
expect "image missing, amd64 asset present: image built from it plus a rebuilt arm64" 0 \
	.mode publish .build true "$sources" "linux/amd64=asset linux/arm64=rebuild" \
	"$uploads" "example-linux-arm64" "$actions" "$image=build" '.rebuild | join(" ")' example@linux/arm64
expect_true "the published asset is handed over for the image" out_asset example-linux-amd64 example linux/amd64

new_case
tag_on_head
publish_asset example-linux-amd64
publish_asset example-linux-arm64 "$(content example linux/arm64)" none
expect "some binaries attested, one published asset not: stop" 1 .reason asset-unattested

new_case
tag_on_head
publish_asset example-linux-amd64 "$(content example linux/amd64)" leinardi/example/.github/workflows/ci.yaml
expect "an asset attested by the wrong workflow: stop" 1 .reason asset-unattested

new_case
tag_on_head
release draft
publish_asset example-linux-amd64 "a different build"
publish_asset example-linux-arm64
publish_checksums
expect "a draft whose asset conflicts with the published checksums.txt: stop" 1 .reason checksums-conflict

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
publish_checksums "$(printf '%s  example-linux-amd64\n%s  example-linux-arm64' "$(sum_of_content example linux/amd64)" "$(printf x | sha256sum | cut -d' ' -f1)")"
expect "a published checksums.txt that conflicts with the image's binary: stop" 1 .reason checksums-conflict

new_case
tag_on_head
publish_checksums "$(printf '%s  example-linux-amd64\n%s  example-linux-arm64\n%s  stray' "$(sum_of_content example linux/amd64)" "$(sum_of_content example linux/arm64)" "$(sum_of_content example linux/amd64)")"
expect "a published checksums.txt listing an unknown file: stop" 1 .reason checksums-conflict

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
publish_checksums "not a checksum line"
expect "a malformed published checksums.txt: stop" 1 .reason checksums-conflict

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
publish_checksums "$(printf '%s  example-linux-amd64' "$(sum_of_content example linux/amd64)")"
expect "a published checksums.txt missing a binary: stop" 1 .reason checksums-conflict

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
publish_asset example-linux-amd64
publish_checksums
expect "image, one asset and checksums.txt published: verify checksums, upload the other asset" 0 \
	.mode reuse .checksums.action verify "$uploads" "example-linux-arm64" \
	'.binaries[1].checksums_sha256' "$(sum_of_content example linux/arm64)"
expect_true "the published checksums.txt is kept for the comparison" test -f "$RM_OUT_DIR/published-checksums.txt"

new_case
tag_on_head
publish_checksums
expect "checksums.txt published, nothing else: rebuild and compare against it" 0 \
	.mode publish .checksums.action verify "$sources" "linux/amd64=rebuild linux/arm64=rebuild"

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
publish_asset example-linux-amd64
publish_asset example-linux-arm64
publish_checksums
expect "everything published in a draft: reuse, nothing to build or upload" 0 \
	.mode reuse .build false "$uploads" "" .checksums.action verify '.warnings | length' 0 .release.state draft

# --- Platform spellings (containerd's platforms.Normalize) -------------------------------------

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64/v8"
expect "requested linux/arm64, published linux/arm64/v8: the same platform, extracted" 0 \
	.mode reuse "$sources" "linux/amd64=image linux/arm64=image" \
	'[.binaries[].asset] | join(" ")' "example-linux-amd64 example-linux-arm64" \
	'.images[0].platform_digests | keys | join(" ")' "linux/amd64 linux/arm64" \
	'.images[0].platform_digests["linux/arm64"]' "$(digest_of "manifest $image:v1.2.0 linux/arm64/v8")"
two_platform_digests() {
	jq -e '.images[0].platform_digests | length == 2' "$RM_OUT_DIR/plan.json" >/dev/null
}
expect_true "the attestation manifests (unknown/unknown) are ignored" two_platform_digests

new_case
RM_PLATFORMS="linux/amd64 linux/arm64/v8"
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
expect "requested linux/arm64/v8, published linux/arm64: the same platform, named as requested" 0 \
	.mode reuse '[.binaries[].asset] | join(" ")' "example-linux-amd64 example-linux-arm64-v8" \
	'.images[0].platform_digests | keys | join(" ")' "linux/amd64 linux/arm64/v8"

new_case
tag_on_head
publish_image "$image" example "linux/x86_64 linux/aarch64"
expect "published x86_64 and aarch64 are amd64 and arm64" 0 .mode reuse "$sources" "linux/amd64=image linux/arm64=image"

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64 linux/arm64/v8"
expect "published linux/arm64 and linux/arm64/v8 both: ambiguous, stop" 1 .reason image-duplicate-platform

new_case
RM_PLATFORMS="linux/amd64 linux/arm/v7"
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm"
expect "requested linux/arm/v7, published linux/arm: the same platform" 0 \
	.mode reuse '[.binaries[].asset] | join(" ")' "example-linux-amd64 example-linux-arm-v7"

new_case
RM_PLATFORMS="linux/amd64 linux/arm/v7"
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm/v6"
expect "requested linux/arm/v7, published only linux/arm/v6: still missing" 1 .reason image-missing-platform

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
publish_asset example-linux-amd64
publish_asset other-file "?"
expect "a release with an unexpected asset: stop" 1 .reason unexpected-asset

new_case
tag_on_head
echo "HTTP 502: Bad Gateway" >"$FIX/release.err"
expect "the release cannot be read: stop" 1 .reason lookup-failed

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
rm "$FIX/fs/$(_key "$(digest_of "manifest $image:v1.2.0 linux/arm64")")/usr/local/bin/example"
expect "the binary is not where the image should hold it: stop" 1 .reason image-binary-missing

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
touch "$FIX/cp-symlink"
expect "the binary in the image is a symlink: stop, never follow it onto the runner" 1 .reason image-binary-symlink

# --- Published releases and their pointers -----------------------------------------------------

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
publish_asset example-linux-amd64
publish_asset example-linux-arm64
publish_checksums
release published
echo v1.2.0 >"$FIX/latest-release"
cp "$FIX/registry/$(_key "$image:v1.2.0").json" "$FIX/registry/$(_key "$image:latest").json"
expect "a published release whose pointers agree: reuse, no warning" 0 \
	.mode reuse .release.state published .pointers.move true '.warnings | length' 0

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
publish_asset example-linux-amd64
publish_asset example-linux-arm64
publish_checksums
release published
echo v1.1.0 >"$FIX/latest-release"
jq -n --arg d "$(digest_of old)" '{digest: $d, manifests: []}' >"$FIX/registry/$(_key "$image:latest").json"
expect "a published release whose pointers disagree: reuse, warn, and move them" 0 \
	.mode reuse .pointers.move true '.warnings | length' 2

new_case
tag_on_head
add_remote_tag v1.3.0
publish_image "$image" example "linux/amd64 linux/arm64"
publish_asset example-linux-amd64
publish_asset example-linux-arm64
publish_checksums
release published
echo v1.3.0 >"$FIX/latest-release"
expect "a published release no longer the highest: reuse, pointers left alone" 0 \
	.mode reuse .pointers.move false .pointers.highest_tag v1.3.0 '.warnings | length' 0

# --- Gates and dry runs ------------------------------------------------------------------------

new_case
RM_REQUIRED_RESULTS="success failure"
expect "an audit failure: stop before anything, the tag push included" 1 .reason required-job-failed .build false
expect_true "an audit failure looks nothing up" test ! -s "$STUB_LOG"

new_case
RM_REQUIRED_RESULTS="success success"
expect "every required job succeeded: fresh" 0 .mode fresh

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
RM_DRY_RUN=true
expect "a dry run rehearses the build even when the mode is reuse" 0 .mode reuse .build true .dry_run true

# --- Repository shapes -------------------------------------------------------------------------

new_case
RM_IMAGE=""
tag_on_head
expect "binaries only, tag on HEAD, nothing published: publish" 0 \
	.mode publish '.images | length' 0 "$sources" "linux/amd64=rebuild linux/arm64=rebuild"

new_case
RM_IMAGE=""
tag_on_head
publish_asset example-linux-amd64
publish_asset example-linux-arm64
expect "binaries only, tag on HEAD, every asset published: reuse" 0 \
	.mode reuse .build false "$sources" "linux/amd64=asset linux/arm64=asset"
no_docker_calls() {
	! grep -q '^docker ' "$STUB_LOG"
}
expect_true "binaries only never calls docker" no_docker_calls

new_case
export RM_TAG_REGEX='^release/v[0-9]+\.[0-9]+\.[0-9]+$'
RM_TAG=release/v1.2.0
RM_IMAGE_TAG=v1.2.0
printf '%s\trefs/tags/release/v1.10.0\n' "$other_sha" >"$FIX/remote-tags"
expect "a tag regex allowing / still finds the highest tag" 0 \
	.mode fresh .pointers.highest_tag release/v1.10.0 .pointers.move false

new_case
RM_BINARIES=""
expect "image only, nothing published (herdquay): fresh" 0 \
	.mode fresh '.binaries | length' 0 .checksums.action none "$actions" "$image=build"

new_case
RM_BINARIES=""
tag_on_head
publish_image "$image" "" "linux/amd64 linux/arm64"
expect "image only, published (herdquay): reuse" 0 .mode reuse .build false "$actions" "$image=reuse"

new_case
RM_BINARIES=""
tag_on_head
release draft
publish_asset example-linux-amd64
expect "image only, a release with a binary asset: stop" 1 .reason unexpected-asset

new_case
RM_IMAGE=""
RM_BINARIES="controller agent"
RM_IMAGES=$'ghcr.io/leinardi/runhold-controller controller\nghcr.io/leinardi/runhold-agent agent\nghcr.io/leinardi/runhold-agent-compose agent'
tag_on_head
publish_image ghcr.io/leinardi/runhold-controller controller "linux/amd64 linux/arm64"
publish_image ghcr.io/leinardi/runhold-agent-compose agent "linux/amd64 linux/arm64"
expect "several images (runhold): the missing image is built from the agent in agent-compose" 0 \
	.mode publish "$actions" "ghcr.io/leinardi/runhold-controller=reuse ghcr.io/leinardi/runhold-agent=build ghcr.io/leinardi/runhold-agent-compose=reuse" \
	"$sources" "linux/amd64=image linux/arm64=image linux/amd64=image linux/arm64=image" \
	'[.binaries[] | select(.binary == "agent") | .image] | unique | join(" ")' ghcr.io/leinardi/runhold-agent-compose \
	"$uploads" "controller-linux-amd64 controller-linux-arm64 agent-linux-amd64 agent-linux-arm64"

new_case
RM_IMAGE=""
RM_BINARIES="controller agent"
RM_IMAGES=$'ghcr.io/leinardi/runhold-controller controller\nghcr.io/leinardi/runhold-agent agent\nghcr.io/leinardi/runhold-agent-compose agent'
tag_on_head
publish_image ghcr.io/leinardi/runhold-agent agent "linux/amd64 linux/arm64"
publish_image ghcr.io/leinardi/runhold-agent-compose agent "linux/amd64 linux/arm64"
set_image_binary ghcr.io/leinardi/runhold-agent-compose linux/arm64 /usr/local/bin/agent "another agent"
expect "several images holding one binary with different bytes: stop" 1 .reason image-binaries-differ

new_case
RM_IMAGE_TAG=1.2.0
RM_IMAGE_BINARY_PATHS="example=/example"
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64" ""
expect "a bare X.Y.Z image tag and a binary at /example (bitgauge)" 0 \
	.mode reuse .image_tag 1.2.0 "$sources" "linux/amd64=image linux/arm64=image"
expect_true "the image is looked up by its own tag" grep -qF "docker buildx imagetools inspect $image:1.2.0 " "$STUB_LOG"
expect_true "the binary is read from its own path" grep -qF ":/example $RM_OUT_DIR/extract/0/example-linux-amd64" "$STUB_LOG"

new_case
RM_PLATFORMS="linux/amd64 linux/arm/v7"
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm/v7"
expect "a platform with a variant is matched and named with it" 0 \
	.mode reuse '[.binaries[].asset] | join(" ")' "example-linux-amd64 example-linux-arm-v7"

new_case
tag_on_head
publish_image "$image" example "linux/amd64 linux/arm64"
run
expect_true "the step outputs carry the decision" grep -qxF "mode=reuse" "$GITHUB_OUTPUT"
# upload_output prints the value of the multi-line upload-files output.
upload_output() {
	awk '/^upload-files<</ {f = 1; next} f && /^EOF_/ {exit} f' "$GITHUB_OUTPUT"
}
expect_true "the upload files are a multi-line output" \
	grep -qxF "$RM_OUT_DIR/assets/example-linux-arm64" <(upload_output)
expect_true "the plan file is an output" grep -qxF "plan-file=$RM_OUT_DIR/plan.json" "$GITHUB_OUTPUT"
expect_true "the verification pins the signer workflow, the ref and the commit" grep -qF \
	"gh attestation verify oci://$image@$(image_digest "$image") --repo $repo --signer-workflow $signer --source-ref refs/heads/main --source-digest $head_sha" "$STUB_LOG"
expect_true "the signature is checked against the signer identity" grep -qF \
	"cosign verify --certificate-identity $identity --certificate-oidc-issuer https://token.actions.githubusercontent.com $image@" "$STUB_LOG"

# --- Inputs ------------------------------------------------------------------------------------

invalid() {
	local name=$1
	shift
	new_case
	local assignment
	for assignment in "$@"; do
		export "${assignment?}"
	done
	run
	if [ "$status" -eq 2 ] && [ ! -s "$STUB_LOG" ] && grep -q '::error::' "$work/stderr"; then
		echo "ok - invalid input: $name"
	else
		echo "not ok - invalid input: $name: exit $status, stderr [$(cat "$work/stderr")]"
		failures=$((failures + 1))
	fi
}

invalid "a short head sha" RM_HEAD_SHA=1234
invalid "a tag that is not a release tag" RM_TAG=v1.2.0-rc.1
invalid "a repo without owner" RM_REPO=example
invalid "a source ref that is not a full ref" RM_SOURCE_REF=main
invalid "a signer workflow outside .github/workflows" RM_SIGNER_WORKFLOW=leinardi/example/release.yaml
invalid "no platforms" RM_PLATFORMS=""
invalid "a malformed platform" RM_PLATFORMS="amd64"
invalid "a platform listed twice" RM_PLATFORMS="linux/amd64,linux/amd64"
invalid "a platform listed twice in two spellings" RM_PLATFORMS="linux/arm64,linux/arm64/v8"
invalid "image and images both set" RM_IMAGES="ghcr.io/leinardi/other example"
invalid "an image with a tag" RM_IMAGE=ghcr.io/leinardi/example:latest
invalid "nothing to release" RM_IMAGE="" RM_BINARIES=""
invalid "an image holding an unknown binary" RM_IMAGE="" RM_IMAGES="ghcr.io/leinardi/example other"
invalid "an asset pattern that names two binaries alike" RM_BINARIES="a b" RM_ASSET_PATTERN="x-{os}-{arch}"
invalid "a relative image binary path" RM_IMAGE_BINARY_PATHS="example=bin/example"
invalid "a malformed toolchain line" RM_EXPECTED_TOOLCHAINS="Rust 1.90.0"
invalid "a dry run that is not a boolean" RM_DRY_RUN=yes

if [ "$failures" -ne 0 ]; then
	echo "$failures case(s) failed" >&2
	exit 1
fi
echo "all cases passed"
