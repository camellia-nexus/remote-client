#![deny(warnings)]

use std::fs;
use std::path::PathBuf;

fn get_client_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_state028_swift_relative_mouse_coordinator_structure() {
    let client_root = get_client_root();
    let swift_path = client_root
        .join("flutter")
        .join("macos")
        .join("Runner")
        .join("MainFlutterWindow.swift");

    let content = fs::read_to_string(&swift_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", swift_path.display(), e));

    // Verify RelativeMouseOwner struct
    assert!(
        content.contains("struct RelativeMouseOwner: Equatable"),
        "MainFlutterWindow.swift must define RelativeMouseOwner struct conforming to Equatable"
    );
    assert!(
        content.contains("let windowId: Int64"),
        "RelativeMouseOwner must contain windowId: Int64"
    );
    assert!(
        content.contains("let sessionId: String"),
        "RelativeMouseOwner must contain sessionId: String"
    );
    assert!(
        content.contains("let generation: UInt64"),
        "RelativeMouseOwner must contain generation: UInt64"
    );

    // Verify RelativeMouseState tracking
    assert!(
        content.contains("class RelativeMouseState"),
        "MainFlutterWindow.swift must define RelativeMouseState"
    );
    assert!(
        content.contains("currentOwner: RelativeMouseOwner?"),
        "RelativeMouseState must track currentOwner: RelativeMouseOwner?"
    );
    assert!(
        content.contains("activeGeneration: UInt64"),
        "RelativeMouseState must track activeGeneration: UInt64"
    );
    assert!(
        content.contains("retryGeneration: UInt64"),
        "RelativeMouseState must track retryGeneration: UInt64"
    );
    assert!(
        content.contains("weak var ownerWindow: NSWindow?"),
        "RelativeMouseState must weakly track ownerWindow: NSWindow?"
    );

    // Verify lifecycle observers
    assert!(
        content.contains("NSWindow.willCloseNotification"),
        "RelativeMouseState must register for NSWindow.willCloseNotification"
    );
    assert!(
        content.contains("NSApplication.willTerminateNotification"),
        "RelativeMouseState must register for NSApplication.willTerminateNotification"
    );
    assert!(
        content.contains("func forceRelease()"),
        "RelativeMouseState must define forceRelease() for lifecycle cleanup"
    );
}

#[test]
fn test_state028_swift_fencing_and_typed_errors() {
    let client_root = get_client_root();
    let swift_path = client_root
        .join("flutter")
        .join("macos")
        .join("Runner")
        .join("MainFlutterWindow.swift");

    let content = fs::read_to_string(&swift_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", swift_path.display(), e));

    // Generation fencing on retries
    assert!(
        content.contains("guard self.retryGeneration == retryGen && !self.isLocked"),
        "Re-association retry must guard against stale generation and active lock"
    );

    // Structured errors
    assert!(
        content.contains("OWNER_CONFLICT"),
        "Enable must return OWNER_CONFLICT when locked by another owner"
    );
    assert!(
        content.contains("NOT_OWNER"),
        "Disable must return NOT_OWNER when caller does not match owner"
    );
    assert!(
        content.contains("STALE_GENERATION"),
        "Disable must return STALE_GENERATION when caller generation is outdated"
    );
    assert!(
        content.contains("CG_ASSOCIATE_FAILED"),
        "Disable must return CG_ASSOCIATE_FAILED when cursor re-association fails"
    );

    // Delta channel delivery with owner identity
    assert!(
        content.contains("\"sessionId\": owner.sessionId"),
        "onMouseDelta must include owner.sessionId"
    );
    assert!(
        content.contains("\"generation\": owner.generation"),
        "onMouseDelta must include owner.generation"
    );

    // bumpMouse check
    assert!(
        content.contains("if !RelativeMouseState.shared.enabled {"),
        "bumpMouse must check !RelativeMouseState.shared.enabled"
    );
}

#[test]
fn test_state028_dart_model_generation_fencing_and_cancellation() {
    let client_root = get_client_root();
    let dart_path = client_root
        .join("flutter")
        .join("lib")
        .join("models")
        .join("relative_mouse_model.dart");

    let content = fs::read_to_string(&dart_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", dart_path.display(), e));

    // Generation tracking
    assert!(
        content.contains("int _nativeGeneration = 0;"),
        "RelativeMouseModel must track _nativeGeneration"
    );
    assert!(
        content.contains("int get nativeGeneration => _nativeGeneration;"),
        "RelativeMouseModel must expose nativeGeneration"
    );

    // Caller identity in channel calls
    assert!(
        content.contains("'windowId': _currentWindowId"),
        "enable/disable must pass _currentWindowId"
    );
    assert!(
        content.contains("'sessionId': sessionId.toString()"),
        "enable/disable must pass sessionId.toString()"
    );
    assert!(
        content.contains("'generation': gen"),
        "enable/disable must pass generation gen"
    );

    // onMouseDelta filtering
    assert!(
        content.contains("deltaSessionId != active.sessionId.toString()"),
        "onMouseDelta must discard foreign session deltas"
    );
    assert!(
        content.contains("deltaGen != active._nativeGeneration"),
        "onMouseDelta must discard stale generation deltas"
    );

    // Cancellation rollback
    assert!(
        content.contains("_enableRequestId != requestId"),
        "Enable callback must check for request cancellation"
    );
    assert!(
        content.contains("_disableNativeRelativeMouseMode()"),
        "Cancelled enable must rollback via _disableNativeRelativeMouseMode()"
    );

    // Invalidation in dispose
    assert!(
        content.contains("_enableRequestId++;"),
        "dispose() must bump _enableRequestId to cancel in-flight requests"
    );
}

#[derive(Debug, PartialEq, Eq, Clone)]
struct Owner {
    window_id: i64,
    session_id: String,
    generation: u64,
}

#[derive(Debug, PartialEq, Eq)]
#[allow(dead_code)]
enum EnableError {
    Conflict(Owner),
    StaleGeneration { active_gen: u64 },
    CoreGraphicsError(i32),
}

#[derive(Debug, PartialEq, Eq)]
#[allow(dead_code)]
enum DisableError {
    NotOwner(Owner),
    StaleGeneration { active_gen: u64 },
    CoreGraphicsError(i32),
}

struct RelativeMouseCoordinatorSim {
    is_locked: bool,
    current_owner: Option<Owner>,
    active_generation: u64,
    retry_generation: u64,
    cursor_associated: bool,
}

impl RelativeMouseCoordinatorSim {
    fn new() -> Self {
        Self {
            is_locked: false,
            current_owner: None,
            active_generation: 0,
            retry_generation: 0,
            cursor_associated: true,
        }
    }

    fn enable(
        &mut self,
        window_id: i64,
        session_id: &str,
        generation: u64,
    ) -> Result<bool, EnableError> {
        self.retry_generation = self.retry_generation.wrapping_add(1);

        if self.is_locked {
            if let Some(owner) = &self.current_owner {
                if owner.window_id == window_id && owner.session_id == session_id {
                    if generation < owner.generation {
                        return Err(EnableError::StaleGeneration {
                            active_gen: owner.generation,
                        });
                    }
                    self.current_owner = Some(Owner {
                        window_id,
                        session_id: session_id.to_string(),
                        generation,
                    });
                    self.active_generation = generation;
                    return Ok(true);
                } else {
                    return Err(EnableError::Conflict(owner.clone()));
                }
            }
        }

        self.cursor_associated = false;
        self.is_locked = true;
        self.current_owner = Some(Owner {
            window_id,
            session_id: session_id.to_string(),
            generation,
        });
        self.active_generation = generation;
        Ok(true)
    }

    fn disable(
        &mut self,
        window_id: i64,
        session_id: &str,
        generation: u64,
    ) -> Result<bool, DisableError> {
        if !self.is_locked {
            return Ok(true);
        }

        let owner = match &self.current_owner {
            Some(o) => o.clone(),
            None => {
                self.force_release();
                return Ok(true);
            }
        };

        if owner.window_id != window_id || owner.session_id != session_id {
            return Err(DisableError::NotOwner(owner));
        }

        if generation < owner.generation {
            return Err(DisableError::StaleGeneration {
                active_gen: owner.generation,
            });
        }

        self.retry_generation = self.retry_generation.wrapping_add(1);
        self.is_locked = false;
        self.current_owner = None;
        self.cursor_associated = true;
        Ok(true)
    }

    fn force_release(&mut self) {
        if !self.is_locked {
            return;
        }
        self.retry_generation = self.retry_generation.wrapping_add(1);
        self.is_locked = false;
        self.current_owner = None;
        self.cursor_associated = true;
    }

    fn window_will_close(&mut self, closing_window_id: i64) -> bool {
        if let Some(owner) = &self.current_owner {
            if owner.window_id == closing_window_id {
                self.force_release();
                return true;
            }
        }
        false
    }

    fn delayed_retry_callback(&mut self, captured_retry_gen: u64) -> bool {
        if self.retry_generation == captured_retry_gen && !self.is_locked {
            self.cursor_associated = true;
            true
        } else {
            false
        }
    }
}

#[test]
fn test_state028_concurrency_and_lifecycle_permutation_model() {
    let mut coordinator = RelativeMouseCoordinatorSim::new();

    // 1. Session A enables in Window 1 (gen 1)
    let res_a = coordinator.enable(1, "sess-A", 1);
    assert_eq!(res_a, Ok(true));
    assert!(coordinator.is_locked);
    assert!(!coordinator.cursor_associated);

    // 2. Session B attempts enable in Window 2 -> Conflict
    let res_b = coordinator.enable(2, "sess-B", 1);
    assert!(matches!(res_b, Err(EnableError::Conflict(_))));
    assert!(coordinator.is_locked);

    // 3. Session B attempts disable Session A's lock -> NotOwner
    let res_dis_b = coordinator.disable(2, "sess-B", 1);
    assert!(matches!(res_dis_b, Err(DisableError::NotOwner(_))));

    // 4. Session A updates with higher generation (gen 2) -> Allowed
    let res_a2 = coordinator.enable(1, "sess-A", 2);
    assert_eq!(res_a2, Ok(true));

    // 4b. Session A attempts stale enable with old gen 1 -> StaleGeneration error
    let res_a_stale = coordinator.enable(1, "sess-A", 1);
    assert_eq!(
        res_a_stale,
        Err(EnableError::StaleGeneration { active_gen: 2 })
    );

    // 5. Stale disable with old gen 1 -> StaleGeneration error
    let res_dis_stale = coordinator.disable(1, "sess-A", 1);
    assert_eq!(
        res_dis_stale,
        Err(DisableError::StaleGeneration { active_gen: 2 })
    );
    assert!(coordinator.is_locked);

    // 6. Legitimate disable with gen 2 -> Success
    let pre_retry_gen = coordinator.retry_generation;
    let res_dis_ok = coordinator.disable(1, "sess-A", 2);
    assert_eq!(res_dis_ok, Ok(true));
    assert!(!coordinator.is_locked);
    assert!(coordinator.cursor_associated);

    // 7. Bounded retry race: simulate retry scheduled during disable
    // New session enables before retry timer executes
    let res_c = coordinator.enable(3, "sess-C", 1);
    assert_eq!(res_c, Ok(true));
    assert!(coordinator.is_locked);
    assert!(!coordinator.cursor_associated);

    // Old retry callback fires -> Must be rejected by generation fence!
    let retry_executed = coordinator.delayed_retry_callback(pre_retry_gen);
    assert!(!retry_executed);
    // Cursor MUST remain locked for session C
    assert!(!coordinator.cursor_associated);
    assert!(coordinator.is_locked);

    // 8. Lifecycle teardown: Window 3 closes abruptly
    let closed = coordinator.window_will_close(3);
    assert!(closed);
    assert!(!coordinator.is_locked);
    assert!(coordinator.cursor_associated);
    assert!(coordinator.current_owner.is_none());
}
