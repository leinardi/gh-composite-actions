# ARGs the check cannot resolve: each is an error at its FROM, never a guess.
ARG NO_DEFAULT
ARG FROM_UNDECLARED=${NOWHERE}/alpine:3.23
FROM ${NO_DEFAULT} AS a
FROM $UNDECLARED AS b
FROM docker.io/library/alpine:3.23@sha256:d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4 AS c
ARG IN_STAGE=alpine:3.23
FROM ${IN_STAGE}
FROM ${TARGETPLATFORM}
FROM ${FROM_UNDECLARED}
FROM ${NO_DEFAULT%:*}
