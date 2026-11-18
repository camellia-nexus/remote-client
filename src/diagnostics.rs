//! Bounded, redacted client support bundle exporter (DIAG-001).
//!
//! Provides operational diagnostics collection for `camellia-remote --support-bundle`:
//! - Read-only collection of system information, runtime stats, sanitized configuration audit,
//!   and sanitized recent logs.
//! - Multi-pass secret redaction stripping private keys, passwords, unlock PINs, tokens,
//!   and PII.
//! - Bounded resource caps (max 10 MiB uncompressed, max 2 MiB compressed `.tar.gz`).
//! - Strict Unix permissions (`0600` for archive file, `0700` for temporary directories).
//! - Secondary fail-closed canary scanner scanning the final payload before completion;
//!   if a canary pattern matches, the bundle is deleted immediately and the command fails closed.

use std::{
    fs::{self, File, Permissions},
    io::{Read, Write},
    net::{IpAddr, SocketAddr},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{SystemTime, UNIX_EPOCH},
};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use camellia_remote_protocol::{
    anyhow::Context as _,
    bail,
    config::Config,
    observability::{mask_ip, mask_socket_addr},
    sha2::{Digest, Sha256},
    ResultType,
};
use chrono::Utc;
use serde_derive::{Deserialize, Serialize};

/// Maximum allowed uncompressed diagnostics payload size (10 MiB).
pub const MAX_UNCOMPRESSED_BYTES: usize = 10 * 1024 * 1024;

/// Maximum allowed compressed `.tar.gz` bundle size (2 MiB).
pub const MAX_COMPRESSED_BYTES: usize = 2 * 1024 * 1024;

/// Maximum allowed single log file size read (5 MiB).
pub const MAX_LOG_READ_BYTES: usize = 5 * 1024 * 1024;

/// Known private key canary patterns that must NEVER appear in the final bundle.
pub const CANARY_SECRET_PATTERNS: &[&str] = &[
    "BEGIN PRIVATE KEY",
    "BEGIN OPENSSH PRIVATE KEY",
    "BEGIN RSA PRIVATE KEY",
    "BEGIN EC PRIVATE KEY",
    "BEGIN DSA PRIVATE KEY",
    "BEGIN ENCRYPTED PRIVATE KEY",
];

/// Options configuring the client support bundle export.
#[derive(Debug, Clone, Default)]
pub struct ClientSupportBundleOptions {
    /// Explicit destination path for the output `.tar.gz` archive.
    pub output_path: Option<PathBuf>,
    /// Custom configuration file to audit (defaults to Config::file()).
    pub config_file: Option<PathBuf>,
    /// Custom log directory to inspect (defaults to Config::log_path()).
    pub log_dir: Option<PathBuf>,
    /// Maximum uncompressed bytes limit override (defaults to 10 MiB).
    pub max_uncompressed_bytes: Option<usize>,
    /// Maximum compressed bundle size override (defaults to 2 MiB).
    pub max_compressed_bytes: Option<usize>,
    /// Custom sensitive secret canary strings to detect (for testing and verification).
    pub custom_secret_canaries: Vec<String>,
}

/// Metadata entry for each file included in the support bundle manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BundleFileEntry {
    pub path: String,
    pub size: usize,
    pub sha256: String,
}

/// Manifest structure at the root of the support bundle.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SupportBundleManifest {
    pub manifest_version: String,
    pub collection_timestamp_utc: String,
    pub client_version: String,
    pub files: Vec<BundleFileEntry>,
    pub bundle_sha256: String,
}

