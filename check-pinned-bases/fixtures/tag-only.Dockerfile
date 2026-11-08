# --tag-only dhi.io: the dhi.io images may be pinned by tag; every other image still needs a digest.
FROM --platform=$BUILDPLATFORM dhi.io/rust:1.98.1-debian13-dev AS build
FROM dhi.io/static:20250419@sha256:e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5 AS pinned
FROM dhi.io/static AS untagged
FROM dhi.io/static:latest AS latest
FROM dhi.io.example.com/static:1 AS lookalike
FROM docker.io/library/alpine:3.23 AS other
FROM dhi.io/static:20250419
