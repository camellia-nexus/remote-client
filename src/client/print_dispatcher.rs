//! Process-level bounded Windows Remote Print Dispatcher (RES-042).
//!
//! Enforces:
//! - Max concurrent print jobs: `MAX_CONCURRENT_PRINT_JOBS = 2`
//! - Max spool bytes per job: `MAX_PRINT_JOB_BYTES = 64 * 1024 * 1024` (64 MiB)
//! - Max total spool bytes globally: `MAX_TOTAL_SPOOL_BYTES = 128 * 1024 * 1024` (128 MiB)
//! - RAII `SpoolFileGuard` streaming directly to owner-only secure temporary files
//! - Explicit job registration binding `job_id`, `connection_generation: u64`, `printer_name: Option<String>`, and `SpoolFileGuard`
//! - Stale generation cancellation on session advance or disconnect
//! - Graceful shutdown join with bounded timeout (5 seconds)

use std::{
    collections::{HashMap, HashSet},
    fmt,
    fs::{self, OpenOptions},
    io,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

pub const MAX_CONCURRENT_PRINT_JOBS: usize = 2;
pub const MAX_PRINT_JOB_BYTES: u64 = 64 * 1024 * 1024; // 64 MiB
pub const MAX_TOTAL_SPOOL_BYTES: u64 = 128 * 1024 * 1024; // 128 MiB
pub const DEFAULT_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);

static SPOOL_COUNTER: AtomicU64 = AtomicU64::new(1);

/// RAII guard managing a secure temporary XPS spool file on disk.
/// Automatically cleans up the temporary file upon drop or explicit deletion.
#[derive(Debug)]
pub struct SpoolFileGuard {
    path: PathBuf,
    active: bool,
    bytes_written: u64,
}

impl SpoolFileGuard {
    /// Create a new owner-only temporary spool file for the given job.
    pub fn create(job_id: i32) -> io::Result<Self> {
        let count = SPOOL_COUNTER.fetch_add(1, Ordering::Relaxed);
        let pid = std::process::id();
        let file_name = format!("camellia_spool_{pid}_{job_id}_{count}.xps");
        let path = std::env::temp_dir().join(file_name);

        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            let _ = OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&path)?;
        }

        #[cfg(not(unix))]
        {
            let _ = OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .open(&path)?;
        }

        Ok(Self {
            path,
            active: true,
            bytes_written: 0,
        })
    }

    /// Construct from an existing path for testing or custom wrapping.
    pub fn from_path(path: PathBuf) -> Self {
        let bytes_written = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        Self {
            path,
            active: true,
            bytes_written,
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn bytes_written(&self) -> u64 {
        self.bytes_written
    }

    pub fn set_bytes_written(&mut self, bytes: u64) {
        self.bytes_written = bytes;
    }

    /// Read data from the spool file and remove the file immediately.
    pub fn consume_data(&mut self) -> io::Result<Vec<u8>> {
        if !self.active {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "Spool file guard already inactive",
            ));
        }
        let data = fs::read(&self.path)?;
        self.delete_file();
        Ok(data)
    }

    /// Explicitly remove the temporary spool file from disk.
    pub fn delete_file(&mut self) {
        if self.active {
            let _ = fs::remove_file(&self.path);
            self.active = false;
        }
    }

    pub fn is_active(&self) -> bool {
        self.active
    }
}

impl Drop for SpoolFileGuard {
    fn drop(&mut self) {
        self.delete_file();
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PrintDispatcherError {
    ConcurrencyLimitExceeded {
        active: usize,
        max: usize,
    },
    JobBytesExceeded {
        requested: u64,
        max: u64,
    },
    TotalSpoolBytesExceeded {
        requested: u64,
        total: u64,
        max: u64,
    },
    StaleGeneration {
        job_generation: u64,
        current_generation: u64,
    },
    JobNotFound(i32),
    JobAlreadyRegistered(i32),
    Shutdown,
    IoError(String),
}

impl fmt::Display for PrintDispatcherError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ConcurrencyLimitExceeded { active, max } => {
                write!(
                    f,
                    "Print concurrency limit exceeded: active {active} >= max {max}"
                )
            }
            Self::JobBytesExceeded { requested, max } => {
                write!(f, "Print job bytes exceeded: {requested} > max {max}")
            }
            Self::TotalSpoolBytesExceeded {
                requested,
                total,
                max,
            } => {
                write!(
                    f,
                    "Total spool bytes exceeded: requested {requested} + current {total} > max {max}"
                )
            }
            Self::StaleGeneration {
                job_generation,
                current_generation,
            } => {
                write!(
                    f,
                    "Print job from stale generation {job_generation} < current {current_generation}"
                )
            }
            Self::JobNotFound(id) => write!(f, "Print job {id} not found"),
            Self::JobAlreadyRegistered(id) => write!(f, "Print job {id} already registered"),
            Self::Shutdown => write!(f, "Print dispatcher is shut down"),
            Self::IoError(msg) => write!(f, "Print dispatcher I/O error: {msg}"),
        }
    }
}

