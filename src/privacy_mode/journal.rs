#[allow(unused_imports)]
use camellia_remote_protocol::{bail, config::Config, log, ResultType};
use serde_derive::{Deserialize, Serialize};

#[cfg(windows)]
use winapi::um::{
    wingdi::DEVMODEW,
    winuser::{
        ChangeDisplaySettingsExW, CDS_NORESET, CDS_RESET, CDS_SET_PRIMARY, CDS_UPDATEREGISTRY,
        DISP_CHANGE_FAILED, DISP_CHANGE_SUCCESSFUL,
    },
};

pub const CONFIG_KEY_PRIVACY_JOURNAL: &str = "privacy_recovery_journal";

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum JournalItemState {
    /// Staged before mutation
    Pending,
    /// Applied to the system (needs restoration on exit)
    Applied,
    /// Successfully restored and verified
    Restored,
    /// Restoration attempted but failed (retained for retry)
    RestoreFailed,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum JournalPhase {
    Initialized,
    VirtualPluggedIn,
    PrimarySwitched,
    PhysicalDisabled,
    CommittedActive,
    Restoring,
    FullyRestored,
    PartiallyRestored,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct DisplaySnapshot {
    pub device_name: String,
    pub is_primary: bool,
    /// Exact binary representation of DEVMODEW
    pub dm_raw_bytes: Vec<u8>,
    pub dm_position: (i32, i32),
    pub dm_pels_width: u32,
    pub dm_pels_height: u32,
    pub dm_bits_per_pel: u32,
    pub dm_display_frequency: u32,
    pub dm_display_flags: u32,
}

impl DisplaySnapshot {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        device_name: String,
        is_primary: bool,
        dm_raw_bytes: Vec<u8>,
        dm_position: (i32, i32),
        dm_pels_width: u32,
        dm_pels_height: u32,
        dm_bits_per_pel: u32,
        dm_display_frequency: u32,
        dm_display_flags: u32,
    ) -> Self {
        Self {
            device_name,
            is_primary,
            dm_raw_bytes,
            dm_position,
            dm_pels_width,
            dm_pels_height,
            dm_bits_per_pel,
            dm_display_frequency,
            dm_display_flags,
        }
    }

    #[cfg(windows)]
    pub fn from_devmode(name: &[u16], dm: &DEVMODEW, is_primary: bool) -> Self {
        let device_name = String::from_utf16_lossy(name)
            .trim_matches('\0')
            .to_string();
        let size = std::mem::size_of::<DEVMODEW>();
        let mut dm_raw_bytes = vec![0u8; size];
        unsafe {
            std::ptr::copy_nonoverlapping(
                dm as *const DEVMODEW as *const u8,
                dm_raw_bytes.as_mut_ptr(),
                size,
            );
        }
        let pos = unsafe {
            let s2 = dm.u1.s2();
            (s2.dmPosition.x, s2.dmPosition.y)
        };
        Self {
            device_name,
            is_primary,
            dm_raw_bytes,
            dm_position: pos,
            dm_pels_width: dm.dmPelsWidth,
            dm_pels_height: dm.dmPelsHeight,
            dm_bits_per_pel: dm.dmBitsPerPel,
            dm_display_frequency: dm.dmDisplayFrequency,
            dm_display_flags: dm.dmDisplayFlags,
        }
    }

    #[cfg(windows)]
    pub fn to_devmode(&self) -> ResultType<DEVMODEW> {
        let expected_size = std::mem::size_of::<DEVMODEW>();
        if self.dm_raw_bytes.len() != expected_size {
            bail!(
                "Invalid DEVMODEW raw byte length: expected {}, got {}",
                expected_size,
                self.dm_raw_bytes.len()
            );
        }
        let mut dm: DEVMODEW = unsafe { std::mem::zeroed() };
        unsafe {
            std::ptr::copy_nonoverlapping(
                self.dm_raw_bytes.as_ptr(),
                &mut dm as *mut DEVMODEW as *mut u8,
                expected_size,
            );
        }
        Ok(dm)
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct PhysicalDisplayJournalEntry {
    pub device_name: String,
    pub snapshot: DisplaySnapshot,
    pub state: JournalItemState,
    pub last_error_code: Option<i32>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct VirtualDisplayJournalEntry {
    pub index: u32,
    pub state: JournalItemState,
    pub last_error: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct RegistryJournalEntry {
    pub recovery_json: String,
    pub state: JournalItemState,
    pub last_error: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct PrivacyRecoveryJournal {
    pub version: u32,
    pub tx_id: String,
    pub conn_id: i32,
    pub generation: u64,
    pub created_at_utc: String,
    pub phase: JournalPhase,
    pub physical_displays: Vec<PhysicalDisplayJournalEntry>,
    pub virtual_displays: Vec<PhysicalDisplayJournalEntry>,
    pub virtual_indices: Vec<VirtualDisplayJournalEntry>,
    pub registry_entry: Option<RegistryJournalEntry>,
    pub global_commit_applied: bool,
    pub input_hook_applied: bool,
}

impl PrivacyRecoveryJournal {
    pub fn new(tx_id: String, conn_id: i32, generation: u64) -> Self {
        Self {
            version: 1,
            tx_id,
            conn_id,
            generation,
            created_at_utc: chrono_lite_now(),
            phase: JournalPhase::Initialized,
            physical_displays: Vec::new(),
            virtual_displays: Vec::new(),
            virtual_indices: Vec::new(),
            registry_entry: None,
            global_commit_applied: false,
            input_hook_applied: false,
        }
    }

    pub fn is_fully_restored(&self) -> bool {
        self.physical_displays
            .iter()
            .all(|d| d.state == JournalItemState::Restored)
            && self
                .virtual_displays
                .iter()
                .all(|d| d.state == JournalItemState::Restored)
            && self
                .virtual_indices
                .iter()
                .all(|v| v.state == JournalItemState::Restored)
            && self
                .registry_entry
                .as_ref()
                .is_none_or(|r| r.state == JournalItemState::Restored)
    }

    pub fn has_pending_or_applied(&self) -> bool {
        self.phase == JournalPhase::PartiallyRestored
            || (self.phase != JournalPhase::FullyRestored
                && self.phase != JournalPhase::Initialized)
            || self.physical_displays.iter().any(|d| {
                d.state == JournalItemState::Pending
                    || d.state == JournalItemState::Applied
                    || d.state == JournalItemState::RestoreFailed
            })
            || self.virtual_displays.iter().any(|d| {
                d.state == JournalItemState::Pending
                    || d.state == JournalItemState::Applied
                    || d.state == JournalItemState::RestoreFailed
            })
            || self.virtual_indices.iter().any(|v| {
                v.state == JournalItemState::Pending
                    || v.state == JournalItemState::Applied
                    || v.state == JournalItemState::RestoreFailed
            })
            || self.registry_entry.as_ref().is_some_and(|r| {
                r.state == JournalItemState::Pending
                    || r.state == JournalItemState::Applied
                    || r.state == JournalItemState::RestoreFailed
            })
    }

    pub fn mark_all_restored(&mut self) {
        for d in &mut self.physical_displays {
            d.state = JournalItemState::Restored;
            d.last_error_code = None;
        }
        for d in &mut self.virtual_displays {
            d.state = JournalItemState::Restored;
            d.last_error_code = None;
        }
        for v in &mut self.virtual_indices {
            v.state = JournalItemState::Restored;
            v.last_error = None;
        }
        if let Some(ref mut reg) = self.registry_entry {
            reg.state = JournalItemState::Restored;
            reg.last_error = None;
        }
        self.phase = JournalPhase::FullyRestored;
    }
}

fn chrono_lite_now() -> String {
    let now = std::time::SystemTime::now();
    let duration = now
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}.{}", duration.as_secs(), duration.subsec_millis())
}

pub fn load_durable_journal() -> Option<PrivacyRecoveryJournal> {
    let raw = Config::get_option(CONFIG_KEY_PRIVACY_JOURNAL);
    if raw.trim().is_empty() {
        return None;
    }
    match serde_json::from_str::<PrivacyRecoveryJournal>(&raw) {
        Ok(j) => Some(j),
        Err(e) => {
            log::warn!("Failed to deserialize privacy recovery journal: {}", e);
            None
        }
    }
}

pub fn save_durable_journal(journal: &PrivacyRecoveryJournal) {
    match serde_json::to_string(journal) {
        Ok(serialized) => {
            Config::set_option(CONFIG_KEY_PRIVACY_JOURNAL.to_owned(), serialized);
        }
        Err(e) => {
            log::error!("Failed to serialize privacy recovery journal: {}", e);
        }
    }
}

pub fn clear_durable_journal() {
    Config::set_option(CONFIG_KEY_PRIVACY_JOURNAL.to_owned(), "".to_owned());
}

#[cfg(windows)]
impl PhysicalDisplayJournalEntry {
    pub fn restore_single(&mut self) -> ResultType<()> {
        let mut dm = self.snapshot.to_devmode()?;
        let flags = if self.snapshot.is_primary {
            CDS_NORESET | CDS_UPDATEREGISTRY | CDS_SET_PRIMARY
        } else {
            CDS_NORESET | CDS_UPDATEREGISTRY
        };
        let wide_name: Vec<u16> = self
            .device_name
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let rc = unsafe {
            ChangeDisplaySettingsExW(
                wide_name.as_ptr(),
                &mut dm,
                std::ptr::null_mut(),
                flags,
                std::ptr::null_mut(),
            )
        };

        if rc == DISP_CHANGE_SUCCESSFUL {
            self.state = JournalItemState::Restored;
            self.last_error_code = None;
            Ok(())
        } else {
            self.state = JournalItemState::RestoreFailed;
            self.last_error_code = Some(rc);
            let err_msg = change_display_settings_ex_err_msg(rc);
            log::error!(
                "Failed ChangeDisplaySettingsExW on {}: {}",
                self.device_name,
                err_msg
            );
            bail!(
                "Failed ChangeDisplaySettingsExW on {}: {}",
                self.device_name,
                err_msg
            )
        }
    }
}

#[cfg(windows)]
fn change_display_settings_ex_err_msg(rc: i32) -> String {
    if rc != DISP_CHANGE_FAILED {
        format!("ret: {}", rc)
    } else {
        format!(
            "ret: {}, last error: {:?}",
            rc,
            std::io::Error::last_os_error()
        )
    }
}

#[cfg(windows)]
pub fn restore_from_journal(journal: &mut PrivacyRecoveryJournal, force: bool) -> ResultType<()> {
    use crate::{platform::windows::reg_display_settings, virtual_display_manager};

    let mut errors: Vec<String> = Vec::new();
    journal.phase = JournalPhase::Restoring;

    // 1. Restore physical displays
    for entry in &mut journal.physical_displays {
        if entry.state != JournalItemState::Restored {
            if let Err(e) = entry.restore_single() {
                errors.push(e.to_string());
            }
        }
    }

    // 2. Restore virtual displays if any pre-existing snapshot existed
    for entry in &mut journal.virtual_displays {
        if entry.state != JournalItemState::Restored {
            if let Err(e) = entry.restore_single() {
                errors.push(e.to_string());
            }
        }
    }

    // 3. Commit display topology change
    let commit_rc = unsafe {
        ChangeDisplaySettingsExW(
            std::ptr::null(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            CDS_RESET,
            std::ptr::null_mut(),
        )
    };
    if commit_rc != DISP_CHANGE_SUCCESSFUL {
        let err = change_display_settings_ex_err_msg(commit_rc);
        errors.push(format!("Global commit failed: {}", err));
    }

    // 4. Plug out virtual display indices
    for entry in &mut journal.virtual_indices {
        if entry.state != JournalItemState::Restored {
            match virtual_display_manager::plug_out_monitor_indices(&[entry.index], true, false) {
                Ok(_) => {
                    entry.state = JournalItemState::Restored;
                    entry.last_error = None;
                }
                Err(e) => {
                    entry.state = JournalItemState::RestoreFailed;
                    entry.last_error = Some(e.to_string());
                    errors.push(format!(
                        "Failed to plug out virtual display index {}: {}",
                        entry.index, e
                    ));
                }
            }
        }
    }

    // 5. Restore registry connectivity diff
    if let Some(ref mut reg_entry) = journal.registry_entry {
        if reg_entry.state != JournalItemState::Restored {
            match serde_json::from_str::<reg_display_settings::RegRecovery>(
                &reg_entry.recovery_json,
            ) {
                Ok(reg_recovery) => {
                    match reg_display_settings::restore_reg_connectivity(reg_recovery, force) {
                        Ok(_) => {
                            reg_entry.state = JournalItemState::Restored;
                            reg_entry.last_error = None;
                        }
                        Err(e) => {
                            reg_entry.state = JournalItemState::RestoreFailed;
                            reg_entry.last_error = Some(e.to_string());
                            errors.push(format!("Failed to restore registry connectivity: {}", e));
                        }
                    }
                }
                Err(e) => {
                    reg_entry.state = JournalItemState::RestoreFailed;
                    reg_entry.last_error = Some(e.to_string());
                    errors.push(format!("Corrupted registry recovery JSON: {}", e));
                }
            }
        }
    }

    // 6. Persistence & Invariant Verification
    if journal.is_fully_restored() && commit_rc == DISP_CHANGE_SUCCESSFUL {
        journal.phase = JournalPhase::FullyRestored;
        clear_durable_journal();
        log::info!(
            "Privacy recovery journal verified fully restored for tx {}",
            journal.tx_id
        );
        Ok(())
    } else {
        journal.phase = JournalPhase::PartiallyRestored;
        save_durable_journal(journal);
        log::warn!(
            "Privacy recovery partially succeeded; journal retained on disk. Errors: {:?}",
            errors
        );
        bail!("Privacy recovery partial failure: {}", errors.join("; "))
    }
}
