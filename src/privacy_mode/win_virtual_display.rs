use super::{
    journal::{
        self, DisplaySnapshot, JournalItemState, JournalPhase, PhysicalDisplayJournalEntry,
        PrivacyRecoveryJournal, RegistryJournalEntry, VirtualDisplayJournalEntry,
    },
    PrivacyMode, PrivacyModeState, INVALID_PRIVACY_MODE_CONN_ID, NO_PHYSICAL_DISPLAYS,
};
use crate::{platform::windows::reg_display_settings, virtual_display_manager};
use camellia_remote_protocol::{allow_err, bail, config::Config, log, ResultType};
use std::{
    io::Error,
    ops::{Deref, DerefMut},
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::Duration,
};
use virtual_display::MonitorMode;
use winapi::{
    shared::{
        minwindef::{DWORD, FALSE},
        ntdef::{NULL, WCHAR},
    },
    um::{
        wingdi::{
            DEVMODEW, DISPLAY_DEVICEW, DISPLAY_DEVICE_ACTIVE, DISPLAY_DEVICE_ATTACHED_TO_DESKTOP,
            DISPLAY_DEVICE_MIRRORING_DRIVER, DISPLAY_DEVICE_PRIMARY_DEVICE, DM_POSITION,
        },
        winuser::{
            ChangeDisplaySettingsExW, EnumDisplayDevicesW, EnumDisplaySettingsExW,
            EnumDisplaySettingsW, CDS_NORESET, CDS_RESET, CDS_SET_PRIMARY, CDS_UPDATEREGISTRY,
            DISP_CHANGE_FAILED, DISP_CHANGE_SUCCESSFUL, EDD_GET_DEVICE_INTERFACE_NAME,
            ENUM_CURRENT_SETTINGS, ENUM_REGISTRY_SETTINGS,
        },
    },
};

pub(super) const PRIVACY_MODE_IMPL: &str = super::PRIVACY_MODE_IMPL_WIN_VIRTUAL_DISPLAY;

const CONFIG_KEY_REG_RECOVERY: &str = "reg_recovery";

struct Display {
    dm: DEVMODEW,
    name: [WCHAR; 32],
    primary: bool,
}

pub struct PrivacyModeImpl {
    impl_key: String,
    conn_id: i32,
    displays: Vec<Display>,
    virtual_displays: Vec<Display>,
    virtual_displays_added: Vec<u32>,
    active_journal: Option<PrivacyRecoveryJournal>,
}

struct TurnOnGuard<'a> {
    privacy_mode: &'a mut PrivacyModeImpl,
    succeeded: bool,
}

impl<'a> Deref for TurnOnGuard<'a> {
    type Target = PrivacyModeImpl;

    fn deref(&self) -> &Self::Target {
        self.privacy_mode
    }
}

impl<'a> DerefMut for TurnOnGuard<'a> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.privacy_mode
    }
}

impl<'a> Drop for TurnOnGuard<'a> {
    fn drop(&mut self) {
        if !self.succeeded {
            log::warn!("Privacy mode activation aborted or failed; executing TurnOnGuard rollback");
            self.privacy_mode
                .turn_off_privacy(INVALID_PRIVACY_MODE_CONN_ID, None)
                .ok();
        }
    }
}

impl PrivacyModeImpl {
    pub fn new(impl_key: &str) -> Self {
        Self {
            impl_key: impl_key.to_owned(),
            conn_id: INVALID_PRIVACY_MODE_CONN_ID,
            displays: Vec::new(),
            virtual_displays: Vec::new(),
            virtual_displays_added: Vec::new(),
            active_journal: None,
        }
    }

    #[inline]
    pub fn active_journal(&self) -> Option<&PrivacyRecoveryJournal> {
        self.active_journal.as_ref()
    }

