#![cfg_attr(
    all(not(debug_assertions), target_os = "windows"),
    windows_subsystem = "windows"
)]

use camellia_remote::*;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Some(pos) = args
        .iter()
        .position(|a| a == "--support-bundle" || a == "support-bundle")
    {
        let output_arg = args.get(pos + 1).cloned().filter(|a| !a.starts_with("--"));
        let mut opts = diagnostics::ClientSupportBundleOptions::default();
        if let Some(out) = output_arg {
            opts.output_path = Some(std::path::PathBuf::from(out));
        }
        let target_dir = std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."));
        match diagnostics::export_client_support_bundle(&target_dir, &opts) {
            Ok(bundle_path) => {
                println!(
                    "Successfully exported support bundle: {}",
                    bundle_path.display()
                );
                return;
            }
            Err(e) => {
                eprintln!("Failed to export support bundle: {:#}", e);
                std::process::exit(1);
            }
        }
    }

    if !common::global_init() {
        eprintln!("Global initialization failed.");
        return;
    }
    common::test_rendezvous_server();
    common::test_nat_type();
    common::global_clean();
}
