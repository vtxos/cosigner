# The cosigner, a wasm32-wasip2 component that the runtime serves, and the crates it shares with
# the wallet and with the services that pair with it.
#
#   make test            every crate's tests, on the host
#   make wasi-sdk        the C toolchain cosigner-wasm needs, under ~/wasi-sdk
#   make cosigner-wasm   the component, at cosigner/target/wasm32-wasip2/release/cosigner.wasm
#
# A release is a tag: pushing `vX.Y.Z` publishes cosigner.wasm (.github/workflows/release.yml).

.PHONY: test wasi-sdk cosigner-wasm

test:
	cd cosigner && cargo test
	cd crates/threshold && cargo test --features std
	cd crates/enclave-client && cargo test
	cd crates/escrow-service && cargo test

wasi-sdk:
	@./scripts/wasi-sdk.sh

# Needs wasi-sdk to compile secp256k1-sys, the one C library left — see the script.
cosigner-wasm:
	@./scripts/build-cosigner-wasm.sh
