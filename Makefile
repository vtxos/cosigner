# The cosigner, a wasm32-wasip2 component that the runtime serves, and the crates it shares with
# the wallet and with the services that pair with it.
#
#   make test            every crate's tests, on the host
#   make cosigner-wasm   the component, built by Nix exactly as a release is: result/bin/cosigner.wasm
#
# A release is a tag: pushing `vX.Y.Z` publishes cosigner.wasm (.github/workflows/release.yml).

.PHONY: test cosigner-wasm

test:
	cd cosigner && cargo test
	cd crates/threshold && cargo test --features std
	cd crates/enclave-client && cargo test
	cd crates/escrow-service && cargo test

# flake.lock pins everything that reaches the bytes, so this builds what a release ships.
cosigner-wasm:
	nix build .#cosigner --out-link result
	@sha256sum result/bin/cosigner.wasm
