#[cfg(not(any(target_os = "android", target_os = "ios")))]
use crate::clipboard::{update_clipboard, ClipboardSide};
#[cfg(not(any(target_os = "ios")))]
use crate::{audio_service, clipboard::CLIPBOARD_INTERVAL, ConnInner, CLIENT_SERVER};
use crate::{
    client::{
        self, new_voice_call_request, AudioWorker, Client, Data, Interface, QualityStatus,
        VideoQueue, VideoQueuePushResult, MAX_DISPLAY_DECODERS, MILLI1, SEC30,
    },
    common::get_default_sound_input,
    ui_session_interface::{InvokeUiSession, OutboundDispatcher, OutboundReceiver, Session},
};

// Empirical no-data window before exposing the restart reconnect state to the UI.
// Restart msgbox text is kept as a legacy UI fallback; Flutter handles the type as a control event.
const RESTART_REMOTE_DEVICE_NO_DATA_TIMEOUT: Duration = Duration::from_secs(5);
const KCP_CLOSE_REASON_FLUSH_DELAY: Duration = Duration::from_millis(30);

fn remove_local_empty_dir_result(id: i32, path: String) -> Data {
    let err = fs::remove_all_empty_dir(&fs::get_path(&path))
        .err()
        .map(|err| err.to_string());
    Data::RemoveDirResult((id, err))
}
#[cfg(feature = "unix-file-copy-paste")]
use crate::{clipboard::try_empty_clipboard_files, clipboard_file::unix_file_clip};
use camellia_remote_protocol::{
    allow_err,
    config::{self, LocalConfig, PeerConfig, TransferSerde},
    fs::{
        self, can_enable_overwrite_detection, get_job, get_string, new_send_confirm,
        DigestCheckResult, RemoveJobMeta,
    },
    get_time, log,
    message_proto::{permission_info::Permission, *},
    protobuf::Message as _,
    rendezvous_proto::ConnType,
    timeout,
    tokio::{
        self,
        sync::mpsc,
        time::{self, Duration, Instant},
    },
    Stream,
};
#[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
use camellia_remote_protocol::{tokio::sync::Mutex as TokioMutex, ResultType};
#[cfg(any(
    target_os = "windows",
    all(target_os = "macos", feature = "unix-file-copy-paste")
))]
use clipboard::ContextSend;
use scrap::CodecFormat;
use std::{
    collections::{HashMap, HashSet, VecDeque},
    ffi::c_void,
    num::NonZeroI64,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
        Arc, RwLock,
    },
};

static NEXT_SESSION_GENERATION: AtomicU64 = AtomicU64::new(1);

// ============================================================================
// RES-014: Voice Call Bounded Queue & Reconfigurable Worker
// ============================================================================

pub const MAX_VOICE_OUTBOUND_QUEUE_FRAMES: usize = 32;
pub const MAX_VOICE_OUTBOUND_QUEUE_BYTES: usize = 64 * 1024; // 64 KiB

pub struct VoiceCallWorker {
    #[cfg(not(any(target_os = "ios")))]
    pub conn_inner: ConnInner,
    pub cancel_token: Arc<AtomicBool>,
    pub join_handle: Option<std::thread::JoinHandle<()>>,
}

impl VoiceCallWorker {
    pub fn stop(&mut self) {
        self.stop_with_timeout(Duration::from_millis(500));
    }

    pub fn stop_with_timeout(&mut self, timeout: Duration) {
        #[cfg(not(any(target_os = "ios")))]
        {
            // Step 1: Synchronously unsubscribe from CLIENT_SERVER
            CLIENT_SERVER.write().unwrap().subscribe(
                audio_service::NAME,
                self.conn_inner.clone(),
                false,
            );

            // Step 2: Synchronously release voice call from VoiceCallManager if owner
            crate::server::voice_call_manager::VOICE_CALL_MANAGER
                .release_call_if_owner(self.conn_inner.id());
        }

        // Step 3: Trigger cancellation token
        self.cancel_token.store(true, Ordering::SeqCst);

        // Step 4: Join worker thread within timeout
        if let Some(handle) = self.join_handle.take() {
            let (tx, rx) = std::sync::mpsc::channel();
            let joiner = std::thread::spawn(move || {
                let res = handle.join();
                let _ = tx.send(res);
            });
            match rx.recv_timeout(timeout) {
                Ok(Ok(())) => {
                    let _ = joiner.join();
                    log::debug!("Voice call worker joined cleanly");
                }
                Ok(Err(_panic)) => {
                    let _ = joiner.join();
                    log::warn!("Voice call worker panicked on join");
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    log::warn!(
                        "Voice call worker join exceeded deadline of {:?}; detached",
                        timeout
                    );
                }
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {}
            }
        }
    }
}

impl Drop for VoiceCallWorker {
    fn drop(&mut self) {
        self.stop();
    }
}

pub struct Remote<T: InvokeUiSession> {
    handler: Session<T>,
    audio_worker: Option<AudioWorker>,
    receiver: OutboundReceiver,
    sender: Arc<OutboundDispatcher>,
    voice_call_worker: Option<VoiceCallWorker>,
    voice_call_request_timestamp: Option<NonZeroI64>,
    read_jobs: Vec<fs::TransferJob>,
    write_jobs: Vec<fs::TransferJob>,
    remove_jobs: HashMap<i32, RemoveJob>,
    timer: crate::RustDeskInterval,
    last_update_jobs_status: (Instant, HashMap<i32, u64>),
    is_connected: bool,
    first_frame: bool,
    #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
    client_conn_id: i32, // used for file clipboard
    data_count: Arc<AtomicUsize>,
    video_format: CodecFormat,
    elevation_requested: bool,
    peer_info: ParsedPeerInfo,
    video_threads: HashMap<usize, VideoThread>,
    allowed_displays: HashSet<usize>,
    chroma: Arc<RwLock<Option<Chroma>>>,
    last_record_state: bool,
    sent_close_reason: bool,
    pub connection_generation: u64,
}

#[derive(Default)]
struct ParsedPeerInfo {
    platform: String,
    is_installed: bool,
    idd_impl: String,
    support_view_camera: bool,
    support_terminal: bool,
}

impl ParsedPeerInfo {
    fn is_support_virtual_display(&self) -> bool {
        self.is_installed
            && self.platform == "Windows"
            && (self.idd_impl == "camellia_idd" || self.idd_impl == "amyuni_idd")
    }
}

impl<T: InvokeUiSession> Remote<T> {
    pub fn new(
        handler: Session<T>,
        receiver: OutboundReceiver,
        sender: Arc<OutboundDispatcher>,
    ) -> Self {
        Self {
            handler,
            audio_worker: None,
            receiver,
            sender,
            read_jobs: Vec::new(),
            write_jobs: Vec::new(),
            remove_jobs: Default::default(),
            timer: crate::rustdesk_interval(time::interval(SEC30)),
            last_update_jobs_status: (Instant::now(), Default::default()),
            is_connected: false,
            first_frame: false,
            #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
            client_conn_id: 0,
            data_count: Arc::new(AtomicUsize::new(0)),
            video_format: CodecFormat::Unknown,
            voice_call_worker: None,
            voice_call_request_timestamp: None,
            elevation_requested: false,
            peer_info: Default::default(),
            video_threads: Default::default(),
            allowed_displays: Default::default(),
            chroma: Default::default(),
            last_record_state: false,
            sent_close_reason: false,
            connection_generation: NEXT_SESSION_GENERATION.fetch_add(1, Ordering::SeqCst),
        }
    }

    pub async fn io_loop(&mut self, key: &str, token: &str, round: u32) {
        #[cfg(target_os = "windows")]
        let _file_clip_context_holder = {
            // `is_port_forward()` will not reach here, but we still check it for clarity.
            if self.handler.is_default() {
                // It is ok to call this function multiple times.
                ContextSend::enable(true);
                Some(crate::SimpleCallOnReturn {
                    b: true,
                    f: Box::new(|| {
                        // Disable file copy/paste once the last controlling session exits.
                        // It's better to check if the peers are windows(support file copy&paste), but it's not necessary.
                        #[cfg(feature = "flutter")]
                        if !crate::flutter::sessions::has_sessions_running(ConnType::DEFAULT_CONN) {
                            ContextSend::enable(false);
                        };
                    }),
                })
            } else {
                None
            }
        };

        let mut received = false;
        let conn_type = if self.handler.is_file_transfer() {
            ConnType::FILE_TRANSFER
        } else if self.handler.is_view_camera() {
            ConnType::VIEW_CAMERA
        } else if self.handler.is_terminal() {
            ConnType::TERMINAL
        } else {
            ConnType::default()
        };

        let cancel_token = self
            .handler
            .connection_round_state
            .lock()
            .unwrap()
            .cancel_token();

        let id = self.handler.get_id();
        let start_res = tokio::select! {
            _ = cancel_token.cancelled() => {
                log::info!("Connection round {} cancelled before start completed", round);
                self.handle_disconnected(round);
                return;
            }
            res = Client::start(
                &id,
                key,
                token,
                conn_type,
                self.handler.clone(),
            ) => res,
        };

        match start_res {
            Ok(((mut peer, direct, pk, kcp, stream_type), (feedback, rendezvous_server))) => {
                // RES-034: Set 10-second send timeout on peer stream
                peer.set_send_timeout(10_000);
                self.handler
                    .connection_round_state
                    .lock()
                    .unwrap()
                    .set_connected();
                let is_secured = peer.is_secured();
                self.handler
                    .set_connection_type(is_secured, direct, stream_type); // flutter -> connection_ready
                if !is_secured
                    && !crate::common::is_direct_ip_access(&self.handler.get_id())
                    && !client::confirm_insecure_connection(&self.handler, &mut self.receiver).await
                {
                    self.send_close_reason(&mut peer, "").await;
                    if kcp.is_some() {
                        tokio::time::sleep(KCP_CLOSE_REASON_FLUSH_DELAY).await;
                    }
                    self.handle_disconnected(round);
                    return;
                }
                self.handler.update_direct(Some(direct));
                if conn_type == ConnType::DEFAULT_CONN || conn_type == ConnType::VIEW_CAMERA {
                    self.handler
                        .set_fingerprint(crate::common::pk_to_fingerprint(pk.unwrap_or_default()));
                }

                // just build for now
                #[cfg(not(any(target_os = "windows", feature = "unix-file-copy-paste")))]
                let (_tx_holder, mut rx_clip_client) = mpsc::unbounded_channel::<i32>();

                #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
                let (_tx_holder, rx) = mpsc::channel(1);
                #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
                let mut rx_clip_client_holder = (Arc::new(TokioMutex::new(rx)), None);
                #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
                {
                    if self.handler.is_default() {
                        (self.client_conn_id, rx_clip_client_holder.0) =
                            clipboard::get_rx_cliprdr_client(&self.handler.get_id());
                        log::debug!("get cliprdr client for conn_id {}", self.client_conn_id);
                        let client_conn_id = self.client_conn_id;
                        rx_clip_client_holder.1 = Some(crate::SimpleCallOnReturn {
                            b: true,
                            f: Box::new(move || {
                                clipboard::operation::ClipboardOpGuard::abort_for_connection(
                                    client_conn_id,
                                    0,
                                );
                                clipboard::remove_channel_by_conn_id(client_conn_id);
                            }),
                        });
                    };
                }
                #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
                let mut rx_clip_client = rx_clip_client_holder.0.lock().await;

                let mut status_timer =
                    crate::rustdesk_interval(time::interval(Duration::new(1, 0)));
                let mut fps_instant = Instant::now();

                let _keep_it = client::hc_connection(feedback, rendezvous_server, token).await;
                let mut last_recv_time = Instant::now();

                loop {
                    tokio::select! {
                        _ = cancel_token.cancelled() => {
                            log::info!("Connection round {} cancelled; breaking io_loop immediately", round);
                            break;
                        }
                        res = peer.next() => {
                            if let Some(res) = res {
                                match res {
                                    Err(err) => {
                                        self.handler.on_establish_connection_error(err.to_string());
                                        break;
                                    }
                                    Ok(ref bytes) => {
                                        last_recv_time = Instant::now();
                                        if !received {
                                            received = true;
                                            self.handler.update_received(true);
                                        }
                                        self.data_count.fetch_add(bytes.len(), Ordering::Relaxed);
                                        if !self.handle_msg_from_peer(bytes, &mut peer).await {
                                            break
                                        }
                                    }
                                }
                            } else {
                                if self.handler.is_restarting_remote_device() {
                                    log::info!("Restart remote device");
                                    self.handler.msgbox("restarting", "Restarting remote device", "Connection in progress. Please wait.", "");
                                } else {
                                    log::info!("Reset by the peer");
                                    self.handler.msgbox("error", "Connection Error", "Reset by the peer", "");
                                }
                                break;
                            }
                        }
                        d = self.receiver.recv() => {
                            if let Some(d) = d {
                                if self.handler.connection_round_state.lock().unwrap().is_round_gt(round) {
                                    log::warn!("Dropping UI message for stale round {}", round);
                                    break;
                                }
                                if !self.handle_msg_from_ui(d, &mut peer).await {
                                    break;
                                }
                            }
                        }
                        _msg = rx_clip_client.recv() => {
                            #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
                            self.handle_local_clipboard_msg(&mut peer, _msg).await;
                        }
                        _ = self.timer.tick() => {
                            if last_recv_time.elapsed() >= SEC30 {
                                self.handler.msgbox("error", "Connection Error", "Timeout", "");
                                break;
                            }
                            if !self.read_jobs.is_empty() {
                                if let Err(err) = fs::handle_read_jobs(&mut self.read_jobs, &mut peer).await {
                                    self.handler.msgbox("error", "Connection Error", &err.to_string(), "");
                                    break;
                                }
                                self.update_jobs_status();
                            } else {
                                self.timer = crate::rustdesk_interval(time::interval_at(Instant::now() + SEC30, SEC30));
                            }
                        }
                        _ = status_timer.tick() => {
                            if self.handler.is_restarting_remote_device()
                                && last_recv_time.elapsed() >= RESTART_REMOTE_DEVICE_NO_DATA_TIMEOUT
                            {
                                self.handler.msgbox("restarting-show", "Restarting remote device", "Connection in progress. Please wait.", "");
                                break;
                            }
                            let elapsed = fps_instant.elapsed().as_millis();
                            if elapsed < 1000 {
                                continue;
                            }
                            fps_instant = Instant::now();
                            let mut speed = self.data_count.swap(0, Ordering::Relaxed);
                            speed = speed * 1000 / elapsed as usize;
                            let speed = format!("{:.2}kB/s", speed as f32 / 1024 as f32);

                            let fps = self.video_threads.iter().map(|(k, v)| {
                                // Correcting the inaccuracy of status_timer
                                (k.clone(), (*v.frame_count.read().unwrap() as i32) * 1000 / elapsed as i32)
                            }).collect::<HashMap<usize, i32>>();
                            self.video_threads.iter().for_each(|(_, v)| {
                                *v.frame_count.write().unwrap() = 0;
                            });
                            self.fps_control(direct, fps.clone());
                            let chroma = self.chroma.read().unwrap().clone();
                            let chroma = match chroma {
                                Some(Chroma::I444) => "4:4:4",
                                Some(Chroma::I420) => "4:2:0",
                                None => "-",
                            };
                            let chroma = Some(chroma.to_string());
                            let codec_format = if self.video_format == CodecFormat::Unknown {
                                None
                            } else {
                                Some(self.video_format.clone())
                            };
                            self.handler.update_quality_status(QualityStatus {
                                speed: Some(speed),
                                fps,
                                chroma,
                                codec_format,
                                ..Default::default()
                            });
                        }
                    }
                }
                // Stop client audio, voice call, and video decoders deterministically.
                self.stop_voice_call();
                if let Some(mut worker) = self.audio_worker.take() {
                    worker.stop();
                }
                self.teardown_video_threads();
                if kcp.is_some() {
                    // Send the close reason if it hasn't been sent yet, as KCP cannot detect the socket close event.
                    self.send_close_reason(&mut peer, "kcp").await;
                    // KCP does not send messages immediately, so wait to ensure the last message is sent.
                    // 1ms works in my test, but 30ms is more reliable.
                    tokio::time::sleep(KCP_CLOSE_REASON_FLUSH_DELAY).await;
                }
            }
            Err(err) => {
                self.handler.on_establish_connection_error(err.to_string());
            }
        }
        self.handle_disconnected(round);
    }

