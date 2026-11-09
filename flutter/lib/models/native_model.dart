import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:external_path/external_path.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/main.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../common.dart';
import '../generated_bridge.dart';

final class RgbaFrame extends Struct {
  @Uint32()
  external int len;
  external Pointer<Uint8> data;
}

typedef F3 = Pointer<Uint8> Function(Pointer<Utf8>, int);
typedef F3Dart = Pointer<Uint8> Function(Pointer<Utf8>, Int32);
typedef FCopyRgbaNative =
    IntPtr Function(Pointer<Utf8>, IntPtr, Pointer<Uint8>, IntPtr);
typedef FCopyRgba = int Function(Pointer<Utf8>, int, Pointer<Uint8>, int);
typedef HandleEvent = Future<void> Function(Map<String, dynamic> evt);

/// NativeModel alias for PlatformFFI.
typedef NativeModel = PlatformFFI;

/// FFI wrapper around the native Rust core.
/// Hides the platform differences.
class PlatformFFI {
  String _dir = '';
  // _homeDir is only needed for Android and IOS.
  String _homeDir = '';

  String get dir => _dir;
  String get homeDir => _homeDir;
  @visibleForTesting
  set dir(String value) => _dir = value;
  @visibleForTesting
  set homeDir(String value) => _homeDir = value;

  final _eventHandlers = <String, Map<String, HandleEvent>>{};
  RustdeskImpl _ffiBind = const RustdeskImpl();
  String _appType = '';
  StreamEventHandler? _eventCallback;

  PlatformFFI._();

  static final PlatformFFI instance = PlatformFFI._();
  final _toAndroidChannel = const MethodChannel('mChannel');

  RustdeskImpl get ffiBind => _ffiBind;
  set ffiBind(RustdeskImpl value) => _ffiBind = value;
  F3? _session_get_rgba;
  FCopyRgba? _session_copy_rgba;
  StreamSubscription<String>? _globalEventSubscription;
  final List<String> _globalEventQueue = [];
  bool _isProcessingGlobalEvent = false;

  static get localeName => Platform.localeName;

  static get isMain => instance._appType == kAppTypeMain;

  static String getByName(String name, [String arg = '']) {
    return '';
  }

  static void setByName(String name, [String value = '']) {}

  static Future<String> getVersion() async {
    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }

  bool registerEventHandler(
    String eventName,
    String handlerName,
    HandleEvent handler, {
    bool replace = false,
  }) {
    debugPrint('registerEventHandler $eventName $handlerName');
    var handlers = _eventHandlers[eventName];
    if (handlers == null) {
      _eventHandlers[eventName] = {handlerName: handler};
      return true;
    } else {
      if (!replace && handlers.containsKey(handlerName)) {
        return false;
      } else {
        handlers[handlerName] = handler;
        return true;
      }
    }
  }

  void unregisterEventHandler(String eventName, String handlerName) {
    debugPrint('unregisterEventHandler $eventName $handlerName');
    var handlers = _eventHandlers[eventName];
    if (handlers != null) {
      handlers.remove(handlerName);
    }
  }

  void removeEventHandler(String eventName, [String? handlerName]) {
    unregisterEventHandler(eventName, handlerName ?? eventName);
  }

  String translate(String name, String locale) =>
      _ffiBind.translate(name: name, locale: locale);

  Uint8List? getRgba(SessionID sessionId, int display, int bufSize) {
    if (bufSize <= 0) return null;
    final sessionIdStr = sessionId.toString();
    final a = sessionIdStr.toNativeUtf8();
    final ptr = malloc.allocate<Uint8>(bufSize);
    try {
      if (_session_copy_rgba != null) {
        final copied = _session_copy_rgba!(a, display, ptr, bufSize);
        if (copied <= 0) {
          malloc.free(ptr);
          return null;
        }
        final list = Uint8List.fromList(ptr.asTypedList(copied));
        malloc.free(ptr);
        return list;
      } else if (_session_get_rgba != null) {
        final buffer = _session_get_rgba!(a, display);
        if (buffer == nullptr) {
          malloc.free(ptr);
          return null;
        }
        final list = Uint8List.fromList(buffer.asTypedList(bufSize));
        malloc.free(ptr);
        return list;
      }
      malloc.free(ptr);
      return null;
    } catch (_) {
      malloc.free(ptr);
      return null;
    } finally {
      malloc.free(a);
    }
  }