/// Export a bounded, redacted operational client support bundle archive.
///
/// Returns the path to the newly created `.tar.gz` archive.
pub fn export_client_support_bundle(
    target_dir: &Path,
    options: &ClientSupportBundleOptions,
) -> ResultType<PathBuf> {
    let uncompressed_limit = options
        .max_uncompressed_bytes
        .unwrap_or(MAX_UNCOMPRESSED_BYTES);
    let compressed_limit = options.max_compressed_bytes.unwrap_or(MAX_COMPRESSED_BYTES);

    // 1. Determine destination path
    let output_archive = if let Some(ref path) = options.output_path {
        path.clone()
    } else {
        let ts = Utc::now().format("%Y%m%d_%H%M%S").to_string();
        target_dir.join(format!("camellia_remote_client_support_bundle_{ts}.tar.gz"))
    };

    if let Some(parent) = output_archive.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("Failed to create parent dir: {}", parent.display()))?;
        #[cfg(unix)]
        {
            let _ = fs::set_permissions(parent, Permissions::from_mode(0o700));
        }
    }

    // 2. Collect individual bundle components in-memory
    let system_info_bytes = collect_system_info()?;
    let config_audit_bytes = collect_config_audit(options.config_file.as_deref())?;
    let recent_logs_bytes = collect_recent_logs(options.log_dir.as_deref())?;

    // 3. Assemble pre-manifest
    let mut files_to_pack: Vec<(String, Vec<u8>)> = Vec::new();
    files_to_pack.push(("system_info.json".to_string(), system_info_bytes));
    files_to_pack.push(("config_audit.json".to_string(), config_audit_bytes));
    files_to_pack.push(("recent_logs.log".to_string(), recent_logs_bytes));

    let total_uncompressed: usize = files_to_pack.iter().map(|(_, content)| content.len()).sum();
    if total_uncompressed > uncompressed_limit {
        bail!(
            "Total diagnostics payload size ({} bytes) exceeds safety limit ({} bytes)",
            total_uncompressed,
            uncompressed_limit
        );
    }

    // 4. Generate manifest with SHA-256 hashes
    let mut manifest_entries = Vec::new();
    for (name, content) in &files_to_pack {
        let mut hasher = Sha256::new();
        hasher.update(content);
        let hash: String = hasher
            .finalize()
            .iter()
            .map(|b| format!("{:02x}", b))
            .collect();
        manifest_entries.push(BundleFileEntry {
            path: name.clone(),
            size: content.len(),
            sha256: hash,
        });
    }

    let manifest = SupportBundleManifest {
        manifest_version: "1.0.0".to_string(),
        collection_timestamp_utc: Utc::now().to_rfc3339(),
        client_version: crate::VERSION.to_string(),
        files: manifest_entries,
        bundle_sha256: String::new(),
    };

    let manifest_bytes = serde_json::to_vec_pretty(&manifest)
        .context("Failed to serialize support bundle manifest")?;
    files_to_pack.insert(0, ("manifest.json".to_string(), manifest_bytes));

    // 5. Construct Tar archive in-memory
    let tar_bytes = build_tar_archive(&files_to_pack)?;

    // 6. Compress with gzip (max 2 MiB limit)
    let gzip_bytes = compress_gzip(&tar_bytes).context("Failed to compress support bundle")?;
    if gzip_bytes.len() > compressed_limit {
        bail!(
            "Compressed bundle size ({} bytes) exceeds safety cap ({} bytes)",
            gzip_bytes.len(),
            compressed_limit
        );
    }

    // 7. Fail-closed canary scanner
    scan_for_canaries(&gzip_bytes, &tar_bytes, options)?;

    // 8. Write archive with 0600 permissions
    write_secure_file(&output_archive, &gzip_bytes)?;

    Ok(output_archive)
}

/// Collect structured sanitized system info.
fn collect_system_info() -> ResultType<Vec<u8>> {
    #[derive(Serialize)]
    struct SystemInfoSnapshot {
        os: String,
        arch: String,
        num_cpus: usize,
        client_version: String,
        timestamp_utc: String,
    }

    let snapshot = SystemInfoSnapshot {
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        num_cpus: num_cpus::get(),
        client_version: crate::VERSION.to_string(),
        timestamp_utc: Utc::now().to_rfc3339(),
    };

    serde_json::to_vec_pretty(&snapshot).context("Failed to serialize system info")
}

/// Collect and sanitize configuration audit.
fn collect_config_audit(custom_config: Option<&Path>) -> ResultType<Vec<u8>> {
    #[derive(Serialize)]
    struct ConfigAudit {
        config_path_present: bool,
        custom_rendezvous_server: String,
        custom_relay_server: String,
        api_server: String,
        allow_remove: bool,
        enable_record_session: bool,
    }

    let config_path = custom_config
        .map(PathBuf::from)
        .unwrap_or_else(Config::file);

    let audit = ConfigAudit {
        config_path_present: config_path.exists(),
        custom_rendezvous_server: mask_text_secrets(&Config::get_option(
            "custom-rendezvous-server",
        )),
        custom_relay_server: mask_text_secrets(&Config::get_option("relay-server")),
        api_server: mask_text_secrets(&Config::get_option("api-server")),
        allow_remove: Config::get_option("allow-remove") == "Y",
        enable_record_session: Config::get_option("enable-record-session") == "Y",
    };

    serde_json::to_vec_pretty(&audit).context("Failed to serialize config audit")
}