    // mainly from https://github.com/rustdesk-org/rustdesk/blob/44c3a52ca8502cf53b58b59db130611778d34dbe/libs/scrap/src/dxgi/mod.rs#L365
    fn set_displays(&mut self) {
        self.displays.clear();
        self.virtual_displays.clear();

        let mut i: DWORD = 0;
        loop {
            #[allow(invalid_value)]
            let mut dd: DISPLAY_DEVICEW = unsafe { std::mem::MaybeUninit::uninit().assume_init() };
            dd.cb = std::mem::size_of::<DISPLAY_DEVICEW>() as _;
            let ok = unsafe { EnumDisplayDevicesW(std::ptr::null(), i, &mut dd as _, 0) };
            if ok == FALSE {
                break;
            }
            i += 1;
            if 0 == (dd.StateFlags & DISPLAY_DEVICE_ACTIVE)
                || (dd.StateFlags & DISPLAY_DEVICE_MIRRORING_DRIVER) > 0
            {
                continue;
            }
            #[allow(invalid_value)]
            let mut dm: DEVMODEW = unsafe { std::mem::MaybeUninit::uninit().assume_init() };
            dm.dmSize = std::mem::size_of::<DEVMODEW>() as _;
            dm.dmDriverExtra = 0;
            unsafe {
                if FALSE
                    == EnumDisplaySettingsExW(
                        dd.DeviceName.as_ptr(),
                        ENUM_CURRENT_SETTINGS,
                        &mut dm as _,
                        0,
                    )
                {
                    if FALSE
                        == EnumDisplaySettingsExW(
                            dd.DeviceName.as_ptr(),
                            ENUM_REGISTRY_SETTINGS,
                            &mut dm as _,
                            0,
                        )
                    {
                        continue;
                    }
                }
            }

            let primary = (dd.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) > 0;
            let display = Display {
                dm,
                name: dd.DeviceName,
                primary,
            };

            let ds = virtual_display_manager::get_cur_device_string();
            if let Ok(s) = String::from_utf16(&dd.DeviceString) {
                if s.len() >= ds.len() && &s[..ds.len()] == ds {
                    self.virtual_displays.push(display);
                    continue;
                }
            }
            self.displays.push(display);
        }
    }

    fn restore_plug_out_monitor(&mut self) {
        let _ = virtual_display_manager::plug_out_monitor_indices(
            &self.virtual_displays_added,
            true,
            false,
        );
        self.virtual_displays_added.clear();
    }

    #[inline]
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

