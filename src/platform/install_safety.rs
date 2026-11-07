// Copyright (c) 2026 Camellia Computing. All rights reserved.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

//! Windows Elevation, Installation Safety & Manifest Verification
//!
//! Provides structured validation, allowlisted file discovery, and atomic
//! batch execution contracts across UAC and elevation boundaries (ACL-001, ELEV-001, UPDATE-001).

use camellia_remote_protocol::{anyhow::anyhow, bail, ResultType};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
};

/// Types of allowed files in a Camellia Remote application bundle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BundleItemType {
    /// The primary executable binary (`<app_name>.exe`).
    MainExecutable,
    /// Core Flutter engine library (`flutter_windows.dll`).
    FlutterLibrary,
    /// Flutter bundle assets directory (`data/`).
    DataDirectory,
    /// Plugin dynamic library (e.g., `screen_retriever_windows_plugin.dll`).
    PluginLibrary(String),
    /// Injected broker/helper executable (`win_topmost_window_broker.exe`).
    BrokerExecutable,
}

/// An allowlisted file or directory entry to be copied during install/update.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BundleFileEntry {
    pub src_path: PathBuf,
    pub dst_path: PathBuf,
    pub item_type: BundleItemType,
    pub is_directory: bool,
}

/// Discovered application bundle manifest.
///
/// Ensures only verified, allowlisted application components are installed
/// or updated, strictly ignoring all unrelated or hostile files in the source directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BundleManifest {
    pub entries: Vec<BundleFileEntry>,
    pub ignored_entries: Vec<PathBuf>,
}

impl BundleManifest {
    /// Scans the source executable's directory to discover allowlisted bundle items.
    ///
    /// Never copies the entire parent directory. Only recognizes:
    /// - The primary executable (`src_exe`)
    /// - `data/` directory
    /// - `flutter_windows.dll`
    /// - `*_plugin.dll` files
    /// - Broker executable (e.g., `win_topmost_window.exe`)
    pub fn scan(src_exe: &Path, install_dir: &Path, app_name: &str) -> ResultType<Self> {
        if !src_exe.exists() {
            bail!("Source executable does not exist: {}", src_exe.display());
        }

        let mut entries = Vec::new();
        let mut ignored_entries = Vec::new();

        // 1. Primary application binary
        let canonical_app_name = format!("{}.exe", app_name.to_lowercase());
        let dst_exe_path = install_dir.join(&canonical_app_name);
        entries.push(BundleFileEntry {
            src_path: src_exe.to_path_buf(),
            dst_path: dst_exe_path,
            item_type: BundleItemType::MainExecutable,
            is_directory: false,
        });

        // 2. Scan sibling items in source parent directory
        if let Some(src_parent) = src_exe.parent() {
            if src_parent.is_dir() {
                let read_dir = fs::read_dir(src_parent).map_err(|e| {
                    anyhow!(
                        "Failed to inspect source directory '{}': {}",
                        src_parent.display(),
                        e
                    )
                })?;

                for entry_res in read_dir {
                    let entry = match entry_res {
                        Ok(e) => e,
                        Err(_) => continue,
                    };
                    let path = entry.path();
                    let file_name = match path.file_name().and_then(|n| n.to_str()) {
                        Some(name) => name,
                        None => {
                            ignored_entries.push(path);
                            continue;
                        }
                    };

                    // Skip the source exe itself (already added as MainExecutable)
                    if path == src_exe {
                        continue;
                    }

                    let lower_name = file_name.to_lowercase();
                    let metadata = match fs::symlink_metadata(&path) {
                        Ok(m) => m,
                        Err(_) => {
                            ignored_entries.push(path);
                            continue;
                        }
                    };

                    if metadata.file_type().is_dir() {
                        if lower_name == "data" {
                            entries.push(BundleFileEntry {
                                src_path: path.clone(),
                                dst_path: install_dir.join("data"),
                                item_type: BundleItemType::DataDirectory,
                                is_directory: true,
                            });
                        } else {
                            ignored_entries.push(path);
                        }
                    } else if metadata.file_type().is_file() {
                        if lower_name == "flutter_windows.dll" {
                            entries.push(BundleFileEntry {
                                src_path: path.clone(),
                                dst_path: install_dir.join("flutter_windows.dll"),
                                item_type: BundleItemType::FlutterLibrary,
                                is_directory: false,
                            });
                        } else if lower_name.ends_with("_plugin.dll") {
                            entries.push(BundleFileEntry {
                                src_path: path.clone(),
                                dst_path: install_dir.join(file_name),
                                item_type: BundleItemType::PluginLibrary(file_name.to_string()),
                                is_directory: false,
                            });
                        } else if lower_name == "win_topmost_window.exe"
                            || lower_name == "win_topmost_window_broker.exe"
                        {
                            entries.push(BundleFileEntry {
                                src_path: path.clone(),
                                dst_path: install_dir.join("win_topmost_window_broker.exe"),
                                item_type: BundleItemType::BrokerExecutable,
                                is_directory: false,
                            });
                        } else {
                            ignored_entries.push(path);
                        }
                    } else {
                        ignored_entries.push(path);
                    }
                }
            }
        }

        Ok(Self {
            entries,
            ignored_entries,
        })
    }