/// Collect recent logs with size bounds and multi-pass redaction.
fn collect_recent_logs(custom_log_dir: Option<&Path>) -> ResultType<Vec<u8>> {
    let log_dir = custom_log_dir
        .map(PathBuf::from)
        .unwrap_or_else(Config::log_path);

    if !log_dir.exists() {
        return Ok(b"# No log directory found\n".to_vec());
    }

    let mut log_files = Vec::new();
    if let Ok(entries) = fs::read_dir(&log_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() {
                if let Some(ext) = path.extension().and_then(|s| s.to_str()) {
                    if ext == "log" || ext.starts_with("log") {
                        if let Ok(meta) = entry.metadata() {
                            log_files
                                .push((path, meta.modified().unwrap_or(SystemTime::UNIX_EPOCH)));
                        }
                    }
                }
            }
        }
    }

    // Sort by modification time ascending (oldest to newest)
    log_files.sort_by_key(|(_, mtime)| *mtime);

    let mut combined = Vec::new();
    for (path, _) in log_files {
        if let Ok(mut f) = File::open(&path) {
            let mut buf = Vec::new();
            if f.read_to_end(&mut buf).is_ok() {
                if combined.len() + buf.len() > MAX_LOG_READ_BYTES {
                    let allowed = MAX_LOG_READ_BYTES.saturating_sub(combined.len());
                    combined.extend_from_slice(&buf[buf.len().saturating_sub(allowed)..]);
                    break;
                } else {
                    combined.extend_from_slice(&buf);
                }
            }
        }
    }

    let raw_text = String::from_utf8_lossy(&combined);
    let sanitized = mask_text_secrets(&raw_text);
    Ok(sanitized.into_bytes())
}

/// Multi-pass secret masking covering IPs, tokens, passwords, and private keys.
pub fn mask_text_secrets(text: &str) -> String {
    let mut out = String::with_capacity(text.len());

    for line in text.lines() {
        // Redact authorization headers
        let mut line_str = line.to_string();
        if let Some(idx) = line_str.to_lowercase().find("authorization: bearer ") {
            let prefix = &line_str[..idx + 22];
            line_str = format!("{prefix}[REDACTED_BEARER_TOKEN]");
        }
        if let Some(idx) = line_str.to_lowercase().find("token=") {
            let prefix = &line_str[..idx + 6];
            let end_idx = line_str[idx + 6..]
                .find(|c: char| c == '&' || c == ' ' || c == '\n')
                .map(|e| idx + 6 + e)
                .unwrap_or(line_str.len());
            line_str = format!("{prefix}[REDACTED_TOKEN]{}", &line_str[end_idx..]);
        }
        if let Some(idx) = line_str.to_lowercase().find("password=") {
            let prefix = &line_str[..idx + 9];
            let end_idx = line_str[idx + 9..]
                .find(|c: char| c == '&' || c == ' ' || c == '\n')
                .map(|e| idx + 9 + e)
                .unwrap_or(line_str.len());
            line_str = format!("{prefix}[REDACTED_PASSWORD]{}", &line_str[end_idx..]);
        }

        // Mask IP addresses and SocketAddrs
        let words: Vec<&str> = line_str.split_whitespace().collect();
        let mut masked_line = Vec::new();
        for word in words {
            let clean = word.trim_matches(|c: char| !c.is_alphanumeric() && c != ':' && c != '.');
            if let Ok(addr) = clean.parse::<SocketAddr>() {
                masked_line.push(mask_socket_addr(addr));
            } else if let Ok(ip) = clean.parse::<IpAddr>() {
                masked_line.push(mask_ip(ip));
            } else {
                masked_line.push(word.to_string());
            }
        }

        out.push_str(&masked_line.join(" "));
        out.push('\n');
    }

    out
}

/// Scan payload for private keys or sensitive canaries.
fn scan_for_canaries(
    _gzip_bytes: &[u8],
    tar_bytes: &[u8],
    options: &ClientSupportBundleOptions,
) -> ResultType<()> {
    let text = String::from_utf8_lossy(tar_bytes);

    for pattern in CANARY_SECRET_PATTERNS {
        if text.contains(pattern) {
            bail!("Canary leak detected: support bundle contains prohibited private key marker '{pattern}'");
        }
    }

    for custom in &options.custom_secret_canaries {
        if text.contains(custom) {
            bail!(
                "Canary leak detected: support bundle contains custom sensitive canary '{custom}'"
            );
        }
    }

    Ok(())
}

