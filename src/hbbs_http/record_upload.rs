use crate::hbbs_http::create_http_client_for_configuration;
use bytes::Bytes;
use camellia_remote_protocol::{
    bail,
    config::{self, keys, Config, Socks5Server},
    log, ResultType,
};
use reqwest::{
    blocking::{Body, Client, Response},
    StatusCode,
};
use scrap::record::RecordState;
use serde_derive::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs::{File, OpenOptions},
    io::{prelude::*, SeekFrom},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::Receiver,
        Arc,
    },
    time::{Duration, Instant},
};
use uuid::Uuid;

const PROTOCOL_VERSION: u8 = 2;
const SHOULD_SEND_TIME: Duration = Duration::from_secs(1);
const SHOULD_SEND_SIZE: u64 = 1024 * 1024;
const MAX_UPLOAD_CHUNK_SIZE: u64 = 4 * 1024 * 1024;
const UPLOAD_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_RESPONSE_BYTES: u64 = 16 * 1024;
const MAX_STATE_BYTES: u64 = 64 * 1024;
const STATE_SUFFIXES: [&str; 2] = [
    ".camellia-record-upload-v2.0",
    ".camellia-record-upload-v2.1",
];
const FINALIZE_RETRY_DELAYS: [Duration; 2] =
    [Duration::from_millis(250), Duration::from_millis(750)];

/// Whether finished recordings are uploaded to the configured API server.
///
/// Uploading is an explicit opt-in because recordings contain the full remote
/// session. A valid account token is also required by the API.
pub fn is_enable() -> bool {
    config::option2bool(
        keys::OPTION_UPLOAD_RECORDINGS_TO_SERVER,
        &Config::get_option(keys::OPTION_UPLOAD_RECORDINGS_TO_SERVER),
    ) && crate::get_api_access_token().is_some()
}

pub struct RecordUploadHandle {
    stop_signal: Arc<AtomicBool>,
    join_handle: Option<std::thread::JoinHandle<()>>,
}

impl RecordUploadHandle {
    pub fn new(stop_signal: Arc<AtomicBool>, handle: std::thread::JoinHandle<()>) -> Self {
        Self {
            stop_signal,
            join_handle: Some(handle),
        }
    }

    pub fn stop(&mut self, deadline: Duration) -> bool {
        self.stop_signal.store(true, Ordering::SeqCst);
        if let Some(handle) = self.join_handle.take() {
            let start = Instant::now();
            while !handle.is_finished() && start.elapsed() < deadline {
                std::thread::sleep(Duration::from_millis(10));
            }
            if handle.is_finished() {
                let _ = handle.join();
                true
            } else {
                log::warn!(
                    "Record upload worker did not exit within bounded deadline {:?}",
                    deadline
                );
                false
            }
        } else {
            true
        }
    }
}

impl Drop for RecordUploadHandle {
    fn drop(&mut self) {
        self.stop(Duration::from_millis(500));
    }
}

