use super::{PrivacyMode, PrivacyModeState};
use camellia_remote_protocol::{anyhow::anyhow, log, ResultType};
use std::sync::{
    atomic::{AtomicI32, Ordering},
    Once,
};

type MacPrivacyLostCallback = Option<extern "C" fn()>;

extern "C" {
    fn MacSetPrivacyMode(on: bool) -> bool;
    fn MacIsPrivacyModeActive() -> bool;
    fn MacGetPendingGammaSnapshotCount() -> usize;
    fn MacRegisterPrivacyLostCallback(callback: MacPrivacyLostCallback);
}

pub const PRIVACY_MODE_IMPL: &str = "privacy_mode_impl_macos";

static ACTIVE_CONN_ID: AtomicI32 = AtomicI32::new(0);
static CALLBACK_REGISTRATION: Once = Once::new();

extern "C" fn on_native_privacy_mode_lost() {
    log::warn!("Native macOS privacy mode was asynchronously lost or shut down");
    ACTIVE_CONN_ID.store(0, Ordering::SeqCst);
}

fn register_privacy_callback_if_needed() {
    CALLBACK_REGISTRATION.call_once(|| unsafe {
        MacRegisterPrivacyLostCallback(Some(on_native_privacy_mode_lost));
    });
}

pub struct PrivacyModeImpl {
    impl_key: String,
    conn_id: i32,
}

impl PrivacyModeImpl {
    pub fn new(impl_key: &str) -> Self {
        register_privacy_callback_if_needed();
        Self {
            impl_key: impl_key.to_owned(),
            conn_id: 0,
        }
    }

    fn sync_with_native(&mut self) {
        let native_active = unsafe { MacIsPrivacyModeActive() };
        if !native_active && self.conn_id != 0 {
            log::info!(
                "Syncing macOS privacy mode owner: native is inactive, resetting Rust conn_id {}",
                self.conn_id
            );
            self.conn_id = 0;
            ACTIVE_CONN_ID.store(0, Ordering::SeqCst);
        }
    }
}

impl PrivacyMode for PrivacyModeImpl {
    fn is_async_privacy_mode(&self) -> bool {
        false
    }

    fn init(&self) -> ResultType<()> {
        register_privacy_callback_if_needed();
        Ok(())
    }

    fn clear(&mut self) {
        let success = unsafe { MacSetPrivacyMode(false) };
        if !success {
            let pending = unsafe { MacGetPendingGammaSnapshotCount() };
            log::warn!(
                "clear(): Failed to fully restore macOS display gammas ({pending} snapshots pending)"
            );
        }
        self.conn_id = 0;
        ACTIVE_CONN_ID.store(0, Ordering::SeqCst);
    }

    fn turn_on_privacy(&mut self, conn_id: i32) -> ResultType<bool> {
        register_privacy_callback_if_needed();
        self.sync_with_native();

        if self.check_on_conn_id(conn_id)? {
            return Ok(true);
        }

        let success = unsafe { MacSetPrivacyMode(true) };
        if !success {
            self.conn_id = 0;
            ACTIVE_CONN_ID.store(0, Ordering::SeqCst);
            let pending = unsafe { MacGetPendingGammaSnapshotCount() };
            if pending > 0 {
                log::warn!(
                    "MacSetPrivacyMode(true) failed; {pending} pending gamma snapshots retained"
                );
            }
            return Err(anyhow!(
                "Failed to turn on macOS privacy mode (display verification or gamma blackout failed)"
            ));
        }

        self.conn_id = conn_id;
        ACTIVE_CONN_ID.store(conn_id, Ordering::SeqCst);
        Ok(true)
    }

    fn turn_off_privacy(
        &mut self,
        conn_id: i32,
        _state: Option<PrivacyModeState>,
    ) -> ResultType<()> {
        register_privacy_callback_if_needed();
        self.sync_with_native();

        self.check_off_conn_id(conn_id)?;
        let success = unsafe { MacSetPrivacyMode(false) };
        if !success {
            let pending = unsafe { MacGetPendingGammaSnapshotCount() };
            log::error!(
                "Failed to fully turn off macOS privacy mode: {pending} display snapshots remain pending"
            );
            return Err(anyhow!(
                "Failed to fully restore macOS privacy mode gammas ({pending} pending)"
            ));
        }

        self.conn_id = 0;
        ACTIVE_CONN_ID.store(0, Ordering::SeqCst);
        Ok(())
    }

    fn pre_conn_id(&self) -> i32 {
        if !unsafe { MacIsPrivacyModeActive() } {
            return 0;
        }
        let global_id = ACTIVE_CONN_ID.load(Ordering::SeqCst);
        if global_id != 0 {
            global_id
        } else {
            self.conn_id
        }
    }

    fn get_impl_key(&self) -> &str {
        &self.impl_key
    }
}

impl Drop for PrivacyModeImpl {
    fn drop(&mut self) {
        self.clear();
    }
}