  int getRgbaSize(SessionID sessionId, int display) =>
      _ffiBind.sessionGetRgbaSize(sessionId: sessionId, display: display);
  void nextRgba(SessionID sessionId, int display) =>
      _ffiBind.sessionNextRgba(sessionId: sessionId, display: display);
  void registerPixelbufferTexture(SessionID sessionId, int display, int ptr) =>
      _ffiBind.sessionRegisterPixelbufferTexture(
        sessionId: sessionId,
        display: display,
        ptr: ptr,
      );
  void registerGpuTexture(SessionID sessionId, int display, int ptr) =>
      _ffiBind.sessionRegisterGpuTexture(
        sessionId: sessionId,
        display: display,
        ptr: ptr,
      );

  bool _initialized = false;

  /// Init the FFI class, loads the native Rust core library.
  Future<void> init(String appType) async {
    if (_initialized) return;
    _initialized = true;
    _appType = appType;
    final externalLibrary = isAndroid
        ? ExternalLibrary.open('camellia_remote.so')
        : isLinux
        ? ExternalLibrary.open('camellia_remote.so')
        : isWindows
        ? ExternalLibrary.open('camellia_remote.dll')
        :
          // Use executable itself as the dynamic library for MacOS.
          // Multiple dylib instances will cause some global instances to be invalid.
          // eg. `lazy_static` objects in rust side, will be created more than once, which is not expected.
          //
          // isMacOS? ExternalLibrary.open("libcamellia_remote.dylib") :
          ExternalLibrary.process(iKnowHowToUseIt: true);
    final dylib = externalLibrary.ffiDynamicLibrary;
    debugPrint('initializing FFI $_appType');
    try {
      _session_get_rgba = dylib.lookupFunction<F3Dart, F3>("session_get_rgba");
      try {
        _session_copy_rgba = dylib.lookupFunction<FCopyRgbaNative, FCopyRgba>(
          "session_copy_rgba",
        );
      } catch (e) {
        debugPrint('session_copy_rgba lookup optional: $e');
      }
      String docDir = '';
      try {
        // SYSTEM user failed
        docDir = (await getApplicationDocumentsDirectory()).path;
      } catch (e) {
        debugPrint('Failed to get documents directory: $e');
      }

      if (isIOS) {
        try {
          final supportDir = await getApplicationSupportDirectory();
          _dir = supportDir.path;
          if (!await supportDir.exists()) {
            await supportDir.create(recursive: true);
          }
          if (docDir.isNotEmpty) {
            await migrateIosLegacyStorage(docDir, _dir);
          }
        } catch (e) {
          debugPrint('Failed to setup iOS application support directory: $e');
          if (_dir.isEmpty) {
            _dir = docDir;
          }
        }
      } else {
        _dir = docDir;
      }
      await RustLib.init(externalLibrary: externalLibrary);
      _ffiBind = const RustdeskImpl();

      if (isLinux) {
        if (isMain) {
          // Start a dbus service for uri links, no need to await
          _ffiBind.mainStartDbusServer();
        }
      } else if (isMacOS && isMain) {
        // Start ipc service for uri links.
        _ffiBind.mainStartIpcUrlServer();
      }
      _startListenEvent(_ffiBind); // global event
      try {
        if (isAndroid) {
          // only support for android
          final directories =
              await ExternalPath.getExternalStorageDirectories();
          if (directories != null && directories.isNotEmpty) {
            _homeDir = directories[0];
          }
        } else if (isIOS) {
          // CRED-011: User downloads and received data live in Documents/data
          _homeDir = _ffiBind.mainGetDataDirIos(
            appDir: docDir.isNotEmpty ? docDir : _dir,
          );
        } else {
          // no need to set home dir
        }
      } catch (e) {
        debugPrintStack(label: 'initialize failed: $e');
      }
      String id = 'NA';
      String name = 'Flutter';
      DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
      if (isAndroid) {
        AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        name = '${androidInfo.brand}-${androidInfo.model}';
        id = androidInfo.id.hashCode.toString();
        androidVersion = androidInfo.version.sdkInt;
      } else if (isIOS) {
        IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
        name = iosInfo.utsname.machine;
        id = iosInfo.identifierForVendor.hashCode.toString();
      } else if (isLinux) {
        LinuxDeviceInfo linuxInfo = await deviceInfo.linuxInfo;
        name = linuxInfo.name;
        id = linuxInfo.machineId ?? linuxInfo.id;
      } else if (isWindows) {
        try {
          WindowsDeviceInfo winInfo = await deviceInfo.windowsInfo;
          name = winInfo.computerName;
          id = winInfo.computerName;
        } catch (e) {
          debugPrintStack(label: "get windows device info failed: $e");
          name = "unknown";
          id = "unknown";
        }
      } else if (isMacOS) {
        MacOsDeviceInfo macOsInfo = await deviceInfo.macOsInfo;
        name = macOsInfo.computerName;
        id = macOsInfo.systemGUID ?? '';
      }
      debugPrint('_appType:$_appType (device initialized)');
      if (desktopType == DesktopType.cm) {
        await _ffiBind.cmInit();
      }
      await _ffiBind.mainDeviceId(id: id);
      await _ffiBind.mainDeviceName(name: name);
      await _ffiBind.mainSetHomeDir(home: _homeDir);
      await _ffiBind.mainInit(appDir: _dir, customClientConfig: '');
    } catch (e) {
      debugPrintStack(label: 'initialize failed: $e');
    }
    version = await getVersion();
  }