impl std::error::Error for PrintDispatcherError {}

struct RegisteredJob {
    job_id: i32,
    generation: u64,
    printer_name: Option<String>,
    spool_guard: SpoolFileGuard,
    bytes: u64,
}

struct DispatcherState {
    current_generation: u64,
    cancelled_generations: HashSet<u64>,
    active_jobs: usize,
    current_spool_bytes: u64,
    registered_jobs: HashMap<i32, RegisteredJob>,
    is_shutdown: bool,
    workers: Vec<std::thread::JoinHandle<()>>,
}

pub type PrintExecutorFn =
    Arc<dyn Fn(Option<String>, Vec<u8>) -> Result<(), String> + Send + Sync>;

pub struct PrintDispatcher {
    pub max_concurrent_jobs: usize,
    pub max_print_job_bytes: u64,
    pub max_total_spool_bytes: u64,
    pub shutdown_timeout: Duration,
    state: Arc<Mutex<DispatcherState>>,
    print_executor: Option<PrintExecutorFn>,
}

impl PrintDispatcher {
    pub fn new(
        max_concurrent_jobs: usize,
        max_print_job_bytes: u64,
        max_total_spool_bytes: u64,
        shutdown_timeout: Duration,
    ) -> Self {
        Self {
            max_concurrent_jobs,
            max_print_job_bytes,
            max_total_spool_bytes,
            shutdown_timeout,
            state: Arc::new(Mutex::new(DispatcherState {
                current_generation: 1,
                cancelled_generations: HashSet::new(),
                active_jobs: 0,
                current_spool_bytes: 0,
                registered_jobs: HashMap::new(),
                is_shutdown: false,
                workers: Vec::new(),
            })),
            print_executor: None,
        }
    }

    pub fn with_executor(mut self, executor: PrintExecutorFn) -> Self {
        self.print_executor = Some(executor);
        self
    }

