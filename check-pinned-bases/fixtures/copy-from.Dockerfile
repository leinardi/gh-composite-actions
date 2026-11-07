# Images pulled by COPY --from and RUN --mount from=, next to stage references that are fine.
FROM docker.io/library/alpine:3.23@sha256:d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4 AS build
COPY --from=docker.io/library/busybox:1.37 /bin/busybox /busybox
COPY --from=ghcr.io/example/tool@sha256:d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4 /tool /tool
COPY --chown=0:0 --from=later /x /x
RUN --mount=type=bind,from=docker.io/library/golang:1.26,source=/usr/local/go,target=/go \
	--mount=type=cache,target=/root/.cache \
	/go/bin/go version
COPY --from=0 /x /y

FROM docker.io/library/alpine:3.23@sha256:d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4 AS later
COPY --from=build /busybox /busybox
COPY --from=1 /x /x
COPY --from=7 /x /x
