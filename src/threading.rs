//! Fallible, named OS-thread creation for startup and FFI boundaries.
//!
//! `std::thread::spawn` panics when the operating system refuses a thread.
//! That is not an acceptable failure mode for a desktop/FFI process: callers
//! need to roll back partial initialization or keep an optional capability
//! disabled. Keep this wrapper small so every migrated call site has one
//! auditable error boundary and a stable diagnostic name.

use std::io;
use std::thread::{self, JoinHandle};

pub trait ThreadSpawner {
    fn spawn<F, T>(&self, name: &str, worker: F) -> io::Result<JoinHandle<T>>
    where
        F: FnOnce() -> T + Send + 'static,
        T: Send + 'static;
}

pub struct SystemThreadSpawner;

impl ThreadSpawner for SystemThreadSpawner {
    fn spawn<F, T>(&self, name: &str, worker: F) -> io::Result<JoinHandle<T>>
    where
        F: FnOnce() -> T + Send + 'static,
        T: Send + 'static,
    {
        thread::Builder::new().name(name.to_owned()).spawn(worker)
    }
}

pub fn spawn_named<F, T>(name: &str, worker: F) -> io::Result<JoinHandle<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    spawn_named_with(&SystemThreadSpawner, name, worker)
}

pub fn spawn_named_with<S, F, T>(spawner: &S, name: &str, worker: F) -> io::Result<JoinHandle<T>>
where
    S: ThreadSpawner,
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    spawner.spawn(name, worker)
}

#[cfg(test)]
mod tests {
    use super::{spawn_named, spawn_named_with, ThreadSpawner};
    use std::{
        io,
        sync::{
            atomic::{AtomicBool, Ordering},
            Arc,
        },
        thread::JoinHandle,
    };

    struct RejectingSpawner;

    impl ThreadSpawner for RejectingSpawner {
        fn spawn<F, T>(&self, _name: &str, _worker: F) -> io::Result<JoinHandle<T>>
        where
            F: FnOnce() -> T + Send + 'static,
            T: Send + 'static,
        {
            Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "simulated thread resource exhaustion",
            ))
        }
    }

    #[test]
    fn creates_named_worker_without_unchecked_spawn() {
        let handle = spawn_named("threading-test", || 7).expect("test thread must start");
        assert_eq!(handle.join().expect("test worker must finish"), 7);
    }

    #[test]
    fn reports_resource_exhaustion_without_starting_the_worker() {
        let ran = Arc::new(AtomicBool::new(false));
        let worker_ran = ran.clone();
        let error = spawn_named_with(&RejectingSpawner, "rejected-worker", move || {
            worker_ran.store(true, Ordering::SeqCst);
        })
        .expect_err("the fake spawner must reject the worker");

        assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
        assert!(!ran.load(Ordering::SeqCst));
    }
}