  Future<bool> tryHandle(Map<String, dynamic> evt) async {
    final name = evt['name'];
    if (name != null) {
      final handlers = _eventHandlers[name];
      if (handlers != null) {
        if (handlers.isNotEmpty) {
          for (var handler in handlers.values) {
            await handler(evt);
          }
          return true;
        }
      }
    }
    return false;
  }

  /// Start listening to the Rust core's events and frames.
  void startListenEvent(RustdeskImpl rustdeskImpl) {
    _startListenEvent(rustdeskImpl);
  }

  void _startListenEvent(RustdeskImpl rustdeskImpl) {
    _globalEventSubscription?.cancel();
    _globalEventQueue.clear();
    final appType = _appType == kAppTypeDesktopRemote
        ? '$_appType,$kWindowId'
        : _appType;
    var sink = rustdeskImpl.startGlobalEventStream(appType: appType);
    _globalEventSubscription = sink.listen(
      (message) {
        _globalEventQueue.add(message);
        _drainGlobalEventQueue();
      },
      onError: (err) {
        debugPrint('Global event stream error: $err');
      },
      onDone: () {
        debugPrint('Global event stream done');
      },
    );
  }

  Future<void> _drainGlobalEventQueue() async {
    if (_isProcessingGlobalEvent) return;
    _isProcessingGlobalEvent = true;
    try {
      while (_globalEventQueue.isNotEmpty) {
        final message = _globalEventQueue.removeAt(0);
        try {
          Map<String, dynamic> event = json.decode(message);
          // _tryHandle here may be more flexible than _eventCallback
          if (!await tryHandle(event)) {
            if (_eventCallback != null) {
              await _eventCallback!(event);
            }
          }
        } catch (e) {
          debugPrint('json.decode fail(): $e');
        }
      }
    } finally {
      _isProcessingGlobalEvent = false;
    }
  }

  void stopListenEvent([RustdeskImpl? rustdeskImpl]) {
    _globalEventSubscription?.cancel();
    _globalEventSubscription = null;
    _globalEventQueue.clear();
    final appType = _appType == kAppTypeDesktopRemote
        ? '$_appType,$kWindowId'
        : _appType;
    try {
      (rustdeskImpl ?? _ffiBind).stopGlobalEventStream(appType: appType);
    } catch (e) {
      debugPrint('stopGlobalEventStream error: $e');
    }
  }

  void clearEventCallback() {
    _eventCallback = null;
  }

  void dispose() {
    stopListenEvent();
    _eventCallback = null;
    _eventHandlers.clear();
  }

  void setEventCallback(StreamEventHandler fun) async {
    _eventCallback = fun;
  }

