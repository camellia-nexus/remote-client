import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:camellia_remote_app/generated_bridge.dart';
import 'package:camellia_remote_app/models/chat_model.dart';
import 'package:camellia_remote_app/models/chat_types.dart';
import 'package:camellia_remote_app/models/file_model.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';

class _FakeRustdeskImpl extends RustdeskImpl {
  final Map<String, String> localOptions = {};
  String asyncJobStatus = ' ';
  int changeIdCalls = 0;
  String? lastChangedId;

  @override
  String mainGetLocalOption({required String key}) => localOptions[key] ?? '';
  @override
  Future<void> mainSetLocalOption({
    required String key,
    required String value,
  }) async {
    localOptions[key] = value;
  }

  @override
  bool isDisableAb() => false;
  @override
  bool isDisableAccount() => false;
  @override
  bool isDisableGroupPanel() => false;
  @override
  Future<bool> optionSynced() async => true;
  @override
  Future<String> mainGetConnectStatus() async => '{"status_num": 1}';
  @override
  Future<String> mainGetOption({required String key}) async => '';
  @override
  Future<void> mainSetOption({
    required String key,
    required String value,
  }) async {}
  @override
  String getLocalFlutterOption({required String k}) => '';
  @override
  Future<void> setLocalFlutterOption({
    required String k,
    required String v,
  }) async {}

  @override
  Future<void> mainChangeId({required String newId}) async {
    changeIdCalls++;
    lastChangedId = newId;
  }

  @override
  Future<String> mainGetAsyncStatus() async => asyncJobStatus;

  @override
  Future<String> sessionPeerOption({
    required UuidValue sessionId,
    required String name,
    required String value,
  }) async => '';

  @override
  Future<void> sessionClose({required UuidValue sessionId}) async {}
  @override
  bool mainGetUseTextureRender() => false;
  @override
  Future<int> sessionGetTrackpadSpeed({required UuidValue sessionId}) async => 0;
  @override
  void sessionRegisterPixelbufferTexture({
    required UuidValue sessionId,
    required int display,
    required int ptr,
  }) {}
  @override
  bool mainHasGpuTextureRender() => false;
  @override
  int getNextTextureKey() => 101;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeRustdeskImpl fakeBridge;

  setUp(() {
    fakeBridge = _FakeRustdeskImpl();
    platformFFI.ffiBind = fakeBridge;
  });

  group('STATE-008: Change ID Asynchronous Generation & Polling Fencing', () {
    test('mainChangeId updates lastChangedId and mainGetAsyncStatus returns status', () async {
      fakeBridge.asyncJobStatus = ' ';
      await platformFFI.ffiBind.mainChangeId(newId: 'camellia99');

      expect(fakeBridge.changeIdCalls, equals(1));
      expect(fakeBridge.lastChangedId, equals('camellia99'));

      final status1 = await platformFFI.ffiBind.mainGetAsyncStatus();
      expect(status1, equals(' '));

      fakeBridge.asyncJobStatus = '';
      final status2 = await platformFFI.ffiBind.mainGetAsyncStatus();
      expect(status2, equals(''));
    });
  });

  group('STATE-009: FileFetcher Atomic Registration, Timer Lifecycle & Instance Fencing', () {
    test('FileFetcher registerReadTask creates completer and times out if uncompleted', () async {
      final sessionUuid = UuidValue.fromString(const Uuid().v4());
      final fetcher = FileFetcher(() => sessionUuid);

      final future = fetcher.registerReadTask(false, '/remote/path1');
      expect(fetcher.remoteTasks.containsKey('/remote/path1'), isTrue);

      // Await timeout (2 seconds)
      await expectLater(
        future,
        throwsA(contains('Failed to read dir, timeout')),
      );

      expect(fetcher.remoteTasks.containsKey('/remote/path1'), isFalse);
      fetcher.close();
    });

    test('Old timeout timer does not remove a newer task with the same path (Instance Fencing)', () async {
      final sessionUuid = UuidValue.fromString(const Uuid().v4());
      final fetcher = FileFetcher(() => sessionUuid);

      // Register task 1
      final future1 = fetcher.registerReadTask(false, '/same/path');
      final completer1 = fetcher.remoteTasks['/same/path']!;

      // Complete task 1 early at 50ms
      await Future.delayed(const Duration(milliseconds: 50));
      fetcher.tryCompleteTask(
        jsonEncode({'id': 0, 'path': '/same/path', 'entries': []}),
        'false',
      );
      final res1 = await future1;
      expect(res1.path, equals('/same/path'));
      expect(completer1.isCompleted, isTrue);

      // Register task 2 for the exact same path
      final future2 = fetcher.registerReadTask(false, '/same/path');
      final completer2 = fetcher.remoteTasks['/same/path']!;
      expect(identical(completer1, completer2), isFalse);

      // Complete task 2 with new entries
      fetcher.tryCompleteTask(
        jsonEncode({'id': 0, 'path': '/same/path', 'entries': [{'name': 'file1.txt', 'size': 100}]}),
        'false',
      );
      final res2 = await future2;
      expect(res2.entries.length, equals(1));
      expect(res2.entries.first.name, equals('file1.txt'));

      fetcher.close();
    });

    test('FileFetcher.close cancels all timers and completes pending tasks with error', () async {
      final sessionUuid = UuidValue.fromString(const Uuid().v4());
      final fetcher = FileFetcher(() => sessionUuid);

      final future1 = fetcher.registerReadTask(false, '/dir1');
      final future2 = fetcher.registerReadEmptyDirsTask(false, '/dir2');
      final future3 = fetcher.registerReadRecursiveTask(1001);

      expect(fetcher.remoteTasks.length, equals(1));
      expect(fetcher.remoteEmptyDirsTasks.length, equals(1));
      expect(fetcher.readRecursiveTasks.length, equals(1));

      fetcher.close();

      expect(fetcher.remoteTasks.isEmpty, isTrue);
      expect(fetcher.remoteEmptyDirsTasks.isEmpty, isTrue);
      expect(fetcher.readRecursiveTasks.isEmpty, isTrue);

      await expectLater(future1, throwsA(contains('FileFetcher closed')));
      await expectLater(future2, throwsA(contains('FileFetcher closed')));
      await expectLater(future3, throwsA(contains('FileFetcher closed')));
    });

    test('registerReadTask throws immediately when FileFetcher is closed', () {
      final sessionUuid = UuidValue.fromString(const Uuid().v4());
      final fetcher = FileFetcher(() => sessionUuid);
      fetcher.close();

      expect(
        () => fetcher.registerReadTask(false, '/path'),
        throwsA(contains('FileFetcher is closed')),
      );
    });
  });

