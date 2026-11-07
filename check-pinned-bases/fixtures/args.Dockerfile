# Global ARG defaults, one built from another, a default substitution, and the platform flag.
ARG REGISTRY=docker.io
ARG BASE=${REGISTRY}/library/alpine:3.23
ARG TOOLS_IMAGE

FROM --platform=$BUILDPLATFORM $BASE AS base
FROM ${TOOLS_IMAGE:-docker.io/library/busybox:1.37@sha256:d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4} AS tools
ARG STAGE=base
COPY --from=${STAGE} /etc/os-release /os-release
