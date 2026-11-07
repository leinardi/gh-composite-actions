# check-pinned-bases

Fails when a Dockerfile pulls an external image that is not pinned by digest, or downloads a file
without verifying its checksum. A tag can be moved to other content at any time; a digest cannot,
so every image the build pulls from outside the file must be named `<image>@sha256:<64 hex>`
(`<image>:<tag>@sha256:…` keeps the tag readable for Dependabot and humans).

The first check covers every external image the build pulls:

- the base of each `FROM`, after resolving ARGs (`FROM ${BASE_IMAGE}`, `FROM $BASE`,
  `${NAME:-default}`) from the global `ARG` defaults before the first `FROM`, overridden by the
  `build-args` input. An ARG it cannot resolve that way (no default and no build arg, declared
  only inside a stage, a platform ARG such as `TARGETPLATFORM`, or a substitution it does not
  understand) is an error at that line, never a guess. Flags such as `--platform=$BUILDPLATFORM`
  are not part of the image and are ignored;
- the image of `COPY --from=<image>` and `RUN --mount=…,from=<image>`;
- the BuildKit frontend of a `# syntax=` parser directive.

`scratch` and the earlier stages of the same file (by `AS` name, case-insensitively, or by index)
are not external and pass.

The second check is a heuristic for downloads: a `curl` or `wget` command, or an `ADD` of a URL,
must be verified in the same instruction. The `RUN` script (line continuations and heredocs
included) is split into simple commands, with quotes, comments and `$( )` understood, so a
downloader counts only where it runs: as the command, behind wrappers (`sudo`, `env`,
`timeout 60`, `nice`, `xargs`, `busybox`, `exec`, `command`, …) or a leading backslash, or inside
a script given to `sh -c`/`bash -c` or `eval`. `apt-get install curl` and `echo "curl"` are not
downloads. Each download must be **followed**, later in the same `RUN`, by `sha256sum` or
`sha512sum` in check mode (`-c`/`--check`, as in
`echo "<hash>  <file>" | sha256sum --check --strict -`) or `shasum -a 256|512 -c`, run as a
command (a mention inside a string does not count) on a path whose failure fails the
instruction. Docker runs a `RUN` with `/bin/sh -c`, which has no errexit, so in
`curl …; sha256sum --check …; echo done` a mismatch is ignored. The check counts when it is
chained with `&&` to the end of the `RUN`, is its last command, is followed by `|| exit 1`, or
runs under errexit: a `set -e` earlier in the same `RUN` that is certain to run in that shell
(first in its `&&`/`||` list, not negated, backgrounded or in a pipeline, at the top level or in
a `{ }` group that is), with nothing after it that may turn errexit off or make it unknown (a
`set` that may not run, `set` inside `if`/`for`/`case` or a function, `.`/`source`, `eval`,
`shopt -o`), or the stage's
`SHELL` with `-e` (inherited by `FROM <stage>`), or `sh -ec`. It does not count when negated,
backgrounded, after a `||`, inside `if`/`while`/`for`/`case`, or a non-final pipeline element
without `pipefail`. Inside `( )`, `{ }` and `sh -c` the same rule applies within, and the group
must itself be propagated; a function's check counts at its calls, when every call is propagated.
When unsure, the download is reported. sha512 counts because some publishers (the npm registry)
give no sha256. A signature
or fingerprint check is not a checksum and does not count; neither is a `sha256sum` that only
prints the hash.

A `COPY` or `ADD` heredoc is a file the build may run, so its body is checked the same way. An
`ADD` source is expanded with the stage's ARGs first: a URL in an ARG needs
`--checksum=sha256:<hash>` too, and a source that cannot be resolved is reported, since it may be
one.

The parser handles line continuations (and the `escape` directive), comment lines inside them,
heredocs, mixed-case keywords, `ONBUILD`, and exec-form `RUN`/`ADD`. Each finding is printed as
`FILE:LINE: message` and as an error annotation on that line.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `dockerfiles` | no | `Dockerfile` | The Dockerfiles, one path or bash glob (`**` included) per line, relative to the working directory. Every line must match at least one file; an empty value is an error, not the default. |
| `build-args` | no | `""` | Build args, one `NAME=VALUE` per line, as `docker build --build-arg`. They override the matching global `ARG` defaults. |

## Outputs

None. The step fails (exit 1) on any finding, and with exit 2 when a file is missing, cannot be
parsed, or a build arg is not `NAME=VALUE`.

## Permissions

`contents: read`, for the checkout. It needs `python3` on the runner (any GitHub-hosted runner
has it) and no network.

## Usage

```yaml
- uses: actions/checkout@<sha> # vX.Y.Z
  with:
    persist-credentials: false
- uses: leinardi/gh-composite-actions/check-pinned-bases@<sha> # v1.0.0
  with:
    dockerfiles: |
      deployments/docker/Dockerfile
      test/**/*.Dockerfile
    build-args: |
      BASE_IMAGE=docker.io/library/ubuntu:26.04@sha256:<digest>
```

Run it locally with `check-pinned-bases/check-pinned-bases.sh [--build-arg NAME=VALUE]... FILE...`.
