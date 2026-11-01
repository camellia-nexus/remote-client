use std::{
    collections::VecDeque,
    hint::spin_loop,
    sync::{
        atomic::{AtomicI32, AtomicU32, Ordering},
        Mutex,
    },
};

use crate::ipc::{Data, DataPortableService};
use camellia_remote_protocol::{
    anyhow, message_proto::MouseEvent, protobuf::Message, tokio, ResultType,
};

/// A single-producer, single-consumer handoff for one shared-memory slot.
///
/// The producer may modify the slot only while `can_publish()` is true. It
/// publishes the completed payload with `publish()`. The consumer holds the
/// returned guard while copying the payload; dropping the guard acknowledges
/// the generation and lets the producer reuse the slot.
#[repr(C, align(8))]
pub(crate) struct SharedSlotCounter {
    published: AtomicU32,
    consumed: AtomicU32,
}

impl SharedSlotCounter {
    pub(crate) fn can_publish(&self) -> bool {
        self.published.load(Ordering::Relaxed) == self.consumed.load(Ordering::Acquire)
    }

    pub(crate) fn publish(&self) -> bool {
        let published = self.published.load(Ordering::Relaxed);
        if self.consumed.load(Ordering::Acquire) != published {
            return false;
        }
        self.published
            .store(published.wrapping_add(1), Ordering::Release);
        true
    }

    pub(crate) fn try_acquire(&self) -> Option<SharedSlotReadGuard<'_>> {
        let published = self.published.load(Ordering::Acquire);
        if self.consumed.load(Ordering::Relaxed) == published {
            return None;
        }
        Some(SharedSlotReadGuard {
            counter: self,
            generation: published,
        })
    }

    #[cfg(test)]
    fn with_generation(published: u32, consumed: u32) -> Self {
        Self {
            published: AtomicU32::new(published),
            consumed: AtomicU32::new(consumed),
        }
    }
}

pub(crate) struct SharedSlotReadGuard<'a> {
    counter: &'a SharedSlotCounter,
    generation: u32,
}

