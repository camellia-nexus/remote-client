use std::sync::{Arc, RwLock};
use std::time::Duration;

use crate::client::*;
use camellia_remote_protocol::{
    allow_err, bail,
    futures::{SinkExt, StreamExt},
    log,
    message_proto::*,
    protobuf::Message as _,
    rendezvous_proto::ConnType,
    tcp,
    tokio::{self, net::TcpStream, sync::mpsc},
    tokio_util::{
        codec::{BytesCodec, Framed},
        sync::CancellationToken,
    },
    ResultType, Stream,
};

pub const MAX_ACTIVE_TUNNELS_PER_LISTENER: usize = 32;
pub const MAX_GLOBAL_ACTIVE_TUNNELS: usize = 128;
pub const MAX_PRELOGIN_BUFFER_BYTES: usize = 64 * 1024; // 64 KiB
pub const PRELOGIN_DEADLINE: Duration = Duration::from_secs(30);

lazy_static::lazy_static! {
    static ref GLOBAL_TUNNEL_SEMAPHORE: Arc<tokio::sync::Semaphore> =
        Arc::new(tokio::sync::Semaphore::new(MAX_GLOBAL_ACTIVE_TUNNELS));
}

pub fn get_global_available_permits() -> usize {
    GLOBAL_TUNNEL_SEMAPHORE.available_permits()
}

pub struct RdpSessionCredentials {
    pub username: String,
    pub password: zeroize::Zeroizing<String>,
}

pub trait RdpCredentialStore: Send + Sync {
    fn write_credential(&self, target: &str, user: &str, pass: &str) -> Result<(), String>;
    fn delete_credential(&self, target: &str) -> Result<(), String>;
}

#[derive(Default)]
pub struct MockCredStore {
    pub credentials: Arc<std::sync::RwLock<std::collections::HashMap<String, (String, String)>>>,
}

impl MockCredStore {
    pub fn new() -> Self {
        Self {
            credentials: Arc::new(std::sync::RwLock::new(std::collections::HashMap::new())),
        }
    }
}

impl RdpCredentialStore for MockCredStore {
    fn write_credential(&self, target: &str, user: &str, pass: &str) -> Result<(), String> {
        let mut map = self.credentials.write().map_err(|e| e.to_string())?;
        map.insert(target.to_string(), (user.to_string(), pass.to_string()));
        Ok(())
    }

    fn delete_credential(&self, target: &str) -> Result<(), String> {
        let mut map = self.credentials.write().map_err(|e| e.to_string())?;
        map.remove(target);
        Ok(())
    }
}

#[cfg(windows)]
pub struct WinCredStore;

#[cfg(windows)]
mod wincred_ffi {
    use std::os::raw::{c_uchar, c_ulong, c_ushort, c_void};

    #[repr(C)]
    pub struct CREDENTIALW {
        pub flags: c_ulong,
        pub type_: c_ulong,
        pub target_name: *mut c_ushort,
        pub comment: *mut c_ushort,
        pub last_written: [c_ulong; 2],
        pub credential_blob_size: c_ulong,
        pub credential_blob: *mut c_uchar,
        pub persist: c_ulong,
        pub attribute_count: c_ulong,
        pub attributes: *mut c_void,
        pub target_alias: *mut c_ushort,
        pub user_name: *mut c_ushort,
    }

    #[link(name = "advapi32")]
    extern "system" {
        pub fn CredWriteW(credential: *const CREDENTIALW, flags: c_ulong) -> i32;
        pub fn CredDeleteW(target_name: *const c_ushort, type_: c_ulong, flags: c_ulong) -> i32;
    }
}

#[cfg(windows)]
impl RdpCredentialStore for WinCredStore {
    fn write_credential(&self, target: &str, user: &str, pass: &str) -> Result<(), String> {
        use std::ffi::OsStr;
        use std::os::windows::ffi::OsStrExt;

        let mut target_w: Vec<u16> = OsStr::new(target).encode_utf16().chain(Some(0)).collect();
        let mut user_w: Vec<u16> = OsStr::new(user).encode_utf16().chain(Some(0)).collect();
        let pass_w: Vec<u16> = OsStr::new(pass).encode_utf16().collect();
        let pass_bytes = pass_w.len() * std::mem::size_of::<u16>();

        let cred = wincred_ffi::CREDENTIALW {
            flags: 0,
            type_: 1, // CRED_TYPE_GENERIC
            target_name: target_w.as_mut_ptr(),
            comment: std::ptr::null_mut(),
            last_written: [0, 0],
            credential_blob_size: pass_bytes as _,
            credential_blob: pass_w.as_ptr() as *mut _,
            persist: 1, // CRED_PERSIST_SESSION
            attribute_count: 0,
            attributes: std::ptr::null_mut(),
            target_alias: std::ptr::null_mut(),
            user_name: user_w.as_mut_ptr(),
        };

        let ret = unsafe { wincred_ffi::CredWriteW(&cred, 0) };
        if ret != 0 {
            Ok(())
        } else {
            Err(format!(
                "CredWriteW failed: {}",
                std::io::Error::last_os_error()
            ))
        }
    }

