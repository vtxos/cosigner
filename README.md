# cosigner

The vtxos cosigner: a `wasm32-wasip2` component that [enclave-runtime](https://github.com/vtxos/enclave-runtime) serves inside a Nitro enclave, one instance per tenant, with no listener of its own. Each release publishes one `cosigner.wasm`, and everything that runs the cosigner downloads that file instead of building it.

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

You need Rust (the toolchain is pinned in `rust-toolchain.toml`) and `protoc`.

```bash
make test                               # every crate, on the host
make enclave-bundle wasi-sdk            # the pinned runtime, and the wasi-sdk it builds with
make cosigner-wasm                      # cosigner/target/wasm32-wasip2/release/cosigner.wasm
```

`make cosigner-wasm` first checks that the WIT vendored in `cosigner/wit/deps` is byte-identical to the WIT of the runtime pinned in [`enclave-bundle.lock`](enclave-bundle.lock).

To serve a local build in a dev enclave:

```bash
~/enclave-runtime/deploy/qemu-nitro/dev-enclave.sh --guest cosigner/target/wasm32-wasip2/release/cosigner.wasm
```

## Releases

Pushing a `v*` tag publishes `cosigner.wasm` and `SHA256SUMS`. A tag with a hyphen, such as `v0.2.0-rc.1`, is a prerelease.

The component is published bare. A deployment writes its own settings into it (`guest-env.py`, or `--guest-env` in a dev enclave), and the enclave then measures the configured file into PCR16. The release sha256 therefore identifies the code, not any one deployment's PCR16.

Consumers pin a release by name and sha256:
- the dev enclave image that infra builds for the wallet's e2e
- the production release
