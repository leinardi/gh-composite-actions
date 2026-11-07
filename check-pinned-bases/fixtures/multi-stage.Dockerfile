# syntax=docker/dockerfile:1.7@sha256:d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4
# escape=\

# Internal stages by name (any case) and by index, scratch, platform flags and verified downloads:
# every image here is either pinned or not external, so the file passes.
ARG GO_IMAGE=golang:1.26-alpine@sha256:d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4

from --platform=$BUILDPLATFORM ${GO_IMAGE} as Builder
RUN apt-get update \
	# A comment inside a continued instruction is not part of it: curl
	&& apt-get install -y --no-install-recommends ca-certificates curl wget \
	&& echo "curl is installed, not run"
RUN --mount=type=cache,target=/root/.cache \
	go build -o /out/app ./...
RUN <<EOT
set -eu
# curl in a comment line is not a download
curl -fsSL -o /tmp/tool.tar.gz https://example.com/tool.tar.gz
echo "d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4  /tmp/tool.tar.gz" | sha256sum --check --strict -
EOT
ADD --checksum=sha256:d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4 https://example.com/data.tar.gz /data.tar.gz

FROM BUILDER AS Test
RUN --mount=type=bind,from=builder,source=/out,target=/mnt true

FROM --platform=${TARGETPLATFORM} scratch AS Runtime
COPY --from=builder /out/app /app
COPY --from=0 /out/app /app0
COPY --link --from=TEST /out/app /app-test

FROM ScRaTcH
Copy --from=runtime /app /app