impl Drop for SharedSlotReadGuard<'_> {
    fn drop(&mut self) {
        self.counter
            .consumed
            .store(self.generation, Ordering::Release);
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct CaptureParameters {
    pub(crate) capture_epoch: u32,
    pub(crate) current_display: u32,
    pub(crate) timeout_ms: i32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct CaptureParametersSnapshot {
    pub(crate) generation: u32,
    pub(crate) value: CaptureParameters,
}

/// Atomic seqlock representation of the main-process capture parameters.
///
/// There is exactly one writer (the main process). Every payload field is
/// atomic so a reader retry never performs a data-racing ordinary load.
#[repr(C, align(8))]
pub(crate) struct SharedCaptureParameters {
    sequence: AtomicU32,
    capture_epoch: AtomicU32,
    current_display: AtomicU32,
    timeout_ms: AtomicI32,
}

impl SharedCaptureParameters {
    pub(crate) fn write(&self, value: CaptureParameters) {
        let sequence = self.sequence.load(Ordering::SeqCst);
        debug_assert_eq!(
            sequence & 1,
            0,
            "capture parameter writer must be single-owner"
        );
        let (writing, complete) = if sequence >= u32::MAX - 1 {
            (1, 2)
        } else {
            (sequence + 1, sequence + 2)
        };
        self.sequence.store(writing, Ordering::SeqCst);
        self.capture_epoch
            .store(value.capture_epoch, Ordering::SeqCst);
        self.current_display
            .store(value.current_display, Ordering::SeqCst);
        self.timeout_ms.store(value.timeout_ms, Ordering::SeqCst);
        self.sequence.store(complete, Ordering::SeqCst);
    }

    pub(crate) fn read(&self) -> Option<CaptureParametersSnapshot> {
        for _ in 0..16 {
            let before = self.sequence.load(Ordering::SeqCst);
            if before == 0 || before & 1 != 0 {
                spin_loop();
                continue;
            }
            let value = CaptureParameters {
                capture_epoch: self.capture_epoch.load(Ordering::SeqCst),
                current_display: self.current_display.load(Ordering::SeqCst),
                timeout_ms: self.timeout_ms.load(Ordering::SeqCst),
            };
            let after = self.sequence.load(Ordering::SeqCst);
            if before == after {
                return Some(CaptureParametersSnapshot {
                    generation: after,
                    value,
                });
            }
            spin_loop();
        }
        None
    }
}

pub const PORTABLE_IPC_QUEUE_CAPACITY: usize = 256;

pub struct PortableInputQueue {
    inner: Mutex<PortableQueueInner>,
    notify: tokio::sync::Notify,
}

struct PortableQueueInner {
    buffer: VecDeque<Data>,
    capacity: usize,
    closed: bool,
}

impl PortableInputQueue {
    pub fn new(capacity: usize) -> Self {
        Self {
            inner: Mutex::new(PortableQueueInner {
                buffer: VecDeque::with_capacity(capacity),
                capacity,
                closed: false,
            }),
            notify: tokio::sync::Notify::new(),
        }
    }

    pub fn send(&self, data: Data) -> ResultType<()> {
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| anyhow::anyhow!("queue lock poisoned"))?;
        if inner.closed {
            return Err(anyhow::anyhow!("portable service queue is closed"));
        }
        inner.enqueue_with_coalescing(data);
        drop(inner);
        self.notify.notify_one();
        Ok(())
    }

    pub async fn recv(&self) -> Option<Data> {
        loop {
            let notified = self.notify.notified();
            {
                let mut inner = self.inner.lock().ok()?;
                if let Some(item) = inner.buffer.pop_front() {
                    return Some(item);
                }
                if inner.closed {
                    return None;
                }
            }
            notified.await;
        }
    }

    pub fn cancel_and_clear(&self) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.buffer.clear();
        }
        self.notify.notify_waiters();
    }

    pub fn close(&self) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.closed = true;
            inner.buffer.clear();
        }
        self.notify.notify_waiters();
    }

    pub fn len(&self) -> usize {
        self.inner.lock().map(|i| i.buffer.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl PortableQueueInner {
    fn is_pure_mouse_move(data: &Data) -> Option<(i32, i32)> {
        if let Data::DataPortableService(DataPortableService::Mouse((bytes, conn, _, _, _, _))) =
            data
        {
            if let Ok(evt) = MouseEvent::parse_from_bytes(bytes) {
                let evt_type = evt.mask & crate::common::input::MOUSE_TYPE_MASK;
                if evt_type == crate::common::input::MOUSE_TYPE_MOVE {
                    return Some((*conn, evt.mask));
                }
            }
        }
        None
    }

    fn enqueue_with_coalescing(&mut self, data: Data) {
        if let Some((conn, mask)) = Self::is_pure_mouse_move(&data) {
            // Check if tail of buffer is a pure move for the same connection and same button mask
            if let Some(back) = self.buffer.back_mut() {
                if let Some((back_conn, back_mask)) = Self::is_pure_mouse_move(back) {
                    if back_conn == conn && back_mask == mask {
                        // Coalesce: replace tail in place with latest coordinates
                        *back = data;
                        return;
                    }
                }
            }

            // If queue is at capacity, drop oldest pure mouse move to make room
            if self.buffer.len() >= self.capacity {
                if let Some(pos) = self
                    .buffer
                    .iter()
                    .position(|item| Self::is_pure_mouse_move(item).is_some())
                {
                    self.buffer.remove(pos);
                } else {
                    // Entire queue is filled with non-droppable events; drop this new move
                    return;
                }
            }
        } else {
            // This is a button transition, key event, or other critical event.
            // If queue is full, evict the oldest pure mouse move to preserve this event.
            if self.buffer.len() >= self.capacity {
                if let Some(pos) = self
                    .buffer
                    .iter()
                    .position(|item| Self::is_pure_mouse_move(item).is_some())
                {
                    self.buffer.remove(pos);
                }
            }
        }

        // Push to buffer
        self.buffer.push_back(data);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn slot_is_not_reused_until_read_guard_is_dropped() {
        let counter = SharedSlotCounter::with_generation(0, 0);
        assert!(counter.can_publish());
        assert!(counter.publish());
        assert!(!counter.can_publish());
        assert!(!counter.publish());

        let guard = counter.try_acquire().expect("published slot");
        assert!(!counter.can_publish());
        drop(guard);
        assert!(counter.can_publish());
    }

    #[test]
    fn slot_generation_wrap_does_not_look_consumed() {
        let counter = SharedSlotCounter::with_generation(u32::MAX, u32::MAX);
        assert!(counter.publish());
        assert!(!counter.can_publish());
        let guard = counter.try_acquire().expect("wrapped generation");
        drop(guard);
        assert!(counter.can_publish());
    }

    #[test]
    fn capture_parameters_require_a_completed_generation() {
        let params = SharedCaptureParameters {
            sequence: AtomicU32::new(0),
            capture_epoch: AtomicU32::new(0),
            current_display: AtomicU32::new(0),
            timeout_ms: AtomicI32::new(0),
        };
        assert_eq!(params.read(), None);
        params.write(CaptureParameters {
            capture_epoch: 9,
            current_display: 7,
            timeout_ms: 33,
        });
        assert_eq!(
            params.read(),
            Some(CaptureParametersSnapshot {
                generation: 2,
                value: CaptureParameters {
                    capture_epoch: 9,
                    current_display: 7,
                    timeout_ms: 33,
                },
            })
        );
    }

    #[test]
    fn capture_parameter_generation_wrap_skips_uninitialized_zero() {
        let params = SharedCaptureParameters {
            sequence: AtomicU32::new(u32::MAX - 1),
            capture_epoch: AtomicU32::new(1),
            current_display: AtomicU32::new(1),
            timeout_ms: AtomicI32::new(1),
        };
        params.write(CaptureParameters {
            capture_epoch: 2,
            current_display: 3,
            timeout_ms: 4,
        });
        assert_eq!(params.read().unwrap().generation, 2);
    }

    #[test]
    fn capture_parameter_reader_never_observes_a_mixed_tuple() {
        let params = Arc::new(SharedCaptureParameters {
            sequence: AtomicU32::new(0),
            capture_epoch: AtomicU32::new(0),
            current_display: AtomicU32::new(0),
            timeout_ms: AtomicI32::new(0),
        });
        params.write(CaptureParameters {
            capture_epoch: 1,
            current_display: 1,
            timeout_ms: 1,
        });

        let writer = params.clone();
        let handle = std::thread::spawn(move || {
            for i in 1..=20_000_u32 {
                writer.write(CaptureParameters {
                    capture_epoch: i,
                    current_display: i,
                    timeout_ms: i as i32,
                });
            }
        });
        for _ in 0..20_000 {
            if let Some(snapshot) = params.read() {
                assert_eq!(
                    snapshot.value.current_display as i32,
                    snapshot.value.timeout_ms
                );
                assert_eq!(snapshot.value.capture_epoch, snapshot.value.current_display);
            }
        }
        handle.join().unwrap();
    }

    fn make_test_mouse_data(conn: i32, mask: i32, x: i32, y: i32) -> Data {
        let mut evt = MouseEvent::new();
        evt.mask = mask;
        evt.x = x;
        evt.y = y;
        let bytes = evt.write_to_bytes().unwrap();
        Data::DataPortableService(DataPortableService::Mouse((
            bytes,
            conn,
            "test".to_string(),
            0,
            true,
            true,
        )))
    }

    fn make_test_key_data(_key: u32) -> Data {
        let mut msg = camellia_remote_protocol::message_proto::KeyEvent::new();
        msg.down = true;
        let bytes = msg.write_to_bytes().unwrap();
        Data::DataPortableService(DataPortableService::Key(bytes))
    }

    #[test]
    fn test_portable_queue_coalesces_consecutive_pure_moves() {
        let queue = PortableInputQueue::new(256);
        // Enqueue 10 sequential moves with identical mask (0 = pure move)
        for i in 1..=10 {
            queue
                .send(make_test_mouse_data(1, 0, i * 10, i * 20))
                .unwrap();
        }
        // Consecutive pure moves for same connection must coalesce to 1
        assert_eq!(queue.len(), 1);

        // Verify the coordinates in the coalesced item are the latest (100, 200)
        let mut inner = queue.inner.lock().unwrap();
        let front = inner.buffer.pop_front().unwrap();
        if let Data::DataPortableService(DataPortableService::Mouse((bytes, conn, _, _, _, _))) =
            front
        {
            assert_eq!(conn, 1);
            let evt = MouseEvent::parse_from_bytes(&bytes).unwrap();
            assert_eq!(evt.x, 100);
            assert_eq!(evt.y, 200);
        } else {
            panic!("Expected mouse data");
        }
    }

    #[test]
    fn test_portable_queue_preserves_button_transitions() {
        let queue = PortableInputQueue::new(256);
        // Move -> LeftDown -> DragMove1 -> DragMove2 -> LeftUp
        let move1 = make_test_mouse_data(1, 0, 10, 10);
        let left_down = make_test_mouse_data(1, 1 | (0x01 << 3), 10, 10); // DOWN event
        let drag1 = make_test_mouse_data(1, 0x01 << 3, 20, 20); // Move with left button down
        let drag2 = make_test_mouse_data(1, 0x01 << 3, 30, 30); // Move with left button down
        let left_up = make_test_mouse_data(1, 2, 30, 30); // UP event

        queue.send(move1).unwrap();
        queue.send(left_down).unwrap();
        queue.send(drag1).unwrap();
        queue.send(drag2).unwrap();
        queue.send(left_up).unwrap();

        // drag1 and drag2 should coalesce into 1, but move1, left_down, and left_up must remain
        assert_eq!(queue.len(), 4);
    }

    #[test]
    fn test_portable_queue_preserves_keys() {
        let queue = PortableInputQueue::new(256);
        for i in 1..=5 {
            queue.send(make_test_key_data(i)).unwrap();
        }
        // Key events must never coalesce
        assert_eq!(queue.len(), 5);
    }

    #[test]
    fn test_portable_queue_bounded_capacity() {
        let queue = PortableInputQueue::new(8);
        // Send alternating connection pure moves so they don't immediately coalesce at the tail
        for i in 1..=20 {
            let conn = (i % 2) + 1;
            queue
                .send(make_test_mouse_data(conn, 0, i * 5, i * 5))
                .unwrap();
        }
        // Queue size must not exceed capacity
        assert!(queue.len() <= 8);
    }

    #[test]
    fn test_portable_queue_cancel_and_clear() {
        let queue = PortableInputQueue::new(256);
        queue.send(make_test_mouse_data(1, 0, 10, 10)).unwrap();
        queue.send(make_test_key_data(42)).unwrap();
        assert_eq!(queue.len(), 2);

        queue.cancel_and_clear();
        assert_eq!(queue.len(), 0);
        assert!(queue.is_empty());
    }
}