    /// Generates strict Win32 copy commands without error-ignoring flags (`/C`).
    ///
    /// Every copy command is safe and can be individually verified for zero exit status.
    pub fn generate_copy_commands(&self) -> Vec<String> {
        let mut cmds = Vec::new();
        for entry in &self.entries {
            if entry.is_directory {
                // XCOPY for directory: without /C, with /Y (overwrite), /E (all subdirs), /I (assume destination dir)
                cmds.push(format!(
                    "xcopy \"{}\" \"{}\" /Y /E /I",
                    entry.src_path.display(),
                    entry.dst_path.display()
                ));
            } else {
                // Ensure parent destination directory exists before copy
                cmds.push(format!(
                    "copy /Y /B \"{}\" \"{}\"",
                    entry.src_path.display(),
                    entry.dst_path.display()
                ));
            }
        }
        cmds
    }
}

/// Assembled elevated batch script with integrity binding and completion verification.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ElevatedBatchScript {
    /// Full batch script content.
    pub script_content: String,
    /// SHA-256 digest of script content in lowercase hex.
    pub sha256_hex: String,
    /// Secret completion token required to prove successful, uninterrupted execution.
    pub success_token: String,
    /// Relative filename of the sentinel file written upon success.
    pub sentinel_file_name: String,
}

/// Formats and verifies batch scripts crossing the UAC elevation boundary.
pub struct ElevatedBatchAssembler;

impl ElevatedBatchAssembler {
    /// Assembles an array of commands into a fail-fast, guarded Windows batch script.
    ///
    /// Invariants:
    /// 1. `setlocal enableextensions enabledelayedexpansion` enabled.
    /// 2. Every executable command is followed by `if errorlevel 1 goto :camellia_script_error`.
    /// 3. The authenticated sentinel file is ONLY written if ALL commands succeed.
    /// 4. Any failure immediately jumps to `:camellia_script_error` and exits with code 1.
    pub fn assemble(commands: &[String], tip: &str) -> ElevatedBatchScript {
        let random_token = uuid::Uuid::new_v4().simple().to_string();
        let sentinel_file_name = format!("camellia_sentinel_{}_{}.token", tip, random_token);

        let mut script = String::new();
        script.push_str("@echo off\r\n");
        script.push_str("setlocal enableextensions enabledelayedexpansion\r\n\r\n");

        for cmd in commands {
            let trimmed = cmd.trim();
            if trimmed.is_empty()
                || trimmed.starts_with("rem ")
                || trimmed.starts_with("REM ")
                || trimmed.starts_with("::")
                || trimmed.starts_with("@echo")
            {
                continue;
            }

            // If the command already contains an explicit errorlevel check, preserve it;
            // otherwise, append the fail-fast error check.
            script.push_str(trimmed);
            script.push_str("\r\n");
            if !trimmed.contains("errorlevel") && !trimmed.contains("goto ") {
                script.push_str("if errorlevel 1 goto :camellia_script_error\r\n");
            }
            script.push_str("\r\n");
        }

        // Write success sentinel with authenticated token
        script.push_str(&format!(
            "echo {} > \"%~dp0{}\"\r\n",
            random_token, sentinel_file_name
        ));
        script.push_str("exit /b 0\r\n\r\n");
        script.push_str(":camellia_script_error\r\n");
        script.push_str("exit /b 1\r\n");

        let mut hasher = Sha256::new();
        hasher.update(script.as_bytes());
        let sha256_hex = format!("{:x}", hasher.finalize());

        ElevatedBatchScript {
            script_content: script,
            sha256_hex,
            success_token: random_token,
            sentinel_file_name,
        }
    }

    /// Verifies that the sentinel file exists and contains the expected authenticated token.
    pub fn verify_sentinel(
        workspace_dir: &Path,
        sentinel_file_name: &str,
        expected_token: &str,
    ) -> ResultType<()> {
        let sentinel_path = workspace_dir.join(sentinel_file_name);
        if !sentinel_path.exists() {
            bail!(
                "Elevation script execution failed: success sentinel not created at '{}'",
                sentinel_path.display()
            );
        }

        let content = fs::read_to_string(&sentinel_path).map_err(|e| {
            anyhow!(
                "Failed to read elevation success sentinel at '{}': {}",
                sentinel_path.display(),
                e
            )
        })?;

        if !content.trim().contains(expected_token) {
            bail!(
                "Elevation success sentinel token mismatch at '{}'",
                sentinel_path.display()
            );
        }

        Ok(())
    }
}

/// RAII workspace guard that securely cleans up temporary elevation files.
#[derive(Debug)]
pub struct ElevationWorkspaceGuard {
    dir: PathBuf,
    active: bool,
}

impl ElevationWorkspaceGuard {
    pub fn new(dir: PathBuf) -> Self {
        Self { dir, active: true }
    }

    pub fn path(&self) -> &Path {
        &self.dir
    }

    /// Defuses automatic deletion (e.g. for debugging).
    pub fn keep(&mut self) {
        self.active = false;
    }
}

impl Drop for ElevationWorkspaceGuard {
    fn drop(&mut self) {
        if self.active && self.dir.exists() {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }
}