    fn set_primary_display(&mut self) -> ResultType<String> {
        // Multiple virtual displays with different origins are tested.
        let display = &self.virtual_displays[0];
        let display_name = std::string::String::from_utf16(&display.name)?;

        #[allow(invalid_value)]
        let mut new_primary_dm: DEVMODEW = unsafe { std::mem::MaybeUninit::uninit().assume_init() };
        new_primary_dm.dmSize = std::mem::size_of::<DEVMODEW>() as _;
        new_primary_dm.dmDriverExtra = 0;
        unsafe {
            if FALSE
                == EnumDisplaySettingsW(
                    display.name.as_ptr(),
                    ENUM_CURRENT_SETTINGS,
                    &mut new_primary_dm,
                )
            {
                bail!(
                    "Failed EnumDisplaySettingsW, device name: {:?}, error: {}",
                    std::string::String::from_utf16(&display.name),
                    Error::last_os_error()
                );
            }

            // Windows 24H2 requires the virtual display to be set first.
            let flags = CDS_UPDATEREGISTRY | CDS_NORESET;
            let offx = new_primary_dm.u1.s2().dmPosition.x;
            let offy = new_primary_dm.u1.s2().dmPosition.y;
            new_primary_dm.u1.s2_mut().dmPosition.x = 0;
            new_primary_dm.u1.s2_mut().dmPosition.y = 0;
            new_primary_dm.dmFields |= DM_POSITION;
            let rc = ChangeDisplaySettingsExW(
                display.name.as_ptr(),
                &mut new_primary_dm,
                NULL as _,
                flags | CDS_SET_PRIMARY,
                NULL,
            );
            if rc != DISP_CHANGE_SUCCESSFUL {
                let err = Self::change_display_settings_ex_err_msg(rc);
                log::error!(
                    "Failed ChangeDisplaySettingsEx, the virtual display, {}",
                    &err
                );
                bail!("Failed ChangeDisplaySettingsEx, {}", err);
            }

            let mut i: DWORD = 0;
            loop {
                #[allow(invalid_value)]
                let mut dd: DISPLAY_DEVICEW = std::mem::MaybeUninit::uninit().assume_init();
                dd.cb = std::mem::size_of::<DISPLAY_DEVICEW>() as _;
                if FALSE
                    == EnumDisplayDevicesW(NULL as _, i, &mut dd, EDD_GET_DEVICE_INTERFACE_NAME)
                {
                    break;
                }
                i += 1;
                if (dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) == 0 {
                    continue;
                }
                // Skip the virtual display.
                if dd.DeviceName == display.name {
                    continue;
                }

                #[allow(invalid_value)]
                let mut dm: DEVMODEW = std::mem::MaybeUninit::uninit().assume_init();
                dm.dmSize = std::mem::size_of::<DEVMODEW>() as _;
                dm.dmDriverExtra = 0;
                if FALSE
                    == EnumDisplaySettingsW(dd.DeviceName.as_ptr(), ENUM_CURRENT_SETTINGS, &mut dm)
                {
                    bail!(
                        "Failed EnumDisplaySettingsW, device name: {:?}, error: {}",
                        std::string::String::from_utf16(&dd.DeviceName),
                        Error::last_os_error()
                    );
                }

                dm.u1.s2_mut().dmPosition.x -= offx;
                dm.u1.s2_mut().dmPosition.y -= offy;
                dm.dmFields |= DM_POSITION;
                let rc = ChangeDisplaySettingsExW(
                    dd.DeviceName.as_ptr(),
                    &mut dm,
                    NULL as _,
                    flags,
                    NULL,
                );
                if rc != DISP_CHANGE_SUCCESSFUL {
                    let err = Self::change_display_settings_ex_err_msg(rc);
                    log::error!(
                        "Failed ChangeDisplaySettingsEx, device name: {:?}, flags: {}, {}",
                        std::string::String::from_utf16(&dd.DeviceName),
                        flags,
                        &err
                    );
                    bail!("Failed ChangeDisplaySettingsEx, {}", err);
                }
            }
        }

        Ok(display_name)
    }

    fn disable_physical_displays(&self) -> ResultType<()> {
        for display in &self.displays {
            let mut dm = display.dm.clone();
            unsafe {
                dm.u1.s2_mut().dmPosition.x = 10000;
                dm.u1.s2_mut().dmPosition.y = 10000;
                dm.dmPelsHeight = 0;
                dm.dmPelsWidth = 0;
                let flags = CDS_UPDATEREGISTRY | CDS_NORESET;
                let rc = ChangeDisplaySettingsExW(
                    display.name.as_ptr(),
                    &mut dm,
                    NULL as _,
                    flags,
                    NULL as _,
                );
                if rc != DISP_CHANGE_SUCCESSFUL {
                    let err = Self::change_display_settings_ex_err_msg(rc);
                    log::error!(
                        "Failed ChangeDisplaySettingsEx, device name: {:?}, flags: {}, {}",
                        std::string::String::from_utf16(&display.name),
                        flags,
                        &err
                    );
                    bail!("Failed ChangeDisplaySettingsEx, {}", err);
                }
            }
        }
        Ok(())
    }

    #[inline]
    fn default_display_modes() -> Vec<MonitorMode> {
        vec![MonitorMode {
            width: 1920,
            height: 1080,
            sync: 60,
        }]
    }

