# The cosigner, a wasm32-wasip2 component that enclave-runtime serves, and the crates it shares
# with the wallet and with the services that pair with it.
#
#   make test            every crate's tests, on the host
#   make cosigner-wasm   the component, checked against the runtime's WIT first
#   make enclave-bundle  the runtime pinned in enclave-bundle.lock, for wit-drift and wasi-sdk
#
# A release is a tag: pushing `vX.Y.Z` publishes cosigner.wasm (.github/workflows/release.yml).

.PHONY: test cosigner-wasm enclave-bundle wasi-sdk wit-drift

# The runtime the WIT is checked against and wasi-sdk comes from: the pinned bundle once fetched,
# else a checkout at ~/enclave-runtime.
ENCLAVE_RUNTIME ?= $(if $(wildcard $(CURDIR)/.enclave/image.env),$(CURDIR)/.enclave,$(HOME)/enclave-runtime)

test:
	cd cosigner && cargo test
	cd crates/threshold && cargo test --features std
	cd crates/enclave-client && cargo test
	cd crates/escrow-service && cargo test

# Needs wasi-sdk to compile secp256k1-sys, the one C library left — see the script.
cosigner-wasm: wit-drift
	@./scripts/build-cosigner-wasm.sh

BUNDLE_URL ?= https://github.com/vtxos/enclave-runtime/releases/download

enclave-bundle: .enclave/image.env

.enclave/image.env: enclave-bundle.lock
	@. ./enclave-bundle.lock; \
	[ -n "$$RELEASE" ] || { echo "enclave-bundle.lock names no release yet" >&2; exit 1; }; \
	t=$$(mktemp); \
	echo "fetching $$RELEASE"; \
	curl -fL --retry 3 --retry-all-errors -o $$t "$(BUNDLE_URL)/$$RELEASE/$$RELEASE.tar.gz" && \
	echo "$$SHA256  $$t" | sha256sum -c - && \
	rm -rf .enclave && mkdir .enclave && tar xzf $$t -C .enclave --strip-components=1 && rm $$t && \
	echo "unpacked into .enclave ($$(. .enclave/image.env; echo runtime $$ENCLAVE_RUNTIME_REV))"

# wasi-sdk, pinned by the runtime: its scripts/wasi-sdk.sh ships in a bundle too.
wasi-sdk:
	@$(ENCLAVE_RUNTIME)/scripts/wasi-sdk.sh

# The vendored WIT under cosigner/wit/deps must equal the runtime's, byte for byte: both sides
# still compile when they differ, and the mismatch surfaces as a trap at runtime.
wit-drift:
	@ENCLAVE_RUNTIME=$(ENCLAVE_RUNTIME) ./scripts/wit-drift.sh
