import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CONC-002: macOS Virtual Input Safe Mutex & Concurrency Contracts', () {
    late Directory clientRoot;
    late File inputServiceRs;
    late String content;

    setUpAll(() {
      if (Directory.current.path.endsWith('flutter')) {
        clientRoot = Directory.current.parent;
      } else {
        clientRoot = Directory.current;
      }

      inputServiceRs = File('${clientRoot.path}/src/server/input_service.rs');
      expect(
        inputServiceRs.existsSync(),
        isTrue,
        reason: 'input_service.rs must exist at ${inputServiceRs.path}',
      );
      content = inputServiceRs.readAsStringSync();
    });

    test('1. Total eradication of static mut in input_service.rs', () {
      final staticMutRegex = RegExp(r'\bstatic\s+mut\b');
      final matches = staticMutRegex.allMatches(content);
      expect(
        matches.isEmpty,
        isTrue,
        reason: 'input_service.rs must contain zero static mut declarations (found ${matches.length})',
      );
    });

    test('2. Legacy VIRTUAL_INPUT_MTX and static mut VIRTUAL_INPUT_STATE removed', () {
      expect(
        content.contains('VIRTUAL_INPUT_MTX'),
        isFalse,
        reason: 'Legacy VIRTUAL_INPUT_MTX must be completely removed',
      );
      expect(
        content.contains('static mut VIRTUAL_INPUT_STATE'),
        isFalse,
        reason: 'Legacy static mut VIRTUAL_INPUT_STATE must be completely removed',
      );
    });

    test('3. Safe Mutex<Option<VirtualInputState>> declared', () {
      final pattern = RegExp(
        r'static\s+VIRTUAL_INPUT_STATE\s*:\s*Mutex\s*<\s*Option\s*<\s*VirtualInputState\s*>\s*>\s*=\s*Mutex::new\s*\(\s*None\s*\)\s*;',
      );
      expect(
        pattern.hasMatch(content),
        isTrue,
        reason: 'VIRTUAL_INPUT_STATE must be declared as static Mutex<Option<VirtualInputState>>',
      );
    });

    test('4. VirtualInputState implements Send', () {
      expect(
        content.contains('unsafe impl Send for VirtualInputState {}'),
        isTrue,
        reason: 'VirtualInputState must implement Send for cross-thread Mutex encapsulation',
      );
    });

    test('5. Poison-resilient lock helper and safe capslock query exist', () {
      expect(
        content.contains('fn lock_virtual_input() -> std::sync::MutexGuard'),
        isTrue,
        reason: 'lock_virtual_input helper must be defined',
      );
      expect(
        content.contains('unwrap_or_else(|poisoned| poisoned.into_inner())'),
        isTrue,
        reason: 'lock_virtual_input must handle PoisonError via into_inner()',
      );
      expect(
        content.contains('fn is_capslock_down() -> bool'),
        isTrue,
        reason: 'is_capslock_down helper must be defined',
      );
    });

    test('6. Zero unsafe in LockModesHandler::new (macOS)', () {
      final handlerSection = content.split('impl LockModesHandler {').last.split('fn new(key_event: &KeyEvent)').last;
      final handlerBody = handlerSection.split('}').first;

      expect(
        handlerBody.contains('is_capslock_down()'),
        isTrue,
        reason: 'LockModesHandler::new must call is_capslock_down()',
      );
      expect(
        handlerBody.contains('unsafe'),
        isFalse,
        reason: 'LockModesHandler::new (macOS) must not contain unsafe',
      );
    });

    test('7. Zero unsafe in reset_input and simulate_', () {
      final resetSection = content.split('fn reset_input()').last.split('}').first;
      expect(
        resetSection.contains('unsafe'),
        isFalse,
        reason: 'reset_input must not contain unsafe',
      );
      expect(
        resetSection.contains('VirtualInputState::new()'),
        isTrue,
        reason: 'reset_input must call VirtualInputState::new()',
      );

      final simSection = content.split('fn simulate_(event_type: &EventType)').last.split('}').first;
      expect(
        simSection.contains('unsafe'),
        isFalse,
        reason: 'simulate_ (macOS) must not contain unsafe',
      );
    });

    test('8. CapsLock handlers invoke key_sleep outside critical section', () {
      final pressSection = content.split('fn press_capslock()').last.split('\n}').first;
      expect(
        pressSection.contains('unsafe'),
        isFalse,
        reason: 'press_capslock must not contain unsafe',
      );
      expect(
        pressSection.contains('if should_sleep {\n        key_sleep();\n    }'),
        isTrue,
        reason: 'press_capslock must invoke key_sleep outside Mutex lock scope',
      );

      final releaseSection = content.split('fn release_capslock()').last.split('\n}').first;
      expect(
        releaseSection.contains('unsafe'),
        isFalse,
        reason: 'release_capslock must not contain unsafe',
      );
      expect(
        releaseSection.contains('if should_sleep {\n        key_sleep();\n    }'),
        isTrue,
        reason: 'release_capslock must invoke key_sleep outside Mutex lock scope',
      );
    });

    test('9. Virtual input state machine and CapsLock synchronization simulation', () {
      final sim = _VirtualInputSim();

      // Step 1: Initial state is uninitialized and safe
      expect(sim.isCapsLockDown, isFalse);
      sim.simulate('KeyPress(KeyA)'); // Dropped safely
      expect(sim.eventLog.isEmpty, isTrue);

      // Step 2: Session connect / reset
      sim.resetInput();
      expect(sim.isCapsLockDown, isFalse);

      // Step 3: Remote CapsLock enabled -> local transitions to True
      sim.syncCapsLock(true);
      expect(sim.isCapsLockDown, isTrue);
      expect(sim.sleepCalls, equals(1));
      expect(sim.eventLog, equals(['KeyPress(CapsLock)']));

      // Step 4: Duplicate CapsLock enabled -> idempotent no-op
      sim.syncCapsLock(true);
      expect(sim.isCapsLockDown, isTrue);
      expect(sim.sleepCalls, equals(1));
      expect(sim.eventLog.length, equals(1));

      // Step 5: Remote CapsLock disabled -> local transitions to False
      sim.syncCapsLock(false);
      expect(sim.isCapsLockDown, isFalse);
      expect(sim.sleepCalls, equals(2));
      expect(sim.eventLog, equals(['KeyPress(CapsLock)', 'KeyRelease(CapsLock)']));

      // Step 6: Duplicate CapsLock disabled -> idempotent no-op
      sim.syncCapsLock(false);
      expect(sim.isCapsLockDown, isFalse);
      expect(sim.sleepCalls, equals(2));
      expect(sim.eventLog.length, equals(2));

      // Step 7: Disconnection reset idempotently restores fresh state
      sim.resetInput();
      expect(sim.isCapsLockDown, isFalse);
    });
  });
}

class _VirtualInputSim {
  bool _initialized = false;
  bool _capsLockDown = false;
  int sleepCalls = 0;
  final List<String> eventLog = [];

  bool get isCapsLockDown {
    if (!_initialized) return false;
    return _capsLockDown;
  }

  void resetInput() {
    _initialized = true;
    _capsLockDown = false;
  }

  void simulate(String event) {
    if (!_initialized) return;
    eventLog.add(event);
  }

  void pressCapsLock() {
    var shouldSleep = false;
    if (_initialized) {
      simulate('KeyPress(CapsLock)');
      _capsLockDown = true;
      shouldSleep = true;
    }
    if (shouldSleep) {
      sleepCalls++;
    }
  }

  void releaseCapsLock() {
    var shouldSleep = false;
    if (_initialized) {
      simulate('KeyRelease(CapsLock)');
      _capsLockDown = false;
      shouldSleep = true;
    }
    if (shouldSleep) {
      sleepCalls++;
    }
  }

  void syncCapsLock(bool remoteEnabled) {
    final localEnabled = isCapsLockDown;
    if (remoteEnabled && !localEnabled) {
      pressCapsLock();
    } else if (!remoteEnabled && localEnabled) {
      releaseCapsLock();
    }
  }
}