    fn delete_credential(&self, target: &str) -> Result<(), String> {
        use std::ffi::OsStr;
        use std::os::windows::ffi::OsStrExt;

        let target_w: Vec<u16> = OsStr::new(target).encode_utf16().chain(Some(0)).collect();
        let ret = unsafe { wincred_ffi::CredDeleteW(target_w.as_ptr(), 1, 0) };
        if ret != 0 {
            Ok(())
        } else {
            Err(format!(
                "CredDeleteW failed: {}",
                std::io::Error::last_os_error()
            ))
        }
    }
}

pub fn default_credential_store() -> Arc<dyn RdpCredentialStore> {
    #[cfg(windows)]
    {
        Arc::new(WinCredStore)
    }
    #[cfg(not(windows))]
    {
        Arc::new(MockCredStore::new())
    }
}

pub struct RdpCredentialGuard {
    store: Arc<dyn RdpCredentialStore>,
    targets: Vec<String>,
}

impl RdpCredentialGuard {
    pub fn new(store: Arc<dyn RdpCredentialStore>, targets: Vec<String>) -> Self {
        Self { store, targets }
    }
}

impl Drop for RdpCredentialGuard {
    fn drop(&mut self) {
        for target in &self.targets {
            let _ = self.store.delete_credential(target);
        }
    }
}

static ALLOCATED_RDP_SLOTS: std::sync::Mutex<Option<std::collections::HashSet<u8>>> =
    std::sync::Mutex::new(None);

pub struct RdpSlotGuard {
    slot: u8,
}

impl RdpSlotGuard {
    pub fn allocate() -> Self {
        let mut lock = ALLOCATED_RDP_SLOTS.lock().unwrap();
        let set = lock.get_or_insert_with(std::collections::HashSet::new);
        for candidate in 2..=254 {
            if set.insert(candidate) {
                return Self { slot: candidate };
            }
        }
        Self { slot: 2 }
    }

    pub fn slot(&self) -> u8 {
        self.slot
    }

    pub fn ip(&self) -> String {
        format!("127.0.0.{}", self.slot)
    }
}

impl Drop for RdpSlotGuard {
    fn drop(&mut self) {
        if let Ok(mut lock) = ALLOCATED_RDP_SLOTS.lock() {
            if let Some(set) = lock.as_mut() {
                set.remove(&self.slot);
            }
        }
    }
}

pub fn run_rdp(
    host: &str,
    port: u16,
    creds: RdpSessionCredentials,
    store: Arc<dyn RdpCredentialStore>,
) -> Option<tokio::task::JoinHandle<()>> {
    let target1 = format!("TERMSRV/{}", host);
    let target2 = format!("TERMSRV/{}:{}", host, port);
    let targets = vec![target1, target2];

    if !creds.username.is_empty() || !creds.password.is_empty() {
        for target in &targets {
            let _ = store.write_credential(target, &creds.username, &creds.password);
        }
    }

    let guard = RdpCredentialGuard::new(store, targets);
    #[allow(unused_variables)]
    let host_port = format!("{}:{}", host, port);

    let handle = tokio::spawn(async move {
        let _guard = guard;
        #[cfg(windows)]
        {
            if let Ok(mut child) = tokio::process::Command::new("mstsc")
                .arg(format!("/v:{}", host_port))
                .spawn()
            {
                let _ = child.wait().await;
            }
        }
        #[cfg(not(windows))]
        {
            let _ = host_port;
        }
    });

    Some(handle)
}