    pub fn global() -> &'static PrintDispatcher {
        static GLOBAL_DISPATCHER: std::sync::OnceLock<PrintDispatcher> =
            std::sync::OnceLock::new();
        GLOBAL_DISPATCHER.get_or_init(|| {
            PrintDispatcher::new(
                MAX_CONCURRENT_PRINT_JOBS,
                MAX_PRINT_JOB_BYTES,
                MAX_TOTAL_SPOOL_BYTES,
                DEFAULT_SHUTDOWN_TIMEOUT,
            )
        })
    }

    /// Register a new print job, allocating a secure temporary spool file and checking capacity.
    pub fn register_job(
        &self,
        job_id: i32,
        generation: u64,
        printer_name: Option<String>,
        initial_bytes: u64,
    ) -> Result<PathBuf, PrintDispatcherError> {
        let mut state = self.state.lock().unwrap();
        if state.is_shutdown {
            return Err(PrintDispatcherError::Shutdown);
        }
        if state.cancelled_generations.contains(&generation)
            || generation < state.current_generation
        {
            return Err(PrintDispatcherError::StaleGeneration {
                job_generation: generation,
                current_generation: state.current_generation,
            });
        }
        if state.active_jobs >= self.max_concurrent_jobs {
            return Err(PrintDispatcherError::ConcurrencyLimitExceeded {
                active: state.active_jobs,
                max: self.max_concurrent_jobs,
            });
        }
        if initial_bytes > self.max_print_job_bytes {
            return Err(PrintDispatcherError::JobBytesExceeded {
                requested: initial_bytes,
                max: self.max_print_job_bytes,
            });
        }
        if state.current_spool_bytes.saturating_add(initial_bytes) > self.max_total_spool_bytes {
            return Err(PrintDispatcherError::TotalSpoolBytesExceeded {
                requested: initial_bytes,
                total: state.current_spool_bytes,
                max: self.max_total_spool_bytes,
            });
        }
        if state.registered_jobs.contains_key(&job_id) {
            return Err(PrintDispatcherError::JobAlreadyRegistered(job_id));
        }

        let spool_guard = SpoolFileGuard::create(job_id)
            .map_err(|e| PrintDispatcherError::IoError(e.to_string()))?;
        let spool_path = spool_guard.path().to_path_buf();

        state.current_spool_bytes = state.current_spool_bytes.saturating_add(initial_bytes);
        state.registered_jobs.insert(
            job_id,
            RegisteredJob {
                job_id,
                generation,
                printer_name,
                spool_guard,
                bytes: initial_bytes,
            },
        );

        Ok(spool_path)
    }

    /// Update accumulated spool bytes for an active streaming job and check limits.
    pub fn update_job_bytes(
        &self,
        job_id: i32,
        new_total_bytes: u64,
    ) -> Result<(), PrintDispatcherError> {
        let mut state = self.state.lock().unwrap();
        if state.is_shutdown {
            return Err(PrintDispatcherError::Shutdown);
        }
        let old_bytes = match state.registered_jobs.get(&job_id) {
            Some(j) => j.bytes,
            None => return Err(PrintDispatcherError::JobNotFound(job_id)),
        };

        if new_total_bytes > self.max_print_job_bytes {
            state.current_spool_bytes = state.current_spool_bytes.saturating_sub(old_bytes);
            state.registered_jobs.remove(&job_id);
            return Err(PrintDispatcherError::JobBytesExceeded {
                requested: new_total_bytes,
                max: self.max_print_job_bytes,
            });
        }

        let diff = new_total_bytes.saturating_sub(old_bytes);
        if state.current_spool_bytes.saturating_add(diff) > self.max_total_spool_bytes {
            state.current_spool_bytes = state.current_spool_bytes.saturating_sub(old_bytes);
            state.registered_jobs.remove(&job_id);
            return Err(PrintDispatcherError::TotalSpoolBytesExceeded {
                requested: diff,
                total: state.current_spool_bytes,
                max: self.max_total_spool_bytes,
            });
        }

        state.current_spool_bytes = state.current_spool_bytes.saturating_add(diff);
        if let Some(job) = state.registered_jobs.get_mut(&job_id) {
            job.bytes = new_total_bytes;
            job.spool_guard.set_bytes_written(new_total_bytes);
        }
        Ok(())
    }

    /// Submit a completed spool job for processing by a worker.
    pub fn submit_job(&self, job_id: i32) -> Result<(), PrintDispatcherError> {
        let mut state = self.state.lock().unwrap();
        if state.is_shutdown {
            return Err(PrintDispatcherError::Shutdown);
        }
        if state.active_jobs >= self.max_concurrent_jobs {
            return Err(PrintDispatcherError::ConcurrencyLimitExceeded {
                active: state.active_jobs,
                max: self.max_concurrent_jobs,
            });
        }
        let Some(job) = state.registered_jobs.remove(&job_id) else {
            return Err(PrintDispatcherError::JobNotFound(job_id));
        };

        if state.cancelled_generations.contains(&job.generation)
            || job.generation < state.current_generation
        {
            state.current_spool_bytes = state.current_spool_bytes.saturating_sub(job.bytes);
            return Err(PrintDispatcherError::StaleGeneration {
                job_generation: job.generation,
                current_generation: state.current_generation,
            });
        }

        let file_size = fs::metadata(job.spool_guard.path())
            .map(|m| m.len())
            .unwrap_or(job.bytes);

        if file_size > self.max_print_job_bytes {
            state.current_spool_bytes = state.current_spool_bytes.saturating_sub(job.bytes);
            return Err(PrintDispatcherError::JobBytesExceeded {
                requested: file_size,
                max: self.max_print_job_bytes,
            });
        }

        state.active_jobs += 1;

        let job_id = job.job_id;
        let generation = job.generation;
        let printer_name = job.printer_name;
        let mut spool_guard = job.spool_guard;
        let bytes = job.bytes;
        let state_arc = self.state.clone();
        let executor = self.print_executor.clone();

        state.workers.retain(|h| !h.is_finished());

        let handle = std::thread::spawn(move || {
            {
                let mut s = state_arc.lock().unwrap();
                if s.is_shutdown
                    || s.cancelled_generations.contains(&generation)
                    || generation < s.current_generation
                {
                    spool_guard.delete_file();
                    drop(spool_guard);
                    s.active_jobs = s.active_jobs.saturating_sub(1);
                    s.current_spool_bytes = s.current_spool_bytes.saturating_sub(bytes);
                    return;
                }
            }

            let data_res = spool_guard.consume_data();
            drop(spool_guard); // ensure deleted

            {
                let mut s = state_arc.lock().unwrap();
                s.current_spool_bytes = s.current_spool_bytes.saturating_sub(bytes);
            }

            match data_res {
                Ok(data) => {
                    if let Some(exec) = executor {
                        let _ = exec(printer_name, data);
                    } else {
                        #[cfg(target_os = "windows")]
                        {
                            if let Err(e) =
                                crate::platform::send_raw_data_to_printer(printer_name, data)
                            {
                                camellia_remote_protocol::log::error!("Print job error: {}", e);
                            }
                        }
                        #[cfg(not(target_os = "windows"))]
                        {
                            let _ = (&printer_name, &data);
                            camellia_remote_protocol::log::info!(
                                "Simulated print job submission for id {job_id}"
                            );
                        }
                    }
                }
                Err(e) => {
                    camellia_remote_protocol::log::error!(
                        "Failed to read spool file for job {job_id}: {e}"
                    );
                }
            }

            {
                let mut s = state_arc.lock().unwrap();
                s.active_jobs = s.active_jobs.saturating_sub(1);
            }
        });

        state.workers.push(handle);
        Ok(())
    }

    /// Cancel a specific registered job, immediately dropping and deleting its spool file.
    pub fn cancel_job(&self, job_id: i32) -> bool {
        let mut state = self.state.lock().unwrap();
        if let Some(job) = state.registered_jobs.remove(&job_id) {
            state.current_spool_bytes = state.current_spool_bytes.saturating_sub(job.bytes);
            true
        } else {
            false
        }
    }

    /// Advance the current connection generation and cancel all jobs with older generations.
    pub fn advance_generation(&self, new_generation: u64) {
        let mut state = self.state.lock().unwrap();
        if new_generation > state.current_generation {
            state.current_generation = new_generation;
        }
        let stale_ids: Vec<i32> = state
            .registered_jobs
            .iter()
            .filter(|(_, j)| j.generation < state.current_generation)
            .map(|(&id, _)| id)
            .collect();

        for id in stale_ids {
            if let Some(job) = state.registered_jobs.remove(&id) {
                state.current_spool_bytes = state.current_spool_bytes.saturating_sub(job.bytes);
            }
        }
    }

    /// Cancel all unspooled or unsubmitted jobs for a specific connection generation.
    pub fn cancel_generation(&self, generation: u64) {
        let mut state = self.state.lock().unwrap();
        state.cancelled_generations.insert(generation);

        let matching_ids: Vec<i32> = state
            .registered_jobs
            .iter()
            .filter(|(_, j)| j.generation == generation)
            .map(|(&id, _)| id)
            .collect();

        for id in matching_ids {
            if let Some(job) = state.registered_jobs.remove(&id) {
                state.current_spool_bytes = state.current_spool_bytes.saturating_sub(job.bytes);
            }
        }
    }

    /// Graceful shutdown: abort unsubmitted jobs, clean up spool files, and join workers with timeout.
    pub fn shutdown(&self) {
        let (handles, _dropped_jobs) = {
            let mut state = self.state.lock().unwrap();
            state.is_shutdown = true;
            let dropped_jobs: Vec<_> = state.registered_jobs.drain().collect();
            state.current_spool_bytes = 0;
            let handles = std::mem::take(&mut state.workers);
            (handles, dropped_jobs)
        };

        let deadline = Instant::now() + self.shutdown_timeout;
        for handle in handles {
            while !handle.is_finished() {
                if Instant::now() >= deadline {
                    camellia_remote_protocol::log::warn!(
                        "Print worker thread did not finish within shutdown timeout"
                    );
                    break;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            if handle.is_finished() {
                let _ = handle.join();
            }
        }
    }

    pub fn active_jobs(&self) -> usize {
        self.state.lock().unwrap().active_jobs
    }

    pub fn current_spool_bytes(&self) -> u64 {
        self.state.lock().unwrap().current_spool_bytes
    }

    pub fn registered_jobs_count(&self) -> usize {
        self.state.lock().unwrap().registered_jobs.len()
    }

    pub fn current_generation(&self) -> u64 {
        self.state.lock().unwrap().current_generation
    }

    pub fn is_shutdown(&self) -> bool {
        self.state.lock().unwrap().is_shutdown
    }
}

impl Default for PrintDispatcher {
    fn default() -> Self {
        Self::new(
            MAX_CONCURRENT_PRINT_JOBS,
            MAX_PRINT_JOB_BYTES,
            MAX_TOTAL_SPOOL_BYTES,
            DEFAULT_SHUTDOWN_TIMEOUT,
        )
    }
}

impl Drop for PrintDispatcher {
    fn drop(&mut self) {
        self.shutdown();
    }
}