    pub fn ensure_virtual_display(
        &mut self,
        is_async_mode: bool,
        cancel_token: Option<&AtomicBool>,
    ) -> ResultType<()> {
        if self.virtual_displays.is_empty() {
            if let Some(token) = cancel_token {
                if token.load(Ordering::SeqCst) {
                    bail!("Privacy mode activation cancelled by supervisor");
                }
            }
            let displays =
                virtual_display_manager::plug_in_peer_request(vec![Self::default_display_modes()])?;
            if is_async_mode {
                thread::sleep(Duration::from_millis(500));
            }
            self.set_displays();
            // No physical displays, no need to use the privacy mode.
            if self.displays.is_empty() {
                virtual_display_manager::plug_out_monitor_indices(&displays, false, false)?;
                bail!(NO_PHYSICAL_DISPLAYS);
            }

            if is_async_mode {
                let now = std::time::Instant::now();
                while self.virtual_displays.is_empty()
                    && now.elapsed() < Duration::from_millis(5000)
                {
                    if let Some(token) = cancel_token {
                        if token.load(Ordering::SeqCst) {
                            virtual_display_manager::plug_out_monitor_indices(
                                &displays, false, false,
                            )?;
                            bail!("Privacy mode activation cancelled by supervisor");
                        }
                    }
                    thread::sleep(Duration::from_millis(250));
                    self.set_displays();
                }
            }

            self.virtual_displays_added.extend(displays);
        }

        Ok(())
    }

    #[inline]
    fn commit_change_display(flags: DWORD) -> ResultType<()> {
        unsafe {
            let rc = ChangeDisplaySettingsExW(NULL as _, NULL as _, NULL as _, flags, NULL as _);
            if rc != DISP_CHANGE_SUCCESSFUL {
                let err = Self::change_display_settings_ex_err_msg(rc);
                bail!("Failed ChangeDisplaySettingsEx, {}", err);
            }
        }
        Ok(())
    }

    fn restore(&mut self) {
        allow_err!(Self::restore_displays(&self.displays));
        allow_err!(Self::restore_displays(&self.virtual_displays));
        allow_err!(Self::commit_change_display(0));
        self.displays.clear();
        self.virtual_displays.clear();
        let is_virtual_display_added = self.virtual_displays_added.len() > 0;
        if is_virtual_display_added {
            self.restore_plug_out_monitor();
        } else {
            let _ = virtual_display_manager::plug_out_monitor(-1, true, false);
        }
    }

    fn restore_displays(displays: &[Display]) -> ResultType<()> {
        let mut errors = Vec::new();
        for display in displays {
            unsafe {
                let mut dm = display.dm.clone();
                let flags = if display.primary {
                    CDS_NORESET | CDS_UPDATEREGISTRY | CDS_SET_PRIMARY
                } else {
                    CDS_NORESET | CDS_UPDATEREGISTRY
                };
                let rc = ChangeDisplaySettingsExW(
                    display.name.as_ptr(),
                    &mut dm,
                    std::ptr::null_mut(),
                    flags,
                    std::ptr::null_mut(),
                );
                if rc != DISP_CHANGE_SUCCESSFUL {
                    let err = Self::change_display_settings_ex_err_msg(rc);
                    log::error!("ChangeDisplaySettingsExW restore failed: {}", err);
                    errors.push(err);
                }
            }
        }
        if errors.is_empty() {
            Ok(())
        } else {
            bail!("Failed to restore displays: {}", errors.join("; "))
        }
    }
}

impl PrivacyMode for PrivacyModeImpl {
    fn is_async_privacy_mode(&self) -> bool {
        virtual_display_manager::is_amyuni_idd()
    }

    fn init(&self) -> ResultType<()> {
        Ok(())
    }

    fn clear(&mut self) {
        allow_err!(self.turn_off_privacy(self.conn_id, None));
    }

    fn turn_on_privacy(&mut self, conn_id: i32) -> ResultType<bool> {
        self.turn_on_privacy_with_token(conn_id, 0, None)
    }

