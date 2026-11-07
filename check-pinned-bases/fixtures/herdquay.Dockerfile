# syntax=docker/dockerfile:1.27.1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
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

# Ubuntu 26.04 LTS: the owner's desktop release, close to GitHub's Ubuntu runners, and the distro
# Playwright supports best. Pinned by tag, not digest: the official image is rebuilt with every
# security update, and each rebuild is one we want.
ARG BASE_IMAGE=ubuntu:26.04

# -------------------------------------------------------------------------------------------------
# fetch: downloads and verifies every artifact that does not come from apt. Nothing from this
# stage reaches the final image except the verified binaries.
# -------------------------------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS fetch

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates curl gnupg jq unzip xz-utils \
	&& rm -rf /var/lib/apt/lists/*

# Herdr publishes neither a checksum file nor a signature: the digest is the release asset's, from
# gh api repos/herdrdev/herdr/releases/tags/v<version> (docs/updating.md).
ARG HERDR_VERSION=0.9.5
ARG HERDR_SHA256=14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d
RUN curl -fsSL -o /tmp/herdr \
	"https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-x86_64" \
	&& echo "${HERDR_SHA256}  /tmp/herdr" | sha256sum --check --strict - \
	&& install -D -m 0755 /tmp/herdr /usr/local/bin/herdr

# Go, one toolchain for every project: their go.mod lines are minimums (1.26.x), and
# GOTOOLCHAIN=auto fetches a newer one for a module that asks for it. Digest from go.dev/dl JSON.
ARG GO_VERSION=1.26.10
ARG GO_SHA256=ccfe7ae822d2c2f41f4fe7c956199967a4dac22d0ee0d2b2bfdb440aab3b20c5
RUN curl -fsSL -o /tmp/go.tar.gz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
	&& echo "${GO_SHA256}  /tmp/go.tar.gz" | sha256sum --check --strict - \
	&& tar -C /usr/local -xzf /tmp/go.tar.gz \
	&& rm /tmp/go.tar.gz

# Node.js, the 24 line every Node project here builds with. Digest from the release's SHASUMS256.txt.
ARG NODE_VERSION=24.22.1
ARG NODE_SHA256=6c172a9ab6718f7b801fb5a7bd486af2ee5e32758086a04b84fcce2aa77095e6
RUN curl -fsSL -o /tmp/node.tar.xz \
	"https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
	&& echo "${NODE_SHA256}  /tmp/node.tar.xz" | sha256sum --check --strict - \
	&& install -d /opt/node \
	&& tar -C /opt/node --strip-components=1 -xJf /tmp/node.tar.xz \
	&& rm /tmp/node.tar.xz

# Release binaries, each checked against its GitHub release asset digest
# (gh api repos/<owner>/<repo>/releases/tags/<tag>).
ARG CARGO_DENY_VERSION=0.20.2
ARG CARGO_DENY_SHA256=9f12ed4c49936e09b48bf862b595cde2fe64fcbd9d74dfacac6131ca824c8d5f
ARG CHEZMOI_VERSION=2.73.3
ARG CHEZMOI_SHA256=56db674bb755c6655d67df3dec3e6727631d1291f5fc799d3f1aded6d0e56472
ARG GH_VERSION=2.103.0
ARG GH_SHA256=fdd768eb70f6409f80fcfa9f3a1c0adf0fc98d827ab3ce0bed2ac22762c5d786
ARG GOLANGCI_LINT_VERSION=2.14.0
ARG GOLANGCI_LINT_SHA256=ab90aeb7b066f92a33415b638a50fe5344bbb75a0d32ad30cc248d88f81032ab
ARG GORELEASER_VERSION=2.18.1
ARG GORELEASER_SHA256=0c6122af0ad8fd65638889bf7d3757148b2f80eeff9f079682f0655df66ec8e8
# Dockerfile Roast for the projects' tests that run it directly (their pre-commit hooks build their
# own) and ShellCheck, which its required ShellCheck bridge runs from PATH.
ARG DROAST_VERSION=1.7.0
ARG DROAST_SHA256=cadb963a040ba2e68641af764f794e5d4fb3371bb9b92255fa5027060b08ea6e
ARG SHELLCHECK_VERSION=0.11.0
ARG SHELLCHECK_SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
# OpenTofu and its linters and scanners, at the versions the OpenTofu projects' CI pins.
ARG OPENTOFU_VERSION=1.13.2
ARG OPENTOFU_SHA256=ac05d9952662c7db28dd57e93f0a68018837bfdf9342384ec0987977c16a9645
ARG TERRAFORM_DOCS_VERSION=0.22.0
ARG TERRAFORM_DOCS_SHA256=8ec66616777c66f3e622af4f2853e8ae399f38908ad4b262c9c526dd42501369
ARG TFLINT_VERSION=0.65.0
ARG TFLINT_SHA256=d4c545ed2e29d6338604b586f34f544f380f70f243aa72f7b484713835eaec61
ARG TRIVY_VERSION=0.76.1
ARG TRIVY_SHA256=c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0
# uv, for Python tools and the Pythons they need, installed into the home volume (`uv tool install`).
ARG UV_VERSION=0.13.5
ARG UV_SHA256=f68d291c75783122dad58ab77def0e13f3233f358731db5d6d7e8715603b928f
ARG YQ_VERSION=4.54.1
ARG YQ_SHA256=8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f
RUN fetch() { curl -fsSL -o "$1" "$2" && echo "$3  $1" | sha256sum --check --strict -; } \
	&& fetch /tmp/gh.tar.gz \
		"https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
		"${GH_SHA256}" \
	&& tar -xzf /tmp/gh.tar.gz -C /tmp \
	&& install -D -m 0755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /opt/gh/bin/gh \
	&& fetch /tmp/cargo-deny.tar.gz \
		"https://github.com/EmbarkStudios/cargo-deny/releases/download/${CARGO_DENY_VERSION}/cargo-deny-${CARGO_DENY_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
		"${CARGO_DENY_SHA256}" \
	&& tar -xzf /tmp/cargo-deny.tar.gz -C /tmp \
	&& install -D -m 0755 "/tmp/cargo-deny-${CARGO_DENY_VERSION}-x86_64-unknown-linux-musl/cargo-deny" \
		/usr/local/bin/cargo-deny \
	&& fetch /tmp/golangci-lint.tar.gz \
		"https://github.com/golangci/golangci-lint/releases/download/v${GOLANGCI_LINT_VERSION}/golangci-lint-${GOLANGCI_LINT_VERSION}-linux-amd64.tar.gz" \
		"${GOLANGCI_LINT_SHA256}" \
	&& tar -xzf /tmp/golangci-lint.tar.gz -C /tmp \
	&& install -D -m 0755 "/tmp/golangci-lint-${GOLANGCI_LINT_VERSION}-linux-amd64/golangci-lint" \
		/usr/local/bin/golangci-lint \
	&& fetch /tmp/goreleaser.tar.gz \
		"https://github.com/goreleaser/goreleaser/releases/download/v${GORELEASER_VERSION}/goreleaser_Linux_x86_64.tar.gz" \
		"${GORELEASER_SHA256}" \
	&& tar -xzf /tmp/goreleaser.tar.gz -C /tmp goreleaser \
	&& install -D -m 0755 /tmp/goreleaser /usr/local/bin/goreleaser \
	&& fetch /usr/local/bin/droast \
		"https://github.com/immanuwell/dockerfile-roast/releases/download/${DROAST_VERSION}/droast-linux-x86_64" \
		"${DROAST_SHA256}" \
	&& fetch /tmp/shellcheck.tar.xz \
		"https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
		"${SHELLCHECK_SHA256}" \
	&& tar -xJf /tmp/shellcheck.tar.xz -C /tmp \
	&& install -D -m 0755 "/tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck \
	&& fetch /tmp/tofu.tar.gz \
		"https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION}_linux_amd64.tar.gz" \
		"${OPENTOFU_SHA256}" \
	&& tar -xzf /tmp/tofu.tar.gz -C /tmp tofu \
	&& install -m 0755 /tmp/tofu /usr/local/bin/tofu \
	&& fetch /tmp/terraform-docs.tar.gz \
		"https://github.com/terraform-docs/terraform-docs/releases/download/v${TERRAFORM_DOCS_VERSION}/terraform-docs-v${TERRAFORM_DOCS_VERSION}-linux-amd64.tar.gz" \
		"${TERRAFORM_DOCS_SHA256}" \
	&& tar -xzf /tmp/terraform-docs.tar.gz -C /tmp terraform-docs \
	&& install -m 0755 /tmp/terraform-docs /usr/local/bin/terraform-docs \
	&& fetch /tmp/tflint.zip \
		"https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_amd64.zip" \
		"${TFLINT_SHA256}" \
	&& unzip -q /tmp/tflint.zip tflint -d /tmp \
	&& install -m 0755 /tmp/tflint /usr/local/bin/tflint \
	&& fetch /tmp/trivy.tar.gz \
		"https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
		"${TRIVY_SHA256}" \
	&& tar -xzf /tmp/trivy.tar.gz -C /tmp trivy \
	&& install -m 0755 /tmp/trivy /usr/local/bin/trivy \
	&& fetch /usr/local/bin/yq \
		"https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
		"${YQ_SHA256}" \
	&& fetch /usr/local/bin/chezmoi \
		"https://github.com/twpayne/chezmoi/releases/download/v${CHEZMOI_VERSION}/chezmoi-linux-amd64" \
		"${CHEZMOI_SHA256}" \
	&& fetch /tmp/uv.tar.gz \
		"https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" \
		"${UV_SHA256}" \
	&& tar -xzf /tmp/uv.tar.gz -C /tmp \
	&& install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uv /tmp/uv-x86_64-unknown-linux-gnu/uvx /usr/local/bin/ \
	&& chmod 0755 /usr/local/bin/droast /usr/local/bin/yq /usr/local/bin/chezmoi \
	&& rm -rf /tmp/*

# rustup's installer, which herdquay-rust-install runs at start to put rustup and a stable toolchain
# into the home volume. Digest from the .sha256 file next to the archived release.
ARG RUSTUP_VERSION=1.29.2
ARG RUSTUP_SHA256=5be191e8c70a5007074254cb74d78dbfdd25cd5a61c27de7b8e5410122ec24f4
RUN curl -fsSL -o /usr/local/bin/rustup-init \
	"https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/x86_64-unknown-linux-gnu/rustup-init" \
	&& echo "${RUSTUP_SHA256}  /usr/local/bin/rustup-init" | sha256sum --check --strict - \
	&& chmod 0755 /usr/local/bin/rustup-init

# opencode 2 ships only on npm, as one package per platform (what https://opencode.ai/v2/install
# downloads). Checked against the registry's SHA-512 integrity for that version:
# npm view @opencode/cli-linux-x64@<version> dist.integrity (docs/updating.md).
ARG OPENCODE_VERSION=2.1.4
ARG OPENCODE_INTEGRITY=sha512-o8EJ0ZsT4dzDKN+0mpG2EKbNGzJyp+F1++Av28UReRVfiEv+N34eZEnN/unkiMoerKHad6W6Ii7k4ukTnPNmNQ==
RUN curl -fsSL -o /tmp/opencode.tgz \
	"https://registry.npmjs.org/@opencode/cli-linux-x64/-/cli-linux-x64-${OPENCODE_VERSION}.tgz" \
	&& echo "$(printf %s "${OPENCODE_INTEGRITY#sha512-}" | base64 -d | od -An -v -tx1 | tr -d ' \n')  /tmp/opencode.tgz" \
		| sha512sum --check --strict - \
	&& tar -xzf /tmp/opencode.tgz -C /tmp package/bin/opencode \
	&& install -D -m 0755 /tmp/package/bin/opencode /usr/local/bin/opencode \
	&& rm -rf /tmp/opencode.tgz /tmp/package

# Docker's apt signing key, asserted to be the one Docker documents (primary key fingerprint).
ARG DOCKER_SIGNER_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
RUN curl -fsSL -o /tmp/docker.asc https://download.docker.com/linux/ubuntu/gpg \
	&& test "$(gpg --show-keys --with-colons /tmp/docker.asc | awk -F: '$1 == "fpr" { print $10; exit }')" \
		= "${DOCKER_SIGNER_FINGERPRINT}" \
	&& install -D -m 0644 /tmp/docker.asc /etc/apt/keyrings/docker.asc

# -------------------------------------------------------------------------------------------------
# final
# -------------------------------------------------------------------------------------------------
FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG DEBIAN_FRONTEND=noninteractive

# The unprivileged user everything runs as. 568:568 is the homelab's apps user, so the image works
# on its datasets unchanged; override at build time for another host.
ARG HERDQUAY_UID=568
ARG HERDQUAY_GID=568

# The Docker CLI and its plugins, client only: there is no daemon in or for this container.
ARG DOCKER_CLI_VERSION=5:29.9.2-1~ubuntu.26.04~resolute
ARG DOCKER_BUILDX_VERSION=0.38.1-1~ubuntu.26.04~resolute
ARG DOCKER_COMPOSE_VERSION=5.6.1-1~ubuntu.26.04~resolute

COPY --from=fetch /etc/apt/keyrings/docker.asc /etc/apt/keyrings/docker.asc

# Ubuntu packages: the shell and runner-style CLI tools, the build toolchain, GNOME extension tooling
# (gjs for headless tests, glib-compile-schemas, gettext's translation tools), Python for pre-commit
# and for Herdr's Claude integration hook (it reports each conversation's session id, so it can be
# resumed after a restart), and sshd. openssh-server's postinst generates host keys; they are
# deleted, because the real host key is generated once at run time on the persistent home volume.
# The base has no CA certificates, which apt needs for Docker's HTTPS repository: they come first.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates \
	&& echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu resolute stable" \
		>/etc/apt/sources.list.d/docker.list \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends \
		acl \
		bash-completion \
		bc \
		build-essential \
		ca-certificates \
		curl \
		bind9-dnsutils \
		"docker-buildx-plugin=${DOCKER_BUILDX_VERSION}" \
		"docker-ce-cli=${DOCKER_CLI_VERSION}" \
		"docker-compose-plugin=${DOCKER_COMPOSE_VERSION}" \
		fd-find \
		file \
		gawk \
		gettext \
		git \
		git-lfs \
		gjs \
		gnupg \
		htop \
		iproute2 \
		iputils-ping \
		jq \
		less \
		libglib2.0-bin \
		lsof \
		nano \
		ncurses-term \
		netcat-openbsd \
		openssh-client \
		openssh-server \
		openssl \
		patch \
		pkg-config \
		procps \
		python3 \
		python3-venv \
		ripgrep \
		rsync \
		sqlite3 \
		strace \
		tig \
		tini \
		tree \
		unzip \
		vim \
		wget \
		xz-utils \
		zip \
		zstd \
	&& rm -rf /var/lib/apt/lists/* \
	&& rm -f /etc/ssh/ssh_host_* \
	&& ln -s /usr/bin/fdfind /usr/local/bin/fd

COPY --from=fetch /usr/local/go /usr/local/go
COPY --from=fetch /opt/node /opt/node
COPY --from=fetch /opt/gh /opt/gh
COPY --from=fetch \
	/usr/local/bin/cargo-deny \
	/usr/local/bin/chezmoi \
	/usr/local/bin/herdr \
	/usr/local/bin/golangci-lint \
	/usr/local/bin/goreleaser \
	/usr/local/bin/droast \
	/usr/local/bin/shellcheck \
	/usr/local/bin/terraform-docs \
	/usr/local/bin/tflint \
	/usr/local/bin/tofu \
	/usr/local/bin/trivy \
	/usr/local/bin/uv \
	/usr/local/bin/uvx \
	/usr/local/bin/yq \
	/usr/local/bin/

# Toolchain commands on the default PATH too, which non-login SSH commands use.
RUN ln -s /usr/local/go/bin/go /usr/local/go/bin/gofmt /usr/local/bin/ \
	&& ln -s /opt/node/bin/node /opt/node/bin/npm /opt/node/bin/npx /opt/node/bin/corepack /usr/local/bin/

# Playwright's system libraries for Chromium, Firefox and WebKit, at the version the projects pin:
# they need apt, so they cannot be installed at run time as the unprivileged user. The browsers
# themselves are per project, in ~/.cache/ms-playwright (npx playwright install).
ARG PLAYWRIGHT_VERSION=1.64.0
RUN apt-get update \
	&& npx -y "playwright@${PLAYWRIGHT_VERSION}" install-deps chromium firefox webkit \
	&& rm -rf /var/lib/apt/lists/* /root/.npm /root/.cache

# pre-commit, the hook runner every project uses, in its own virtualenv.
ARG PRE_COMMIT_VERSION=4.6.2
RUN python3 -m venv /opt/pre-commit \
	&& /opt/pre-commit/bin/pip install --no-cache-dir "pre-commit==${PRE_COMMIT_VERSION}" \
	&& ln -s /opt/pre-commit/bin/pre-commit /usr/local/bin/pre-commit

# The image's stock `ubuntu` user (1000) goes: HerdQuay has exactly one account. Its password is
# `*`, matching none, rather than useradd's locked `!`, which sshd would refuse even for a key. sshd
# only accepts keys anyway, and the account has no sudo (the sudo package is not even installed).
RUN userdel --remove ubuntu \
	&& groupadd --gid "${HERDQUAY_GID}" herdquay \
	&& useradd --uid "${HERDQUAY_UID}" --gid "${HERDQUAY_GID}" --comment HerdQuay \
		--home-dir /home/herdquay --shell /bin/bash --no-create-home herdquay \
	&& usermod --password '*' herdquay \
	&& install -d -m 0755 -o "${HERDQUAY_UID}" -g "${HERDQUAY_GID}" /home/herdquay \
	&& install -d -m 0755 -o "${HERDQUAY_UID}" -g "${HERDQUAY_GID}" /home/herdquay/workspace

COPY container/etc/ /etc/
COPY container/bin/ /usr/local/bin/
COPY container/share/ /usr/local/share/
# Claude Code is not in the image: herdquay-claude-install puts the pinned release into the home
# volume at start (its license grants no right to redistribute it), verified against this
# key, whose fingerprint is pinned below.
COPY container/keys/claude-code.asc /usr/local/share/herdquay/claude-code.asc
# npm's global prefix in the user's home, so `npm install -g` works without root.
COPY container/npmrc /opt/node/etc/npmrc
# The build context keeps the checkout's modes, which may be group-writable: ssh refuses such a
# config file, and nothing in the image should be writable by anyone but root.
# Only these paths: a chmod copies a file into a new layer, and /usr/local/bin also holds the big
# binaries from the fetch stage.
RUN chmod -R go-w /etc/ssh /etc/gitconfig /etc/profile.d/herdquay.sh /usr/local/share/herdquay \
		/opt/node/etc/npmrc /usr/local/bin/gh /usr/local/bin/herdquay /usr/local/bin/herdquay-*

# Nothing in the image may raise a process's privileges: Docker Swarm ignores no-new-privileges,
# and a setuid root binary (su, mount, passwd) would still run as UID 0 there, without
# capabilities but able to write root-owned files. HerdQuay never uses one. The smoke test checks
# that none is left.
RUN find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec chmod ug-s {} + \
	&& getcap -r / 2>/dev/null | awk '{print $1}' | xargs -r -n1 setcap -r

# opencode outside the PATH: the entrypoint copies it into the home volume, where it updates
# itself. After the chmod above, which would copy it into one more layer.
COPY --from=fetch /usr/local/bin/opencode /usr/local/share/herdquay/opencode
COPY --from=fetch /usr/local/bin/rustup-init /usr/local/share/herdquay/rustup-init

# The minimum Rust version herdquay-rust-install holds the default toolchain to, in a file for the
# same reason as the Claude Code pin below. rustup itself, and the toolchains above it, update in the
# home volume (rustup update).
ARG RUST_MINIMUM=1.99.1
RUN printf 'HERDQUAY_RUST_MINIMUM=%s\n' "${RUST_MINIMUM}" >/usr/local/share/herdquay/rust-release

# The Claude Code release to install and the fingerprint its manifest must be signed with, in a
# file rather than ENV so that SSH sessions (herdquay doctor) read the same pin.
ARG CLAUDE_VERSION=2.1.308
ARG CLAUDE_SIGNER_FINGERPRINT=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
RUN printf 'HERDQUAY_CLAUDE_VERSION=%s\nHERDQUAY_CLAUDE_SIGNER_FINGERPRINT=%s\n' \
		"${CLAUDE_VERSION}" "${CLAUDE_SIGNER_FINGERPRINT}" >/usr/local/share/herdquay/claude-release

ARG VERSION=dev
ARG REVISION=unknown
ARG CREATED=unknown
LABEL org.opencontainers.image.title="HerdQuay" \
	org.opencontainers.image.description="Persistent, remotely accessible Herdr + Claude Code development environment" \
	org.opencontainers.image.source="https://github.com/leinardi/herdquay" \
	org.opencontainers.image.version="${VERSION}" \
	org.opencontainers.image.revision="${REVISION}" \
	org.opencontainers.image.created="${CREATED}" \
	org.opencontainers.image.licenses="MIT"

ENV HOME=/home/herdquay \
	USER=herdquay \
	SHELL=/bin/bash \
	LANG=C.UTF-8 \
	PATH=/home/herdquay/.local/bin:/home/herdquay/.opencode/bin:/home/herdquay/.cargo/bin:/home/herdquay/go/bin:/usr/local/go/bin:/opt/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	GOTOOLCHAIN=auto

USER ${HERDQUAY_UID}:${HERDQUAY_GID}
WORKDIR /home/herdquay

EXPOSE 2222

HEALTHCHECK --interval=30s --timeout=10s --start-period=6m --retries=3 \
	CMD ["/usr/local/bin/herdquay-healthcheck"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/herdquay-entrypoint"]
