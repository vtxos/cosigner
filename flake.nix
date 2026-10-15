{
  description = "The vtxos cosigner, built reproducibly: cosigner.wasm";

  # cosigner.wasm is what PCR16 measures, so anyone must be able to rebuild a release and get the
  # same bytes. One lock pins everything that goes into them: Rust (rust-toolchain.toml), protoc for
  # the build scripts, and the clang that compiles secp256k1-sys's C to wasm. The sandbox fixes the
  # paths that end up in the binary.

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
  };

  outputs = { self, nixpkgs, rust-overlay, crane }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ (import rust-overlay) ];
      };
      inherit (pkgs) lib;

      craneLib = (crane.mkLib pkgs).overrideToolchain
        (p: p.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml);

      # Unwrapped: the wrapper's flags are the host's. secp256k1-sys brings its own wasm headers,
      # so a clang with a wasm backend is all it needs.
      clang = pkgs.llvmPackages.clang-unwrapped;

      args = {
        pname = "cosigner";
        version = "0.1.0";
        # The cosigner's path dependencies live beside it, so the source is the whole repository:
        # Rust, the protos its build scripts compile, and the WIT its bindings come from.
        src = lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            lib.hasSuffix ".proto" path || lib.hasSuffix ".wit" path
            || craneLib.filterCargoSources path type;
          name = "cosigner-source";
        };
        cargoToml = ./cosigner/Cargo.toml;
        cargoLock = ./cosigner/Cargo.lock;
        cargoExtraArgs = "--locked --bin cosigner";
        CARGO_BUILD_TARGET = "wasm32-wasip2";
        strictDeps = true;
        doCheck = false;
        nativeBuildInputs = [ pkgs.protobuf ];
        PROTOC = "${pkgs.protobuf}/bin/protoc";
        CC_wasm32_wasip2 = "${clang}/bin/clang";
        AR_wasm32_wasip2 = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ar";
        # The crate is in a subdirectory, with its path dependencies beside it: build from there.
        # The dependency-only build's stand-in source carries the lock only at its root, so it goes
        # beside the manifest too.
        postUnpack = ''
          cd $sourceRoot/cosigner
          sourceRoot="."
        '';
        extraDummyScript = "cp ${./cosigner/Cargo.lock} $out/cosigner/Cargo.lock";
        # Where the build ran must not reach the binary: a sandboxed Nix builds in /build, one
        # without a sandbox in a temporary directory, and the path dependencies' sources and the C
        # compiler's __FILE__ would carry whichever it was.
        preBuild = ''
          export RUSTFLAGS="''${RUSTFLAGS:-} --remap-path-prefix=$NIX_BUILD_TOP=/build"
          export CFLAGS_wasm32_wasip2="-ffile-prefix-map=$NIX_BUILD_TOP=/build"
        '';
      };

      cosigner = craneLib.buildPackage (args // {
        cargoArtifacts = craneLib.buildDepsOnly args;
      });
    in
    {
      packages.${system} = {
        inherit cosigner;
        default = cosigner;
      };
    };
}