    fn handle_disconnected(&self, round: u32) {
        // set_disconnected_ok is used to check if new connection round is started.
        let _set_disconnected_ok = self
            .handler
            .connection_round_state
            .lock()
            .unwrap()
            .set_disconnected(round);

        #[cfg(not(target_os = "ios"))]
        if self.handler.is_default() && _set_disconnected_ok {
            Client::try_stop_clipboard();
        }

        #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
        if self.handler.is_default() && _set_disconnected_ok {
            // Linux client cleanup runs synchronously in try_stop_clipboard() before FUSE is
            // unmounted. Keep this async path for other file-clipboard platforms.
            crate::clipboard::try_empty_clipboard_files(ClipboardSide::Client, self.client_conn_id);
        }
    }

    #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
    async fn handle_local_clipboard_msg(
        &self,
        peer: &mut Stream,
        msg: Option<clipboard::ClipboardFile>,
    ) {
        match msg {
            Some(clip) => match clip {
                clipboard::ClipboardFile::NotifyCallback {
                    r#type,
                    title,
                    text,
                } => {
                    self.handler.msgbox(&r#type, &title, &text, "");
                }
                _ => {
                    let is_stopping_allowed = clip.is_stopping_allowed();
                    let server_file_transfer_enabled =
                        *self.handler.server_file_transfer_enabled.read().unwrap();
                    let file_transfer_enabled =
                        self.handler.lc.read().unwrap().enable_file_copy_paste.v;
                    let view_only = self.handler.lc.read().unwrap().view_only.v;
                    let stop = is_stopping_allowed
                        && (view_only
                            || !self.is_connected
                            || !(server_file_transfer_enabled && file_transfer_enabled));
                    log::debug!(
                        "Process clipboard message from system, stop: {}, is_stopping_allowed: {}, view_only: {}, server_file_transfer_enabled: {}, file_transfer_enabled: {}",
                        view_only, stop, is_stopping_allowed, server_file_transfer_enabled, file_transfer_enabled
                    );
                    if stop {
                        #[cfg(target_os = "windows")]
                        {
                            ContextSend::set_is_stopped();
                        }
                    } else {
                        #[cfg(target_os = "windows")]
                        if let Err(e) = ContextSend::make_sure_enabled() {
                            log::error!("failed to restart clipboard context: {}", e);
                            // to-do: Show msgbox with "Don't show again" option
                        };
                        log::debug!("Send system clipboard message to remote");
                        let msg = crate::clipboard_file::clip_2_msg(clip);
                        allow_err!(peer.send(&msg).await);
                    }
                }
            },
            None => {
                // unreachable!()
            }
        }
    }

    fn handle_job_status(&mut self, id: i32, file_num: i32, err: Option<String>) {
        if let Some(job) = self.remove_jobs.get_mut(&id) {
            if job.no_confirm {
                let file_num = (file_num + 1) as usize;
                if file_num < job.files.len() {
                    let path = format!("{}{}{}", job.path, job.sep, job.files[file_num].name);
                    self.sender
                        .send(Data::RemoveFile((id, path, file_num as i32, job.is_remote)))
                        .ok();
                    let elapsed = job.last_update_job_status.elapsed().as_millis() as i32;
                    if elapsed >= 1000 {
                        job.last_update_job_status = Instant::now();
                    } else {
                        return;
                    }
                } else {
                    self.remove_jobs.remove(&id);
                }
            }
        }
        if let Some(err) = err {
            self.handler.job_error(id, err, file_num);
        } else {
            self.handler.job_done(id, file_num);
        }
    }

    fn file_transfer_protocol_error(&self) -> Option<String> {
        let version = self
            .handler
            .lc
            .read()
            .unwrap()
            .file_transfer_protocol_version;
        fs::validate_file_transfer_protocol_version(version)
            .err()
            .map(|err| err.to_string())
    }

    fn stop_voice_call(&mut self) {
        if let Some(mut worker) = self.voice_call_worker.take() {
            worker.stop();
        }
    }

    // Start a voice call recorder, records audio and sends to remote peer
    fn start_voice_call(&mut self) -> Option<VoiceCallWorker> {
        if self.handler.is_file_transfer()
            || self.handler.is_port_forward()
            || self.handler.is_terminal()
        {
            return None;
        }
        // iOS does not have this server.
        #[cfg(not(any(target_os = "ios")))]
        {
            let conn_id = CLIENT_SERVER.write().unwrap().get_new_id();
            let _ = crate::server::voice_call_manager::VOICE_CALL_MANAGER.try_register_call(
                conn_id,
                crate::server::voice_call_manager::generate_call_id(),
                1,
            );
            crate::server::voice_call_manager::VOICE_CALL_MANAGER
                .set_voice_call_input_device(get_default_sound_input(), Some(conn_id));
            let (tx_audio_data, mut rx_audio_data) =
                camellia_remote_protocol::tokio::sync::mpsc::unbounded_channel();
            let client_conn_inner = ConnInner::new(conn_id, Some(tx_audio_data), None);
            CLIENT_SERVER.write().unwrap().subscribe(
                audio_service::NAME,
                client_conn_inner.clone(),
                true,
            );
            let tx_audio = self.sender.clone();
            let cancel_token = Arc::new(AtomicBool::new(false));
            let cancel = cancel_token.clone();

            let handle = std::thread::Builder::new()
                .name("voice_call_worker".to_string())
                .spawn(move || {
                    let rt = match camellia_remote_protocol::tokio::runtime::Builder::new_current_thread()
                        .enable_all()
                        .build()
                    {
                        Ok(rt) => rt,
                        Err(e) => {
                            log::error!("Failed to create voice call runtime: {}", e);
                            return;
                        }
                    };

                    rt.block_on(async move {
                        let mut outbound_frames: usize = 0;
                        let mut outbound_bytes: usize = 0;
                        let mut frame_queue: VecDeque<usize> = VecDeque::new();

                        while !cancel.load(Ordering::Relaxed) {
                            camellia_remote_protocol::tokio::select! {
                                biased;
                                item = rx_audio_data.recv() => {
                                    match item {
                                        Some((_instant, msg)) => {
                                            match &msg.union {
                                                Some(message::Union::AudioFrame(frame)) => {
                                                    let frame_len = frame.data.len();
                                                    // Congestion control: drop oldest when outbound queue exceeds limits
                                                    while !frame_queue.is_empty() && (
                                                        outbound_frames >= MAX_VOICE_OUTBOUND_QUEUE_FRAMES
                                                        || outbound_bytes + frame_len > MAX_VOICE_OUTBOUND_QUEUE_BYTES
                                                    ) {
                                                        if let Some(old_len) = frame_queue.pop_front() {
                                                            outbound_frames = outbound_frames.saturating_sub(1);
                                                            outbound_bytes = outbound_bytes.saturating_sub(old_len);
                                                        }
                                                    }

                                                    outbound_frames += 1;
                                                    outbound_bytes += frame_len;
                                                    frame_queue.push_back(frame_len);

                                                    let mut out_msg = Message::new();
                                                    out_msg.set_audio_frame(frame.clone());
                                                    if tx_audio.send(Data::Message(out_msg)).is_err() {
                                                        log::debug!("UI sender disconnected; exiting voice call worker");
                                                        break;
                                                    }
                                                }
                                                Some(message::Union::Misc(misc)) => {
                                                    let mut out_msg = Message::new();
                                                    out_msg.set_misc(misc.clone());
                                                    if tx_audio.send(Data::Message(out_msg)).is_err() {
                                                        break;
                                                    }
                                                }
                                                _ => {}
                                            }
                                        }
                                        None => {
                                            log::debug!("Voice call audio stream closed; exiting worker");
                                            break;
                                        }
                                    }
                                }
                                _ = camellia_remote_protocol::tokio::time::sleep(Duration::from_millis(100)) => {
                                    // Periodic cancellation check while idle, 0.0% CPU
                                }
                            }
                        }
                        log::info!("Voice call audio worker exited cleanly");
                    });
                })
                .expect("Failed to spawn voice call worker thread");

            Some(VoiceCallWorker {
                conn_inner: client_conn_inner,
                cancel_token,
                join_handle: Some(handle),
            })
        }
        #[cfg(target_os = "ios")]
        {
            None
        }
    }

    async fn send_close_reason(&mut self, peer: &mut Stream, reason: &str) {
        if self.sent_close_reason {
            return;
        }
        let mut misc = Misc::new();
        misc.set_close_reason(reason.to_owned());
        let mut msg = Message::new();
        msg.set_misc(misc);
        allow_err!(peer.send(&msg).await);
        self.sent_close_reason = true;
    }

    async fn handle_msg_from_ui(&mut self, data: Data, peer: &mut Stream) -> bool {
        match data {
            Data::Close => {
                self.send_close_reason(peer, "").await;
                return false;
            }
            Data::Login((os_username, os_password, password, remember)) => {
                self.handler
                    .handle_login_from_ui(os_username, os_password, password, remember, peer)
                    .await;
            }
            Data::Message(msg) => {
                match &msg.union {
                    Some(message::Union::Misc(misc)) => match misc.union {
                        Some(misc::Union::RefreshVideo(_)) => {
                            self.video_threads.iter().for_each(|(_, v)| {
                                v.queue.request_refresh();
                            });
                        }
                        Some(misc::Union::RefreshVideoDisplay(display)) => {
                            if let Some(v) = self.video_threads.get_mut(&(display as usize)) {
                                v.queue.request_refresh();
                            }
                        }
                        _ => {}
                    },
                    _ => {}
                }
                allow_err!(peer.send(&msg).await);
            }
            Data::SendFiles((id, r#type, path, to, file_num, include_hidden, is_remote)) => {
                if let Some(err) = self.file_transfer_protocol_error() {
                    self.handle_job_status(id, file_num, Some(err));
                    return true;
                }
                log::info!("send files, is remote {}", is_remote);
                let od = can_enable_overwrite_detection(self.handler.lc.read().unwrap().version);
                if is_remote {
                    log::debug!("New job {}, write to {} from remote {}", id, to, path);
                    let to = match r#type {
                        fs::JobType::Generic => fs::DataSource::FilePath(PathBuf::from(&to)),
                        fs::JobType::Printer => {
                            let printer_name =
                                self.handler.printer_names.read().unwrap().get(&id).cloned();
                            match crate::client::print_dispatcher::PrintDispatcher::global()
                                .register_job(id, self.connection_generation, printer_name, 0)
                            {
                                Ok(spool_path) => fs::DataSource::FilePath(spool_path),
                                Err(err) => {
                                    log::error!("Print job registration failed for {id}: {err}");
                                    self.handle_job_status(id, file_num, Some(err.to_string()));
                                    return true;
                                }
                            }
                        }
                    };
                    self.write_jobs.push(fs::TransferJob::new_write(
                        id,
                        r#type,
                        path.clone(),
                        to,
                        file_num,
                        include_hidden,
                        is_remote,
                        od,
                    ));
                    allow_err!(
                        peer.send(&fs::new_send(id, r#type, path, file_num, include_hidden))
                            .await
                    );
                } else {
                    match fs::TransferJob::new_read(
                        id,
                        r#type,
                        to.clone(),
                        fs::DataSource::FilePath(PathBuf::from(&path)),
                        file_num,
                        include_hidden,
                        is_remote,
                        od,
                    ) {
                        Err(err) => {
                            self.handle_job_status(id, -1, Some(err.to_string()));
                        }
                        Ok(job) => {
                            log::debug!(
                                "New job {}, read {} to remote {}, {} files",
                                id,
                                path,
                                to,
                                job.files().len()
                            );
                            self.handler.update_folder_files(
                                job.id(),
                                job.files(),
                                path,
                                !is_remote,
                                true,
                            );
                            #[cfg(not(windows))]
                            let files = job.files().clone();
                            #[cfg(windows)]
                            let mut files = job.files().clone();
                            #[cfg(windows)]
                            if self.handler.peer_platform() != "Windows" {
                                // peer is not windows, need transform \ to /
                                fs::transform_windows_path(&mut files);
                            }
                            let total_size = job.total_size();
                            self.read_jobs.push(job);
                            self.timer = crate::rustdesk_interval(time::interval(MILLI1));
                            allow_err!(
                                peer.send(&fs::new_receive(id, to, file_num, files, total_size))
                                    .await
                            );
                        }
                    }
                }
            }
            Data::AddJob((id, r#type, path, to, file_num, include_hidden, is_remote)) => {
                if let Some(err) = self.file_transfer_protocol_error() {
                    self.handle_job_status(id, file_num, Some(err));
                    return true;
                }
                let od = can_enable_overwrite_detection(self.handler.lc.read().unwrap().version);
                if is_remote {
                    log::debug!(
                        "new write waiting job {}, write to {} from remote {}",
                        id,
                        to,
                        path
                    );
                    let mut job = fs::TransferJob::new_write(
                        id,
                        r#type,
                        path.clone(),
                        fs::DataSource::FilePath(PathBuf::from(&to)),
                        file_num,
                        include_hidden,
                        is_remote,
                        od,
                    );
                    job.is_last_job = true;
                    self.write_jobs.push(job);
                } else {
                    match fs::TransferJob::new_read(
                        id,
                        r#type,
                        to.clone(),
                        fs::DataSource::FilePath(PathBuf::from(&path)),
                        file_num,
                        include_hidden,
                        is_remote,
                        od,
                    ) {
                        Err(err) => {
                            self.handle_job_status(id, -1, Some(err.to_string()));
                        }
                        Ok(mut job) => {
                            log::debug!(
                                "new read waiting job {}, read {} to remote {}, {} files",
                                id,
                                path,
                                to,
                                job.files().len()
                            );
                            self.handler.update_folder_files(
                                job.id(),
                                job.files(),
                                path,
                                !is_remote,
                                true,
                            );
                            job.is_last_job = true;
                            self.read_jobs.push(job);
                            self.timer = crate::rustdesk_interval(time::interval(MILLI1));
                        }
                    }
                }
            }
            Data::ResumeJob((id, is_remote)) => {
                if let Some(err) = self.file_transfer_protocol_error() {
                    self.handle_job_status(id, -1, Some(err));
                    return true;
                }
                if is_remote {
                    if let Some(job) = get_job(id, &mut self.write_jobs) {
                        job.is_last_job = false;
                        job.is_resume = true;
                        allow_err!(
                            peer.send(&fs::new_send(
                                id,
                                fs::JobType::Generic,
                                job.remote.clone(),
                                job.file_num,
                                job.show_hidden
                            ))
                            .await
                        );
                    }
                } else {
                    if let Some(job) = get_job(id, &mut self.read_jobs) {
                        match &job.data_source {
                            fs::DataSource::FilePath(_p) => {
                                job.is_last_job = false;
                                job.is_resume = true;
                                job.set_finished_size_on_resume();
                                #[cfg(not(windows))]
                                let files = job.files().clone();
                                #[cfg(windows)]
                                let mut files = job.files().clone();
                                #[cfg(windows)]
                                if self.handler.peer_platform() != "Windows" {
                                    // peer is not windows, need transform \ to /
                                    fs::transform_windows_path(&mut files);
                                }
                                allow_err!(
                                    peer.send(&fs::new_receive(
                                        id,
                                        job.remote.clone(),
                                        job.file_num,
                                        files,
                                        job.total_size(),
                                    ))
                                    .await
                                );
                            }
                            fs::DataSource::MemoryCursor(_) => {
                                // unreachable!()
                                log::error!("Resume job with memory cursor");
                            }
                        }
                    }
                }
            }
            Data::SetNoConfirm(id) => {
                if let Some(job) = self.remove_jobs.get_mut(&id) {
                    job.no_confirm = true;
                }
            }
            Data::ConfirmDeleteFiles((id, file_num)) => {
                if let Some(job) = self.remove_jobs.get_mut(&id) {
                    let i = file_num as usize;
                    if i < job.files.len() {
                        self.handler.ui_handler.confirm_delete_files(
                            id,
                            file_num,
                            job.files[i].name.clone(),
                        );
                    }
                }
            }
            Data::SetConfirmOverrideFile((id, file_num, need_override, remember, is_upload)) => {
                let req = FileTransferSendConfirmRequest {
                    id,
                    file_num,
                    union: if need_override {
                        Some(file_transfer_send_confirm_request::Union::OffsetBytes(0))
                    } else {
                        Some(file_transfer_send_confirm_request::Union::Skip(true))
                    },
                    ..Default::default()
                };
                let confirmation = {
                    let jobs = if is_upload {
                        &mut self.read_jobs
                    } else {
                        &mut self.write_jobs
                    };
                    if let Some(job) = fs::get_job(id, jobs) {
                        if remember {
                            job.set_overwrite_strategy(Some(need_override));
                        }
                        Some(if job.confirm(&req).await {
                            Ok(())
                        } else {
                            Err(job
                                .job_error()
                                .unwrap_or_else(|| "file transfer confirmation failed".to_owned()))
                        })
                    } else {
                        None
                    }
                };
                let Some(confirmation) = confirmation else {
                    return true;
                };
                match confirmation {
                    Ok(()) if !is_upload => {
                        let mut msg = Message::new();
                        let mut file_action = FileAction::new();
                        file_action.set_send_confirm(req);
                        msg.set_file_action(file_action);
                        allow_err!(peer.send(&msg).await);
                    }
                    Ok(()) => {}
                    Err(err) => {
                        if is_upload {
                            let _ = fs::remove_job(id, &mut self.read_jobs);
                        } else {
                            let _ = fs::remove_job(id, &mut self.write_jobs);
                        }
                        allow_err!(peer.send(&fs::new_error(id, &err, file_num)).await);
                        self.handle_job_status(id, file_num, Some(err));
                    }
                }
            }
            Data::RemoveDirAll((id, path, is_remote, include_hidden)) => {
                let sep = self.handler.get_path_sep(is_remote);
                if is_remote {
                    let mut msg_out = Message::new();
                    let mut file_action = FileAction::new();
                    file_action.set_all_files(ReadAllFiles {
                        id,
                        path: path.clone(),
                        include_hidden,
                        ..Default::default()
                    });
                    msg_out.set_file_action(file_action);
                    allow_err!(peer.send(&msg_out).await);
                    self.remove_jobs
                        .insert(id, RemoveJob::new(Vec::new(), path, sep, is_remote));
                } else {
                    match fs::get_recursive_files(&path, include_hidden) {
                        Ok(entries) => {
                            self.handler.update_folder_files(
                                id,
                                &entries,
                                path.clone(),
                                !is_remote,
                                false,
                            );
                            self.remove_jobs
                                .insert(id, RemoveJob::new(entries, path, sep, is_remote));
                        }
                        Err(err) => {
                            self.handle_job_status(id, -1, Some(err.to_string()));
                        }
                    }
                }
            }
            Data::CancelJob(id) => {
                self.cancel_transfer_job(id, peer).await;
            }
            Data::RemoveDir((id, path, is_remote)) => {
                if is_remote {
                    let mut msg_out = Message::new();
                    let mut file_action = FileAction::new();
                    file_action.set_remove_dir(FileRemoveDir {
                        id,
                        path,
                        recursive: true,
                        ..Default::default()
                    });
                    msg_out.set_file_action(file_action);
                    allow_err!(peer.send(&msg_out).await);
                } else {
                    let sender = self.sender.clone();
                    drop(tokio::task::spawn_blocking(move || {
                        allow_err!(sender.send(remove_local_empty_dir_result(id, path)));
                    }));
                }
            }
            Data::RemoveDirResult((id, err)) => self.handle_job_status(id, -1, err),
            Data::RemoveFile((id, path, file_num, is_remote)) => {
                if is_remote {
                    let mut msg_out = Message::new();
                    let mut file_action = FileAction::new();
                    file_action.set_remove_file(FileRemoveFile {
                        id,
                        path,
                        file_num,
                        ..Default::default()
                    });
                    msg_out.set_file_action(file_action);
                    allow_err!(peer.send(&msg_out).await);
                } else {
                    match fs::remove_file(&path) {
                        Err(err) => {
                            self.handle_job_status(id, file_num, Some(err.to_string()));
                        }
                        Ok(()) => {
                            self.handle_job_status(id, file_num, None);
                        }
                    }
                }
            }
            Data::CreateDir((id, path, is_remote)) => {
                if is_remote {
                    let mut msg_out = Message::new();
                    let mut file_action = FileAction::new();
                    file_action.set_create(FileDirCreate {
                        id,
                        path,
                        ..Default::default()
                    });
                    msg_out.set_file_action(file_action);
                    allow_err!(peer.send(&msg_out).await);
                } else {
                    match fs::create_dir(&path) {
                        Err(err) => {
                            self.handle_job_status(id, -1, Some(err.to_string()));
                        }
                        Ok(()) => {
                            self.handle_job_status(id, -1, None);
                        }
                    }
                }
            }
            Data::RenameFile((id, path, new_name, is_remote)) => {
                if is_remote {
                    let mut msg_out = Message::new();
                    let mut file_action = FileAction::new();
                    file_action.set_rename(FileRename {
                        id,
                        path,
                        new_name,
                        ..Default::default()
                    });
                    msg_out.set_file_action(file_action);
                    allow_err!(peer.send(&msg_out).await);
                } else {
                    let err = fs::rename_file(&path, &new_name)
                        .err()
                        .map(|e| e.to_string());
                    self.handle_job_status(id, -1, err);
                }
            }
            Data::RecordScreen(start) => {
                self.handler.lc.write().unwrap().record_state = start;
                self.update_record_state();
            }
            Data::RecordScreenFailed(err) => {
                log::error!("Screen recording failed: {err}");
                self.handler.lc.write().unwrap().record_state = false;
                self.update_record_state_with_error(Some(err));
            }
            Data::ElevateDirect => {
                let mut request = ElevationRequest::new();
                request.set_direct(true);
                let mut misc = Misc::new();
                misc.set_elevation_request(request);
                let mut msg = Message::new();
                msg.set_misc(misc);
                allow_err!(peer.send(&msg).await);
                self.elevation_requested = true;
            }
            Data::ElevateWithLogon(username, password) => {
                let mut request = ElevationRequest::new();
                request.set_logon(ElevationRequestWithLogon {
                    username,
                    password,
                    ..Default::default()
                });
                let mut misc = Misc::new();
                misc.set_elevation_request(request);
                let mut msg = Message::new();
                msg.set_misc(misc);
                allow_err!(peer.send(&msg).await);
                self.elevation_requested = true;
            }
            Data::NewVoiceCall => {
                #[cfg(target_os = "ios")]
                {
                    log::warn!("Voice call request blocked on iOS (not supported)");
                    self.handler
                        .on_voice_call_closed("Voice call is not supported on iOS");
                }
                #[cfg(not(target_os = "ios"))]
                {
                    let msg = new_voice_call_request(true);
                    // Save the voice call request timestamp for the further validation.
                    self.voice_call_request_timestamp = Some(
                        NonZeroI64::new(msg.voice_call_request().req_timestamp)
                            .unwrap_or(NonZeroI64::new(get_time()).unwrap()),
                    );
                    allow_err!(peer.send(&msg).await);
                    self.handler.on_voice_call_waiting();
                }
            }
            Data::CloseVoiceCall => {
                self.stop_voice_call();
                let msg = new_voice_call_request(false);
                self.handler
                    .on_voice_call_closed("Closed manually by the peer");
                allow_err!(peer.send(&msg).await);
            }
            Data::ResetDecoder(display) => match display {
                Some(display) => {
                    if let Some(v) = self.video_threads.get_mut(&display) {
                        v.queue.push_reset();
                    }
                }
                None => {
                    for (_, v) in self.video_threads.iter_mut() {
                        v.queue.push_reset();
                    }
                }
            },
            Data::TakeScreenshot((display, sid)) => {
                let mut msg = Message::new();
                msg.set_screenshot_request(ScreenshotRequest {
                    display,
                    sid,
                    ..Default::default()
                });
                allow_err!(peer.send(&msg).await);
            }
            _ => {}
        }
        true
    }

    #[inline]
    fn update_job_status(
        job: &fs::TransferJob,
        elapsed: i32,
        last_update_jobs_status: &mut (Instant, HashMap<i32, u64>),
        handler: &Session<T>,
    ) {
        if elapsed <= 0 {
            return;
        }
        let transferred = job.transferred();
        let last_transferred = {
            if let Some(v) = last_update_jobs_status.1.get(&job.id()) {
                v.to_owned()
            } else {
                0
            }
        };
        last_update_jobs_status.1.insert(job.id(), transferred);
        let speed = (transferred - last_transferred) as f64 / (elapsed as f64 / 1000.);
        let file_num = job.file_num() - 1;
        handler.job_progress(job.id(), file_num, speed, job.finished_size() as f64);
    }

    fn update_jobs_status(&mut self) {
        let elapsed = self.last_update_jobs_status.0.elapsed().as_millis() as i32;
        if elapsed >= 1000 {
            for job in self.read_jobs.iter() {
                Self::update_job_status(
                    job,
                    elapsed,
                    &mut self.last_update_jobs_status,
                    &self.handler,
                );
            }
            for job in self.write_jobs.iter() {
                Self::update_job_status(
                    job,
                    elapsed,
                    &mut self.last_update_jobs_status,
                    &mut self.handler,
                );
            }
            self.last_update_jobs_status.0 = Instant::now();
        }
    }

    async fn cancel_transfer_job(&mut self, id: i32, peer: &mut Stream) {
        let mut msg_out = Message::new();
        let mut file_action = FileAction::new();
        file_action.set_cancel(FileTransferCancel {
            id,
            ..Default::default()
        });
        msg_out.set_file_action(file_action);
        allow_err!(peer.send(&msg_out).await);
        if let Some(mut job) = fs::remove_job(id, &mut self.write_jobs) {
            if let Err(err) = job.remove_download_file().await {
                log::error!("Failed to clean up cancelled transfer {}: {}", id, err);
                self.handle_job_status(id, job.file_num(), Some(err.to_string()));
            }
        }
        let _ = fs::remove_job(id, &mut self.read_jobs);
        self.remove_jobs.remove(&id);
    }

    pub async fn sync_jobs_status_to_local(&mut self) -> bool {
        if !self.is_connected {
            return false;
        }
        let mut config: PeerConfig = self.handler.load_config();
        let mut transfer_metas = TransferSerde::default();
        for job in self.read_jobs.iter() {
            let json_str = serde_json::to_string(&job.gen_meta()).unwrap_or_default();
            transfer_metas.read_jobs.push(json_str);
        }
        for job in self.write_jobs.iter() {
            let json_str = serde_json::to_string(&job.gen_meta()).unwrap_or_default();
            transfer_metas.write_jobs.push(json_str);
        }
        log::info!("meta: {:?}", transfer_metas);
        if config.transfer != transfer_metas {
            config.transfer = transfer_metas;
            self.handler.save_config(config);
        }
        true
    }

    async fn send_toggle_virtual_display_msg(&self, peer: &mut Stream) {
        if self.handler.is_view_camera() {
            return;
        }
        if !self.peer_info.is_support_virtual_display() {
            return;
        }
        let displays = self
            .handler
            .lc
            .read()
            .unwrap()
            .get_option("virtual-display");
        for d in displays.split(',') {
            if let Ok(index) = d.parse::<i32>() {
                let mut misc = Misc::new();
                misc.set_toggle_virtual_display(ToggleVirtualDisplay {
                    display: index,
                    on: true,
                    ..Default::default()
                });
                let mut msg_out = Message::new();
                msg_out.set_misc(misc);
                allow_err!(peer.send(&msg_out).await);
            }
        }
    }

    async fn send_toggle_privacy_mode_msg(&self, peer: &mut Stream) {
        if self.handler.is_view_camera() {
            return;
        }
        let (version, enabled, impl_key) = {
            let lc = self.handler.lc.read().unwrap();
            (
                lc.version,
                lc.get_toggle_option("privacy-mode"),
                lc.get_option("privacy-mode-impl-key"),
            )
        };
        if version >= camellia_remote_protocol::get_version_number("1.2.4") && enabled {
            if impl_key == crate::privacy_mode::PRIVACY_MODE_IMPL_WIN_VIRTUAL_DISPLAY
                && !self.peer_info.is_support_virtual_display()
            {
                return;
            }
            let mut misc = Misc::new();
            misc.set_toggle_privacy_mode(TogglePrivacyMode {
                impl_key,
                on: true,
                ..Default::default()
            });
            let mut msg_out = Message::new();
            msg_out.set_misc(misc);
            allow_err!(peer.send(&msg_out).await);
        }
    }

    fn contains_key_frame(vf: &VideoFrame) -> bool {
        use video_frame::Union::*;
        match &vf.union {
            Some(vf) => match vf {
                Vp8s(f) | Vp9s(f) | Av1s(f) | H264s(f) | H265s(f) => f.frames.iter().any(|e| e.key),
                _ => false,
            },
            None => false,
        }
    }

    // Currently, this function only considers decoding speed and queue length, not network delay.
    // The controlled end can consider auto fps as the maximum decoding fps.
    #[inline]
    fn fps_control(&mut self, direct: bool, real_fps_map: HashMap<usize, i32>) {
        self.video_threads.iter_mut().for_each(|(k, v)| {
            let real_fps = real_fps_map.get(k).cloned().unwrap_or_default();
            if real_fps == 0 {
                v.fps_control.inactive_counter += 1;
            } else {
                v.fps_control.inactive_counter = 0;
            }
        });
        let custom_fps = self.handler.lc.read().unwrap().custom_fps.clone();
        let custom_fps = custom_fps.lock().unwrap().clone();
        let mut custom_fps = custom_fps.unwrap_or(30);
        if custom_fps < 5 || custom_fps > 120 {
            custom_fps = 30;
        }
        let inactive_threshold = 15;
        let max_queue_len = self
            .video_threads
            .iter()
            .map(|v| v.1.queue.len())
            .max()
            .unwrap_or_default();
        let min_decode_fps = self
            .video_threads
            .iter()
            .filter(|v| v.1.fps_control.inactive_counter < inactive_threshold)
            .map(|v| *v.1.decode_fps.read().unwrap())
            .min()
            .flatten();
        let Some(min_decode_fps) = min_decode_fps else {
            return;
        };
        let mut limited_fps = if direct {
            min_decode_fps * 9 / 10 // 30 got 27
        } else {
            min_decode_fps * 4 / 5 // 30 got 24
        };
        if limited_fps > custom_fps {
            limited_fps = custom_fps;
        }
        let last_auto_fps = self.handler.lc.read().unwrap().last_auto_fps.clone();
        let displays = self.video_threads.keys().cloned().collect::<Vec<_>>();
        let mut fps_trending = |display: usize| {
            let thread = self.video_threads.get_mut(&display)?;
            let ctl = &mut thread.fps_control;
            let len = thread.queue.len();
            let decode_fps = thread.decode_fps.read().unwrap().clone()?;
            let last_auto_fps = last_auto_fps.clone().unwrap_or(custom_fps as _);
            if ctl.inactive_counter > inactive_threshold {
                return None;
            }
            if len > 1 && last_auto_fps > limited_fps || len > std::cmp::max(1, decode_fps / 2) {
                ctl.idle_counter = 0;
                return Some(false);
            }
            if len <= 1 {
                ctl.idle_counter += 1;
                if ctl.idle_counter > 3 && last_auto_fps + 3 <= limited_fps {
                    return Some(true);
                }
            }
            if len > 1 {
                ctl.idle_counter = 0;
            }
            None
        };
        let trendings: Vec<_> = displays.iter().map(|k| fps_trending(*k)).collect();
        let should_decrease = trendings.iter().any(|v| *v == Some(false));
        let should_increase = !should_decrease && trendings.iter().any(|v| *v == Some(true));
        if last_auto_fps.is_none() || should_decrease || should_increase {
            // limited_fps to ensure decoding is faster than encoding
            let mut auto_fps = limited_fps;
            if should_decrease && limited_fps < max_queue_len {
                auto_fps = limited_fps / 2;
            }
            if auto_fps < 1 {
                auto_fps = 1;
            }
            if Some(auto_fps) != last_auto_fps {
                // Report this as the automatic cap, not as a user preference:
                // custom_fps carries what the user chose, and the peer already
                // takes the lower of the two. Sending the decode-derived value
                // through custom_fps would overwrite that choice for the rest of
                // the session, so a moment of slow decoding would permanently
                // lower the ceiling the user asked for.
                let mut misc = Misc::new();
                misc.set_auto_adjust_fps(auto_fps as _);
                let mut msg = Message::new();
                msg.set_misc(misc);
                self.sender.send(Data::Message(msg)).ok();
                log::info!("Set auto adjust fps to {}", auto_fps);
                self.handler.lc.write().unwrap().last_auto_fps = Some(auto_fps);
            }
        }
        // send refresh
        for (display, thread) in self.video_threads.iter_mut() {
            let ctl = &mut thread.fps_control;
            let tolerable = std::cmp::min(min_decode_fps, thread.queue.capacity() / 2);
            if ctl.refresh_times < 20 // enough
                    && (thread.queue.len() > tolerable
                            && (ctl.refresh_times == 0 || ctl.last_refresh_instant.map(|t|t.elapsed().as_secs() > 10).unwrap_or(false)))
            {
                // Refresh causes client set_display, left frames cause flickering.
                self.handler.refresh_video(*display as _);
                log::info!("Refresh display {} to reduce delay", display);
                ctl.refresh_times += 1;
                ctl.last_refresh_instant = Some(Instant::now());
            }
        }
    }

    fn check_view_camera_support(&self, peer_version: &str, peer_platform: &str) -> bool {
        if self.peer_info.support_view_camera {
            return true;
        }
        if camellia_remote_protocol::get_version_number(&peer_version)
            < camellia_remote_protocol::get_version_number("1.3.9")
            && (peer_platform == "Windows" || peer_platform == "Linux")
        {
            self.handler.msgbox(
                "error",
                "Download new version",
                "upgrade_remote_rustdesk_client_to_{1.3.9}_tip",
                "",
            );
        } else {
            self.handler.on_error("view_camera_unsupported_tip");
        }
        return false;
    }

    fn check_terminal_support(&self, peer_version: &str) -> bool {
        if self.peer_info.support_terminal {
            return true;
        }
        if camellia_remote_protocol::get_version_number(&peer_version)
            < camellia_remote_protocol::get_version_number("1.4.1")
        {
            self.handler.msgbox(
                "error",
                "Remote terminal not supported",
                "Remote terminal is not supported by the remote side. Please upgrade to version 1.4.1 or higher.",
                "",
            );
        } else {
            self.handler
                .on_error("Remote terminal is not supported by the remote side");
        }
        return false;
    }

    async fn handle_msg_from_peer(&mut self, data: &[u8], peer: &mut Stream) -> bool {
        if let Ok(msg_in) = Message::parse_from_bytes(&data) {
            match msg_in.union {
                Some(message::Union::VideoFrame(vf)) => {
                    if !self.is_connected {
                        log::warn!("Rejected VideoFrame received before session login completion");
                        return true;
                    }
                    if vf.display < 0 || vf.display >= MAX_DISPLAY_DECODERS as i32 {
                        log::warn!(
                            "Rejected VideoFrame with invalid display ID: {} (bounds 0..{})",
                            vf.display,
                            MAX_DISPLAY_DECODERS
                        );
                        return true;
                    }
                    let display = vf.display as usize;
                    if !self.allowed_displays.contains(&display) {
                        log::warn!(
                            "Rejected VideoFrame for unannounced display: {} (allowed: {:?})",
                            display,
                            self.allowed_displays
                        );
                        return true;
                    }

                    if !self.first_frame {
                        self.first_frame = true;
                        self.handler.close_success();
                        self.handler.adapt_size();
                        self.send_toggle_virtual_display_msg(peer).await;
                        self.send_toggle_privacy_mode_msg(peer).await;
                    }
                    self.video_format = CodecFormat::from(&vf);

                    if !self.video_threads.contains_key(&display) {
                        self.new_video_thread(display);
                    }
                    let Some(thread) = self.video_threads.get_mut(&display) else {
                        return true;
                    };

                    let is_key = Self::contains_key_frame(&vf);
                    match thread.queue.push_frame(Box::new(vf), is_key) {
                        VideoQueuePushResult::DroppedOverloadNeedRefresh => {
                            self.handler.refresh_video(display as _);
                        }
                        _ => {}
                    }
                }
                Some(message::Union::Hash(hash)) => {
                    self.handler
                        .handle_hash(&self.handler.password.clone(), hash, peer)
                        .await;
                }
                Some(message::Union::LoginResponse(lr)) => match lr.union {
                    Some(login_response::Union::Error(err)) => {
                        if err == client::REQUIRE_2FA {
                            self.handler.lc.write().unwrap().enable_trusted_devices =
                                lr.enable_trusted_devices;
                        }
                        if !self.handler.handle_login_error(&err) {
                            return false;
                        }
                    }
                    Some(login_response::Union::PeerInfo(pi)) => {
                        let peer_version = pi.version.clone();
                        let peer_platform = pi.platform.clone();
                        self.set_peer_info(&pi);
                        if self.handler.is_view_camera() {
                            if !self.check_view_camera_support(&peer_version, &peer_platform) {
                                self.handler.lc.write().unwrap().handle_peer_info(&pi);
                                return false;
                            }
                        }
                        if self.handler.is_terminal() {
                            if !self.check_terminal_support(&peer_version) {
                                self.handler.lc.write().unwrap().handle_peer_info(&pi);
                                return false;
                            }
                        }
                        self.update_allowed_displays(&pi.displays);
                        self.handler.handle_peer_info(pi);
                        if self.handler.is_default() {
                            #[cfg(feature = "flutter")]
                            #[cfg(not(target_os = "ios"))]
                            let rx = Client::try_start_clipboard(None);
                            // To make sure current text clipboard data is updated.
                            #[cfg(not(target_os = "ios"))]
                            if let Some(mut rx) = rx {
                                timeout(CLIPBOARD_INTERVAL, rx.recv()).await.ok();
                            }

                            #[cfg(not(any(target_os = "android", target_os = "ios")))]
                            if self.handler.lc.read().unwrap().sync_init_clipboard.v {
                                if let Some(msg_out) = crate::clipboard::get_current_clipboard_msg(
                                    &peer_version,
                                    &peer_platform,
                                    crate::clipboard::ClipboardSide::Client,
                                ) {
                                    let sender = self.sender.clone();
                                    let permission_config = self.handler.get_permission_config();
                                    tokio::spawn(async move {
                                        if permission_config.is_text_clipboard_required() {
                                            sender.send(Data::Message(msg_out)).ok();
                                        }
                                    });
                                }
                            }
                            // to-do: Android, is `sync_init_clipboard` really needed?
                            // https://github.com/rustdesk/rustdesk/discussions/9010

                            #[cfg(feature = "flutter")]
                            #[cfg(not(target_os = "ios"))]
                            crate::flutter::update_text_clipboard_required();

                            #[cfg(all(feature = "flutter", feature = "unix-file-copy-paste"))]
                            crate::flutter::update_file_clipboard_required();
                        }

                        if self.handler.is_file_transfer() {
                            self.handler.load_last_jobs();
                        }

                        self.is_connected = true;
                    }
                    _ => {}
                },
                Some(message::Union::CursorData(cd)) => {
                    self.handler.set_cursor_data(cd);
                }
                Some(message::Union::CursorId(id)) => {
                    self.handler.set_cursor_id(id.to_string());
                }
                Some(message::Union::CursorPosition(cp)) => {
                    self.handler.set_cursor_position(cp);
                }
                Some(message::Union::Clipboard(cb)) => {
                    let clipboard_allowed = {
                        let lc = self.handler.lc.read().unwrap();
                        !lc.disable_clipboard.v && !lc.view_only.v
                    };
                    if clipboard_allowed {
                        #[cfg(not(any(target_os = "android", target_os = "ios")))]
                        update_clipboard(vec![cb], ClipboardSide::Client);
                        #[cfg(target_os = "ios")]
                        {
                            let content = if cb.compress {
                                match camellia_remote_protocol::compress::decompress(&cb.content) {
                                    Ok(content) => content,
                                    Err(err) => {
                                        log::warn!(
                                            "Dropping malformed compressed clipboard payload: {err}"
                                        );
                                        return true;
                                    }
                                }
                            } else {
                                cb.content.into()
                            };
                            if let Ok(content) = String::from_utf8(content) {
                                self.handler.clipboard(content);
                            }
                        }
                        #[cfg(target_os = "android")]
                        crate::clipboard::handle_msg_clipboard(cb);
                    }
                }
                Some(message::Union::MultiClipboards(_mcb)) => {
                    let clipboard_allowed = {
                        let lc = self.handler.lc.read().unwrap();
                        !lc.disable_clipboard.v && !lc.view_only.v
                    };
                    if clipboard_allowed {
                        #[cfg(not(any(target_os = "android", target_os = "ios")))]
                        update_clipboard(_mcb.clipboards, ClipboardSide::Client);
                        #[cfg(target_os = "ios")]
                        {
                            if let Some(cb) = _mcb
                                .clipboards
                                .iter()
                                .find(|c| c.format.enum_value() == Ok(ClipboardFormat::Text))
                            {
                                let content = if cb.compress {
                                    match camellia_remote_protocol::compress::decompress(
                                        &cb.content,
                                    ) {
                                        Ok(content) => content,
                                        Err(err) => {
                                            log::warn!(
                                                "Dropping malformed compressed clipboard payload: {err}"
                                            );
                                            return true;
                                        }
                                    }
                                } else {
                                    cb.content.to_vec()
                                };
                                if let Ok(content) = String::from_utf8(content) {
                                    self.handler.clipboard(content);
                                }
                            }
                        }
                        #[cfg(target_os = "android")]
                        crate::clipboard::handle_msg_multi_clipboards(_mcb);
                    }
                }
                #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
                Some(message::Union::Cliprdr(clip)) => {
                    self.handle_cliprdr_msg(clip, peer).await;
                }
                Some(message::Union::FileResponse(fr)) => {
                    match fr.union {
                        Some(file_response::Union::EmptyDirs(res)) => {
                            self.handler.update_empty_dirs(res);
                        }
                        Some(file_response::Union::Dir(fd)) => {
                            #[cfg(windows)]
                            let entries = fd.entries.to_vec();
                            #[cfg(not(windows))]
                            let mut entries = fd.entries.to_vec();
                            #[cfg(not(windows))]
                            {
                                if self.handler.peer_platform() == "Windows" {
                                    fs::transform_windows_path(&mut entries);
                                }
                            }
                            // We cannot call cancel_transfer_job/handle_job_status while holding
                            // a mutable borrow from fs::get_job(&mut self.write_jobs), so defer
                            // the error handling until after the borrow scope ends.
                            let mut set_files_err = None;
                            if let Some(job) = fs::get_job(fd.id, &mut self.write_jobs) {
                                log::info!("job set_files: {:?}", entries);
                                if let Err(err) = job.set_files(entries) {
                                    set_files_err = Some(err.to_string());
                                } else {
                                    job.set_finished_size_on_resume();
                                    self.handler.update_folder_files(
                                        fd.id,
                                        job.files(),
                                        fd.path,
                                        false,
                                        false,
                                    );
                                }
                            } else if let Some(job) = self.remove_jobs.get_mut(&fd.id) {
                                // Intentionally keep raw entries here:
                                // - remote remove flow executes deletions on peer side;
                                // - local remove flow is populated from local get_recursive_files().
                                job.files = entries;
                                self.handler
                                    .update_folder_files(fd.id, &job.files, fd.path, false, false);
                            } else {
                                self.handler
                                    .update_folder_files(fd.id, &entries, fd.path, false, false);
                            }
                            if let Some(err) = set_files_err {
                                log::warn!(
                                    "Rejected unsafe file list from remote peer for job {}: {}",
                                    fd.id,
                                    err
                                );
                                self.cancel_transfer_job(fd.id, peer).await;
                                self.handle_job_status(fd.id, -1, Some(err));
                            }
                        }
                        Some(file_response::Union::Digest(digest)) => {
                            if digest.is_upload {
                                if let Some(job) = fs::get_job(digest.id, &mut self.read_jobs) {
                                    if let Some(file) = job.files().get(digest.file_num as usize) {
                                        if let fs::DataSource::FilePath(p) = &job.data_source {
                                            let read_path =
                                                get_string(&fs::TransferJob::join(p, &file.name));
                                            let mut overwrite_strategy =
                                                job.default_overwrite_strategy();
                                            let mut offset = 0;
                                            if digest.is_identical && job.is_resume {
                                                if digest.transferred_size > 0 {
                                                    overwrite_strategy = Some(true);
                                                    offset = digest.transferred_size;
                                                }
                                            }
                                            if let Some(overwrite) = overwrite_strategy {
                                                let req = FileTransferSendConfirmRequest {
                                                    id: digest.id,
                                                    file_num: digest.file_num,
                                                    union: Some(if overwrite {
                                                        file_transfer_send_confirm_request::Union::OffsetBytes(offset)
                                                    } else {
                                                        file_transfer_send_confirm_request::Union::Skip(
                                                            true,
                                                        )
                                                    }),
                                                    ..Default::default()
                                                };
                                                if job.confirm(&req).await {
                                                    let msg = new_send_confirm(req);
                                                    allow_err!(peer.send(&msg).await);
                                                } else {
                                                    let err =
                                                        job.job_error().unwrap_or_else(|| {
                                                            "file transfer confirmation failed"
                                                                .to_owned()
                                                        });
                                                    let _ = job;
                                                    let _ = fs::remove_job(
                                                        digest.id,
                                                        &mut self.read_jobs,
                                                    );
                                                    allow_err!(
                                                        peer.send(&fs::new_error(
                                                            digest.id,
                                                            &err,
                                                            digest.file_num,
                                                        ))
                                                        .await
                                                    );
                                                    self.handle_job_status(
                                                        digest.id,
                                                        digest.file_num,
                                                        Some(err),
                                                    );
                                                }
                                            } else {
                                                self.handler.override_file_confirm(
                                                    digest.id,
                                                    digest.file_num,
                                                    read_path,
                                                    true,
                                                    digest.is_identical,
                                                );
                                            }
                                        }
                                    }
                                }
                            } else {
                                if let Some(job) = fs::get_job(digest.id, &mut self.write_jobs) {
                                    if let Some(file) = job.files().get(digest.file_num as usize) {
                                        if let fs::DataSource::FilePath(p) = &job.data_source {
                                            let write_path =
                                                get_string(&fs::TransferJob::join(p, &file.name));
                                            job.set_digest(digest.file_size, digest.last_modified);
                                            let peer_ver = self.handler.lc.read().unwrap().version;
                                            let is_support_resume =
                                                crate::is_support_file_transfer_resume_num(
                                                    peer_ver,
                                                );
                                            match fs::is_write_need_confirmation(
                                                is_support_resume && job.is_resume,
                                                &write_path,
                                                &digest,
                                            ) {
                                                Ok(res) => match res {
                                                    DigestCheckResult::IsSame => {
                                                        let req = FileTransferSendConfirmRequest {
                                                            id: digest.id,
                                                            file_num: digest.file_num,
                                                            union: Some(file_transfer_send_confirm_request::Union::Skip(true)),
                                                            ..Default::default()
                                                        };
                                                        if job.confirm(&req).await {
                                                            let msg = new_send_confirm(req);
                                                            allow_err!(peer.send(&msg).await);
                                                        } else {
                                                            let err = job.job_error().unwrap_or_else(
                                                                || {
                                                                    "file transfer confirmation failed"
                                                                        .to_owned()
                                                                },
                                                            );
                                                            let _ = job;
                                                            let _ = fs::remove_job(
                                                                digest.id,
                                                                &mut self.write_jobs,
                                                            );
                                                            allow_err!(
                                                                peer.send(&fs::new_error(
                                                                    digest.id,
                                                                    &err,
                                                                    digest.file_num,
                                                                ))
                                                                .await
                                                            );
                                                            self.handle_job_status(
                                                                digest.id,
                                                                digest.file_num,
                                                                Some(err),
                                                            );
                                                        }
                                                    }
                                                    DigestCheckResult::NeedConfirm(digest) => {
                                                        let mut overwrite_strategy =
                                                            job.default_overwrite_strategy();
                                                        let mut offset = 0;
                                                        if digest.is_identical
                                                            && job.is_resume
                                                            && digest.transferred_size > 0
                                                        {
                                                            overwrite_strategy = Some(true);
                                                            offset = digest.transferred_size;
                                                        }
                                                        if let Some(overwrite) = overwrite_strategy
                                                        {
                                                            let req =
                                                                FileTransferSendConfirmRequest {
                                                                    id: digest.id,
                                                                    file_num: digest.file_num,
                                                                    union: Some(if overwrite {
                                                                        file_transfer_send_confirm_request::Union::OffsetBytes(offset)
                                                                    } else {
                                                                        file_transfer_send_confirm_request::Union::Skip(true)
                                                                    }),
                                                                    ..Default::default()
                                                                };
                                                            if job.confirm(&req).await {
                                                                let msg = new_send_confirm(req);
                                                                allow_err!(peer.send(&msg).await);
                                                            } else {
                                                                let err = job
                                                                    .job_error()
                                                                    .unwrap_or_else(|| {
                                                                        "file transfer confirmation failed"
                                                                            .to_owned()
                                                                    });
                                                                let _ = job;
                                                                let _ = fs::remove_job(
                                                                    digest.id,
                                                                    &mut self.write_jobs,
                                                                );
                                                                allow_err!(
                                                                    peer.send(&fs::new_error(
                                                                        digest.id,
                                                                        &err,
                                                                        digest.file_num,
                                                                    ))
                                                                    .await
                                                                );
                                                                self.handle_job_status(
                                                                    digest.id,
                                                                    digest.file_num,
                                                                    Some(err),
                                                                );
                                                            }
                                                        } else {
                                                            self.handler.override_file_confirm(
                                                                digest.id,
                                                                digest.file_num,
                                                                write_path,
                                                                false,
                                                                digest.is_identical,
                                                            );
                                                        }
                                                    }
                                                    DigestCheckResult::NoSuchFile => {
                                                        let req = FileTransferSendConfirmRequest {
                                                        id: digest.id,
                                                        file_num: digest.file_num,
                                                        union: Some(file_transfer_send_confirm_request::Union::OffsetBytes(0)),
                                                        ..Default::default()
                                                    };
                                                        if job.confirm(&req).await {
                                                            let msg = new_send_confirm(req);
                                                            allow_err!(peer.send(&msg).await);
                                                        } else {
                                                            let err = job.job_error().unwrap_or_else(
                                                                || {
                                                                    "file transfer confirmation failed"
                                                                        .to_owned()
                                                                },
                                                            );
                                                            let _ = job;
                                                            let _ = fs::remove_job(
                                                                digest.id,
                                                                &mut self.write_jobs,
                                                            );
                                                            allow_err!(
                                                                peer.send(&fs::new_error(
                                                                    digest.id,
                                                                    &err,
                                                                    digest.file_num,
                                                                ))
                                                                .await
                                                            );
                                                            self.handle_job_status(
                                                                digest.id,
                                                                digest.file_num,
                                                                Some(err),
                                                            );
                                                        }
                                                    }
                                                },
                                                Err(err) => {
                                                    let err = err.to_string();
                                                    let _ = job;
                                                    let _ = fs::remove_job(
                                                        digest.id,
                                                        &mut self.write_jobs,
                                                    );
                                                    allow_err!(
                                                        peer.send(&fs::new_error(
                                                            digest.id,
                                                            &err,
                                                            digest.file_num,
                                                        ))
                                                        .await
                                                    );
                                                    self.handle_job_status(
                                                        digest.id,
                                                        digest.file_num,
                                                        Some(err),
                                                    );
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        Some(file_response::Union::Block(block)) => {
                            let id = block.id;
                            let file_num = block.file_num;
                            let write_result = match fs::get_job(id, &mut self.write_jobs) {
                                Some(job) => job
                                    .write(block)
                                    .await
                                    .map(|_| (job.r#type, job.transferred()))
                                    .map_err(|err| err.to_string()),
                                None => return true,
                            };
                            match write_result {
                                Ok((fs::JobType::Generic, _)) => self.update_jobs_status(),
                                Ok((fs::JobType::Printer, total_written)) => {
                                    if let Err(err) = crate::client::print_dispatcher::PrintDispatcher::global()
                                        .update_job_bytes(id, total_written)
                                    {
                                        log::error!("Print job {id} exceeded limits: {err}");
                                        let _ = fs::remove_job(id, &mut self.write_jobs);
                                        allow_err!(peer.send(&fs::new_error(id, &err.to_string(), file_num)).await);
                                        self.handle_job_status(id, file_num, Some(err.to_string()));
                                    }
                                }
                                Err(err) => {
                                    let removed = fs::remove_job(id, &mut self.write_jobs);
                                    if let Some(j) = removed {
                                        if j.r#type == fs::JobType::Printer {
                                            crate::client::print_dispatcher::PrintDispatcher::global().cancel_job(id);
                                        }
                                    }
                                    allow_err!(peer.send(&fs::new_error(id, &err, file_num)).await);
                                    self.handle_job_status(id, file_num, Some(err));
                                }
                            }
                        }
                        Some(file_response::Union::Done(d)) => {
                            let finalize_error = match fs::get_job(d.id, &mut self.write_jobs) {
                                Some(job) => job
                                    .modify_time()
                                    .await
                                    .err()
                                    .map(|error| error.to_string())
                                    .or_else(|| job.job_error()),
                                None => return true,
                            };
                            let Some(job) = fs::remove_job(d.id, &mut self.write_jobs) else {
                                return true;
                            };
                            let job_type = job.r#type;
                            let err = finalize_error;
                            if let Some(err) = err.as_deref() {
                                allow_err!(peer.send(&fs::new_error(d.id, err, d.file_num)).await);
                            }
                            match job_type {
                                fs::JobType::Generic => {
                                    self.handle_job_status(d.id, d.file_num, err);
                                }
                                fs::JobType::Printer => {
                                    let _ = self.handler.printer_names.write().unwrap().remove(&d.id);
                                    if let Some(err) = err {
                                        log::error!("Receive print job failed, error {err}");
                                        crate::client::print_dispatcher::PrintDispatcher::global().cancel_job(d.id);
                                    } else {
                                        log::info!("Receive print job done for id {}", d.id);
                                        if let Err(e) = crate::client::print_dispatcher::PrintDispatcher::global()
                                            .submit_job(d.id)
                                        {
                                            log::error!("Print job submission failed for {}: {}", d.id, e);
                                        }
                                    }
                                }
                            }
                        }
                        Some(file_response::Union::Error(e)) => match e.operation.enum_value() {
                            Ok(FileErrorOperation::ReadDir) => {
                                self.handler.file_listing_error(e.path, e.error, false);
                            }
                            Ok(FileErrorOperation::ReadEmptyDirs) => {
                                self.handler.file_listing_error(e.path, e.error, true);
                            }
                            _ => {
                                let job_type = fs::remove_job(e.id, &mut self.write_jobs)
                                    .or_else(|| fs::remove_job(e.id, &mut self.read_jobs))
                                    .map(|j| j.r#type)
                                    .unwrap_or(fs::JobType::Generic);
                                match job_type {
                                    fs::JobType::Generic => {
                                        self.handle_job_status(e.id, e.file_num, Some(e.error));
                                    }
                                    fs::JobType::Printer => {
                                        log::error!("Printer job error: {}", e.error);
                                        let _ = self.handler.printer_names.write().unwrap().remove(&e.id);
                                        crate::client::print_dispatcher::PrintDispatcher::global()
                                            .cancel_job(e.id);
                                    }
                                }
                            }
                        },
                        _ => {}
                    }
                }
                Some(message::Union::Misc(misc)) => match misc.union {
                    Some(misc::Union::AudioFormat(f)) => {
                        if self.audio_worker.is_none() {
                            self.audio_worker = Some(crate::client::start_audio_thread());
                        }
                        if let Some(worker) = &self.audio_worker {
                            worker.queue().set_format(f);
                        }
                    }
                    Some(misc::Union::ChatMessage(c)) => {
                        self.handler.new_message(c.text);
                    }
                    Some(misc::Union::PermissionInfo(p)) => {
                        log::info!("Change permission {:?} -> {}", p.permission, p.enabled);
                        // https://github.com/rustdesk/rustdesk/issues/3703#issuecomment-1474734754
                        match p.permission.enum_value() {
                            Ok(Permission::Keyboard) => {
                                *self.handler.server_keyboard_enabled.write().unwrap() = p.enabled;
                                #[cfg(feature = "flutter")]
                                #[cfg(not(target_os = "ios"))]
                                crate::flutter::update_text_clipboard_required();
                                #[cfg(all(feature = "flutter", feature = "unix-file-copy-paste"))]
                                crate::flutter::update_file_clipboard_required();
                                self.handler.set_permission("keyboard", p.enabled);
                            }
                            Ok(Permission::Clipboard) => {
                                *self.handler.server_clipboard_enabled.write().unwrap() = p.enabled;
                                #[cfg(feature = "flutter")]
                                #[cfg(not(target_os = "ios"))]
                                crate::flutter::update_text_clipboard_required();
                                self.handler.set_permission("clipboard", p.enabled);
                            }
                            Ok(Permission::Audio) => {
                                if !p.enabled {
                                    if let Some(mut worker) = self.audio_worker.take() {
                                        worker.stop();
                                    }
                                }
                                self.handler.set_permission("audio", p.enabled);
                            }
                            Ok(Permission::File) => {
                                *self.handler.server_file_transfer_enabled.write().unwrap() =
                                    p.enabled;
                                if !p.enabled && self.handler.is_file_transfer() {
                                    return true;
                                }
                                #[cfg(all(feature = "flutter", feature = "unix-file-copy-paste"))]
                                crate::flutter::update_file_clipboard_required();
                                self.handler.set_permission("file", p.enabled);
                                #[cfg(feature = "unix-file-copy-paste")]
                                if !p.enabled {
                                    try_empty_clipboard_files(
                                        ClipboardSide::Client,
                                        self.client_conn_id,
                                    );
                                }
                            }
                            Ok(Permission::Restart) => {
                                self.handler.set_permission("restart", p.enabled);
                            }
                            Ok(Permission::Recording) => {
                                self.handler.lc.write().unwrap().record_permission = p.enabled;
                                self.update_record_state();
                                self.handler.set_permission("recording", p.enabled);
                            }
                            Ok(Permission::BlockInput) => {
                                self.handler.set_permission("block_input", p.enabled);
                            }
                            Ok(Permission::PrivacyMode) => {
                                self.handler.set_permission("privacy_mode", p.enabled);
                            }
                            _ => {}
                        }
                    }
                    Some(misc::Union::SwitchDisplay(s)) => {
                        self.handler.handle_peer_switch_display(&s);
                        if let Some(thread) = self.video_threads.get_mut(&(s.display as usize)) {
                            thread.queue.push_reset();
                        }

                        let mut scale = 1.0;
                        if let Some(pi) = &self.handler.lc.read().unwrap().peer_info {
                            if let Some(d) = pi.displays.get(s.display as usize) {
                                scale = d.scale;
                            }
                        }

                        if s.width > 0 && s.height > 0 {
                            self.handler.set_display(
                                s.x,
                                s.y,
                                s.width,
                                s.height,
                                s.cursor_embedded,
                                scale,
                            );
                        }
                    }
                    Some(misc::Union::CloseReason(c)) => {
                        self.sent_close_reason = true; // The controlled end will close, no need to send close reason
                        self.handler.clear_restarting_remote_device();
                        self.handler.msgbox("error", "Connection Error", &c, "");
                        return false;
                    }
                    Some(misc::Union::BackNotification(notification)) => {
                        if !self.handle_back_notification(notification).await {
                            return false;
                        }
                    }
                    Some(misc::Union::Uac(uac)) => {
                        let keyboard = self.handler.server_keyboard_enabled.read().unwrap().clone();
                        #[cfg(feature = "flutter")]
                        {
                            if uac && keyboard {
                                self.handler.msgbox(
                                    "on-uac",
                                    "Prompt",
                                    "Please wait for confirmation of UAC...",
                                    "",
                                );
                            } else {
                                self.handler.cancel_msgbox("on-uac");
                                self.handler.cancel_msgbox("wait-uac");
                                self.handler.cancel_msgbox("elevation-error");
                            }
                        }
                    }
                    Some(misc::Union::ForegroundWindowElevated(elevated)) => {
                        let keyboard = self.handler.server_keyboard_enabled.read().unwrap().clone();
                        #[cfg(feature = "flutter")]
                        {
                            if elevated && keyboard {
                                self.handler.msgbox(
                                    "on-foreground-elevated",
                                    "Prompt",
                                    "elevated_foreground_window_tip",
                                    "",
                                );
                            } else {
                                self.handler.cancel_msgbox("on-foreground-elevated");
                                self.handler.cancel_msgbox("wait-uac");
                                self.handler.cancel_msgbox("elevation-error");
                            }
                        }
                    }
                    Some(misc::Union::ElevationResponse(err)) => {
                        if err.is_empty() {
                            self.handler.msgbox("wait-uac", "", "", "");
                        } else {
                            self.handler.cancel_msgbox("wait-uac");
                            self.handler
                                .msgbox("elevation-error", "Elevation Error", &err, "");
                        }
                    }
                    Some(misc::Union::PortableServiceRunning(b)) => {
                        self.handler.portable_service_running(b);
                        if self.elevation_requested && b {
                            self.handler.msgbox(
                                "custom-nocancel-success",
                                "Successful",
                                "Elevate successfully",
                                "",
                            );
                        }
                    }
                    #[cfg(feature = "flutter")]
                    #[cfg(not(any(target_os = "android", target_os = "ios")))]
                    Some(misc::Union::SwitchBack(_)) => {
                        let allow_switch_back = self
                            .handler
                            .lc
                            .write()
                            .unwrap()
                            .consume_switch_back_permission();
                        if allow_switch_back {
                            self.handler.switch_back(&self.handler.get_id());
                        } else {
                            log::warn!(
                                "Ignored unsolicited SwitchBack from {}",
                                self.handler.get_id()
                            );
                        }
                    }
                    Some(misc::Union::SupportedEncoding(e)) => {
                        log::info!("update supported encoding:{:?}", e);
                        self.handler.lc.write().unwrap().supported_encoding = e;
                    }
                    Some(misc::Union::FollowCurrentDisplay(d_idx)) => {
                        self.handler.set_current_display(d_idx);
                    }
                    _ => {}
                },
                Some(message::Union::TestDelay(t)) => {
                    self.handler.handle_test_delay(t, peer).await;
                }
                Some(message::Union::AudioFrame(frame)) => {
                    if !self.handler.lc.read().unwrap().disable_audio.v {
                        if self.audio_worker.is_none() {
                            self.audio_worker = Some(crate::client::start_audio_thread());
                        }
                        if let Some(worker) = &self.audio_worker {
                            worker.queue().push_frame(Box::new(frame));
                        }
                    }
                }
                Some(message::Union::FileAction(action)) => match action.union {
                    Some(file_action::Union::Send(_s)) => match _s.file_type.enum_value() {
                        #[cfg(target_os = "windows")]
                        Ok(file_transfer_send_request::FileType::Printer) => {
                            #[cfg(feature = "flutter")]
                            let action = LocalConfig::get_option(
                                config::keys::OPTION_PRINTER_INCOMING_JOB_ACTION,
                            );
                            if action == "dismiss" {
                                // Just ignore the incoming print job.
                            } else {
                                let id = fs::get_next_job_id();
                                #[cfg(feature = "flutter")]
                                let allow_auto_print = LocalConfig::get_bool_option(
                                    config::keys::OPTION_PRINTER_ALLOW_AUTO_PRINT,
                                );
                                if allow_auto_print {
                                    let printer_name = if action == "" {
                                        "".to_string()
                                    } else {
                                        LocalConfig::get_option(
                                            config::keys::OPTION_PRINTER_SELECTED_NAME,
                                        )
                                    };
                                    self.handler.printer_response(id, _s.path, printer_name);
                                } else {
                                    self.handler.printer_request(id, _s.path);
                                }
                            }
                        }
                        _ => {}
                    },
                    Some(file_action::Union::SendConfirm(c)) => {
                        let confirmation_error =
                            if let Some(job) = fs::get_job(c.id, &mut self.read_jobs) {
                                if job.confirm(&c).await {
                                    None
                                } else {
                                    Some(job.job_error().unwrap_or_else(|| {
                                        "file transfer confirmation failed".to_owned()
                                    }))
                                }
                            } else {
                                None
                            };
                        if let Some(err) = confirmation_error {
                            let _ = fs::remove_job(c.id, &mut self.read_jobs);
                            allow_err!(peer.send(&fs::new_error(c.id, &err, c.file_num)).await);
                            self.handle_job_status(c.id, c.file_num, Some(err));
                        }
                    }
                    _ => {}
                },
                Some(message::Union::MessageBox(msgbox)) => {
                    let mut link = msgbox.link;
                    if let Some(v) = config::HELPER_URL.get(&link as &str) {
                        link = v.to_string();
                    } else {
                        log::warn!("Message box ignore link {} for security", &link);
                        link = "".to_string();
                    }
                    self.handler
                        .msgbox(&msgbox.msgtype, &msgbox.title, &msgbox.text, &link);
                }
                Some(message::Union::VoiceCallRequest(request)) => {
                    if request.is_connect {
                        #[cfg(target_os = "ios")]
                        {
                            log::warn!(
                                "Rejecting incoming voice call on unsupported platform (iOS)"
                            );
                            let msg = crate::client::new_voice_call_response(
                                request.req_timestamp,
                                false,
                            );
                            allow_err!(peer.send(&msg).await);
                        }
                        #[cfg(not(target_os = "ios"))]
                        {
                            // TODO: maybe we will do a voice call from the peer in the future.
                        }
                    } else {
                        log::debug!("The remote has requested to close the voice call");
                        self.stop_voice_call();
                        self.handler.on_voice_call_closed("");
                    }
                }
                Some(message::Union::VoiceCallResponse(response)) => {
                    let ts = std::mem::replace(&mut self.voice_call_request_timestamp, None);
                    if let Some(ts) = ts {
                        if response.req_timestamp != ts.get() {
                            log::debug!("Possible encountering a voice call attack.");
                        } else {
                            if response.accepted {
                                // The peer accepted the voice call.
                                self.stop_voice_call();
                                if let Some(worker) = self.start_voice_call() {
                                    self.voice_call_worker = Some(worker);
                                    self.handler.on_voice_call_started();
                                } else {
                                    log::warn!(
                                        "Voice call accepted by peer, but local audio capture failed or is unsupported"
                                    );
                                    let msg = new_voice_call_request(false);
                                    allow_err!(peer.send(&msg).await);
                                    self.handler.on_voice_call_closed(
                                        "Voice call is not supported on this platform",
                                    );
                                }
                            } else {
                                // The peer refused the voice call.
                                self.stop_voice_call();
                                self.handler.on_voice_call_closed("");
                            }
                        }
                    }
                }
                Some(message::Union::PeerInfo(pi)) => {
                    self.update_allowed_displays(&pi.displays);
                    self.handler.set_displays(&pi.displays);
                    self.handler.set_platform_additions(&pi.platform_additions);
                }
                Some(message::Union::ScreenshotResponse(response)) => {
                    crate::client::screenshot::set_session_screenshot(&response.sid, response.data);
                    self.handler
                        .handle_screenshot_resp(response.sid, response.msg);
                }
                Some(message::Union::TerminalResponse(response)) => {
                    use camellia_remote_protocol::message_proto::terminal_response::Union;
                    if let Some(Union::Opened(opened)) = &response.union {
                        if opened.success && !opened.service_id.is_empty() {
                            let mut lc = self.handler.lc.write().unwrap();
                            let key = lc.get_key_terminal_service_id().to_owned();
                            lc.set_option(key, opened.service_id.clone());
                        }
                    }
                    self.handler.handle_terminal_response(response);
                }
                _ => {}
            }
        }
        true
    }

    fn set_peer_info(&mut self, pi: &PeerInfo) {
        self.peer_info.platform = pi.platform.clone();

        // Check features field for terminal support
        if let Some(features) = pi.features.as_ref() {
            self.peer_info.support_terminal = features.terminal;
        }

        if let Ok(platform_additions) =
            serde_json::from_str::<HashMap<String, serde_json::Value>>(&pi.platform_additions)
        {
            self.peer_info.is_installed = platform_additions
                .get("is_installed")
                .map(|v| v.as_bool())
                .flatten()
                .unwrap_or(false);
            self.peer_info.idd_impl = platform_additions
                .get("idd_impl")
                .map(|v| v.as_str())
                .flatten()
                .unwrap_or_default()
                .to_string();
            self.peer_info.support_view_camera = platform_additions
                .get("support_view_camera")
                .map(|v| v.as_bool())
                .flatten()
                .unwrap_or(false);
        }
    }

    async fn handle_back_notification(&mut self, notification: BackNotification) -> bool {
        match notification.union {
            Some(back_notification::Union::BlockInputState(state)) => {
                self.handle_back_msg_block_input(
                    state.enum_value_or(back_notification::BlockInputState::BlkStateUnknown),
                    notification.details,
                )
                .await;
            }
            Some(back_notification::Union::PrivacyModeState(state)) => {
                if !self
                    .handle_back_msg_privacy_mode(
                        state.enum_value_or(back_notification::PrivacyModeState::PrvStateUnknown),
                        notification.details,
                        notification.impl_key,
                    )
                    .await
                {
                    return false;
                }
            }
            _ => {}
        }
        true
    }

    #[inline(always)]
    fn update_block_input_state(&mut self, on: bool) {
        self.handler.update_block_input_state(on);
    }

    async fn handle_back_msg_block_input(
        &mut self,
        state: back_notification::BlockInputState,
        details: String,
    ) {
        match state {
            back_notification::BlockInputState::BlkOnSucceeded => {
                self.update_block_input_state(true);
            }
            back_notification::BlockInputState::BlkOnFailed => {
                self.handler.msgbox(
                    "custom-error",
                    "Block user input",
                    if details.is_empty() {
                        "Failed"
                    } else {
                        &details
                    },
                    "",
                );
                self.update_block_input_state(false);
            }
            back_notification::BlockInputState::BlkOffSucceeded => {
                self.update_block_input_state(false);
            }
            back_notification::BlockInputState::BlkOffFailed => {
                self.handler.msgbox(
                    "custom-error",
                    "Unblock user input",
                    if details.is_empty() {
                        "Failed"
                    } else {
                        &details
                    },
                    "",
                );
                self.update_block_input_state(true);
            }
            _ => {}
        }
    }

    #[inline(always)]
    fn update_privacy_mode(&mut self, impl_key: String, on: bool) {
        let mut config = self.handler.load_config();
        config.privacy_mode.v = on;
        if on {
            // For compatibility, version < 1.2.4, the default value is 'privacy_mode_impl_mag'.
            let impl_key = if impl_key.is_empty() {
                "privacy_mode_impl_mag".to_string()
            } else {
                impl_key
            };
            config
                .options
                .insert("privacy-mode-impl-key".to_string(), impl_key);
        }
        self.handler.save_config(config);

        self.handler.update_privacy_mode();
    }

    async fn handle_back_msg_privacy_mode(
        &mut self,
        state: back_notification::PrivacyModeState,
        details: String,
        impl_key: String,
    ) -> bool {
        match state {
            back_notification::PrivacyModeState::PrvOnByOther => {
                self.handler.msgbox(
                    "error",
                    "Connecting...",
                    "Someone turns on privacy mode, exit",
                    "",
                );
                return false;
            }
            back_notification::PrivacyModeState::PrvNotSupported => {
                self.handler
                    .msgbox("custom-error", "Privacy mode", "Unsupported", "");
                self.update_privacy_mode(impl_key, false);
            }
            back_notification::PrivacyModeState::PrvOnSucceeded => {
                self.handler
                    .msgbox("custom-nocancel", "Privacy mode", "Enter privacy mode", "");
                self.update_privacy_mode(impl_key, true);
            }
            back_notification::PrivacyModeState::PrvOnFailedDenied => {
                self.handler
                    .msgbox("custom-error", "Privacy mode", "Peer denied", "");
                self.update_privacy_mode(impl_key, false);
            }
            back_notification::PrivacyModeState::PrvOnFailedPlugin => {
                self.handler
                    .msgbox("custom-error", "Privacy mode", "Please install plugins", "");
                self.update_privacy_mode(impl_key, false);
            }
            back_notification::PrivacyModeState::PrvOnFailed => {
                self.handler.msgbox(
                    "custom-error",
                    "Privacy mode",
                    if details.is_empty() {
                        "Failed"
                    } else {
                        &details
                    },
                    "",
                );
                self.update_privacy_mode(impl_key, false);
            }
            back_notification::PrivacyModeState::PrvOffSucceeded => {
                self.handler
                    .msgbox("custom-nocancel", "Privacy mode", "Exit privacy mode", "");
                self.update_privacy_mode(impl_key, false);
            }
            back_notification::PrivacyModeState::PrvOffByPeer => {
                self.handler
                    .msgbox("custom-error", "Privacy mode", "Peer exit", "");
                self.update_privacy_mode(impl_key, false);
            }
            back_notification::PrivacyModeState::PrvOffFailed => {
                self.handler.msgbox(
                    "custom-error",
                    "Privacy mode",
                    if details.is_empty() {
                        "Failed to turn off"
                    } else {
                        &details
                    },
                    "",
                );
            }
            back_notification::PrivacyModeState::PrvOffUnknown => {
                self.handler
                    .msgbox("custom-error", "Privacy mode", "Turned off", "");
                // log::error!("Privacy mode is turned off with unknown reason");
                self.update_privacy_mode(impl_key, false);
            }
            _ => {}
        }
        true
    }

    #[cfg(any(target_os = "windows", feature = "unix-file-copy-paste"))]
    async fn handle_cliprdr_msg(
        &mut self,
        clip: camellia_remote_protocol::message_proto::Cliprdr,
        _peer: &mut Stream,
    ) {
        log::debug!("handling cliprdr msg from server peer");
        #[cfg(feature = "flutter")]
        if let Some(camellia_remote_protocol::message_proto::cliprdr::Union::FormatList(_)) =
            &clip.union
        {
            if self.client_conn_id
                != clipboard::get_client_conn_id(&crate::flutter::get_cur_peer_id()).unwrap_or(0)
            {
                return;
            }
        }

        let Some(clip) = crate::clipboard_file::msg_2_clip(clip) else {
            log::warn!("failed to decode cliprdr msg from server peer");
            return;
        };

        match &clip {
            clipboard::ClipboardFile::FormatList { .. } => {
                clipboard::operation::ClipboardOpGuard::initiate_operation(
                    self.client_conn_id,
                    0,
                    true,
                    0,
                );
            }
            clipboard::ClipboardFile::FormatDataResponse { .. } => {
                if let Err(e) =
                    clipboard::operation::ClipboardOpGuard::validate_format_data_response(
                        self.client_conn_id,
                        0,
                    )
                {
                    log::warn!("FormatDataResponse rejected: {}", e);
                    return;
                }
            }
            clipboard::ClipboardFile::FileContentsResponse { .. } => {
                if let Err(e) =
                    clipboard::operation::ClipboardOpGuard::validate_file_contents_response(
                        self.client_conn_id,
                        0,
                    )
                {
                    log::warn!("FileContentsResponse rejected: {}", e);
                    return;
                }
            }
            _ => {}
        }

        let is_stopping_allowed = clip.is_beginning_message();
        let file_transfer_enabled = self.handler.is_file_clipboard_required();
        let stop = is_stopping_allowed && !file_transfer_enabled;
        log::debug!(
                "Process clipboard message from server peer, stop: {}, is_stopping_allowed: {}, file_transfer_enabled: {}",
                stop, is_stopping_allowed, file_transfer_enabled);
        if !stop {
            #[cfg(any(
                target_os = "windows",
                all(target_os = "macos", feature = "unix-file-copy-paste")
            ))]
            if let Err(e) = ContextSend::make_sure_enabled() {
                log::error!("failed to restart clipboard context: {}", e);
            };
            #[cfg(target_os = "windows")]
            {
                let _ = ContextSend::proc(|context| -> ResultType<()> {
                    context
                        .server_clip_file(self.client_conn_id, clip)
                        .map_err(|e| e.into())
                });
            }
            #[cfg(feature = "unix-file-copy-paste")]
            if crate::is_support_file_copy_paste_num(self.handler.lc.read().unwrap().version) {
                let mut out_msgs = vec![];

                #[cfg(target_os = "macos")]
                if clipboard::platform::unix::macos::should_handle_msg(&clip) {
                    if let Err(e) = ContextSend::proc(|context| -> ResultType<()> {
                        context
                            .server_clip_file(self.client_conn_id, clip)
                            .map_err(|e| e.into())
                    }) {
                        log::error!("failed to handle cliprdr msg: {}", e);
                    }
                } else {
                    out_msgs = unix_file_clip::serve_clip_messages(
                        ClipboardSide::Client,
                        clip,
                        self.client_conn_id,
                    );
                }

                #[cfg(not(target_os = "macos"))]
                {
                    out_msgs = unix_file_clip::serve_clip_messages(
                        ClipboardSide::Client,
                        clip,
                        self.client_conn_id,
                    );
                }

                for msg in out_msgs.into_iter() {
                    allow_err!(_peer.send(&msg).await);
                }
            }
        }
    }

    fn new_video_thread(&mut self, display: usize) {
        if self.video_threads.len() >= MAX_DISPLAY_DECODERS {
            log::warn!(
                "Maximum concurrent display decoders ({}) reached; ignoring display {}",
                MAX_DISPLAY_DECODERS,
                display
            );
            return;
        }
        let video_queue = Arc::new(VideoQueue::new());
        let decode_fps = Arc::new(RwLock::new(None));
        let frame_count = Arc::new(RwLock::new(0));
        let cancel_token = Arc::new(AtomicBool::new(false));
        let handler = self.handler.ui_handler.clone();
        let fc = frame_count.clone();

        let handle = crate::client::start_video_thread(
            self.handler.clone(),
            display,
            video_queue.clone(),
            decode_fps.clone(),
            self.chroma.clone(),
            cancel_token.clone(),
            move |display: usize,
                  data: &mut scrap::ImageRgb,
                  _texture: *mut c_void,
                  pixelbuffer: bool| {
                *fc.write().unwrap() += 1;
                if pixelbuffer {
                    handler.on_rgba(display, data);
                } else {
                    #[cfg(all(feature = "vram", feature = "flutter"))]
                    handler.on_texture(display, _texture);
                }
            },
        );

        let video_thread = VideoThread {
            queue: video_queue,
            decode_fps,
            frame_count,
            cancel_token,
            join_handle: Some(handle),
            fps_control: Default::default(),
        };

        self.video_threads.insert(display, video_thread);
        if self.video_threads.len() == 1 {
            let auto_record =
                LocalConfig::get_bool_option(config::keys::OPTION_ALLOW_AUTO_RECORD_OUTGOING);
            self.handler.lc.write().unwrap().record_state = auto_record;
            self.update_record_state();
        }
    }

    fn update_record_state(&mut self) {
        self.update_record_state_with_error(None);
    }

    fn update_record_state_with_error(&mut self, error: Option<String>) {
        // state
        let permission = self.handler.lc.read().unwrap().record_permission;
        if !permission {
            self.handler.lc.write().unwrap().record_state = false;
        }
        let state = self.handler.lc.read().unwrap().record_state;
        let start = state && permission;
        if self.last_record_state == start && error.is_none() {
            return;
        }
        self.last_record_state = start;
        log::info!("record screen start: {start}, error: {error:?}");
        // update local
        for (_, v) in self.video_threads.iter_mut() {
            v.queue.push_record_screen(start);
        }
        self.handler.update_record_status(start, error);
        // update remote
        let mut misc = Misc::new();
        misc.set_client_record_status(start);
        let mut msg = Message::new();
        msg.set_misc(misc);
        self.sender.send(Data::Message(msg)).ok();
    }

    fn update_allowed_displays(&mut self, displays: &[DisplayInfo]) {
        let new_allowed: HashSet<usize> = if displays.is_empty() {
            let mut s = HashSet::new();
            s.insert(0);
            s
        } else {
            (0..displays.len().min(MAX_DISPLAY_DECODERS)).collect()
        };
        self.allowed_displays = new_allowed.clone();

        let removed: Vec<usize> = self
            .video_threads
            .keys()
            .filter(|d| !new_allowed.contains(d))
            .cloned()
            .collect();
        for d in removed {
            log::info!("Pruning removed display decoder thread for display {d}");
            if let Some(mut thread) = self.video_threads.remove(&d) {
                thread.stop();
            }
        }
    }

    pub fn teardown_video_threads(&mut self) {
        for (_, mut thread) in self.video_threads.drain() {
            thread.stop();
        }
    }
}

impl<T: InvokeUiSession> Drop for Remote<T> {
    fn drop(&mut self) {
        self.stop_voice_call();
        if let Some(mut worker) = self.audio_worker.take() {
            worker.stop();
        }
        self.teardown_video_threads();
        crate::client::print_dispatcher::PrintDispatcher::global()
            .cancel_generation(self.connection_generation);
    }
}

struct RemoveJob {
    files: Vec<FileEntry>,
    path: String,
    sep: &'static str,
    is_remote: bool,
    no_confirm: bool,
    last_update_job_status: Instant,
}

impl RemoveJob {
    fn new(files: Vec<FileEntry>, path: String, sep: &'static str, is_remote: bool) -> Self {
        Self {
            files,
            path,
            sep,
            is_remote,
            no_confirm: false,
            last_update_job_status: Instant::now(),
        }
    }

    pub fn _gen_meta(&self) -> RemoveJobMeta {
        RemoveJobMeta {
            path: self.path.clone(),
            is_remote: self.is_remote,
            no_confirm: self.no_confirm,
        }
    }
}

#[derive(Debug, Default)]
pub struct FpsControl {
    pub refresh_times: usize,
    pub last_refresh_instant: Option<Instant>,
    pub idle_counter: usize,
    pub inactive_counter: usize,
}

pub struct VideoThread {
    pub queue: Arc<VideoQueue>,
    pub decode_fps: Arc<RwLock<Option<usize>>>,
    pub frame_count: Arc<RwLock<usize>>,
    pub cancel_token: Arc<AtomicBool>,
    pub join_handle: Option<std::thread::JoinHandle<()>>,
    pub fps_control: FpsControl,
}

impl VideoThread {
    pub fn stop(&mut self) {
        self.stop_with_timeout(Duration::from_millis(500));
    }

    pub fn stop_with_timeout(&mut self, timeout: Duration) {
        self.cancel_token.store(true, Ordering::SeqCst);
        self.queue.clear();
        if let Some(handle) = self.join_handle.take() {
            let (tx, rx) = std::sync::mpsc::channel();
            let joiner = std::thread::spawn(move || {
                let res = handle.join();
                let _ = tx.send(res);
            });
            match rx.recv_timeout(timeout) {
                Ok(Ok(())) => {
                    let _ = joiner.join();
                    log::debug!("Video thread joined cleanly");
                }
                Ok(Err(_panic)) => {
                    let _ = joiner.join();
                    log::warn!("Video thread panicked on join");
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    log::warn!(
                        "Video thread join exceeded deadline of {:?}; detached",
                        timeout
                    );
                }
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {}
            }
        }
    }
}

impl Drop for VideoThread {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn local_recursive_directory_removal_preserves_failure_result() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "camellia-local-remove-error-{}-{unique}",
            std::process::id()
        ));
        let nested = root.join("nested");
        std::fs::create_dir_all(&nested).unwrap();
        std::fs::write(nested.join("payload.txt"), b"must remain").unwrap();

        let result = remove_local_empty_dir_result(701, root.to_string_lossy().into_owned());
        match result {
            Data::RemoveDirResult((id, Some(err))) => {
                assert_eq!(id, 701);
                assert!(err.contains("nested"), "unexpected removal error: {err}");
            }
            _ => panic!("expected a failed local recursive removal result"),
        }
        assert!(nested.join("payload.txt").is_file());
        std::fs::remove_dir_all(root).unwrap();
    }
}