pub fn run(rx: Receiver<RecordState>, recording_dir: String) -> RecordUploadHandle {
    let stop_signal = Arc::new(AtomicBool::new(false));
    let stop_signal_clone = stop_signal.clone();
    let handle = std::thread::spawn(move || {
        let api_server = crate::get_api_server(
            Config::get_option("api-server"),
            Config::get_option("custom-rendezvous-server"),
        );
        if api_server.is_empty() {
            log::warn!("recording upload is enabled, but the API server is not configured");
            return;
        }
        // Lazy construction permits recovery after an invalid proxy is repaired
        // without abandoning this recording's durable state or receiver.
        let mut uploader = RecordUploader::new(api_server);
        uploader.recover_pending(&recording_dir);

        while !stop_signal_clone.load(Ordering::SeqCst) {
            let msg = match rx.recv_timeout(Duration::from_millis(200)) {
                Ok(m) => m,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    log::trace!("recording upload thread channel disconnected");
                    break;
                }
            };
            let result = match msg {
                RecordState::NewFile(filepath) => uploader.handle_new_file(filepath),
                RecordState::NewFrame => {
                    // Coalesce any redundant NewFrame messages already waiting in the channel
                    let mut extra_non_frame = None;
                    while let Ok(extra) = rx.try_recv() {
                        match extra {
                            RecordState::NewFrame => {} // drop duplicate NewFrame
                            other => {
                                extra_non_frame = Some(other);
                                break;
                            }
                        }
                    }
                    let res = uploader.handle_frame(false).map(|_| ());
                    if let Some(other) = extra_non_frame {
                        let res2 = match other {
                            RecordState::NewFile(filepath) => uploader.handle_new_file(filepath),
                            RecordState::WriteTail => uploader.handle_tail_with_retry(),
                            RecordState::RemoveFile => uploader.handle_abort(),
                            RecordState::NewFrame => Ok(()),
                        };
                        if let Err(e) = res2 {
                            log::error!("recording upload error on coalesced event: {}", e);
                        }
                    }
                    res
                }
                RecordState::WriteTail => uploader.handle_tail_with_retry(),
                RecordState::RemoveFile => uploader.handle_abort(),
            };
            if let Err(error) = result {
                // The durable sidecar remains authoritative after errors. A
                // later frame/event or the next process start can reconcile it
                // with the server instead of guessing whether a request landed.
                log::error!("recording upload paused: {}", error);
            }
        }
    });
    RecordUploadHandle::new(stop_signal, handle)
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct PendingChunk {
    chunk_id: String,
    offset: u64,
    revision: u64,
    length: u64,
    digest: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct PersistedUpload {
    protocol: u8,
    api_server_fingerprint: String,
    filepath: String,
    filename: String,
    create_id: String,
    upload_id: Option<String>,
    offset: u64,
    revision: u64,
    pending_chunk: Option<PendingChunk>,
    final_size: Option<u64>,
    final_digest: Option<String>,
    abort_requested: bool,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct StoredUpload {
    protocol: u8,
    sequence: u64,
    payload: PersistedUpload,
    checksum: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RemoteUploadState {
    protocol: u8,
    upload_id: String,
    state: String,
    offset: u64,
    revision: u64,
    finalized: bool,
    final_size: Option<u64>,
    final_digest: Option<String>,
    queried_chunk_committed: Option<bool>,
}

struct RecordUploader {
    client: Option<Client>,
    client_policy: Option<Socks5Server>,
    api_server: String,
    api_server_fingerprint: String,
    state: Option<PersistedUpload>,
    state_sequence: u64,
    last_send: Instant,
    retry_not_before: Option<Instant>,
}

impl RecordUploader {
    fn client_for_policy(&mut self, policy: Option<Socks5Server>) -> ResultType<Client> {
        if self.client_policy == policy {
            if let Some(client) = &self.client {
                return Ok(client.clone());
            }
        }
        // Remove the old route BEFORE validating/building a replacement. A
        // failed policy update must not leave a usable stale direct client.
        self.client = None;
        let client = create_http_client_for_configuration(policy.as_ref())?;
        self.client_policy = policy;
        self.client = Some(client.clone());
        Ok(client)
    }

    fn new(api_server: String) -> Self {
        let api_server_fingerprint = sha256_hex(api_server.as_bytes());
        Self {
            client: None,
            client_policy: None,
            api_server,
            api_server_fingerprint,
            state: None,
            state_sequence: 0,
            last_send: Instant::now(),
            retry_not_before: None,
        }
    }

    fn request<Q, B>(
        &mut self,
        operation_event_id: &str,
        query: &Q,
        body: B,
    ) -> ResultType<RemoteUploadState>
    where
        Q: serde::Serialize + ?Sized,
        B: Into<Body>,
    {
        if self
            .retry_not_before
            .is_some_and(|deadline| Instant::now() < deadline)
        {
            bail!("recording upload is waiting for the server retry window");
        }
        let Some(access_token) = crate::get_api_access_token() else {
            bail!("API account session required for recording upload");
        };
        let operation = crate::common::HttpOperation::from_event_id(operation_event_id)?;
        let client = self.client_for_policy(Config::get_socks())?;
        let mut request = client
            .post(format!("{}/api/record", self.api_server))
            .bearer_auth(access_token)
            .query(query)
            .body(body)
            .timeout(UPLOAD_TIMEOUT);
        for (name, value) in operation.correlation_headers() {
            request = request.header(name, value);
        }
        let response = request
            .send()
            .map_err(|error| camellia_remote_protocol::anyhow::anyhow!(error.to_string()))?;
        let status = response.status();
        if let Some(delay) = retry_delay(
            status,
            response
                .headers()
                .get(reqwest::header::RETRY_AFTER)
                .and_then(|value| value.to_str().ok()),
        ) {
            self.retry_not_before = Some(Instant::now() + delay);
        } else if status.is_success() {
            self.retry_not_before = None;
        }
        parse_response(response)
    }

    fn retry_window_active(&self) -> bool {
        self.retry_not_before
            .is_some_and(|deadline| Instant::now() < deadline)
    }

    fn recover_pending(&mut self, recording_dir: &str) {
        let pending_paths = match discover_state_paths(Path::new(recording_dir)) {
            Ok(paths) => paths,
            Err(error) => {
                log::error!("recording upload recovery scan failed: {}", error);
                return;
            }
        };
        for filepath in pending_paths {
            let loaded = match load_state(&filepath, &self.api_server_fingerprint) {
                Ok(Some(loaded)) => loaded,
                Ok(None) => continue,
                Err(error) => {
                    log::error!("recording upload recovery state is invalid: {}", error);
                    continue;
                }
            };
            self.state = Some(loaded.0);
            self.state_sequence = loaded.1;
            self.last_send = Instant::now();
            let finalizing = self
                .state
                .as_ref()
                .map(|state| state.final_size.is_some() && !state.abort_requested)
                .unwrap_or(false);
            let result = if finalizing {
                self.handle_tail_with_retry()
            } else {
                self.handle_abort()
            };
            if let Err(error) = result {
                log::error!("recording upload recovery paused: {}", error);
                self.state = None;
                self.state_sequence = 0;
            }
        }
    }

    fn handle_new_file(&mut self, filepath: String) -> ResultType<()> {
        let path = PathBuf::from(&filepath);
        let Some(filename) = path.file_name().and_then(|name| name.to_str()) else {
            bail!("recording path has no UTF-8 filename");
        };
        if let Some(current) = &self.state {
            if Path::new(&current.filepath) == path {
                return self.ensure_created();
            }
            bail!("previous recording upload is still unresolved");
        }
        if state_files_exist(&path) {
            bail!("recording upload state already exists for this file");
        }
        let state = PersistedUpload {
            protocol: PROTOCOL_VERSION,
            api_server_fingerprint: self.api_server_fingerprint.clone(),
            filepath,
            filename: filename.to_owned(),
            create_id: Uuid::new_v4().to_string(),
            upload_id: None,
            offset: 0,
            revision: 0,
            pending_chunk: None,
            final_size: None,
            final_digest: None,
            abort_requested: false,
        };
        self.start_state(state)?;
        self.last_send = Instant::now();
        self.ensure_created()
    }

    fn ensure_created(&mut self) -> ResultType<()> {
        let state = self.current_state()?.clone();
        if state.upload_id.is_some() {
            return Ok(());
        }
        let response = self.request(
            &state.create_id,
            &[
                ("version", PROTOCOL_VERSION.to_string()),
                ("type", "new".to_owned()),
                ("file", state.filename.clone()),
                ("create_id", state.create_id.clone()),
            ],
            Bytes::new(),
        )?;
        validate_remote_state(&response)?;
        if response.state != "active" || response.offset != 0 || response.revision != 0 {
            bail!("recording create returned an invalid committed state");
        }
        let mut updated = state;
        updated.upload_id = Some(response.upload_id);
        self.store_state(updated)
    }

    fn handle_frame(&mut self, flush: bool) -> ResultType<bool> {
        // Recorded-frame notifications can arrive many times per second. A
        // retryable server rejection must suppress that hot path as well as
        // the HTTP request itself, otherwise every frame would still emit an
        // error and repeat local reconciliation work during Retry-After.
        if !flush && self.retry_window_active() {
            return Ok(false);
        }
        self.ensure_created()?;
        if self.current_state()?.pending_chunk.is_some() {
            self.reconcile_pending_chunk()?;
        }
        let state = self.current_state()?.clone();
        if state.abort_requested {
            bail!("recording upload is aborting");
        }
        if !flush && self.last_send.elapsed() < SHOULD_SEND_TIME {
            return Ok(false);
        }
        let file = File::open(&state.filepath)?;
        let current_len = file.metadata()?.len();
        let available_len = state.final_size.unwrap_or(current_len);
        if current_len < available_len {
            bail!("recording file is shorter than its persisted final size");
        }
        if available_len <= state.offset {
            return Ok(false);
        }
        if !flush && available_len - state.offset < SHOULD_SEND_SIZE {
            return Ok(false);
        }
        let length = (available_len - state.offset).min(MAX_UPLOAD_CHUNK_SIZE);
        let data = read_local_range(&state.filepath, state.offset, length)?;
        let pending = PendingChunk {
            chunk_id: Uuid::new_v4().to_string(),
            offset: state.offset,
            revision: state.revision,
            length,
            digest: sha256_hex(&data),
        };
        let mut with_pending = state;
        with_pending.pending_chunk = Some(pending.clone());
        self.store_state(with_pending)?;

        let response = self.send_pending_chunk(&pending, data)?;
        self.commit_pending_response(&pending, response)?;
        self.last_send = Instant::now();
        Ok(true)
    }

    fn reconcile_pending_chunk(&mut self) -> ResultType<()> {
        let state = self.current_state()?.clone();
        let Some(pending) = state.pending_chunk.clone() else {
            return Ok(());
        };
        let upload_id = required_upload_id(&state)?;
        let response = self.request(
            &pending.chunk_id,
            &[
                ("version", PROTOCOL_VERSION.to_string()),
                ("type", "status".to_owned()),
                ("upload_id", upload_id.to_owned()),
                ("chunk_id", pending.chunk_id.clone()),
                ("offset", pending.offset.to_string()),
                ("revision", pending.revision.to_string()),
                ("length", pending.length.to_string()),
                ("digest", pending.digest.clone()),
            ],
            Bytes::new(),
        )?;
        validate_remote_state(&response)?;
        if pending_was_committed(&response, &pending, upload_id)? {
            self.commit_pending_response(&pending, response)?;
            return Ok(());
        }
        let data = read_local_range(&state.filepath, pending.offset, pending.length)?;
        if sha256_hex(&data) != pending.digest {
            bail!("recording pending chunk no longer matches the local file");
        }
        let response = self.send_pending_chunk(&pending, data)?;
        self.commit_pending_response(&pending, response)
    }

    fn send_pending_chunk(
        &mut self,
        pending: &PendingChunk,
        data: Vec<u8>,
    ) -> ResultType<RemoteUploadState> {
        let state = self.current_state()?;
        let upload_id = required_upload_id(state)?.to_owned();
        self.request(
            &pending.chunk_id,
            &[
                ("version", PROTOCOL_VERSION.to_string()),
                ("type", "part".to_owned()),
                ("upload_id", upload_id),
                ("offset", pending.offset.to_string()),
                ("revision", pending.revision.to_string()),
                ("length", pending.length.to_string()),
                ("digest", pending.digest.clone()),
                ("chunk_id", pending.chunk_id.clone()),
            ],
            data,
        )
    }

    fn commit_pending_response(
        &mut self,
        pending: &PendingChunk,
        response: RemoteUploadState,
    ) -> ResultType<()> {
        validate_remote_state(&response)?;
        let state = self.current_state()?.clone();
        if response.upload_id != required_upload_id(&state)?
            || response.state != "active"
            || response.offset != pending.offset + pending.length
            || response.revision != pending.revision + 1
        {
            bail!("recording chunk acknowledgement is not the durable next revision");
        }
        let mut updated = state;
        updated.offset = response.offset;
        updated.revision = response.revision;
        updated.pending_chunk = None;
        self.store_state(updated)
    }

    fn handle_tail_with_retry(&mut self) -> ResultType<()> {
        let mut result = self.handle_tail();
        for delay in FINALIZE_RETRY_DELAYS {
            if result.is_ok() {
                return result;
            }
            std::thread::sleep(delay);
            result = self.handle_tail();
        }
        result
    }

    fn handle_tail(&mut self) -> ResultType<()> {
        if self.current_state()?.final_size.is_none() {
            let state = self.current_state()?.clone();
            let (final_size, final_digest) = hash_local_file(&state.filepath)?;
            let mut finalizing = state;
            finalizing.final_size = Some(final_size);
            finalizing.final_digest = Some(final_digest);
            self.store_state(finalizing)?;
        }
        while self.handle_frame(true)? {}
        let state = self.current_state()?.clone();
        if state.pending_chunk.is_some() {
            bail!("recording still has an uncommitted chunk");
        }
        let final_size = state.final_size.ok_or_else(|| {
            camellia_remote_protocol::anyhow::anyhow!("recording final size is missing")
        })?;
        let final_digest = state.final_digest.clone().ok_or_else(|| {
            camellia_remote_protocol::anyhow::anyhow!("recording final digest is missing")
        })?;
        if state.offset != final_size {
            bail!("recording upload offset does not match the final size");
        }
        let upload_id = required_upload_id(&state)?;
        let response = self.request(
            upload_id,
            &[
                ("version", PROTOCOL_VERSION.to_string()),
                ("type", "finalize".to_owned()),
                ("upload_id", upload_id.to_owned()),
                ("revision", state.revision.to_string()),
                ("final_size", final_size.to_string()),
                ("final_digest", final_digest.clone()),
            ],
            Bytes::new(),
        )?;
        validate_remote_state(&response)?;
        if response.upload_id != upload_id
            || response.state != "finalized"
            || !response.finalized
            || response.offset != final_size
            || response.revision != state.revision
            || response.final_size != Some(final_size)
            || response.final_digest.as_deref() != Some(final_digest.as_str())
        {
            bail!("recording finalize acknowledgement is inconsistent");
        }
        remove_state_files(Path::new(&state.filepath))?;
        self.state = None;
        self.state_sequence = 0;
        log::info!("recording upload finalized");
        Ok(())
    }

    fn handle_abort(&mut self) -> ResultType<()> {
        let Some(current) = self.state.clone() else {
            return Ok(());
        };
        let mut state = current;
        if !state.abort_requested {
            state.abort_requested = true;
            self.store_state(state.clone())?;
        }
        self.ensure_created()?;
        state = self.current_state()?.clone();
        let upload_id = required_upload_id(&state)?;
        let response = self.request(
            upload_id,
            &[
                ("version", PROTOCOL_VERSION.to_string()),
                ("type", "abort".to_owned()),
                ("upload_id", upload_id.to_owned()),
            ],
            Bytes::new(),
        )?;
        validate_remote_state(&response)?;
        if response.upload_id != upload_id || response.state != "aborted" || response.finalized {
            bail!("recording abort acknowledgement is inconsistent");
        }
        remove_state_files(Path::new(&state.filepath))?;
        self.state = None;
        self.state_sequence = 0;
        Ok(())
    }

    fn current_state(&self) -> ResultType<&PersistedUpload> {
        self.state.as_ref().ok_or_else(|| {
            camellia_remote_protocol::anyhow::anyhow!("recording upload state is missing")
        })
    }

    fn start_state(&mut self, state: PersistedUpload) -> ResultType<()> {
        if self.state.is_some() {
            bail!("previous recording upload is still unresolved");
        }
        validate_persisted_state(&state, &self.api_server_fingerprint)?;
        save_state(&state, 1)?;
        self.state = Some(state);
        self.state_sequence = 1;
        Ok(())
    }

    fn store_state(&mut self, state: PersistedUpload) -> ResultType<()> {
        validate_persisted_state(&state, &self.api_server_fingerprint)?;
        let next_sequence = self.state_sequence.checked_add(1).ok_or_else(|| {
            camellia_remote_protocol::anyhow::anyhow!("recording state sequence exhausted")
        })?;
        save_state(&state, next_sequence)?;
        self.state = Some(state);
        self.state_sequence = next_sequence;
        Ok(())
    }
}

fn parse_response(mut response: Response) -> ResultType<RemoteUploadState> {
    let status = response.status();
    if !status.is_success() {
        bail!("recording upload failed with HTTP {}", status.as_u16());
    }
    let mut body = Vec::new();
    response
        .by_ref()
        .take(MAX_RESPONSE_BYTES + 1)
        .read_to_end(&mut body)?;
    if body.len() as u64 > MAX_RESPONSE_BYTES {
        bail!("recording upload response is too large");
    }
    let state: RemoteUploadState = serde_json::from_slice(&body)?;
    validate_remote_state(&state)?;
    Ok(state)
}

fn retry_delay(status: StatusCode, retry_after: Option<&str>) -> Option<Duration> {
    if !matches!(
        status,
        StatusCode::TOO_MANY_REQUESTS
            | StatusCode::SERVICE_UNAVAILABLE
            | StatusCode::INSUFFICIENT_STORAGE
    ) {
        return None;
    }
    let seconds = retry_after
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(30)
        .clamp(1, 3600);
    Some(Duration::from_secs(seconds))
}

fn validate_remote_state(state: &RemoteUploadState) -> ResultType<()> {
    if state.protocol != PROTOCOL_VERSION || !is_canonical_v4_uuid(&state.upload_id) {
        bail!("recording upload response uses an unsupported protocol or identity");
    }
    match state.state.as_str() {
        "active"
            if !state.finalized && state.final_size.is_none() && state.final_digest.is_none() => {}
        "aborted"
            if !state.finalized && state.final_size.is_none() && state.final_digest.is_none() => {}
        "finalized"
            if state.finalized
                && state.final_size == Some(state.offset)
                && state
                    .final_digest
                    .as_deref()
                    .map(is_lower_sha256)
                    .unwrap_or(false) => {}
        _ => bail!("recording upload response has an invalid state"),
    }
    Ok(())
}

fn pending_was_committed(
    remote: &RemoteUploadState,
    pending: &PendingChunk,
    upload_id: &str,
) -> ResultType<bool> {
    validate_remote_state(remote)?;
    if remote.upload_id != upload_id || remote.state != "active" {
        bail!("recording status does not match the active upload");
    }
    if remote.offset == pending.offset + pending.length
        && remote.revision == pending.revision + 1
        && remote.queried_chunk_committed == Some(true)
    {
        return Ok(true);
    }
    if remote.offset == pending.offset
        && remote.revision == pending.revision
        && remote.queried_chunk_committed == Some(false)
    {
        return Ok(false);
    }
    bail!("recording status diverged from the persisted pending chunk")
}

fn validate_persisted_state(state: &PersistedUpload, expected_server: &str) -> ResultType<()> {
    if state.protocol != PROTOCOL_VERSION
        || state.api_server_fingerprint != expected_server
        || !is_lower_sha256(&state.api_server_fingerprint)
        || !is_canonical_v4_uuid(&state.create_id)
        || state
            .upload_id
            .as_deref()
            .map(is_canonical_v4_uuid)
            .is_some_and(|valid| !valid)
        || state.filename.is_empty()
        || Path::new(&state.filepath)
            .file_name()
            .and_then(|name| name.to_str())
            != Some(&state.filename)
    {
        bail!("recording upload sidecar identity is invalid");
    }
    if let Some(pending) = &state.pending_chunk {
        if !is_canonical_v4_uuid(&pending.chunk_id)
            || pending.offset != state.offset
            || pending.revision != state.revision
            || pending.length == 0
            || pending.length > MAX_UPLOAD_CHUNK_SIZE
            || !is_lower_sha256(&pending.digest)
        {
            bail!("recording upload sidecar pending chunk is invalid");
        }
    }
    match (&state.final_size, &state.final_digest) {
        (None, None) => {}
        (Some(size), Some(digest)) if *size >= state.offset && is_lower_sha256(digest) => {}
        _ => bail!("recording upload sidecar final identity is invalid"),
    }
    if state.abort_requested && state.final_size.is_some() {
        bail!("recording upload cannot finalize and abort simultaneously");
    }
    Ok(())
}

fn required_upload_id(state: &PersistedUpload) -> ResultType<&str> {
    state.upload_id.as_deref().ok_or_else(|| {
        camellia_remote_protocol::anyhow::anyhow!("recording upload identity is missing")
    })
}

fn is_canonical_v4_uuid(value: &str) -> bool {
    Uuid::parse_str(value)
        .ok()
        .filter(|parsed| parsed.get_version_num() == 4 && parsed.to_string() == value)
        .is_some()
}

fn is_lower_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn sha256_hex(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}

fn read_local_range(filepath: &str, offset: u64, length: u64) -> ResultType<Vec<u8>> {
    let length: usize = length.try_into().map_err(|_| {
        camellia_remote_protocol::anyhow::anyhow!("recording chunk length is too large")
    })?;
    let mut file = File::open(filepath)?;
    file.seek(SeekFrom::Start(offset))?;
    let mut data = vec![0; length];
    file.read_exact(&mut data)?;
    Ok(data)
}

fn hash_local_file(filepath: &str) -> ResultType<(u64, String)> {
    let mut file = File::open(filepath)?;
    let mut digest = Sha256::new();
    let mut size = 0u64;
    let mut buffer = vec![0; 1024 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        size = size
            .checked_add(read as u64)
            .ok_or_else(|| camellia_remote_protocol::anyhow::anyhow!("recording size exhausted"))?;
        digest.update(&buffer[..read]);
    }
    Ok((size, format!("{:x}", digest.finalize())))
}

fn state_path(filepath: &Path, slot: usize) -> PathBuf {
    let mut value = filepath.as_os_str().to_owned();
    value.push(STATE_SUFFIXES[slot]);
    PathBuf::from(value)
}

fn state_files_exist(filepath: &Path) -> bool {
    (0..STATE_SUFFIXES.len()).any(|slot| state_path(filepath, slot).exists())
}

fn state_checksum(sequence: u64, state: &PersistedUpload) -> ResultType<String> {
    Ok(sha256_hex(&serde_json::to_vec(&(sequence, state))?))
}

fn save_state(state: &PersistedUpload, sequence: u64) -> ResultType<()> {
    let stored = StoredUpload {
        protocol: PROTOCOL_VERSION,
        sequence,
        payload: state.clone(),
        checksum: state_checksum(sequence, state)?,
    };
    let data = serde_json::to_vec(&stored)?;
    if data.len() as u64 > MAX_STATE_BYTES {
        bail!("recording upload state is too large");
    }
    let path = state_path(
        Path::new(&state.filepath),
        sequence as usize % STATE_SUFFIXES.len(),
    );
    let mut options = OpenOptions::new();
    options.create(true).truncate(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(
            camellia_remote_protocol::libc::O_CLOEXEC | camellia_remote_protocol::libc::O_NOFOLLOW,
        );
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        use windows::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT;
        options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0);
    }
    let mut file = options.open(&path)?;
    if !file.metadata()?.is_file() {
        bail!("recording upload sidecar is not a regular file");
    }
    file.write_all(&data)?;
    file.sync_all()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    }
    sync_parent_directory(&path)?;
    Ok(())
}

fn load_state(
    filepath: &Path,
    expected_server: &str,
) -> ResultType<Option<(PersistedUpload, u64)>> {
    let mut valid = Vec::new();
    let mut found = false;
    for slot in 0..STATE_SUFFIXES.len() {
        let path = state_path(filepath, slot);
        let mut options = OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(
                camellia_remote_protocol::libc::O_CLOEXEC
                    | camellia_remote_protocol::libc::O_NOFOLLOW,
            );
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            use windows::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT;
            options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0);
        }
        let mut file = match options.open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error.into()),
        };
        if !file.metadata()?.is_file() {
            bail!("recording upload sidecar is not a regular file");
        }
        found = true;
        let mut data = Vec::new();
        Read::by_ref(&mut file)
            .take(MAX_STATE_BYTES + 1)
            .read_to_end(&mut data)?;
        if data.len() as u64 > MAX_STATE_BYTES {
            continue;
        }
        let Ok(stored) = serde_json::from_slice::<StoredUpload>(&data) else {
            continue;
        };
        if stored.protocol != PROTOCOL_VERSION
            || state_checksum(stored.sequence, &stored.payload)? != stored.checksum
            || validate_persisted_state(&stored.payload, expected_server).is_err()
            || Path::new(&stored.payload.filepath) != filepath
        {
            continue;
        }
        valid.push((stored.payload, stored.sequence));
    }
    if let Some(latest) = valid.into_iter().max_by_key(|(_, sequence)| *sequence) {
        return Ok(Some(latest));
    }
    if found {
        bail!("all recording upload sidecar slots are invalid");
    }
    Ok(None)
}