  group('STATE-010: MessageKey and Connection Route Demultiplexing', () {
    test('MessageKey differentiates connections from the same peer', () {
      final key1 = MessageKey('peerA', 101);
      final key2 = MessageKey('peerA', 102);
      final keyClient = MessageKey('peerA', ChatModel.clientModeID);

      expect(key1 == key2, isFalse);
      expect(key1.hashCode == key2.hashCode, isFalse);
      expect(key1 == MessageKey('peerA', 101), isTrue);
      expect(key1.isOut, isFalse);
      expect(keyClient.isOut, isTrue);
    });

    test('ChatModel maintains independent messages for concurrent connections from the same peer', () {
      final ffi = FFI(null);
      final chatModel = ChatModel(WeakReference(ffi));
      final keyConn1 = MessageKey('peerA', 101);
      final keyConn2 = MessageKey('peerA', 102);

      final user1 = ChatUser(id: 'peerA', firstName: 'Peer User');
      final msg1 = ChatMessage(text: 'Hello on conn 1', user: user1, createdAt: DateTime.now());
      final msg2 = ChatMessage(text: 'Hello on conn 2', user: user1, createdAt: DateTime.now());

      chatModel.insertMessage(keyConn1, msg1);
      chatModel.insertMessage(keyConn2, msg2);

      expect(chatModel.messages.containsKey(keyConn1), isTrue);
      expect(chatModel.messages.containsKey(keyConn2), isTrue);
      expect(chatModel.messages[keyConn1]!.chatMessages.first.text, equals('Hello on conn 1'));
      expect(chatModel.messages[keyConn2]!.chatMessages.first.text, equals('Hello on conn 2'));
    });

    test('updateConnIdOfKey does not hijack _currentKey when another connection message arrives', () {
      final ffi = FFI(null);
      final chatModel = ChatModel(WeakReference(ffi));
      final keyConn1 = MessageKey('peerA', 101);
      final keyConn2 = MessageKey('peerA', 102);

      chatModel.changeCurrentKey(keyConn1);
      expect(chatModel.currentKey, equals(keyConn1));

      // Conn 2 inserts a message
      final user = ChatUser(id: 'peerA', firstName: 'Peer User');
      chatModel.insertMessage(keyConn2, ChatMessage(text: 'Msg on 2', user: user, createdAt: DateTime.now()));

      // Current key must NOT be hijacked to Conn 2
      expect(chatModel.currentKey, equals(keyConn1));
      expect(chatModel.currentKey.connId, equals(101));
    });
  });

  group('RES-050: FileManager Directory Subscription Teardown', () {
    test('FileController directory stream cancels subscription without error', () async {
      final ffi = FFI(null);
      final fileModel = FileModel(WeakReference(ffi));
      final controller = fileModel.localController;

      int eventsCount = 0;
      final sub = controller.directory.listen((dir) {
        eventsCount++;
      });

      controller.directory.value = FileDirectory()
        ..path = '/test1'
        ..entries = [];
      await Future.delayed(const Duration(milliseconds: 10));
      expect(eventsCount, equals(1));

      await sub.cancel();

      controller.directory.value = FileDirectory()
        ..path = '/test2'
        ..entries = [];
      await Future.delayed(const Duration(milliseconds: 10));
      // No more events delivered after cancellation
      expect(eventsCount, equals(1));

      await fileModel.close();
    });
  });
}