pub async fn listen(
    id: String,
    password: String,
    port: i32,
    interface: impl Interface,
    ui_receiver: mpsc::UnboundedReceiver<Data>,
    key: &str,
    token: &str,
    lc: Arc<RwLock<LoginConfigHandler>>,
    remote_host: String,
    remote_port: i32,
) -> ResultType<()> {
    let slot_guard = if port == 0 {
        Some(RdpSlotGuard::allocate())
    } else {
        None
    };

    let (listener, bind_ip) = if let Some(ref slot) = slot_guard {
        let slot_ip = slot.ip();
        match tcp::new_listener(format!("{}:{}", slot_ip, port), true).await {
            Ok(l) => (l, slot_ip),
            Err(_) => (
                tcp::new_listener(format!("127.0.0.1:{}", port), true).await?,
                "127.0.0.1".to_string(),
            ),
        }
    } else {
        (
            tcp::new_listener(format!("127.0.0.1:{}", port), true).await?,
            "127.0.0.1".to_string(),
        )
    };

    let addr = listener.local_addr()?;
    log::info!("listening on port {:?}", addr);
    let is_rdp = port == 0;
    let _rdp_supervisor = if is_rdp {
        let (rdp_user, rdp_pass) = {
            let guard = lc.read().unwrap();
            let u = guard
                .options
                .get("rdp_username")
                .cloned()
                .unwrap_or_default();
            let p = guard
                .options
                .get("rdp_password")
                .cloned()
                .unwrap_or_default();
            (u, zeroize::Zeroizing::new(p))
        };
        let creds = RdpSessionCredentials {
            username: rdp_user,
            password: rdp_pass,
        };
        run_rdp(&bind_ip, addr.port(), creds, default_credential_store())
    } else {
        None
    };
    let mut ui_receiver = ui_receiver;
    let listener_semaphore = Arc::new(tokio::sync::Semaphore::new(MAX_ACTIVE_TUNNELS_PER_LISTENER));
    let cancel_token = CancellationToken::new();

    loop {
        tokio::select! {
            accept_res = listener.accept() => {
                match accept_res {
                    Ok((forward, addr)) => {
                        log::info!("new connection from {:?}", addr);

                        // Bound active tunnel capacity per listener and globally (RES-024)
                        let global_permit = match GLOBAL_TUNNEL_SEMAPHORE.clone().try_acquire_owned() {
                            Ok(p) => p,
                            Err(_) => {
                                log::warn!(
                                    "Global port forward capacity reached ({} tunnels), dropping connection from {:?}",
                                    MAX_GLOBAL_ACTIVE_TUNNELS,
                                    addr
                                );
                                continue;
                            }
                        };
                        let listener_permit = match listener_semaphore.clone().try_acquire_owned() {
                            Ok(p) => p,
                            Err(_) => {
                                log::warn!(
                                    "Listener port forward capacity reached ({} tunnels), dropping connection from {:?}",
                                    MAX_ACTIVE_TUNNELS_PER_LISTENER,
                                    addr
                                );
                                continue;
                            }
                        };

                        lc.write().unwrap().port_forward = (remote_host.clone(), remote_port);
                        let id = id.clone();
                        let password = password.clone();
                        let mut forward = Framed::new(forward, BytesCodec::new());
                        let mut close_port_forward = false;
                        let tunnel_cancel = cancel_token.child_token();

                        match connect_and_login(
                            &id,
                            &password,
                            &mut ui_receiver,
                            interface.clone(),
                            &mut forward,
                            key,
                            token,
                            is_rdp,
                            &mut close_port_forward,
                            &tunnel_cancel,
                        ).await {
                            Ok(Some(stream)) => {
                                let interface = interface.clone();
                                tokio::spawn(async move {
                                    let _gp = global_permit;
                                    let _lp = listener_permit;
                                    tokio::select! {
                                        _ = tunnel_cancel.cancelled() => {
                                            log::info!("tunnel from {:?} cancelled by listener teardown", addr);
                                        }
                                        res = run_forward(forward, stream) => {
                                            if let Err(err) = res {
                                                interface.msgbox("error", "Error", &err.to_string(), "");
                                            }
                                        }
                                    }
                                    log::info!("connection from {:?} closed", addr);
                                });
                            }
                            _ if close_port_forward => {
                                break;
                            }
                            Err(err) => {
                                interface.on_establish_connection_error(err.to_string());
                            }
                            _ => {}
                        }
                    }
                    Err(e) => {
                        log::error!("port forward listener accept failed: {:?}", e);
                        break;
                    }
                }
            }
            d = ui_receiver.recv() => {
                match d {
                    Some(Data::Close) | None => {
                        log::info!("port forward listener on {:?} received close or channel EOF", addr);
                        break;
                    }
                    Some(Data::NewRDP) => {
                        log::info!("receive run_rdp from ui_receiver");
                        let (rdp_user, rdp_pass) = {
                            let guard = lc.read().unwrap();
                            let u = guard.options.get("rdp_username").cloned().unwrap_or_default();
                            let p = guard.options.get("rdp_password").cloned().unwrap_or_default();
                            (u, zeroize::Zeroizing::new(p))
                        };
                        let creds = RdpSessionCredentials {
                            username: rdp_user,
                            password: rdp_pass,
                        };
                        run_rdp(&bind_ip, addr.port(), creds, default_credential_store());
                    }
                    _ => {}
                }
            }
        }
    }
    cancel_token.cancel();
    Ok(())
}