  void setRgbaCallback(void Function(int, Uint8List, int, int) fun) async {}

  void setVideoFrameCallback(void Function(int, int, int) fun) {}

  void clearVideoFrameCallback() {}

  void startDesktopWebListener() {}

  void stopDesktopWebListener() {}

  void setMethodCallHandler(FMethod callback) {
    _toAndroidChannel.setMethodCallHandler((call) async {
      callback(call.method, call.arguments);
      return null;
    });
  }

  invokeMethod(String method, [dynamic arguments]) async {
    if (!isAndroid) return Future<bool>(() => false);
    return await _toAndroidChannel.invokeMethod(method, arguments);
  }

  void syncAndroidServiceAppDirConfigPath() {
    invokeMethod(AndroidChannel.kSyncAppDirConfigPath, _dir);
  }

  void setFullscreenCallback(void Function(bool) fun) {}

  /// CRED-011: Migrate legacy configuration and credentials from shareable
  /// Documents root to Application Support directory on iOS.
  static Future<void> migrateIosLegacyStorage(
    String docDir,
    String supportDir,
  ) async {
    final legacyItems = <String>{
      'camellia_remote.toml',
      'rustdesk.toml',
      'peers',
      'config2.toml',
      'LocalConfig',
      'LocalConfig.json',
      'peer_settings',
      'management-operation-journal-v1',
      'audit-evidence-outbox-v1',
      'audit_outbox',
      'camellia_remote_ab',
      'rustdesk_ab',
      'camellia_remote_group',
      'rustdesk_group',
    };

    final docDirectory = Directory(docDir);
    if (!await docDirectory.exists()) return;

    final supportDirectory = Directory(supportDir);
    if (!await supportDirectory.exists()) {
      await supportDirectory.create(recursive: true);
    }

    try {
      await for (final entity in docDirectory.list(recursive: false)) {
        try {
          final name =
              entity.uri.pathSegments.where((s) => s.isNotEmpty).last;

          // Never migrate or remove the data directory (user downloads / received data)
          if (name == 'data') continue;

          // Clean up leftover scratch/tmp files from prior interrupted attempts
          if (name.contains('.tmp.')) {
            try {
              await entity.delete(recursive: true);
            } catch (_) {}
            continue;
          }

          final isLegacyTarget =
              legacyItems.contains(name) || name.endsWith('.toml');
          if (!isLegacyTarget) continue;

          final targetPath = '$supportDir/$name';

          if (entity is File) {
            final targetFile = File(targetPath);
            final bool targetExists = await targetFile.exists();
            final bool targetHasData =
                targetExists && (await targetFile.length()) > 0;

            if (!targetExists || !targetHasData) {
              final srcLength = await entity.length();
              final tmpPath =
                  '$targetPath.tmp.${DateTime.now().microsecondsSinceEpoch}';
              final tmpFile = File(tmpPath);
              try {
                await entity.copy(tmpPath);
                if (await tmpFile.exists() &&
                    (await tmpFile.length()) == srcLength) {
                  await tmpFile.rename(targetPath);
                  if (await targetFile.exists() &&
                      (await targetFile.length()) == srcLength) {
                    await entity.delete();
                    debugPrint(
                      'CRED-011: Successfully migrated $name to Application Support',
                    );
                  } else {
                    debugPrint(
                      'CRED-011: Verification failed after rename for $name',
                    );
                  }
                } else {
                  if (await tmpFile.exists()) await tmpFile.delete();
                  debugPrint(
                    'CRED-011: Verification failed during copy of $name',
                  );
                }
              } catch (e) {
                if (await tmpFile.exists()) {
                  try {
                    await tmpFile.delete();
                  } catch (_) {}
                }
                debugPrint('CRED-011: Error copying $name: $e');
              }
            } else {
              // Target already exists with valid data - remove legacy copy from shareable Documents root
              try {
                await entity.delete();
                debugPrint(
                  'CRED-011: Removed duplicate legacy file $name from Documents',
                );
              } catch (e) {
                debugPrint(
                  'CRED-011: Failed to remove duplicate legacy file $name: $e',
                );
              }
            }
          } else if (entity is Directory) {
            final targetDir = Directory(targetPath);
            if (!await targetDir.exists()) {
              final tmpPath =
                  '$targetPath.tmp.${DateTime.now().microsecondsSinceEpoch}';
              final tmpDir = Directory(tmpPath);
              try {
                await tmpDir.create(recursive: true);
                await _copyDirRecursive(entity, tmpDir);
                await tmpDir.rename(targetPath);
                if (await targetDir.exists()) {
                  await entity.delete(recursive: true);
                  debugPrint(
                    'CRED-011: Successfully migrated directory $name to Application Support',
                  );
                }
              } catch (e) {
                if (await tmpDir.exists()) {
                  try {
                    await tmpDir.delete(recursive: true);
                  } catch (_) {}
                }
                debugPrint(
                  'CRED-011: Failed migrating directory $name: $e',
                );
              }
            } else {
              // Target directory exists, migrate any missing entries inside
              try {
                await _migrateDirContents(entity, targetDir);
                if (await entity.list().isEmpty) {
                  await entity.delete(recursive: true);
                  debugPrint(
                    'CRED-011: Removed migrated directory $name from Documents',
                  );
                }
              } catch (e) {
                debugPrint(
                  'CRED-011: Error migrating dir contents for $name: $e',
                );
              }
            }
          }
        } catch (itemErr) {
          debugPrint('CRED-011: Error processing entity during migration: $itemErr');
        }
      }
    } catch (e) {
      debugPrint('CRED-011: Error during iOS legacy storage migration: $e');
    }
  }

