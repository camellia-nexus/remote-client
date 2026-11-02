use camellia_remote_protocol::message_proto::{Message, VoiceCallRequest, VoiceCallResponse};
use scrap::CodecFormat;
use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, Ordering};

lazy_static::lazy_static! {
    static ref CALL_ID_COUNTER: AtomicI64 = AtomicI64::new(1);
}

/// Generates a 64-bit cryptographic/monotonic call ID:
/// High 32 bits monotonic sequence + low 32 bits CSPRNG entropy.
pub fn generate_call_id() -> i64 {
    let seq = CALL_ID_COUNTER.fetch_add(1, Ordering::SeqCst) as u64 & 0xFFFF_FFFF;
    let entropy = (camellia_remote_protocol::rand::random::<u32>()) as u64;
    let combined = ((seq << 32) | entropy) as i64;
    if combined == 0 {
        1
    } else {
        combined
    }
}

#[derive(Debug, Default)]
pub struct QualityStatus {
    pub speed: Option<String>,
    pub fps: HashMap<usize, i32>,
    pub delay: Option<i32>,
    pub target_bitrate: Option<i32>,
    pub codec_format: Option<CodecFormat>,
    pub chroma: Option<String>,
}

#[inline]
pub fn new_voice_call_request(is_connect: bool) -> Message {
    let mut req = VoiceCallRequest::new();
    req.is_connect = is_connect;
    req.req_timestamp = generate_call_id();
    let mut msg = Message::new();
    msg.set_voice_call_request(req);
    msg
}

#[inline]
pub fn new_voice_call_response(request_timestamp: i64, accepted: bool) -> Message {
    let mut resp = VoiceCallResponse::new();
    resp.accepted = accepted;
    resp.req_timestamp = request_timestamp;
    resp.ack_timestamp = generate_call_id();
    let mut msg = Message::new();
    msg.set_voice_call_response(resp);
    msg
}