async fn connect_and_login(
    id: &str,
    password: &str,
    ui_receiver: &mut mpsc::UnboundedReceiver<Data>,
    interface: impl Interface,
    forward: &mut Framed<TcpStream, BytesCodec>,
    key: &str,
    token: &str,
    is_rdp: bool,
    close_port_forward: &mut bool,
    cancel_token: &CancellationToken,
) -> ResultType<Option<Stream>> {
    let conn_type = if is_rdp {
        ConnType::RDP
    } else {
        ConnType::PORT_FORWARD
    };
    let ((mut stream, direct, _pk, _kcp, _stream_type), (feedback, rendezvous_server)) =
        Client::start(id, key, token, conn_type, interface.clone()).await?;
    interface.update_direct(Some(direct));
    if !stream.is_secured() && !crate::common::is_direct_ip_access(id) {
        if !confirm_insecure_connection(&interface, ui_receiver).await {
            *close_port_forward = true;
            return Ok(None);
        }
    }
    let mut buffer = Vec::new();
    let mut received = false;

    let _keep_it = hc_connection(feedback, rendezvous_server, token).await;

    // RES-024: Enforce an immutable absolute deadline for the entire login sequence
    let deadline = tokio::time::Instant::now() + PRELOGIN_DEADLINE;

    loop {
        tokio::select! {
            _ = cancel_token.cancelled() => {
                bail!("Port-forward connection cancelled");
            }
            _ = tokio::time::sleep_until(deadline) => {
                bail!("Port-forward login deadline exceeded (30s)");
            }
            res = stream.next() => match res {
                Some(Ok(bytes)) => {
                    if !received {
                        received = true;
                        interface.update_received(true);
                    }
                    let msg_in = Message::parse_from_bytes(&bytes)?;
                    match msg_in.union {
                        Some(message::Union::Hash(hash)) => {
                            interface.handle_hash(password, hash, &mut stream).await;
                        }
                        Some(message::Union::LoginResponse(lr)) => match lr.union {
                            Some(login_response::Union::Error(err)) => {
                                if !interface.handle_login_error(&err) {
                                    return Ok(None);
                                }
                            }
                            Some(login_response::Union::PeerInfo(pi)) => {
                                interface.handle_peer_info(pi);
                                break;
                            }
                            _ => {}
                        }
                        Some(message::Union::TestDelay(t)) => {
                            interface.handle_test_delay(t, &mut stream).await;
                        }
                        _ => {}
                    }
                }
                Some(Err(err)) => {
                    bail!("Connection closed: {}", err);
                }
                None => {
                    bail!("Reset by the peer");
                }
            },
            d = ui_receiver.recv() => {
                match d {
                    Some(Data::Login((os_username, os_password, password, remember))) => {
                        interface.handle_login_from_ui(os_username, os_password, password, remember, &mut stream).await;
                    }
                    Some(Data::Message(msg)) => {
                        allow_err!(stream.send(&msg).await);
                    }
                    Some(Data::Close) | None => {
                        *close_port_forward = true;
                        return Ok(None);
                    }
                    _ => {}
                }
            },
            res = forward.next(), if buffer.len() < MAX_PRELOGIN_BUFFER_BYTES => {
                if let Some(Ok(bytes)) = res {
                    let to_take = (MAX_PRELOGIN_BUFFER_BYTES - buffer.len()).min(bytes.len());
                    buffer.extend_from_slice(&bytes[..to_take]);
                    if buffer.len() >= MAX_PRELOGIN_BUFFER_BYTES {
                        log::warn!(
                            "Prelogin buffer limit reached ({} bytes), pausing local reads until login succeeds",
                            MAX_PRELOGIN_BUFFER_BYTES
                        );
                    }
                } else {
                    return Ok(None);
                }
            },
        }
    }
    stream.set_raw();
    if !buffer.is_empty() {
        allow_err!(stream.send_bytes(buffer.into()).await);
    }
    Ok(Some(stream))
}

async fn run_forward(forward: Framed<TcpStream, BytesCodec>, stream: Stream) -> ResultType<()> {
    log::info!("new port forwarding connection started");
    let mut forward = forward;
    let mut stream = stream;
    loop {
        tokio::select! {
            res = forward.next() => {
                match res {
                    Some(Ok(bytes)) => {
                        if let Err(e) = stream.send_bytes(bytes.into()).await {
                            log::debug!("port forward stream send failed: {:?}", e);
                            break;
                        }
                    }
                    _ => break,
                }
            },
            res = stream.next() => {
                match res {
                    Some(Ok(bytes)) => {
                        if let Err(e) = forward.send(bytes).await {
                            log::debug!("port forward local socket send failed: {:?}", e);
                            break;
                        }
                    }
                    _ => break,
                }
            },
        }
    }
    Ok(())
}
