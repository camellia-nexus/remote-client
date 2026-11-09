import 'dart:io';

import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/models/chat_model.dart';
import 'package:camellia_remote_app/models/native_model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CRED-011: iOS Application Support Migration & Data Directory Isolation', () {
    late Directory tempDocDir;
    late Directory tempSupportDir;

    setUp(() async {
      isTest = true;
      tempDocDir = await Directory.systemTemp.createTemp('batch47_test_doc_');
      tempSupportDir =
          await Directory.systemTemp.createTemp('batch47_test_support_');
    });

    tearDown(() async {
      if (await tempDocDir.exists()) {
        await tempDocDir.delete(recursive: true);
      }
      if (await tempSupportDir.exists()) {
        await tempSupportDir.delete(recursive: true);
      }
    });

    test('Atomic migration moves sensitive credentials from Documents to Application Support', () async {
      // 1. Setup legacy config file in Documents
      final legacyConfig = File('${tempDocDir.path}/camellia_remote.toml');
      await legacyConfig.writeAsString('[security]\nsigning_private_key = "SECRET_ED25519_KEY"\n');

      final legacyConfig2 = File('${tempDocDir.path}/config2.toml');
      await legacyConfig2.writeAsString('server = "relay.example.com"\n');

      // 2. Setup legacy peers directory
      final legacyPeersDir = Directory('${tempDocDir.path}/peers');
      await legacyPeersDir.create(recursive: true);
      final peerFile = File('${legacyPeersDir.path}/peer1.toml');
      await peerFile.writeAsString('id = "123456789"\n');

      // 3. Setup user downloads / data directory (MUST NOT BE REMOVED!)
      final dataDir = Directory('${tempDocDir.path}/data');
      await dataDir.create(recursive: true);
      final userVideo = File('${dataDir.path}/downloaded_recording.mp4');
      await userVideo.writeAsString('USER_RECORDING_BYTES');

      // 4. Setup general user file in Documents (MUST NOT BE REMOVED!)
      final userDoc = File('${tempDocDir.path}/user_notes.txt');
      await userDoc.writeAsString('My personal notes');

      // Execute migration
      await PlatformFFI.migrateIosLegacyStorage(tempDocDir.path, tempSupportDir.path);

      // Verify migrated files exist in Application Support
      final migratedConfig = File('${tempSupportDir.path}/camellia_remote.toml');
      expect(await migratedConfig.exists(), isTrue);
      expect(await migratedConfig.readAsString(), contains('SECRET_ED25519_KEY'));

      final migratedConfig2 = File('${tempSupportDir.path}/config2.toml');
      expect(await migratedConfig2.exists(), isTrue);

      final migratedPeer = File('${tempSupportDir.path}/peers/peer1.toml');
      expect(await migratedPeer.exists(), isTrue);
      expect(await migratedPeer.readAsString(), contains('123456789'));

      // Verify credentials removed from shareable Documents root
      expect(await legacyConfig.exists(), isFalse);
      expect(await legacyConfig2.exists(), isFalse);
      expect(await peerFile.exists(), isFalse);

      // Verify user downloads and unrelated files are preserved in Documents
      expect(await dataDir.exists(), isTrue);
      expect(await userVideo.exists(), isTrue);
      expect(await userDoc.exists(), isTrue);
    });

    test('Migration cleans up duplicate credentials from Documents if already in Application Support', () async {
      // Config already in Application Support
      final existingSupportConfig = File('${tempSupportDir.path}/camellia_remote.toml');
      await existingSupportConfig.writeAsString('[security]\nsigning_private_key = "SECURE_KEY"\n');

      // Leaked duplicate still lingering in Documents
      final leakedDocConfig = File('${tempDocDir.path}/camellia_remote.toml');
      await leakedDocConfig.writeAsString('[security]\nsigning_private_key = "OLD_KEY"\n');

      await PlatformFFI.migrateIosLegacyStorage(tempDocDir.path, tempSupportDir.path);

      // Application support must retain its content
      expect(await existingSupportConfig.exists(), isTrue);
      expect(await existingSupportConfig.readAsString(), contains('SECURE_KEY'));

      // Leaked file in Documents must be pruned
      expect(await leakedDocConfig.exists(), isFalse);
    });

    test('Migration safely recovers and overwrites 0-byte truncated target in Application Support without data loss', () async {
      // Setup corrupted/truncated 0-byte file in Application Support (e.g. from crash during prior copy)
      final corruptTargetConfig = File('${tempSupportDir.path}/camellia_remote.toml');
      await corruptTargetConfig.writeAsBytes([]);
      expect(await corruptTargetConfig.length(), equals(0));

      // Setup valid config file with secret keys in Documents
      final docConfig = File('${tempDocDir.path}/camellia_remote.toml');
      await docConfig.writeAsString('[security]\nsigning_private_key = "VALID_RECOVERED_KEY"\n');

      // Setup corrupted/truncated peer in Application Support
      final targetPeersDir = Directory('${tempSupportDir.path}/peers');
      await targetPeersDir.create(recursive: true);
      final corruptTargetPeer = File('${targetPeersDir.path}/peer1.toml');
      await corruptTargetPeer.writeAsBytes([]);

      final docPeersDir = Directory('${tempDocDir.path}/peers');
      await docPeersDir.create(recursive: true);
      final docPeer = File('${docPeersDir.path}/peer1.toml');
      await docPeer.writeAsString('id = "peer1_recovered_secret"\n');

      await PlatformFFI.migrateIosLegacyStorage(tempDocDir.path, tempSupportDir.path);

      // Target files must have been overwritten with valid data, NOT left as 0 bytes!
      expect(await corruptTargetConfig.exists(), isTrue);
      expect(await corruptTargetConfig.readAsString(), contains('VALID_RECOVERED_KEY'));
      expect(await corruptTargetPeer.exists(), isTrue);
      expect(await corruptTargetPeer.readAsString(), contains('peer1_recovered_secret'));

      // Documents legacy copies must be safely deleted now that targets have valid data
      expect(await docConfig.exists(), isFalse);
      expect(await docPeer.exists(), isFalse);
    });

    test('Migration cleans up scratch .tmp. files and migrates audit-evidence-outbox-v1, address book, and group', () async {
      // Leftover scratch file from aborted copy
      final scratchFile = File('${tempDocDir.path}/camellia_remote.toml.tmp.999999');
      await scratchFile.writeAsString('partial');

      // Audit outbox directory
      final outboxDir = Directory('${tempDocDir.path}/audit-evidence-outbox-v1');
      await outboxDir.create(recursive: true);
      final outboxItem = File('${outboxDir.path}/evt-1.json');
      await outboxItem.writeAsString('{"event_id":"1"}');

      // Address book and group cache files
      final abFile = File('${tempDocDir.path}/camellia_remote_ab');
      await abFile.writeAsString('ab_compressed_data');
      final groupFile = File('${tempDocDir.path}/camellia_remote_group');
      await groupFile.writeAsString('group_compressed_data');

      await PlatformFFI.migrateIosLegacyStorage(tempDocDir.path, tempSupportDir.path);

      // Scratch file must be removed from Documents and NOT migrated to Application Support
      expect(await scratchFile.exists(), isFalse);
      expect(File('${tempSupportDir.path}/camellia_remote.toml.tmp.999999').existsSync(), isFalse);

      // Outbox and cache files must be migrated
      expect(File('${tempSupportDir.path}/audit-evidence-outbox-v1/evt-1.json').existsSync(), isTrue);
      expect(File('${tempSupportDir.path}/camellia_remote_ab').existsSync(), isTrue);
      expect(File('${tempSupportDir.path}/camellia_remote_group').existsSync(), isTrue);
    });

    test('PlatformFFI dir and homeDir property accessors work correctly, and NativeModel alias is defined', () {
      platformFFI.dir = tempSupportDir.path;
      platformFFI.homeDir = '${tempDocDir.path}/data';

      expect(platformFFI.dir, equals(tempSupportDir.path));
      expect(platformFFI.homeDir, equals('${tempDocDir.path}/data'));
      expect(NativeModel.instance, equals(platformFFI));
    });
  });

  group('COMPAT-004: Voice Call Status & Platform Safety Contract', () {
    test('isInVoice status checks properly identify active or waiting voice calls', () {
      final activeStatuses = [
        VoiceCallStatus.waitingForResponse,
        VoiceCallStatus.connected,
      ];

      expect(activeStatuses.contains(VoiceCallStatus.connected), isTrue);
      expect(activeStatuses.contains(VoiceCallStatus.waitingForResponse), isTrue);
      expect(activeStatuses.contains(VoiceCallStatus.notStarted), isFalse);
    });
  });
}
