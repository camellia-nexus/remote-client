#!/usr/bin/env python3
"""Contract and invariant verification tests for Batch 58:
STATE-028 — macOS relative mouse process-level pointer-lock owner & generation coordinator.

Verifies:
1. MainFlutterWindow.swift:
   - RelativeMouseOwner struct with windowId, sessionId, generation.
   - RelativeMouseState tracks currentOwner, isLocked, activeGeneration, retryGeneration.
   - Lifecycle observers on NSWindow.willCloseNotification and NSApplication.willTerminateNotification.
   - Owner teardown via forceRelease() on window close and app termination.
   - Re-association retry generation fencing (guard retryGeneration == retryGen && !isLocked).
   - enableNativeRelativeMouseMode requires windowId, sessionId, generation; rejects conflict with OWNER_CONFLICT.
   - disableNativeRelativeMouseMode requires windowId, sessionId, generation; rejects non-owner with NOT_OWNER and stale gen with STALE_GENERATION.
   - onMouseDelta channel invocation passes dx, dy, sessionId, and generation.
   - bumpMouse checks !RelativeMouseState.shared.enabled before associate.
2. relative_mouse_model.dart:
   - Tracks _nativeGeneration monotonically.
   - Passes windowId, sessionId.toString(), and generation in enable/disable calls.
   - onMouseDelta filters out deltas with mismatched sessionId or generation.
   - Rollback of native pointer-lock if enable request was cancelled while awaiting.
   - dispose() and setRelativeMouseMode(false) invalidate in-flight enable requests.
3. Behavioral state machine simulation verifying concurrent and edge-case transitions.
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
MAIN_FLUTTER_WINDOW_SWIFT = REPO_ROOT / "flutter" / "macos" / "Runner" / "MainFlutterWindow.swift"
RELATIVE_MOUSE_MODEL_DART = REPO_ROOT / "flutter" / "lib" / "models" / "relative_mouse_model.dart"


class TestBatch58MacOSRelativeMouseContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.swift_source = MAIN_FLUTTER_WINDOW_SWIFT.read_text(encoding="utf-8")
        cls.dart_source = RELATIVE_MOUSE_MODEL_DART.read_text(encoding="utf-8")

    # =========================================================================
    # 1. Swift Native Coordinator Invariants
    # =========================================================================

    def test_swift_relative_mouse_owner_struct_defined(self):
        """RelativeMouseOwner struct must track windowId, sessionId, and generation."""
        self.assertRegex(
            self.swift_source,
            r"struct\s+RelativeMouseOwner\s*:\s*Equatable\s*\{",
            "RelativeMouseOwner struct must be defined as Equatable",
        )
        self.assertRegex(
            self.swift_source,
            r"let\s+windowId\s*:\s*Int64",
            "RelativeMouseOwner must contain windowId: Int64",
        )
        self.assertRegex(
            self.swift_source,
            r"let\s+sessionId\s*:\s*String",
            "RelativeMouseOwner must contain sessionId: String",
        )
        self.assertRegex(
            self.swift_source,
            r"let\s+generation\s*:\s*UInt64",
            "RelativeMouseOwner must contain generation: UInt64",
        )

    def test_swift_relative_mouse_state_tracks_owner_and_generations(self):
        """RelativeMouseState must track isLocked, currentOwner, activeGeneration, and retryGeneration."""
        self.assertIn("class RelativeMouseState", self.swift_source)
        self.assertIn("currentOwner: RelativeMouseOwner?", self.swift_source)
        self.assertIn("activeGeneration: UInt64", self.swift_source)
        self.assertIn("retryGeneration: UInt64", self.swift_source)
        self.assertIn("weak var ownerWindow: NSWindow?", self.swift_source)

    def test_swift_lifecycle_cleanup_observers_registered(self):
        """RelativeMouseState must register for NSWindow.willCloseNotification and willTerminateNotification."""
        self.assertIn("NSWindow.willCloseNotification", self.swift_source)
        self.assertIn("NSApplication.willTerminateNotification", self.swift_source)
        self.assertIn("forceRelease()", self.swift_source)
        self.assertRegex(
            self.swift_source,
            r"func\s+forceRelease\s*\(\s*\)",
            "RelativeMouseState must define forceRelease() for lifecycle cleanup",
        )

    def test_swift_retry_generation_fencing_prevents_stale_associate(self):
        """Cursor re-association retry must check retryGeneration and !isLocked."""
        self.assertIn("scheduleBoundedRetry", self.swift_source)
        self.assertRegex(
            self.swift_source,
            r"guard\s+self\.retryGeneration\s*==\s*retryGen\s*&&\s*!self\.isLocked",
            "scheduleBoundedRetry must guard against stale retry callbacks using retryGeneration and isLocked",
        )

    def test_swift_enable_rejects_owner_conflicts(self):
        """enable method must reject different owners with OWNER_CONFLICT error."""
        self.assertIn("OWNER_CONFLICT", self.swift_source)
        self.assertIn("ownerWindowId", self.swift_source)
        self.assertIn("ownerSessionId", self.swift_source)
        self.assertIn("ownerGeneration", self.swift_source)

    def test_swift_disable_enforces_owner_and_generation_verification(self):
        """disable method must reject non-owners (NOT_OWNER) and stale generations (STALE_GENERATION)."""
        self.assertIn("NOT_OWNER", self.swift_source)
        self.assertIn("STALE_GENERATION", self.swift_source)
        self.assertIn("CG_ASSOCIATE_FAILED", self.swift_source)

    def test_swift_delta_channel_invocation_includes_owner_identity(self):
        """onMouseDelta must invoke method with dx, dy, sessionId, and generation."""
        self.assertRegex(
            self.swift_source,
            r'self\.deltaChannel\?\.invokeMethod\("onMouseDelta",\s*arguments:\s*\[[\s\S]*?"sessionId":[\s\S]*?"generation":',
            "onMouseDelta must pass sessionId and generation to deltaChannel",
        )

    def test_swift_bump_mouse_respects_relative_mouse_locked_state(self):
        """bumpMouse must not associate mouse if RelativeMouseState is enabled/locked."""
        self.assertRegex(
            self.swift_source,
            r"if\s+!RelativeMouseState\.shared\.enabled\s*\{\s*CGAssociateMouseAndMouseCursorPosition\(1",
            "bumpMouse must check !RelativeMouseState.shared.enabled before associate",
        )

    # =========================================================================
    # 2. Dart Model Invariants
    # =========================================================================

    def test_dart_tracks_native_generation(self):
        """RelativeMouseModel must define nativeGeneration and increment monotonically."""
        self.assertIn("int _nativeGeneration = 0;", self.dart_source)
        self.assertIn("int get nativeGeneration => _nativeGeneration;", self.dart_source)
        self.assertIn("final gen = ++_nativeGeneration;", self.dart_source)

    def test_dart_passes_caller_identity_to_native_channels(self):
        """Dart enable/disable calls must pass windowId, sessionId, and generation."""
        self.assertRegex(
            self.dart_source,
            r"'enableNativeRelativeMouseMode',\s*<String,\s*dynamic>\{\s*'windowId':\s*_currentWindowId,\s*'sessionId':\s*sessionId\.toString\(\),\s*'generation':\s*gen,",
            "enableNativeRelativeMouseMode must pass windowId, sessionId, generation",
        )
        self.assertRegex(
            self.dart_source,
            r"'disableNativeRelativeMouseMode',\s*<String,\s*dynamic>\{\s*'windowId':\s*_currentWindowId,\s*'sessionId':\s*sessionId\.toString\(\),\s*'generation':\s*gen,",
            "disableNativeRelativeMouseMode must pass windowId, sessionId, generation",
        )

    def test_dart_delta_handler_filters_stale_session_and_generation(self):
        """Dart onMouseDelta handler must reject deltas with mismatched sessionId or generation."""
        self.assertRegex(
            self.dart_source,
            r"if\s*\(\s*deltaSessionId\s*!=\s*null\s*&&\s*deltaSessionId\s*!=\s*active\.sessionId\.toString\(\)\s*\)\s*\{\s*return\s+null;\s*\}",
            "onMouseDelta must reject deltas from foreign sessionId",
        )
        self.assertRegex(
            self.dart_source,
            r"if\s*\(\s*deltaGen\s*!=\s*null\s*&&\s*deltaGen\s*!=\s*active\._nativeGeneration\s*\)\s*\{\s*return\s+null;\s*\}",
            "onMouseDelta must reject deltas with stale generation",
        )

    def test_dart_enable_cancellation_rollback_guard(self):
        """Cancelled enable request must roll back native relative mouse mode."""
        self.assertRegex(
            self.dart_source,
            r"if\s*\(_enableRequestId\s*!=\s*requestId\)\s*\{\s*if\s*\(success\)\s*\{\s*_disableNativeRelativeMouseMode\(\);\s*\}\s*return;\s*\}",
            "Cancelled enable callback must call _disableNativeRelativeMouseMode()",
        )

    def test_dart_dispose_invalidates_in_flight_requests(self):
        """dispose() must increment _enableRequestId to invalidate in-flight enables."""
        self.assertRegex(
            self.dart_source,
            r"void\s+dispose\(\)\s*\{[\s\S]*?_enableRequestId\+\+;",
            "dispose() must bump _enableRequestId to cancel pending callbacks",
        )

    # =========================================================================
    # 3. Behavioral State Machine Simulation
    # =========================================================================

    def test_simulated_coordinator_multi_window_concurrency_and_generation_fencing(self):
        """Simulate RelativeMouseCoordinator state machine under concurrency and edge cases."""

        class SimOwner:
            def __init__(self, window_id: int, session_id: str, generation: int):
                self.window_id = window_id
                self.session_id = session_id
                self.generation = generation

        class SimCoordinator:
            def __init__(self):
                self.is_locked = False
                self.current_owner = None
                self.active_generation = 0
                self.retry_generation = 0
                self.cursor_associated = True
                self.active_deltas = []

            def enable(self, window_id: int, session_id: str, generation: int):
                self.retry_generation += 1
                if self.is_locked:
                    if (
                        self.current_owner.window_id == window_id
                        and self.current_owner.session_id == session_id
                    ):
                        self.current_owner = SimOwner(window_id, session_id, generation)
                        self.active_generation = generation
                        return "SUCCESS"
                    return "OWNER_CONFLICT"
                self.cursor_associated = False
                self.is_locked = True
                self.current_owner = SimOwner(window_id, session_id, generation)
                self.active_generation = generation
                return "SUCCESS"

            def disable(self, window_id: int, session_id: str, generation: int):
                if not self.is_locked:
                    return "SUCCESS"
                if (
                    self.current_owner.window_id != window_id
                    or self.current_owner.session_id != session_id
                ):
                    return "NOT_OWNER"
                if generation < self.current_owner.generation:
                    return "STALE_GENERATION"
                self.retry_generation += 1
                self.is_locked = False
                self.current_owner = None
                self.cursor_associated = True
                return "SUCCESS"

            def force_release_on_window_close(self, closing_window_id: int):
                if self.is_locked and self.current_owner and self.current_owner.window_id == closing_window_id:
                    self.retry_generation += 1
                    self.is_locked = False
                    self.current_owner = None
                    self.cursor_associated = True
                    return True
                return False

            def trigger_delayed_retry(self, captured_retry_gen: int):
                if self.retry_generation == captured_retry_gen and not self.is_locked:
                    self.cursor_associated = True
                    return "RETRY_EXECUTED"
                return "RETRY_IGNORED"

        coord = SimCoordinator()

        # Step 1: Session A in Window 1 enables relative mouse mode (gen 1)
        res = coord.enable(window_id=1, session_id="session-A", generation=1)
        self.assertEqual(res, "SUCCESS")
        self.assertTrue(coord.is_locked)
        self.assertFalse(coord.cursor_associated)
        self.assertEqual(coord.active_generation, 1)

        # Step 2: Session B in Window 2 attempts to enable -> Must be rejected with OWNER_CONFLICT
        res_conflict = coord.enable(window_id=2, session_id="session-B", generation=1)
        self.assertEqual(res_conflict, "OWNER_CONFLICT")
        self.assertTrue(coord.is_locked)
        self.assertEqual(coord.current_owner.session_id, "session-A")

        # Step 3: Session B attempts to disable Session A's pointer lock -> Must be rejected with NOT_OWNER
        res_not_owner = coord.disable(window_id=2, session_id="session-B", generation=1)
        self.assertEqual(res_not_owner, "NOT_OWNER")
        self.assertTrue(coord.is_locked)

        # Step 4: Stale disable from Session A (older gen) -> Must be rejected with STALE_GENERATION
        coord.enable(window_id=1, session_id="session-A", generation=2)
        res_stale = coord.disable(window_id=1, session_id="session-A", generation=1)
        self.assertEqual(res_stale, "STALE_GENERATION")
        self.assertTrue(coord.is_locked)

        # Step 5: Delayed retry race condition test
        # Suppose disable scheduled retry at retry_gen=X, but Session B immediately enables at retry_gen=X+1
        captured_retry_gen = coord.retry_generation
        coord.disable(window_id=1, session_id="session-A", generation=2)
        self.assertFalse(coord.is_locked)

        # New owner enables immediately
        coord.enable(window_id=2, session_id="session-B", generation=1)
        self.assertTrue(coord.is_locked)
        self.assertFalse(coord.cursor_associated)

        # Old delayed retry callback fires -> Must be IGNORED and NOT unlock the cursor
        retry_result = coord.trigger_delayed_retry(captured_retry_gen)
        self.assertEqual(retry_result, "RETRY_IGNORED")
        self.assertTrue(coord.is_locked)
        self.assertFalse(coord.cursor_associated)

        # Step 6: Window close teardown test
        # When Window 2 closes abruptly, relative mouse mode must be automatically released
        released = coord.force_release_on_window_close(closing_window_id=2)
        self.assertTrue(released)
        self.assertFalse(coord.is_locked)
        self.assertIsNone(coord.current_owner)
        self.assertTrue(coord.cursor_associated)


if __name__ == "__main__":
    unittest.main()
