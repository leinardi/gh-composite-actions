# AGENTS.md

## What this is

Composite GitHub Actions shared by the `leinardi/*` repositories (`leinardi/gh-composite-actions/<action>@<sha>`):
tool setup (`setup-svu`, `setup-shellcheck`, `setup-cargo-deny`, `setup-zigbuild`), release
versioning (`release-version`), the CI-green release gate (`require-ci-green`), the same-run job
gate (`require-job-success`), release recovery (`release-mode`, `binary-attestation-status`,
`toolchain-record`, `toolchain-recover`), image checks (`trivy-gate`, `check-pinned-bases`) and
cache pruning (`prune-caches`). Callers trust these with their releases: a gate that passes when it
should not is the worst bug this repository can have.

**Not here:** the pre-commit and reviewdog actions belong in
[gha-pre-commit-reviewdog-actions](https://github.com/leinardi/gha-pre-commit-reviewdog-actions),
and reusable workflows in [gh-reusable-workflows](https://github.com/leinardi/gh-reusable-workflows).
A new action that runs a pre-commit hook or posts reviewdog comments goes there, not here.

## Common commands

```bash
make check               # pre-commit on all files: the local gate, as CI's pre-commit-all
make test                # every action's script tests (*/*.test.sh), as CI's script-tests
make check-stage         # pre-commit on the staged files only
make pre-commit-install  # installs the pre-commit and commit-msg hooks
make mk-common-update    # refresh the shared .mk snippets from leinardi/make-common@v1
make help                # lists every target
```

Before calling a change done, run `make check` and `make test`. In CI, `ci-result` is the one
required check: it needs `pre-commit-all`, `conventional-commits`, `script-tests` and every
`self-test-*` job (`ci.yaml`); the reviewdog jobs only annotate pull requests.

The Makefile pulls shared snippets from `leinardi/make-common@v1` into `.mk/` on first run. Project
targets live in the local `.mk/*.mk` files listed in `MK_LOCAL_FILES` (`test.mk`), never as recipes
in the Makefile.

## Layout

| Path | What lives there |
| --- | --- |
| `<action>/action.yaml` | one composite action per top-level directory; its name is the action's path in `uses:` |
| `<action>/<name>.sh` (and `.py`) | the action's logic, called as `"${GITHUB_ACTION_PATH}/<name>.sh"`, inputs through `env:` |
| `<action>/<name>.test.sh` | plain-bash table tests for that script: stubs on a temp `PATH`, no network, no token |
| `<action>/README.md` | the action's contract: inputs, outputs, permissions, an example |
| `check-pinned-bases/fixtures/` | Dockerfile fixtures, including copies of the callers' real Dockerfiles |
| `scripts/run-tests.sh` | `make test`: runs every tracked `*/*.test.sh` |
| `.github/workflows/ci.yaml` | `pre-commit-all`, `script-tests`, one `self-test-*` job per action (`uses: ./<action>` on a real runner), `ci-result` |
| `.github/workflows/release.yaml` | the **Release** workflow: dispatched, or on a Dependabot merge through gh-reusable-workflows' `dependabot-release`; publishes with `simple-tag-and-release`, which also moves `v1` |
| `.github/workflows/pre-commit-warmup.yaml` | refreshes the pre-commit cache on `main` and prunes the older entries |
| `scripts/check-license-headers.sh` | the MIT license-header check |
| `.agents/skills/` | project skills; `.claude/skills` is a symlink to it |

### Generated or vendored: never hand-edit

- `.mk/help.mk`, `.mk/pre-commit.mk`, `.mk/password.mk` and `.mk/.mk-common-version`: fetched from
  `leinardi/make-common`, refreshed with `make mk-common-update`.
- `scripts/bootstrap-mk-common.sh`: also from make-common; a change is ported upstream.

## Conventions

- Pin every action and reusable workflow by full commit SHA, with the version in a trailing comment
  (`@<sha> # vX.Y.Z`), inside `action.yaml` files too: Dependabot scans `/` (`chore(deps)`) and `/*`
  (`fix(deps)`, since callers run those pins).
- Give every workflow a top-level `permissions: contents: read`, and widen it only on the job that
  needs more. `persist-credentials: false` on every checkout.
- Pass `${{ }}` expressions into `run:` scripts through `env:`, never inline them in the script.
- Name workflow and action files `.yaml`. Name action inputs and outputs in kebab-case; the token
  input is `github-token`.
- Fail closed: every API error, unexpected state, unparsable response or missing tool is a non-zero
  exit with an `::error::` message that says what was found and that nothing was changed.
- Validate inputs before any API call or download; an input passed as an empty string does not
  silently become a default.
- Downloads: `curl -fsSL --proto '=https' --retry 3`, `sha256sum --check --strict`, installed under
  `RUNNER_TEMP` onto `GITHUB_PATH`, then a version check that must match the pin. No `sudo`, no
  `go install`.
- An input, output or permission change is a contract change for every caller: update the
  action's README and the root README table, and use `feat`/`fix` (`!` when a caller breaks).
- Every script change gets a test case that fails without it, and a `self-test-*` step when it
  changes what a real runner does.
- `README.md` is the user-facing contract: keep it in step with what the repository does.

## License headers

The repository is MIT-licensed (`LICENSE`). `scripts/check-license-headers.sh`, run by the
`check-license-headers` pre-commit hook, fails on any tracked shell or Python script, the Makefile
or a repo-local `.mk` fragment whose first lines lack the MIT notice with Roberto Leinardi's
copyright. Never YAML, JSON or Markdown. The make-common files are exempt: they carry make-common's
own header. A new file takes the year it was first committed.

## Markdown

Prose wraps at 100 columns (markdownlint `line-length`, `.editorconfig`); tables, code blocks and
headings may run longer. Never wrap inside a table, a code block or a link target.

## Commit messages

All commits MUST be Conventional Commits 1.0.0 **with a scope**:
`<type>(<scope>)[!]: <description>`, optional blank-line body and footers. Enforced by the
`conventional-pre-commit` `commit-msg` hook (`--force-scope`, installed by
`make pre-commit-install`) and by the `conventional-commits` CI job. Types: `feat`, `fix`, `docs`,
`test`, `refactor`, `perf`, `build`, `ci`, `chore`, `style`, `revert`. Breaking changes use `!`
before `:` or a `BREAKING CHANGE:` footer. Release notes are not built from these messages:
`gh release create --generate-notes` lists the merged pull requests by title. Examples:
`fix(ci): pin actionlint by SHA`, `feat(release): attach the build to the release`.

A release with no explicit version is derived by `svu` from the commits since the last `vX.Y.Z` tag,
so a wrong type ships a wrong version:

| Release | Commit | Example |
| --- | --- | --- |
| major | any type with `!` before the colon, or a `BREAKING CHANGE:` footer | `feat(api)!: drop the v1 endpoints` |
| minor | `feat` | `feat(release): attach the build to the release` |
| patch | `fix` | `fix(ci): pin actionlint by SHA` |
| none | everything else: `perf`, `refactor`, `build`, `ci`, `chore`, `docs`, `style`, `test`, `revert` | `docs(readme): fix a link` |

The highest bump among the commits wins; with only "none" commits since the last tag, a release
with no version fails with "nothing to bump".

**Pick the type by whether the change should ship, not by what kind of change it is.** Anything
that changes what the project ships and that users should receive is `fix` (or `feat`), even when
it is a performance improvement, a refactor or a revert. Use `perf`, `refactor`, `style` and
`revert` only when the commit is deliberately not meant to trigger a release on its own. A `revert`
of a shipped `feat` or `fix` is itself a `fix`. `svu` matches `feat`/`fix` anywhere in the subject
(e.g. `prefix:` counts as `fix:`), so avoid a word ending in `feat` or `fix` directly before a colon
in other subjects. PRs land as merge commits, so every commit counts, not just the PR title. See
[`CONTRIBUTING.md`](CONTRIBUTING.md#releasing).

## Validation matrix

Run before considering an edit done. `make check` applies to every row.

| You edited | Run |
| --- | --- |
| `<action>/*.sh`, `<action>/*.py` | `make test`; break the change on purpose and see a case fail |
| `<action>/action.yaml` | `make test`; the action's `self-test-*` job in `ci.yaml` covers the change; its README and the root README table match |
| `.github/workflows/**`, `.github/dependabot.yml` | `pre-commit run actionlint --all-files`; reason through each trigger the workflow has (pull request, push, dispatch, schedule) |
| `.pre-commit-config.yaml` | `make check`; a hook that needs a system tool also gets it in `ci.yaml`'s `pre-commit-all` |
| `Makefile`, the `.mk/*.mk` files in `MK_LOCAL_FILES` | `make check` (checkmake), `make help` |
| `scripts/bootstrap-mk-common.sh`, the make-common `.mk` files | never by hand: port the change to make-common, then `make mk-common-update` and `make help` |
| `scripts/check-license-headers.sh` | `make check`; see a file without the header fail it |
| `**/*.md`, `.agents/skills/**` | `make check` (markdownlint); prose wrapped at 100 columns |

## Project skills

Skills live in `.agents/skills/` (symlinked as `.claude/skills`). Load `adversarial-review` for any
review request ("review my diff", "is this ready to merge").