fn remove_state_files(filepath: &Path) -> ResultType<()> {
    for slot in 0..STATE_SUFFIXES.len() {
        match std::fs::remove_file(state_path(filepath, slot)) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    if let Some(parent) = filepath.parent() {
        sync_directory(parent)?;
    }
    Ok(())
}

fn discover_state_paths(directory: &Path) -> ResultType<Vec<PathBuf>> {
    let mut paths = HashSet::new();
    let entries = match std::fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error.into()),
    };
    for entry in entries {
        let entry = entry?;
        if !entry.file_type()?.is_file() {
            continue;
        }
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        for suffix in STATE_SUFFIXES {
            if let Some(recording_name) = name.strip_suffix(suffix) {
                paths.insert(directory.join(recording_name));
            }
        }
    }
    let mut paths: Vec<_> = paths.into_iter().collect();
    paths.sort();
    Ok(paths)
}

fn sync_parent_directory(path: &Path) -> ResultType<()> {
    if let Some(parent) = path.parent() {
        sync_directory(parent)?;
    }
    Ok(())
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> ResultType<()> {
    File::open(path)?.sync_all()?;
    Ok(())
}

#[cfg(not(unix))]
fn sync_directory(_path: &Path) -> ResultType<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_state(filepath: &Path, server_fingerprint: &str) -> PersistedUpload {
        PersistedUpload {
            protocol: PROTOCOL_VERSION,
            api_server_fingerprint: server_fingerprint.to_owned(),
            filepath: filepath.to_string_lossy().into_owned(),
            filename: filepath.file_name().unwrap().to_string_lossy().into_owned(),
            create_id: "11111111-1111-4111-8111-111111111111".to_owned(),
            upload_id: Some("22222222-2222-4222-8222-222222222222".to_owned()),
            offset: 0,
            revision: 0,
            pending_chunk: None,
            final_size: None,
            final_digest: None,
            abort_requested: false,
        }
    }

    #[test]
    fn sidecar_falls_back_to_last_checksum_valid_slot() {
        let directory =
            std::env::temp_dir().join(format!("camellia-record-state-{}", Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let filepath = directory.join("recording.webm");
        File::create(&filepath).unwrap();
        let server_fingerprint = sha256_hex(b"https://management.example.test");
        let mut first = test_state(&filepath, &server_fingerprint);
        save_state(&first, 1).unwrap();
        first.offset = 4;
        first.revision = 1;
        save_state(&first, 2).unwrap();
        std::fs::write(state_path(&filepath, 0), b"truncated").unwrap();

        let (recovered, sequence) = load_state(&filepath, &server_fingerprint).unwrap().unwrap();
        assert_eq!(sequence, 1);
        assert_eq!(recovered.offset, 0);
        assert_eq!(
            discover_state_paths(&directory).unwrap(),
            vec![filepath.clone()]
        );

        remove_state_files(&filepath).unwrap();
        std::fs::remove_file(filepath).unwrap();
        std::fs::remove_dir(directory).unwrap();
    }

    #[test]
    fn remote_state_rejects_protocol_and_finalization_mismatches() {
        let mut state = RemoteUploadState {
            protocol: PROTOCOL_VERSION,
            upload_id: "22222222-2222-4222-8222-222222222222".to_owned(),
            state: "active".to_owned(),
            offset: 0,
            revision: 0,
            finalized: false,
            final_size: None,
            final_digest: None,
            queried_chunk_committed: None,
        };
        assert!(validate_remote_state(&state).is_ok());
        state.protocol = 1;
        assert!(validate_remote_state(&state).is_err());
        state.protocol = PROTOCOL_VERSION;
        state.state = "finalized".to_owned();
        state.finalized = true;
        assert!(validate_remote_state(&state).is_err());
        state.final_size = Some(0);
        state.final_digest = Some(sha256_hex(b""));
        assert!(validate_remote_state(&state).is_ok());
    }

    #[test]
    fn retryable_ingestion_rejections_use_a_bounded_server_retry_window() {
        assert_eq!(
            retry_delay(StatusCode::INSUFFICIENT_STORAGE, Some("300")),
            Some(Duration::from_secs(300))
        );
        assert_eq!(
            retry_delay(StatusCode::TOO_MANY_REQUESTS, Some("0")),
            Some(Duration::from_secs(1))
        );
        assert_eq!(
            retry_delay(StatusCode::SERVICE_UNAVAILABLE, Some("999999")),
            Some(Duration::from_secs(3600))
        );
        assert_eq!(retry_delay(StatusCode::BAD_REQUEST, Some("30")), None);

        let mut uploader = RecordUploader::new("https://management.example.test".to_owned());
        uploader.retry_not_before = Some(Instant::now() + Duration::from_secs(30));
        assert_eq!(uploader.handle_frame(false).unwrap(), false);
    }

    #[test]
    fn ambiguous_chunk_status_selects_ack_replay_or_divergence() {
        let upload_id = "22222222-2222-4222-8222-222222222222";
        let pending = PendingChunk {
            chunk_id: "33333333-3333-4333-8333-333333333333".to_owned(),
            offset: 4,
            revision: 1,
            length: 7,
            digest: sha256_hex(b"pending"),
        };
        let mut remote = RemoteUploadState {
            protocol: PROTOCOL_VERSION,
            upload_id: upload_id.to_owned(),
            state: "active".to_owned(),
            offset: 4,
            revision: 1,
            finalized: false,
            final_size: None,
            final_digest: None,
            queried_chunk_committed: Some(false),
        };
        assert!(!pending_was_committed(&remote, &pending, upload_id).unwrap());
        remote.offset = 11;
        remote.revision = 2;
        assert!(pending_was_committed(&remote, &pending, upload_id).is_err());
        remote.queried_chunk_committed = Some(true);
        assert!(pending_was_committed(&remote, &pending, upload_id).unwrap());
        remote.offset = 12;
        assert!(pending_was_committed(&remote, &pending, upload_id).is_err());
    }

    #[test]
    fn new_recording_never_replaces_unresolved_or_unpersisted_state() {
        let directory =
            std::env::temp_dir().join(format!("camellia-record-switch-{}", Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let old_filepath = directory.join("old.webm");
        let new_filepath = directory.join("new.webm");
        File::create(&old_filepath).unwrap();
        File::create(&new_filepath).unwrap();
        let api_server = "https://management.example.test".to_owned();
        let server_fingerprint = sha256_hex(api_server.as_bytes());
        let old_state = test_state(&old_filepath, &server_fingerprint);
        let mut uploader = RecordUploader::new(api_server);
        uploader.state = Some(old_state.clone());
        uploader.state_sequence = 7;

        assert!(uploader
            .handle_new_file(new_filepath.to_string_lossy().into_owned())
            .is_err());
        assert_eq!(
            uploader.current_state().unwrap().filepath,
            old_state.filepath
        );
        assert_eq!(uploader.state_sequence, 7);
        assert!(!state_files_exist(&new_filepath));

        uploader.state = None;
        uploader.state_sequence = 0;
        let missing_parent = directory.join("missing").join("unpersisted.webm");
        assert!(uploader
            .handle_new_file(missing_parent.to_string_lossy().into_owned())
            .is_err());
        assert!(uploader.state.is_none());
        assert_eq!(uploader.state_sequence, 0);

        std::fs::remove_file(old_filepath).unwrap();
        std::fs::remove_file(new_filepath).unwrap();
        std::fs::remove_dir(directory).unwrap();
    }

    #[test]
    fn changed_invalid_proxy_never_reuses_a_recording_clients_old_direct_route() {
        let mut uploader = RecordUploader::new("https://management.example.test".to_owned());
        assert!(uploader.client_for_policy(None).is_ok());
        let invalid = Socks5Server {
            proxy: "ftp://127.0.0.1:1080".to_owned(),
            username: "test-user".to_owned(),
            password: "PRIVATE-PROXY-PASSWORD".to_owned(),
        };
        assert!(uploader.client_for_policy(Some(invalid)).is_err());
        assert!(uploader.client.is_none());
        assert!(uploader.client_for_policy(None).is_ok());
        assert!(uploader.client.is_some());
    }

    #[test]
    fn recording_client_rebuilds_for_new_proxy_without_sending_to_direct_endpoint() {
        use std::net::TcpListener;
        let direct = TcpListener::bind("127.0.0.1:0").unwrap();
        direct.set_nonblocking(true).unwrap();
        let proxy = TcpListener::bind("127.0.0.1:0").unwrap();
        proxy.set_nonblocking(true).unwrap();
        let endpoint = format!("http://{}/api/record", direct.local_addr().unwrap());
        let policy = Socks5Server {
            proxy: format!("http://localhost:{}", proxy.local_addr().unwrap().port()),
            ..Default::default()
        };
        let server = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(3);
            let mut stream = loop {
                match proxy.accept() {
                    Ok((stream, _)) => break stream,
                    Err(error)
                        if error.kind() == std::io::ErrorKind::WouldBlock
                            && Instant::now() < deadline =>
                    {
                        std::thread::sleep(Duration::from_millis(2));
                    }
                    Err(error) => panic!("isolated proxy listener failed: {:?}", error.kind()),
                }
            };
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut request = vec![0; 4096];
            let count = stream.read(&mut request).unwrap();
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
                .unwrap();
            String::from_utf8(request[..count].to_vec()).unwrap()
        });
        let mut uploader = RecordUploader::new(endpoint.clone());
        assert!(uploader.client_for_policy(None).is_ok());
        let selected = uploader.client_for_policy(Some(policy.clone())).unwrap();
        let response = selected
            .get(&endpoint)
            .timeout(Duration::from_secs(2))
            .send()
            .unwrap();
        assert_eq!(response.text().unwrap(), "OK");
        assert!(server.join().unwrap().starts_with("GET http://127.0.0.1:"));
        assert_eq!(
            direct.accept().unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
        assert_eq!(uploader.client_policy, Some(policy));
        let invalid = Socks5Server {
            proxy: "ftp://invalid.test".to_owned(),
            ..Default::default()
        };
        assert!(uploader.client_for_policy(Some(invalid)).is_err());
        assert!(uploader.client.is_none());
        assert!(uploader.client_for_policy(None).is_ok());
        assert!(uploader.client_policy.is_none());
    }

    #[cfg(unix)]
    #[test]
    fn sidecar_write_rejects_symlink_without_touching_its_target() {
        use std::os::unix::fs::symlink;

        let directory =
            std::env::temp_dir().join(format!("camellia-record-symlink-{}", Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let filepath = directory.join("recording.webm");
        let victim = directory.join("victim.txt");
        File::create(&filepath).unwrap();
        std::fs::write(&victim, b"do-not-truncate").unwrap();
        let server_fingerprint = sha256_hex(b"https://management.example.test");
        let state = test_state(&filepath, &server_fingerprint);
        let sidecar = state_path(&filepath, 1);
        symlink(&victim, &sidecar).unwrap();

        assert!(save_state(&state, 1).is_err());
        assert_eq!(std::fs::read(&victim).unwrap(), b"do-not-truncate");

        std::fs::remove_file(sidecar).unwrap();
        std::fs::remove_file(victim).unwrap();
        std::fs::remove_file(filepath).unwrap();
        std::fs::remove_dir(directory).unwrap();
    }
}