    fn turn_on_privacy_with_token(
        &mut self,
        conn_id: i32,
        generation: u64,
        cancel_token: Option<&AtomicBool>,
    ) -> ResultType<bool> {
        let check_cancel = || -> ResultType<()> {
            if let Some(token) = cancel_token {
                if token.load(Ordering::SeqCst) {
                    bail!("Privacy mode activation cancelled by supervisor");
                }
            }
            Ok(())
        };

        check_cancel()?;

        if !virtual_display_manager::is_virtual_display_supported() {
            bail!("idd_not_support_under_win10_2004_tip");
        }

        if self.check_on_conn_id(conn_id)? {
            log::debug!("Privacy mode of conn {} is already on", conn_id);
            return Ok(true);
        }
        self.set_displays();
        if self.displays.is_empty() {
            log::debug!("{}", NO_PHYSICAL_DISPLAYS);
            bail!(NO_PHYSICAL_DISPLAYS);
        }

        check_cancel()?;

        // Capture physical display snapshot into durable journal
        let mut recovery_journal = PrivacyRecoveryJournal::new(
            format!("tx_{}_{}", conn_id, generation),
            conn_id,
            generation,
        );
        for d in &self.displays {
            let snapshot = DisplaySnapshot::from_devmode(&d.name, &d.dm, d.primary);
            recovery_journal
                .physical_displays
                .push(PhysicalDisplayJournalEntry {
                    device_name: snapshot.device_name.clone(),
                    snapshot,
                    state: JournalItemState::Applied,
                    last_error_code: None,
                });
        }
        journal::save_durable_journal(&recovery_journal);

        let is_async_mode = self.is_async_privacy_mode();
        let mut guard = TurnOnGuard {
            privacy_mode: self,
            succeeded: false,
        };

        guard.ensure_virtual_display(is_async_mode, cancel_token)?;
        if guard.virtual_displays.is_empty() {
            log::debug!("No virtual displays");
            bail!("No virtual displays.");
        }

        for &idx in &guard.virtual_displays_added {
            recovery_journal
                .virtual_indices
                .push(VirtualDisplayJournalEntry {
                    index: idx,
                    state: JournalItemState::Applied,
                    last_error: None,
                });
        }
        recovery_journal.phase = JournalPhase::VirtualPluggedIn;
        journal::save_durable_journal(&recovery_journal);

        check_cancel()?;

        let reg_connectivity_1 = reg_display_settings::read_reg_connectivity()?;
        let primary_display_name = guard.set_primary_display()?;
        recovery_journal.phase = JournalPhase::PrimarySwitched;
        journal::save_durable_journal(&recovery_journal);

        check_cancel()?;

        guard.disable_physical_displays()?;
        recovery_journal.phase = JournalPhase::PhysicalDisabled;
        journal::save_durable_journal(&recovery_journal);

        check_cancel()?;

        Self::commit_change_display(CDS_RESET)?;
        recovery_journal.global_commit_applied = true;
        journal::save_durable_journal(&recovery_journal);

        // Explicitly set the resolution(virtual display) to 1920x1080.
        allow_err!(crate::platform::change_resolution(
            &primary_display_name,
            1920,
            1080
        ));

        check_cancel()?;

        let reg_connectivity_2 = reg_display_settings::read_reg_connectivity()?;
        if let Some(reg_recovery) =
            reg_display_settings::diff_recent_connectivity(reg_connectivity_1, reg_connectivity_2)
        {
            if let Ok(reg_json) = serde_json::to_string(&reg_recovery) {
                recovery_journal.registry_entry = Some(RegistryJournalEntry {
                    recovery_json: reg_json.clone(),
                    state: JournalItemState::Applied,
                    last_error: None,
                });
                Config::set_option(CONFIG_KEY_REG_RECOVERY.to_owned(), reg_json);
            }
        } else {
            reset_config_reg_connectivity();
        }
        journal::save_durable_journal(&recovery_journal);

        check_cancel()?;

        // STRICT CAPABILITY ENFORCEMENT (PRIV-005):
        // Hook installation is mandatory. If hooks fail, we propagate the error with `?`.
        // `guard.succeeded` remains false, triggering TurnOnGuard::drop which invokes
        // `turn_off_privacy`, completely restoring displays and registry via the journal.
        super::win_input::hook()?;
        recovery_journal.input_hook_applied = true;

        check_cancel()?;

        recovery_journal.phase = JournalPhase::CommittedActive;
        journal::save_durable_journal(&recovery_journal);
        guard.active_journal = Some(recovery_journal);

        guard.conn_id = conn_id;
        guard.succeeded = true;

        Ok(true)
    }

