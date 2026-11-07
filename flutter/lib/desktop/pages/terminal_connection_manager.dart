import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import '../../common/shared_state.dart';
import '../../models/model.dart';

/// Manages terminal connections to ensure one FFI instance per peer and privilege mode
class TerminalConnectionManager {
  static final Map<String, FFI> _connections = {};
  static final Map<String, int> _connectionRefCount = {};

  // Track service IDs per connection key
  static final Map<String, String> _serviceIds = {};
  // Track privilege modes per connection key
  static final Map<String, bool> _connectionAdminMode = {};

  static String connectionKey(String peerId, bool isTerminalRunAsAdmin) {
    return '$peerId:${isTerminalRunAsAdmin ? "admin" : "standard"}';
  }

  /// Get or create an FFI instance for a peer and privilege mode
  static FFI getConnection({
    required String peerId,
    required String? password,
    required bool? isSharedPassword,
    required bool? forceRelay,
    required String? connToken,
    bool isTerminalRunAsAdmin = false,
  }) {
    final key = connectionKey(peerId, isTerminalRunAsAdmin);
    final existingFfi = _connections[key];
    if (existingFfi != null && !existingFfi.closed) {
      // Increment reference count
      _connectionRefCount[key] = (_connectionRefCount[key] ?? 0) + 1;
      debugPrint(
        '[TerminalConnectionManager] Reusing existing connection for key $key. Reference count: ${_connectionRefCount[key]}',
      );
      return existingFfi;
    }

    // Create new FFI instance for terminal
    debugPrint(
      '[TerminalConnectionManager] Creating new terminal connection for key $key (admin=$isTerminalRunAsAdmin)',
    );
    final ffi = FFI(null);
    ffi.start(
      peerId,
      password: password,
      isSharedPassword: isSharedPassword,
      forceRelay: forceRelay,
      connToken: connToken,
      isTerminal: true,
      isTerminalRunAsAdmin: isTerminalRunAsAdmin,
    );

    _connections[key] = ffi;
    _connectionAdminMode[key] = isTerminalRunAsAdmin;
    _connectionRefCount[key] = 1;

    // Register the FFI instance with Get for dependency injection
    Get.put<FFI>(ffi, tag: 'terminal_$key');

    debugPrint(
      '[TerminalConnectionManager] New connection created. Total connections: ${_connections.length}',
    );
    return ffi;
  }

  /// Release a connection reference
  static void releaseConnection(
    String peerId, {
    bool isTerminalRunAsAdmin = false,
  }) {
    final key = connectionKey(peerId, isTerminalRunAsAdmin);
    final refCount = _connectionRefCount[key] ?? 0;
    debugPrint(
      '[TerminalConnectionManager] Releasing connection for key $key. Current ref count: $refCount',
    );

    if (refCount <= 1) {
      // Last reference, close the connection
      final ffi = _connections[key];
      if (ffi != null) {
        debugPrint(
          '[TerminalConnectionManager] Closing connection for key $key (last reference)',
        );
        ffi.close();
        _connections.remove(key);
        _connectionRefCount.remove(key);
        _connectionAdminMode.remove(key);
        deleteIfMatching<FFI>('terminal_$key', ffi);
      }
    } else {
      // Decrement reference count
      _connectionRefCount[key] = refCount - 1;
      debugPrint(
        '[TerminalConnectionManager] Connection still in use. New ref count: ${_connectionRefCount[key]}',
      );
    }
  }

  /// Check if a connection exists for a peer and privilege mode
  static bool hasConnection(
    String peerId, {
    bool isTerminalRunAsAdmin = false,
  }) {
    final key = connectionKey(peerId, isTerminalRunAsAdmin);
    final ffi = _connections[key];
    return ffi != null && !ffi.closed;
  }

  /// Get existing connection without creating new one
  static FFI? getExistingConnection(
    String peerId, {
    bool isTerminalRunAsAdmin = false,
  }) {
    final key = connectionKey(peerId, isTerminalRunAsAdmin);
    return _connections[key];
  }

  /// Get connection count for debugging
  static int getConnectionCount() => _connections.length;

  /// Get terminal count for a peer and privilege mode
  static int getTerminalCount(
    String peerId, {
    bool isTerminalRunAsAdmin = false,
  }) {
    final key = connectionKey(peerId, isTerminalRunAsAdmin);
    return _connectionRefCount[key] ?? 0;
  }

  /// Get service ID for a peer and privilege mode
  static String? getServiceId(
    String peerId, {
    bool isTerminalRunAsAdmin = false,
  }) {
    final key = connectionKey(peerId, isTerminalRunAsAdmin);
    return _serviceIds[key];
  }

  /// Set service ID for a peer and privilege mode
  static void setServiceId(
    String peerId,
    String serviceId, {
    bool isTerminalRunAsAdmin = false,
  }) {
    final key = connectionKey(peerId, isTerminalRunAsAdmin);
    _serviceIds[key] = serviceId;
    debugPrint(
      '[TerminalConnectionManager] Service ID for key $key: $serviceId',
    );
  }
}
