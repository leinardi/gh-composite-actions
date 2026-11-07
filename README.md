# gh-composite-actions

Composite GitHub Actions shared by the `leinardi/*` repositories: tool setup, release versioning,
the CI-green release gate, image checks, toolchain records and cache pruning. Each action lives in
its own top-level directory, with its own README, and is tested here before any repository uses it.

The pre-commit and reviewdog actions are not here: they live in
[gha-pre-commit-reviewdog-actions](https://github.com/leinardi/gha-pre-commit-reviewdog-actions).
The reusable workflows that call these actions live in
[gh-reusable-workflows](https://github.com/leinardi/gh-reusable-workflows).

## Actions

| Action | What it does | Permissions |
| --- | --- | --- |
| [`setup-svu`](setup-svu/README.md) | Installs svu from its release archive, checked against a pinned SHA-256 (Linux X64 and ARM64) | none |
| [`release-version`](release-version/README.md) | Resolves and validates the next release version and tag: explicit or derived by svu, strict `<prefix>X.Y.Z`, higher than every release, optional floor | `contents: read` |
| [`require-ci-green`](require-ci-green/README.md) | Waits until `ci.yaml`'s `ci-result` job passed on one exact commit, for an accepted event and branch, in the newest attempt; fails closed otherwise | `actions: read` |
| [`release-mode`](release-mode/README.md) | Decides whether a release run is fresh, publishes, reuses or stops, per binary and platform, after verifying everything already published | `contents: read` (+ `packages: read`, `attestations: read` on private repositories) |
| [`binary-attestation-status`](binary-attestation-status/README.md) | Lists the release files that still need a build-provenance attestation from the signer workflow | `contents: read` |
| [`trivy-gate`](trivy-gate/README.md) | Scans an image with a pinned Trivy and fails on fixable findings, or only on findings a baseline image does not have | `contents: read` |
| [`check-pinned-bases`](check-pinned-bases/README.md) | Fails on an external Dockerfile image not pinned by digest, or a download with no checksum verification | `contents: read` |
| [`toolchain-record`](toolchain-record/README.md) | Prints the Rust, Go and Node versions a release is built with, as tag-annotation lines | none |
| [`toolchain-recover`](toolchain-recover/README.md) | Switches a release recovery to the toolchains a tag's annotation records, and fails closed unless they are active | `contents: read` |
| [`setup-shellcheck`](setup-shellcheck/README.md) | Installs a pinned ShellCheck onto PATH, for actionlint and droast | none |
| [`setup-cargo-deny`](setup-cargo-deny/README.md) | Installs a pinned cargo-deny onto PATH | none |
| [`setup-zigbuild`](setup-zigbuild/README.md) | Installs pinned zig and cargo-zigbuild onto PATH, for static musl release binaries | none |
| [`prune-caches`](prune-caches/README.md) | Deletes the older Actions cache entries of one ref under one key prefix, keeping the newest | `actions: write` |

## Usage

Pin every action by full commit SHA, with the release in a trailing comment:

```yaml
- uses: leinardi/gh-composite-actions/require-ci-green@<sha> # v1.0.0
```

The `v1` tag moves to the highest `v1.x.y` release, for reading; callers still pin the SHA, and
Dependabot's `github-actions` ecosystem keeps it current.

## Conventions

- Every action fails closed: an API error, an unexpected state or an unparsable response is a
  failed step with a message, never a silent pass.
- Inputs reach scripts only through `env:`, and are validated before any API call or download.
- Downloads are `https`-only, retried, verified against a pinned SHA-256 (toolchain-recover: the
  digests go.dev and nodejs.org publish for the recorded release) and installed under
  `RUNNER_TEMP` onto `PATH`: no `sudo`, no `go install`.
- The logic lives in a script next to `action.yaml`, with a plain-bash table test that stubs every
  external command (`make test`). CI also runs each action the way a caller does
  (`uses: ./<action>`) on a real runner.

## Development

```bash
make check               # every pre-commit hook on every file
make test                # every action's script tests
make pre-commit-install  # installs the pre-commit and commit-msg hooks
```

See [AGENTS.md](AGENTS.md) for the layout and the rules a change follows, and
[CONTRIBUTING.md](CONTRIBUTING.md) for commits and releases.

## License

[MIT](LICENSE)
