# External bases with no digest, a short digest, and a digest-only reference that passes.
FROM alpine:3.23 AS tagged
FROM ubuntu
FROM ghcr.io/example/tool@sha256:abc123
FROM ghcr.io/example/tool:1.0@sha256:d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4
FROM ghcr.io/example/tool@sha256:d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4
FROM tagged