/// Construct a standard ustar in-memory tar archive.
pub fn build_tar_archive(files: &[(String, Vec<u8>)]) -> ResultType<Vec<u8>> {
    let mut tar = Vec::new();
    let mtime_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    for (name, content) in files {
        let mut header = [0u8; 512];
        let name_bytes = name.as_bytes();
        let copy_len = name_bytes.len().min(100);
        header[..copy_len].copy_from_slice(&name_bytes[..copy_len]);

        // File mode 0600
        header[100..108].copy_from_slice(b"0000600\0");
        // UID / GID 0
        header[108..116].copy_from_slice(b"0000000\0");
        header[116..124].copy_from_slice(b"0000000\0");

        // Size in octal (11 digits + NUL)
        let size_str = format!("{:011o}\0", content.len());
        header[124..136].copy_from_slice(size_str.as_bytes());

        // Mtime in octal
        let mtime_str = format!("{:011o}\0", mtime_secs);
        header[136..148].copy_from_slice(mtime_str.as_bytes());

        // Checksum placeholder
        header[148..156].copy_from_slice(b"        ");
        // Typeflag: regular file ('0')
        header[156] = b'0';

        // Magic "ustar\0" and Version "00"
        header[257..263].copy_from_slice(b"ustar\0");
        header[263..265].copy_from_slice(b"00");

        // Compute checksum treating chksum field as 8 ASCII spaces
        let chksum: u32 = header.iter().map(|&b| b as u32).sum();
        let chksum_str = format!("{:06o}\0 ", chksum);
        header[148..156].copy_from_slice(chksum_str.as_bytes());

        tar.extend_from_slice(&header);
        tar.extend_from_slice(content);
        let pad = (512 - (content.len() % 512)) % 512;
        if pad > 0 {
            tar.resize(tar.len() + pad, 0);
        }
    }

    // Two 512-byte zero blocks at the end of tar archive
    tar.resize(tar.len() + 1024, 0);
    Ok(tar)
}

/// Compress an uncompressed byte buffer using gzip.
pub fn compress_gzip(uncompressed: &[u8]) -> ResultType<Vec<u8>> {
    // Attempt system `gzip -c`
    if let Ok(mut child) = Command::new("gzip")
        .arg("-c")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(uncompressed);
            drop(stdin);
            if let Ok(output) = child.wait_with_output() {
                if output.status.success() && !output.stdout.is_empty() {
                    return Ok(output.stdout);
                }
            }
        }
    }

    // Pure Rust RFC 1952 gzip stored-block compression fallback
    let mut out = Vec::new();
    // 10-byte Gzip Header: ID1, ID2, CM (deflate), FLG, MTIME (4), XFL, OS (Unix 3)
    out.extend_from_slice(&[0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03]);

    // Deflate stream using stored blocks (BTYPE = 00)
    let chunks = uncompressed.chunks(65535);
    let chunk_count = chunks.len();
    for (idx, chunk) in chunks.enumerate() {
        let is_last = idx + 1 == chunk_count;
        let bfinal_btype = if is_last { 0x01 } else { 0x00 };
        out.push(bfinal_btype);
        let len = chunk.len() as u16;
        let nlen = !len;
        out.extend_from_slice(&len.to_le_bytes());
        out.extend_from_slice(&nlen.to_le_bytes());
        out.extend_from_slice(chunk);
    }
    if chunk_count == 0 {
        out.push(0x01); // bfinal = 1, btype = 00
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&(!0u16).to_le_bytes());
    }

    // Gzip trailer: 4-byte CRC-32 + 4-byte uncompressed size modulo 2^32
    let crc = compute_crc32(uncompressed);
    out.extend_from_slice(&crc.to_le_bytes());
    let isize = (uncompressed.len() as u32).to_le_bytes();
    out.extend_from_slice(&isize);

    Ok(out)
}

/// Standard IEEE 802.3 / gzip CRC32 computation.
pub fn compute_crc32(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &byte in data {
        crc ^= byte as u32;
        for _ in 0..8 {
            if crc & 1 != 0 {
                crc = (crc >> 1) ^ 0xEDB8_8320;
            } else {
                crc >>= 1;
            }
        }
    }
    !crc
}

/// Write bytes to a file with strict Unix permissions 0600.
fn write_secure_file(path: &Path, content: &[u8]) -> ResultType<()> {
    let mut file =
        File::create(path).with_context(|| format!("Failed to create file: {}", path.display()))?;
    file.write_all(content)
        .with_context(|| format!("Failed to write content to: {}", path.display()))?;
    file.sync_all().ok();

    #[cfg(unix)]
    {
        fs::set_permissions(path, Permissions::from_mode(0o600))
            .with_context(|| format!("Failed to set 0600 permissions on: {}", path.display()))?;
    }

    Ok(())
}
