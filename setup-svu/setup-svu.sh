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
# Installs svu (github.com/caarlos0/svu) from its release archive, checked against a pinned
# SHA-256, into $RUNNER_TEMP and onto $GITHUB_PATH. Nothing is installed system-wide, so no sudo.
#
# Inputs (environment):
#   SVU_VERSION  X.Y.Z (a leading v is accepted). Default: PINNED_VERSION below.
#   SVU_SHA256   the SHA-256 of svu_<version>_linux_<arch>.tar.gz, from the release's
#                checksums.txt. Empty: the pinned one, which exists only for PINNED_VERSION; any
#                other version must come with its own.
#   RUNNER_OS, RUNNER_ARCH, RUNNER_TEMP, GITHUB_PATH: set by the runner. Linux X64 and ARM64 only.
#
# Outputs (to $GITHUB_OUTPUT when set):
#   path  the directory holding the svu binary, as added to $GITHUB_PATH
#
# Any failure (download, checksum, a binary that reports another version) exits non-zero before
# anything is added to $GITHUB_PATH.

set -euo pipefail

# Pinned by hand as one unit: the version and the SHA-256 of each archive, from the release's
# checksums.txt. Dependabot does not track a release download, so bump all three together.
PINNED_VERSION=3.4.1
PINNED_SHA256_AMD64=7ee8c91998c15109130638dc661a912d5f426e2f8642f6f6c04e6502be920770
PINNED_SHA256_ARM64=801f310be2f91df86868a2de1f61fefaf06e3eb773431be7dde9765ecde4d21c

fail() {
	echo "::error title=setup-svu::$*" >&2
	exit 1
}

VERSION="${SVU_VERSION:-$PINNED_VERSION}"
VERSION="${VERSION#v}"
SHA256="${SVU_SHA256:-}"

if ! [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
	fail "version must be X.Y.Z or vX.Y.Z (got '${SVU_VERSION:-}'). Nothing was installed."
fi
if [[ "${RUNNER_OS:-}" != "Linux" ]]; then
	fail "svu is installed on Linux runners only (RUNNER_OS is '${RUNNER_OS:-unset}'). Nothing was installed."
fi
case "${RUNNER_ARCH:-}" in
X64) ARCH=amd64 PINNED_SHA256=$PINNED_SHA256_AMD64 ;;
ARM64) ARCH=arm64 PINNED_SHA256=$PINNED_SHA256_ARM64 ;;
*) fail "svu is installed on X64 and ARM64 runners only (RUNNER_ARCH is '${RUNNER_ARCH:-unset}'). Nothing was installed." ;;
esac

# A checksum belongs to one archive: the pinned one cannot vouch for another version, so a
# version override without its own checksum fails rather than downloading something unchecked.
if [[ -z "$SHA256" ]]; then
	if [[ "$VERSION" != "$PINNED_VERSION" ]]; then
		fail "version $VERSION is not the pinned $PINNED_VERSION, so pass its sha256 too (svu_${VERSION}_linux_${ARCH}.tar.gz in the release's checksums.txt). Nothing was installed."
	fi
	SHA256=$PINNED_SHA256
fi
if ! [[ "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
	fail "sha256 must be 64 lowercase hex characters (got '$SHA256'). Nothing was installed."
fi
if [[ -z "${RUNNER_TEMP:-}" ]] || [[ -z "${GITHUB_PATH:-}" ]]; then
	fail "RUNNER_TEMP and GITHUB_PATH must be set (they are, on a GitHub runner). Nothing was installed."
fi

ARCHIVE="svu_${VERSION}_linux_${ARCH}.tar.gz"
URL="https://github.com/caarlos0/svu/releases/download/v${VERSION}/${ARCHIVE}"
# The archive is fetched next to, not into, the directory that goes on PATH: only the binary is
# put there.
DOWNLOAD=$(mktemp -d "${RUNNER_TEMP}/setup-svu-download.XXXXXX")
trap 'rm -rf "$DOWNLOAD"' EXIT
BIN_DIR="${RUNNER_TEMP}/setup-svu/${VERSION}-${ARCH}"

echo "Downloading $URL"
curl -fsSL --proto '=https' --retry 3 -o "$DOWNLOAD/$ARCHIVE" "$URL"
if ! echo "$SHA256  $DOWNLOAD/$ARCHIVE" | sha256sum --check --strict --quiet -; then
	fail "$ARCHIVE does not match the SHA-256 $SHA256. Nothing was installed."
fi
rm -rf "$BIN_DIR"
mkdir -p "$BIN_DIR"
tar -xzf "$DOWNLOAD/$ARCHIVE" -C "$BIN_DIR" svu

# The archive is the one checked, but its binary must also be the version asked for: a wrong
# pin (a checksum of another version's archive) fails here instead of running the wrong svu.
if ! REPORTED=$("$BIN_DIR/svu" --version); then
	fail "$BIN_DIR/svu --version failed. Nothing was added to PATH."
fi
echo "$REPORTED"
if ! grep -qE "^GitVersion:[[:space:]]+v?${VERSION//./\\.}\$" <<<"$REPORTED"; then
	fail "$BIN_DIR/svu reports a version other than $VERSION. Nothing was added to PATH."
fi

echo "$BIN_DIR" >>"$GITHUB_PATH"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	echo "path=$BIN_DIR" >>"$GITHUB_OUTPUT"
fi
echo "Installed svu $VERSION ($ARCH) at $BIN_DIR."
