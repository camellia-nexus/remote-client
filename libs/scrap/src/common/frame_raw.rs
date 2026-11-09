use camellia_remote_protocol::log;
use std::time::{Duration, Instant};

pub const MAX_VIDEO_FRAME_BYTES: usize = 32 * 1024 * 1024; // 32 MiB budget for 4K RGBA frames
pub const MAX_AUDIO_FRAME_BYTES: usize = 1 * 1024 * 1024; // 1 MiB budget for audio chunks
pub const MAX_VIDEO_FRAME_TIMEOUT: Duration = Duration::from_millis(100);
pub const MAX_AUDIO_FRAME_TIMEOUT: Duration = Duration::from_millis(1000);

/// Bounded, thread-safe, generation-tracked buffer for raw video and audio frames.
///
/// Designed to eliminate Use-After-Free vulnerabilities at JNI boundaries. Instead of
/// storing unmanaged raw pointers to DirectByteBuffers past callback return, JNI handlers
/// copy incoming frames into `FrameRaw` during the callback while Java/Kotlin keeps the
/// backing image or buffer live.
#[derive(Debug)]
pub struct FrameRaw {
    pub name: &'static str,
    pub buffer: Vec<u8>,
    pub max_bytes: usize,
    pub last_update: Instant,
    pub timeout: Duration,
    pub enable: bool,
    pub generation: u64,
    pub consumed_generation: u64,
}

impl FrameRaw {
    pub fn new(name: &'static str, timeout: Duration, max_bytes: usize) -> Self {
        FrameRaw {
            name,
            buffer: Vec::new(),
            max_bytes,
            last_update: Instant::now(),
            timeout,
            enable: false,
            generation: 0,
            consumed_generation: 0,
        }
    }

    pub fn set_enable(&mut self, value: bool) {
        self.enable = value;
        self.buffer.clear();
        self.buffer.shrink_to_fit();
        self.generation = self.generation.wrapping_add(1);
        self.consumed_generation = self.generation;
    }

    pub fn update(&mut self, slice: &[u8]) {
        if !self.enable {
            return;
        }
        if slice.is_empty() {
            return;
        }
        if slice.len() > self.max_bytes {
            log::warn!(
                "FrameRaw {}: incoming frame size {} exceeds budget {}",
                self.name,
                slice.len(),
                self.max_bytes
            );
            return;
        }
        self.buffer.clear();
        self.buffer.extend_from_slice(slice);
        self.generation = self.generation.wrapping_add(1);
        self.last_update = Instant::now();
    }

    pub fn take(&mut self, dst: &mut Vec<u8>, last: &mut Vec<u8>) -> Option<()> {
        if !self.enable || self.buffer.is_empty() || self.generation == self.consumed_generation {
            return None;
        }
        if self.last_update.elapsed() > self.timeout {
            log::trace!("Failed to take {} raw, timeout!", self.name);
            return None;
        }
        if !last.is_empty() && crate::would_block_if_equal(last, &self.buffer).is_err() {
            self.consumed_generation = self.generation;
            return None;
        }
        dst.resize(self.buffer.len(), 0);
        dst.copy_from_slice(&self.buffer);
        last.resize(self.buffer.len(), 0);
        last.copy_from_slice(&self.buffer);
        self.consumed_generation = self.generation;
        Some(())
    }

    #[inline]
    pub fn is_enabled(&self) -> bool {
        self.enable
    }

    #[inline]
    pub fn current_generation(&self) -> u64 {
        self.generation
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.buffer.len()
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.buffer.is_empty()
    }
}