  static Future<void> _copyDirRecursive(Directory src, Directory dst) async {
    await for (final child in src.list(recursive: false)) {
      final childName =
          child.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final newPath = '${dst.path}/$childName';
      if (child is Directory) {
        final subDir = Directory(newPath);
        await subDir.create(recursive: true);
        await _copyDirRecursive(child, subDir);
      } else if (child is File) {
        final len = await child.length();
        final tmpPath =
            '$newPath.tmp.${DateTime.now().microsecondsSinceEpoch}';
        final tmpFile = File(tmpPath);
        try {
          await child.copy(tmpPath);
          if (await tmpFile.exists() && (await tmpFile.length()) == len) {
            await tmpFile.rename(newPath);
          } else {
            if (await tmpFile.exists()) await tmpFile.delete();
            throw StateError('Failed to copy $childName atomically');
          }
        } catch (e) {
          if (await tmpFile.exists()) {
            try {
              await tmpFile.delete();
            } catch (_) {}
          }
          rethrow;
        }
      }
    }
  }

  static Future<void> _migrateDirContents(Directory src, Directory dst) async {
    await for (final child in src.list(recursive: false)) {
      final childName =
          child.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final targetPath = '${dst.path}/$childName';
      if (child is File) {
        final targetFile = File(targetPath);
        final bool targetExists = await targetFile.exists();
        final bool targetHasData =
            targetExists && (await targetFile.length()) > 0;

        if (!targetExists || !targetHasData) {
          final len = await child.length();
          final tmpPath =
              '$targetPath.tmp.${DateTime.now().microsecondsSinceEpoch}';
          final tmpFile = File(tmpPath);
          try {
            await child.copy(tmpPath);
            if (await tmpFile.exists() && (await tmpFile.length()) == len) {
              await tmpFile.rename(targetPath);
              if (await targetFile.exists() &&
                  (await targetFile.length()) == len) {
                await child.delete();
              }
            } else {
              if (await tmpFile.exists()) await tmpFile.delete();
            }
          } catch (e) {
            if (await tmpFile.exists()) {
              try {
                await tmpFile.delete();
              } catch (_) {}
            }
            debugPrint('CRED-011: Error migrating child $childName: $e');
          }
        } else {
          try {
            await child.delete();
          } catch (_) {}
        }
      } else if (child is Directory) {
        final targetSubDir = Directory(targetPath);
        if (!await targetSubDir.exists()) {
          await targetSubDir.create(recursive: true);
        }
        await _migrateDirContents(child, targetSubDir);
        if (await child.list().isEmpty) {
          await child.delete(recursive: true);
        }
      }
    }
  }
}
