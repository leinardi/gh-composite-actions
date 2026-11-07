# setup-zigbuild

Installs [zig](https://ziglang.org) and [cargo-zigbuild](https://github.com/rust-cross/cargo-zigbuild),
the cross-compiler and linker behind static musl release binaries. Both archives are downloaded
over HTTPS only, checked with `sha256sum --check --strict`, unpacked under `$RUNNER_TEMP` and
added to `PATH`. No `sudo`. Linux X64 runners only (the binaries it builds may target any
platform).

Pass the same versions the caller's image build stage pins, so release binaries and image
binaries are built with the same zig and cargo-zigbuild.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `zig-version` | no | `0.17.0` | zig release, `X.Y.Z`. |
| `zig-sha256` | no | `1cbe9df9…2026` | SHA-256 of `zig-x86_64-linux-<version>.tar.xz`, from `https://ziglang.org/download/index.json`. Override together with `zig-version`. |
| `cargo-zigbuild-version` | no | `0.24.0` | cargo-zigbuild release, `X.Y.Z`. |
| `cargo-zigbuild-sha256` | no | `52be2cb8…b96f` | SHA-256 of `cargo-zigbuild-x86_64-unknown-linux-musl.tar.xz`, from the release asset's `.sha256`. Override together with `cargo-zigbuild-version`. |

## Outputs

| Name | Description |
| --- | --- |
| `zig-path` | The directory holding `zig`, as added to `PATH`. |
| `cargo-zigbuild-path` | The directory holding `cargo-zigbuild`, as added to `PATH`. |

## Permissions

None beyond the default: the downloads are public release assets.

## Usage

```yaml
- uses: leinardi/gh-composite-actions/setup-zigbuild@<sha> # v1.0.0
- run: cargo zigbuild --release --target aarch64-unknown-linux-musl
```