    fn turn_off_privacy(
        &mut self,
        conn_id: i32,
        state: Option<PrivacyModeState>,
    ) -> ResultType<()> {
        self.check_off_conn_id(conn_id)?;

        let mut aggregated_errors: Vec<String> = Vec::new();

        // 1. Unhook input (isolated from display and registry restoration!)
        if let Err(e) = super::win_input::unhook() {
            log::warn!(
                "Input unhook error during privacy teardown (isolated from display restore): {}",
                e
            );
            aggregated_errors.push(format!("Input unhook failed: {}", e));
        }

        // 2. Prioritize Display & Registry restoration
        let _tmp_ignore_changed_holder = crate::display_service::temp_ignore_displays_changed();

        if let Some(mut journal) = self
            .active_journal
            .take()
            .or_else(journal::load_durable_journal)
        {
            if let Err(e) = journal::restore_from_journal(&mut journal, true) {
                log::error!("Display journal restoration error: {}", e);
                aggregated_errors.push(format!("Display journal restore failed: {}", e));
                self.active_journal = Some(journal);
            }
        } else {
            self.restore();
        }

        if let Err(e) = restore_reg_connectivity_result(false, true) {
            log::error!("Registry restoration error: {}", e);
            aggregated_errors.push(format!("Registry restore failed: {}", e));
        }

        if self.conn_id != INVALID_PRIVACY_MODE_CONN_ID {
            if let Some(state) = state {
                allow_err!(super::set_privacy_mode_state(
                    conn_id,
                    state,
                    PRIVACY_MODE_IMPL.to_string(),
                    1_000
                ));
            }
            self.conn_id = INVALID_PRIVACY_MODE_CONN_ID.to_owned();
        }

        if aggregated_errors.is_empty() {
            Ok(())
        } else {
            bail!(
                "Errors during turn_off_privacy: {}",
                aggregated_errors.join("; ")
            )
        }
    }

    #[inline]
    fn pre_conn_id(&self) -> i32 {
        self.conn_id
    }

    #[inline]
    fn get_impl_key(&self) -> &str {
        &self.impl_key
    }
}

impl Drop for PrivacyModeImpl {
    fn drop(&mut self) {
        if self.conn_id != INVALID_PRIVACY_MODE_CONN_ID {
            allow_err!(self.turn_off_privacy(self.conn_id, None));
        }
    }
}

#[inline]
fn reset_config_reg_connectivity() {
    Config::set_option(CONFIG_KEY_REG_RECOVERY.to_owned(), "".to_owned());
}

pub fn restore_reg_connectivity_result(plug_out_monitors: bool, force: bool) -> ResultType<()> {
    let config_recovery_value = Config::get_option(CONFIG_KEY_REG_RECOVERY);
    if config_recovery_value.is_empty() {
        return Ok(());
    }
    if plug_out_monitors {
        let _ = virtual_display_manager::plug_out_monitor(-1, true, false);
    }
    let reg_recovery =
        serde_json::from_str::<reg_display_settings::RegRecovery>(&config_recovery_value)?;
    reg_display_settings::restore_reg_connectivity(reg_recovery, force)?;
    reset_config_reg_connectivity();
    Ok(())
}

pub fn restore_reg_connectivity(plug_out_monitors: bool, force: bool) {
    if let Err(e) = restore_reg_connectivity_result(plug_out_monitors, force) {
        log::error!("Failed restore_reg_connectivity: {}", e);
    }
}
