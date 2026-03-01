fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Client-facing wallet API
    tonic_build::compile_protos("proto/mpc_wallet.proto")?;
    Ok(())
}
