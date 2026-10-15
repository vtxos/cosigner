# cosigner

The vtxos cosigner: a `wasm32-wasip2` component that [enclave-runtime](https://github.com/vtxos/runtime) serves inside a Nitro enclave, one instance per tenant, with no listener of its own. Each release publishes one `cosigner.wasm`, and everything that runs the cosigner downloads that file instead of building it.

| Path | Contents |
|---|---|
| [`cosigner`](cosigner/) | The component. [`src/session.rs`](cosigner/src/session.rs) routes each gRPC stream to its ceremony, [`src/escrow.rs`](cosigner/src/escrow.rs) holds everything that knows a service exists, and the seal ([`src/store.rs`](cosigner/src/store.rs)) is the only durable state. [`wit/`](cosigner/wit/) is its world and the runtime WIT it vendors |
| [`crates/threshold`](crates/threshold/) | FROST/DKG cryptography |
| [`crates/ark`](crates/ark/) | The Ark protocol, and arkd's protos |
| [`crates/enclave-client`](crates/enclave-client/) | Attestation verification, for clients and services |
| [`crates/escrow-service`](crates/escrow-service/) | A settlement service's side of an escrow |
| [`protocol/protos`](protocol/protos/) | The cosigner's wire, which is the source of truth for every client |

The wallet uses the crates and protos through a submodule. Services depend on them as git dependencies pinned to a release tag.

## Build and test

```bash
make test             # every crate, on the host: Rust (rust-toolchain.toml) and protoc
make cosigner-wasm    # the component, built by Nix: result/bin/cosigner.wasm, and its sha256
```

`cosigner.wasm` is what the enclave measures into PCR16, so it is built reproducibly. [`flake.nix`](flake.nix) builds it with everything that reaches its bytes pinned by `flake.lock`: Rust (from `rust-toolchain.toml`), protoc for the build scripts, and the clang that compiles libsecp256k1's C to WebAssembly. The build directory is mapped out of the binary, so a sandboxed Nix and one without a sandbox produce the same file.

`cosigner/wit/deps` vendors the runtime's capability interfaces (tasks, notify, streams, telemetry). This repository runs nothing against the runtime: the cosigner's whole flow, and so its fit with the runtime, is proven by the wallet's e2e, on the dev enclave image infra builds from a release.

## Releases

Pushing a `v*` tag publishes `cosigner.wasm`, built by Nix, and `SHA256SUMS`. To check a release, rebuild it from its tag and compare: `nix build github:vtxos/cosigner/<tag>#cosigner && sha256sum result/bin/cosigner.wasm`. A tag with a hyphen, such as `v0.2.0-rc.1`, is a prerelease.

The component is published bare. A deployment writes its own settings into it (`guest-env.py`, or `--guest-env` in a dev enclave), and the enclave then measures the configured file into PCR16. The release sha256 therefore identifies the code, not any one deployment's PCR16.

Consumers pin a release by name and sha256:
- the dev enclave image that infra builds for the wallet's e2e
- the production release
