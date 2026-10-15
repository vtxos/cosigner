# The cosigner, a wasm32-wasip2 component that the runtime serves, and the crates it shares with
# the wallet and with the services that pair with it.
#
#   make test            every crate's tests, on the host
#   make lint            clippy on the cosigner, warnings denied
#   make cosigner-wasm   the component, built by Nix exactly as a release is: result/bin/cosigner.wasm
#   make test-wasm       that component, run by the fake host (fake-host/) through a wallet's life
#
# A release is a tag: pushing `vX.Y.Z` publishes cosigner.wasm (.github/workflows/release.yml).

.PHONY: test lint cosigner-wasm test-wasm

test:
	cd cosigner && cargo test
	cd crates/threshold && cargo test --features std
	cd crates/ark && cargo test --all-features
	cd crates/enclave-client && cargo test
	cd crates/escrow-service && cargo test

lint:
	cd cosigner && cargo clippy -- -D warnings

# flake.lock pins everything that reaches the bytes, so this builds what a release ships.
cosigner-wasm:
	nix build .#cosigner --out-link result
	@sha256sum result/bin/cosigner.wasm

# The component a release ships, driven as the runtime would: DKG, a signature, the delegate's
# renewal, and the refresh the cosigner then runs by itself against a fake ASP. COSIGNER_WASM picks
# another build.
COSIGNER_WASM ?= $(CURDIR)/result/bin/cosigner.wasm
test-wasm: $(if $(filter $(origin COSIGNER_WASM),file),cosigner-wasm)
	cd fake-host && cargo clippy --all-targets -- -D warnings
	COSIGNER_WASM=$(COSIGNER_WASM) cargo test --manifest-path fake-host/Cargo.toml
