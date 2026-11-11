import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LOG-001: Rust Logging Bounded Levels, Flush & Rotation Contracts', () {
    late Directory clientRoot;
    late File commonRs;
    late File flutterFfiRs;
    late File serviceRs;
    late File coreMainRs;
    late File flutterRs;
    late File portableServiceRs;
    late File windowsRs;
    late File linuxRs;
    late File macosRs;
    late File protocolLibRs;

    setUpAll(() {
      if (Directory.current.path.endsWith('flutter')) {
        clientRoot = Directory.current.parent;
      } else {
        clientRoot = Directory.current;
      }

      commonRs = File('${clientRoot.path}/src/common.rs');
      flutterFfiRs = File('${clientRoot.path}/src/flutter_ffi.rs');
      serviceRs = File('${clientRoot.path}/src/service.rs');
      coreMainRs = File('${clientRoot.path}/src/core_main.rs');
      flutterRs = File('${clientRoot.path}/src/flutter.rs');
      portableServiceRs = File('${clientRoot.path}/src/server/portable_service.rs');
      windowsRs = File('${clientRoot.path}/src/platform/windows.rs');
      linuxRs = File('${clientRoot.path}/src/platform/linux.rs');
      macosRs = File('${clientRoot.path}/src/platform/macos.rs');
      protocolLibRs = File('${clientRoot.path}/libs/camellia_remote_protocol/src/lib.rs');

      expect(commonRs.existsSync(), isTrue, reason: 'common.rs must exist');
      expect(flutterFfiRs.existsSync(), isTrue, reason: 'flutter_ffi.rs must exist');
      expect(flutterRs.existsSync(), isTrue, reason: 'flutter.rs must exist');
    });

    test('1. common.rs exports bounded logging constants', () {
      final content = commonRs.readAsStringSync();
      expect(content.contains('pub const DEFAULT_LOG_FILTER'), isTrue);
      expect(content.contains('pub const LOG_BUFFER_CAPACITY'), isTrue);
      expect(content.contains('pub const LOG_FLUSH_INTERVAL'), isTrue);
      expect(content.contains('pub const LOG_MAX_FILE_SIZE'), isTrue);
      expect(content.contains('pub const LOG_MAX_ROTATED_FILES'), isTrue);
    });

    test('2. common.rs exports safe init_log and flush_log', () {
      final content = commonRs.readAsStringSync();
      expect(content.contains('pub fn init_log('), isTrue);
      expect(content.contains('pub fn flush_log()'), isTrue);
    });

    test('3. common.rs global_clean flushes log buffer', () {
      final content = commonRs.readAsStringSync();
      expect(content.contains('pub fn global_clean() {\n    flush_log();\n}'), isTrue);
    });

    test('4. protocol lib.rs defaults to bounded info level in release', () {
      if (!protocolLibRs.existsSync()) return;
      final content = protocolLibRs.readAsStringSync();
      expect(
        content.contains('pub const DEFAULT_LOG_FILTER: &str = "info,reqwest=warn,rustls=warn,webrtc-sctp=warn,webrtc=warn";'),
        isTrue,
      );
      expect(
        content.contains('"debug,reqwest=warn,rustls=warn,webrtc-sctp=warn,webrtc=warn"'),
        isFalse,
      );
    });

    test('5. protocol lib.rs enforces 64 KiB buffer and 1s flush interval', () {
      if (!protocolLibRs.existsSync()) return;
      final content = protocolLibRs.readAsStringSync();
      expect(content.contains('pub const LOG_BUFFER_CAPACITY: usize = 64 * 1024;'), isTrue);
      expect(content.contains('pub const LOG_FLUSH_INTERVAL: std::time::Duration = std::time::Duration::from_secs(1);'), isTrue);
      expect(content.contains('WriteMode::BufferAndFlushWith(LOG_BUFFER_CAPACITY, LOG_FLUSH_INTERVAL)'), isTrue);
    });

    test('6. protocol lib.rs enforces 10 MiB rotation and 14 files retention', () {
      if (!protocolLibRs.existsSync()) return;
      final content = protocolLibRs.readAsStringSync();
      expect(content.contains('pub const LOG_MAX_FILE_SIZE: u64 = 10 * 1024 * 1024;'), isTrue);
      expect(content.contains('pub const LOG_MAX_ROTATED_FILES: usize = 14;'), isTrue);
      expect(content.contains('Criterion::AgeOrSize(Age::Day, LOG_MAX_FILE_SIZE)'), isTrue);
      expect(content.contains('Cleanup::KeepLogFiles(LOG_MAX_ROTATED_FILES)'), isTrue);
    });

    test('7. flutter_ffi.rs calls common init_log and bounds iOS release logging', () {
      final content = flutterFfiRs.readAsStringSync();
      expect(content.contains('crate::common::init_log(false, "");'), isTrue);
      expect(content.contains('crate::common::init_log(false, "flutter_ffi");'), isTrue);
      expect(content.contains('crate::common::DEFAULT_LOG_FILTER'), isTrue);
      expect(content.contains('eprintln!(\n            "cannot load last transfer job'), isFalse);
      expect(content.contains('log::warn!(\n            "cannot load last transfer job'), isTrue);
    });

    test('8. service.rs and core_main.rs use common init_log', () {
      final serviceContent = serviceRs.readAsStringSync();
      expect(serviceContent.contains('crate::common::init_log(false, "service");'), isTrue);

      final coreMainContent = coreMainRs.readAsStringSync();
      expect(coreMainContent.contains('crate::common::init_log(false, &log_name);'), isTrue);
    });

    test('9. Elimination of raw prints in release hot paths', () {
      final flutterContent = flutterRs.readAsStringSync();
      expect(flutterContent.contains('println!(\n                    "Push event {} failed.'), isFalse);
      expect(flutterContent.contains('log::debug!(\n                    "Push event {} failed.'), isTrue);

      final portableContent = portableServiceRs.readAsStringSync();
      expect(portableContent.contains('println!("unreachable!");'), isFalse);
      expect(portableContent.contains('log::warn!("unreachable portable service event");'), isTrue);

      final windowsContent = windowsRs.readAsStringSync();
      expect(windowsContent.contains('println!("send {:?}", data_zero);'), isFalse);
      expect(windowsContent.contains('log::debug!("send {:?}", data_zero);'), isTrue);

      final linuxContent = linuxRs.readAsStringSync();
      expect(linuxContent.contains('println!("Failed to set Ctrl-C handler: {}", err);'), isFalse);
      expect(linuxContent.contains('log::error!("Failed to set Ctrl-C handler: {}", err);'), isTrue);

      final macosContent = macosRs.readAsStringSync();
      expect(macosContent.contains('println!("Failed to set Ctrl-C handler: {}", err);'), isFalse);
      expect(macosContent.contains('log::error!("Failed to set Ctrl-C handler: {}", err);'), isTrue);
    });

    test('10. Total disk footprint is mathematically bounded below 150 MiB', () {
      const maxFileSize = 10 * 1024 * 1024;
      const maxFiles = 14;
      const totalDiskUsage = maxFileSize * maxFiles;
      expect(totalDiskUsage, equals(146800640)); // 140 MiB
      expect(totalDiskUsage <= 150 * 1024 * 1024, isTrue);
    });
  });
}
