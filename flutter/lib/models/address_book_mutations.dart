/// Mandatory Management content-write protocol. No UI, global account state or
/// persistence fallback belongs here. A journal must durably reserve before send.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

const _maxSafeInteger = 9007199254740991;
final _uuid4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final _digest = RegExp(r'^[0-9a-f]{64}$');
final _guid = RegExp(r'^[A-Za-z0-9_-]{1,60}$');

bool _isDigest(String value) => _digest.stringMatch(value) == value;
bool _isUuid4(String value) => _uuid4.stringMatch(value) == value;

bool _validApiBase(Uri value) =>
    value.hasAuthority &&
    value.host.isNotEmpty &&
    value.toString().length <= 2048 &&
    value.userInfo.isEmpty &&
    !value.hasQuery &&
    !value.hasFragment &&
    !value.path.contains('\\') &&
    !value.pathSegments.any((segment) => segment == '.' || segment == '..') &&
    (value.scheme == 'https' ||
        (value.scheme == 'http' &&
            const ['localhost', '127.0.0.1', '::1'].contains(value.host)));

/// The provider's own personal-book GUID is a stable actor identity across
/// logins and username changes. Never derive persistent scope from a token.
String addressBookMutationScope(Uri apiBase, String personalGuid) {
  if (!_validApiBase(apiBase) ||
      personalGuid.length > 60 ||
      RegExp(r'^personal-[1-9][0-9]*$').stringMatch(personalGuid) !=
          personalGuid) {
    throw const AddressBookMutationException('invalid_scope');
  }
  final api = apiBase.replace(
    path: apiBase.path.replaceFirst(RegExp(r'/+$'), ''),
  );
  return sha256
      .convert(
        utf8.encode(
          jsonEncode({'api': api.toString(), 'personal': personalGuid}),
        ),
      )
      .toString();
}

enum AddressBookMutationKind {
  peerAdd('address_book_peer_add', 'POST', 'peer/add'),
  peerUpdate('address_book_peer_update', 'PUT', 'peer/update'),
  peerDelete('address_book_peer_delete', 'DELETE', 'peer'),
  tagAdd('address_book_tag_add', 'POST', 'tag/add'),
  tagRename('address_book_tag_rename', 'PUT', 'tag/rename'),
  tagUpdate('address_book_tag_update', 'PUT', 'tag/update'),
  tagDelete('address_book_tag_delete', 'DELETE', 'tag');

  final String operation;
  final String method;
  final String route;
  const AddressBookMutationKind(this.operation, this.method, this.route);
}

class AddressBookMutationException implements Exception {
  final String code;
  const AddressBookMutationException(this.code);
  @override
  String toString() => 'Address book operation: $code';
}

String newAddressBookOperationId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class AddressBookMutationCommand {
  final AddressBookMutationKind kind;
  final String operationId;
  final String guid;
  final int expectedGeneration;
  final Uri uri;
  final String body;
  final String requestDigest;

  AddressBookMutationCommand._(
    this.kind,
    this.operationId,
    this.guid,
    this.expectedGeneration,
    this.uri,
    this.body,
    this.requestDigest,
  );

  factory AddressBookMutationCommand({
    required AddressBookMutationKind kind,
    required Uri apiBase,
    required String guid,
    required int expectedGeneration,
    required Object payload,
    String? operationId,
  }) {
    if (_guid.stringMatch(guid) != guid ||
        expectedGeneration < 0 ||
        expectedGeneration >= _maxSafeInteger ||
        !_validApiBase(apiBase)) {
      throw const AddressBookMutationException('invalid_request');
    }
    final id = operationId ?? newAddressBookOperationId();
    if (!_isUuid4(id)) {
      throw const AddressBookMutationException('invalid_operation_id');
    }
    final prefix = apiBase.path.replaceFirst(RegExp(r'/+$'), '');
    final uri = apiBase.replace(path: '$prefix/api/ab/${kind.route}/$guid');
    final String body;
    try {
      body = jsonEncode(payload);
    } on JsonUnsupportedObjectError {
      throw const AddressBookMutationException('invalid_payload');
    }
    if (utf8.encode(body).length > 1024 * 1024) {
      throw const AddressBookMutationException('request_too_large');
    }
    final digest = addressBookRequestDigest(
      operation: kind.operation,
      method: kind.method,
      path: uri.path,
      body: body,
      expectedGeneration: expectedGeneration,
    );
    return AddressBookMutationCommand._(
      kind,
      id,
      guid,
      expectedGeneration,
      uri,
      body,
      digest,
    );
  }

  Map<String, String> headers(String token) => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
    'Idempotency-Key': 'v2:$operationId',
    'If-Match': '"$expectedGeneration"',
  };
}

class AddressBookMutationInput {
  final AddressBookMutationKind kind;
  final Object payload;
  const AddressBookMutationInput(this.kind, this.payload);
}

class AddressBookMutationBatch {
  final List<AddressBookMutationCommand> commands;
  AddressBookMutationBatch._(this.commands);

  /// Freeze and validate the entire selection before the first reservation or
  /// POST. Later caller edits cannot change a child intent mid-batch.
  factory AddressBookMutationBatch({
    required Uri apiBase,
    required String guid,
    required int expectedGeneration,
    required List<AddressBookMutationInput> inputs,
  }) {
    if (inputs.isEmpty ||
        inputs.length > 1000 ||
        expectedGeneration < 0 ||
        expectedGeneration + inputs.length > _maxSafeInteger) {
      throw const AddressBookMutationException('invalid_selection');
    }
    final commands = <AddressBookMutationCommand>[];
    var bytes = 0;
    for (final (index, input) in inputs.indexed) {
      final command = AddressBookMutationCommand(
        kind: input.kind,
        apiBase: apiBase,
        guid: guid,
        expectedGeneration: expectedGeneration + index,
        payload: input.payload,
      );
      bytes += utf8.encode(command.body).length;
      if (bytes > 4 * 1024 * 1024) {
        throw const AddressBookMutationException('selection_too_large');
      }
      commands.add(command);
    }
    return AddressBookMutationBatch._(List.unmodifiable(commands));
  }
}

/// Receipt v2 exposes only a canonical public projection. The provider privately
/// binds the full intent using an encrypted per-operation key; no password hash
/// or binding key belongs in this public proof.
const _secretIntentFields = {
  'password',
  'default_password',
  'address_book_password',
  'hash',
  'rhash',
  'token',
};

int _compareIntentKeys(String first, String second) {
  final a = first.runes.iterator;
  final b = second.runes.iterator;
  while (true) {
    final hasA = a.moveNext();
    final hasB = b.moveNext();
    if (!hasA || !hasB) {
      return hasA
          ? 1
          : hasB
          ? -1
          : 0;
    }
    final comparison = a.current.compareTo(b.current);
    if (comparison != 0) return comparison;
  }
}

Object? _publicMutationIntent(Object? value, [int depth = 0]) {
  if (depth > 256) {
    throw const AddressBookMutationException('invalid_payload');
  }
  if (value is num) {
    if (value.isNaN || value.isInfinite) {
      throw const AddressBookMutationException('invalid_payload');
    }
    if (value == 0) return 0; // Collapses -0.0 to 0
    if (value is double &&
        value.truncateToDouble() == value &&
        value >= -9007199254740991 &&
        value <= 9007199254740991) {
      return value.toInt(); // Normalizes 1.0 to 1 on native Dart VM
    }
    return value;
  }
  if (value is Map) {
    if (value.keys.any((key) => key is! String)) {
      throw const AddressBookMutationException('invalid_payload');
    }
    final keys = value.keys.cast<String>().toList()..sort(_compareIntentKeys);
    return {
      for (final key in keys)
        key: _secretIntentFields.contains(key)
            ? {
                '\$secret_intent': value[key] == null
                    ? 'keep'
                    : value[key] == ''
                    ? 'clear'
                    : 'set',
              }
            : _publicMutationIntent(value[key], depth + 1),
    };
  }
  if (value is List) {
    return [for (final child in value) _publicMutationIntent(child, depth + 1)];
  }
  return value;
}

Object? publicMutationIntent(Object? value, [int depth = 0]) =>
    _publicMutationIntent(value, depth);

String addressBookRequestDigest({
  required String operation,
  required String method,
  required String path,
  required String body,
  required int expectedGeneration,
}) {
  final document = {
    'args': <String, Object>{},
    'body': body.isEmpty ? null : jsonDecode(body),
    'expected_generation': expectedGeneration,
    'has_body': body.isNotEmpty,
    'method': method,
    'operation': operation,
    'path': path,
  };
  return sha256
      .convert(utf8.encode(jsonEncode(_publicMutationIntent(document))))
      .toString();
}

class AddressBookMutationResponse {
  final int status;
  final Map<String, String> headers;
  final List<int> bytes;
  AddressBookMutationResponse(this.status, this.headers, this.bytes);
}

Map<String, dynamic> _decodeReceipt(AddressBookMutationResponse response) {
  final media = response.headers.entries
      .where((entry) => entry.key.toLowerCase() == 'content-type')
      .map((entry) => entry.value.toLowerCase().trim());
  if (response.status < 200 ||
      response.status >= 500 ||
      media.length != 1 ||
      !RegExp(
        r'^application/json(?:;\s*charset=(?:utf-8|"utf-8"))?$',
      ).hasMatch(media.single) ||
      response.bytes.length > 1024 * 1024) {
    throw const AddressBookMutationException('invalid_receipt');
  }
  try {
    final body = jsonDecode(utf8.decode(response.bytes));
    if (body is Map<String, dynamic>) return body;
  } on FormatException {
    // Raw remote bodies, parser errors and credentials never become UI errors.
  }
  throw const AddressBookMutationException('invalid_receipt');
}

bool _versionOne(Object? value) => value is int && value == 1;
bool _positiveInteger(Object? value) =>
    value is int && value > 0 && value <= _maxSafeInteger;
bool _mutationCount(Object? value, int count) =>
    value is Map<String, dynamic> &&
    value.length == 1 &&
    value['mutations'] is int &&
    value['mutations'] == count;

class AddressBookMutationReceipt {
  final String operationId;
  final String operation;
  final int status;
  final int? generation;
  final String? guid;
  final String? rejectionCode;
  const AddressBookMutationReceipt._(
    this.operationId,
    this.operation,
    this.status,
    this.generation,
    this.guid,
    this.rejectionCode,
  );
  bool get succeeded => status == 200;

  static AddressBookMutationReceipt verify(
    AddressBookMutationCommand command,
    AddressBookMutationResponse response,
  ) => _validated(
    _decodeReceipt(response),
    response.status,
    operationId: command.operationId,
    expectedOperation: command.kind.operation,
    expectedDigest: command.requestDigest,
    expectedGuid: command.guid,
    expectedGeneration: command.expectedGeneration,
  );

  /// After restart only metadata remains. The original actor's authenticated
  /// receipt GET is the authority, not a reconstructed/guessed mutation body.
  /// The result MUST NOT advance the generation of a stale displayed cache.
  static AddressBookMutationReceipt recover(
    PendingAddressBookOperation pending,
    AddressBookMutationResponse response,
  ) {
    if (response.status != 200) {
      throw AddressBookMutationException(
        response.status == 404
            ? 'operation_not_found'
            : response.status == 410
            ? 'operation_retired'
            : const [401, 403].contains(response.status)
            ? 'recovery_denied'
            : 'recovery_unavailable',
      );
    }
    final envelope = _decodeReceipt(response);
    final status = envelope['original_status_code'];
    final body = envelope['receipt'];
    if (!_versionOne(envelope['response_schema_version']) ||
        envelope.containsKey('error') ||
        status is! int ||
        !(status == 200 || (status >= 400 && status < 500)) ||
        body is! Map<String, dynamic>) {
      throw const AddressBookMutationException('invalid_receipt');
    }
    return _validated(body, status, operationId: pending.operationId);
  }

  static AddressBookMutationReceipt _validated(
    Map<String, dynamic> body,
    int status, {
    required String operationId,
    String? expectedOperation,
    String? expectedDigest,
    String? expectedGuid,
    int? expectedGeneration,
  }) {
    final operation = body['operation'];
    final requestDigest = body['request_digest'];
    if (!_versionOne(body['response_schema_version']) ||
        !(body['management_operation_receipt_version'] is int &&
            body['management_operation_receipt_version'] == 2) ||
        body['operation_id'] != operationId ||
        operation is! String ||
        !AddressBookMutationKind.values.any(
          (kind) => kind.operation == operation,
        ) ||
        (expectedOperation != null && operation != expectedOperation) ||
        requestDigest is! String ||
        !_isDigest(requestDigest) ||
        (expectedDigest != null && requestDigest != expectedDigest) ||
        body['result_digest'] is! String ||
        !_isDigest(body['result_digest']) ||
        !_positiveInteger(body['operation_generation']) ||
        !_mutationCount(body['requested'], 1)) {
      throw const AddressBookMutationException('invalid_receipt');
    }
    if (status == 200) {
      final generations = body['mutation_generations'];
      final generation = body['mutation_generation'];
      if (body['result'] != 'OK' ||
          body.containsKey('error') ||
          !_mutationCount(body['applied'], 1) ||
          !_positiveInteger(generation) ||
          (expectedGeneration != null &&
              generation != expectedGeneration + 1) ||
          generations is! Map<String, dynamic> ||
          generations.length != 1) {
        throw const AddressBookMutationException('invalid_receipt');
      }
      final guid = generations.keys.single;
      if (_guid.stringMatch(guid) != guid ||
          (expectedGuid != null && guid != expectedGuid) ||
          generations[guid] is! int ||
          generations[guid] != generation) {
        throw const AddressBookMutationException('invalid_receipt');
      }
      return AddressBookMutationReceipt._(
        operationId,
        operation,
        status,
        generation as int,
        guid,
        null,
      );
    }
    final code = body['code'];
    final message = body['message'];
    if (status < 400 ||
        status >= 500 ||
        body.containsKey('result') ||
        body.containsKey('error') ||
        !_mutationCount(body['applied'], 0) ||
        code is! String ||
        RegExp(r'^[a-z][a-z0-9_]{0,63}$').stringMatch(code) != code ||
        message is! String ||
        message.isEmpty ||
        message.runes.length > 256 ||
        body['retryable'] is! bool) {
      throw const AddressBookMutationException('invalid_receipt');
    }
    return AddressBookMutationReceipt._(
      operationId,
      operation,
      status,
      null,
      expectedGuid,
      code,
    );
  }
}

final class PendingAddressBookOperation {
  final String operationId;
  final String scope;
  final int createdAt;
  PendingAddressBookOperation(this.operationId, this.scope, this.createdAt) {
    if (!_isUuid4(operationId) ||
        !_isDigest(scope) ||
        createdAt < 0 ||
        createdAt > _maxSafeInteger) {
      throw const AddressBookMutationException('invalid_journal_record');
    }
  }

  factory PendingAddressBookOperation.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 3 ||
        value['operation_id'] is! String ||
        value['scope'] is! String ||
        value['created_at'] is! int) {
      throw const AddressBookMutationException('invalid_journal_record');
    }
    return PendingAddressBookOperation(
      value['operation_id'],
      value['scope'],
      value['created_at'],
    );
  }

  Map<String, Object> toJson() => {
    'operation_id': operationId,
    'scope': scope,
    'created_at': createdAt,
  };
  bool matches(PendingAddressBookOperation other) =>
      operationId == other.operationId &&
      scope == other.scope &&
      createdAt == other.createdAt;
}

abstract interface class AddressBookMutationJournal {
  /// Atomic across all writers: if ANY unresolved record exists, fail before
  /// send. Success means durable metadata (ID/time/opaque scope only), not RAM.
  Future<void> reserve(PendingAddressBookOperation operation);
  Future<List<PendingAddressBookOperation>> readPending();

  /// Idempotent if absent; an existing different ID/scope/time must never be removed.
  Future<void> acknowledge(PendingAddressBookOperation operation);
}

enum AddressBookMutationState { confirmed, rejected, unknown, notSent }

class AddressBookMutationOutcome {
  final AddressBookMutationState state;
  final String operationId;
  final String code;
  final AddressBookMutationReceipt? receipt;
  final bool pendingCleanup;
  const AddressBookMutationOutcome(
    this.state,
    this.operationId,
    this.code, {
    this.receipt,
    this.pendingCleanup = false,
  });
  bool get succeeded => state == AddressBookMutationState.confirmed;
}

class AddressBookMutationBatchOutcome {
  final int requested;
  final List<AddressBookMutationOutcome> outcomes;
  AddressBookMutationBatchOutcome(
    this.requested,
    List<AddressBookMutationOutcome> outcomes,
  ) : outcomes = List.unmodifiable(outcomes);
  int get confirmed => outcomes.where((result) => result.succeeded).length;
  int get rejected => outcomes
      .where((result) => result.state == AddressBookMutationState.rejected)
      .length;
  List<String> get unknownOperationIds => List.unmodifiable(
    outcomes
        .where((result) => result.state == AddressBookMutationState.unknown)
        .map((result) => result.operationId),
  );
  int get notAttempted =>
      requested -
      outcomes
          .where((result) => result.state != AddressBookMutationState.notSent)
          .length;
  bool get fullyConfirmed => requested > 0 && confirmed == requested;
  bool get pendingCleanup => outcomes.any((result) => result.pendingCleanup);
}

typedef AddressBookMutationSend =
    Future<AddressBookMutationResponse> Function(
      AddressBookMutationCommand command,
    );

class AddressBookRecoveryOutcome {
  final PendingAddressBookOperation pending;
  final AddressBookMutationReceipt? receipt;
  final String code;
  final bool pendingCleanup;
  const AddressBookRecoveryOutcome(
    this.pending,
    this.code, {
    this.receipt,
    this.pendingCleanup = false,
  });
  bool get resolved => receipt != null;
}

class AddressBookMutationService {
  final AddressBookMutationJournal journal;
  final AddressBookMutationSend send;
  final String Function() currentScope;

  /// Revalidate async account/endpoint/frame state AFTER durable reservation,
  /// before crossing the transport uncertainty boundary. Must not send traffic.
  final Future<bool> Function()? beforeSend;
  final void Function()? cancelTransport;
  bool _busy = false;
  AddressBookMutationService({
    required this.journal,
    required this.send,
    required this.currentScope,
    this.beforeSend,
    this.cancelTransport,
  });

  bool _sameScope(String scope) {
    try {
      return currentScope() == scope;
    } catch (_) {
      return false;
    }
  }

  Future<AddressBookRecoveryOutcome> recover(
    PendingAddressBookOperation pending, {
    required Uri apiBase,
    required Future<AddressBookMutationResponse> Function(Uri uri) read,
    Duration budget = const Duration(seconds: 30),
  }) async {
    if (_busy) return AddressBookRecoveryOutcome(pending, 'operation_busy');
    if (!_validApiBase(apiBase) || !_sameScope(pending.scope)) {
      return AddressBookRecoveryOutcome(pending, 'context_changed');
    }
    if (budget <= Duration.zero || budget > const Duration(minutes: 10)) {
      return AddressBookRecoveryOutcome(pending, 'invalid_budget');
    }
    _busy = true;
    final watch = Stopwatch()..start();
    Duration remaining() {
      final left = budget - watch.elapsed;
      if (left <= Duration.zero) {
        throw const AddressBookMutationException('deadline');
      }
      return left;
    }

    try {
      // Receipt lookup is independent of local inventory: another window may
      // already have acknowledged this ID, or the local journal may be damaged.
      // Only acknowledgement needs the exact local identity, after verification.
      final prefix = apiBase.path.replaceFirst(RegExp(r'/+$'), '');
      final uri = apiBase.replace(
        path: '$prefix/api/management-operations/${pending.operationId}',
      );
      final response = await read(uri).timeout(remaining());
      final receipt = AddressBookMutationReceipt.recover(pending, response);
      var pendingCleanup = false;
      try {
        await journal.acknowledge(pending).timeout(remaining());
      } catch (_) {
        pendingCleanup = true;
      }
      return AddressBookRecoveryOutcome(
        pending,
        receipt.rejectionCode ?? 'confirmed',
        receipt: receipt,
        pendingCleanup: pendingCleanup,
      );
    } catch (error) {
      final code =
          error is AddressBookMutationException &&
              const {
                'invalid_receipt',
                'operation_not_found',
                'operation_retired',
                'recovery_denied',
                'recovery_unavailable',
                'deadline',
                'journal_busy',
                'journal_unavailable',
                'journal_corrupt',
              }.contains(error.code)
          ? error.code
          : error is TimeoutException
          ? 'deadline'
          : 'recovery_unavailable';
      // A failed/late read, including 404/retention expiry, cannot prove that the
      // ORIGINAL mutation was not sent. Keep it unknown and keep the record.
      return AddressBookRecoveryOutcome(pending, code);
    } finally {
      cancelTransport?.call();
      _busy = false;
    }
  }

  Future<AddressBookMutationOutcome> execute(
    AddressBookMutationCommand command, {
    required String scope,
    Duration budget = const Duration(seconds: 30),
  }) async {
    final id = command.operationId;
    if (_busy) {
      return AddressBookMutationOutcome(
        AddressBookMutationState.notSent,
        id,
        'operation_busy',
      );
    }
    _busy = true;
    try {
      return await _execute(command, scope: scope, budget: budget);
    } finally {
      cancelTransport?.call();
      _busy = false;
    }
  }

  Future<AddressBookMutationBatchOutcome> executeBatch(
    AddressBookMutationBatch batch, {
    required String scope,
    Duration budget = const Duration(seconds: 30),
  }) async {
    if (_busy) {
      return AddressBookMutationBatchOutcome(batch.commands.length, [
        AddressBookMutationOutcome(
          AddressBookMutationState.notSent,
          batch.commands.first.operationId,
          'operation_busy',
        ),
      ]);
    }
    _busy = true;
    try {
      final outcomes = <AddressBookMutationOutcome>[];
      final watch = Stopwatch()..start();
      for (final command in batch.commands) {
        final outcome = await _execute(
          command,
          scope: scope,
          budget: budget - watch.elapsed,
        );
        outcomes.add(outcome);
        // Every child advances exactly once. Rejection/unknown/persistence
        // cleanup failure stops the batch; no new-generation/new-ID retry.
        if (!outcome.succeeded || outcome.pendingCleanup) break;
      }
      return AddressBookMutationBatchOutcome(batch.commands.length, outcomes);
    } finally {
      cancelTransport?.call();
      _busy = false;
    }
  }

  Future<AddressBookMutationOutcome> _execute(
    AddressBookMutationCommand command, {
    required String scope,
    required Duration budget,
  }) async {
    final id = command.operationId;
    if (budget <= Duration.zero) {
      return AddressBookMutationOutcome(
        AddressBookMutationState.notSent,
        id,
        'deadline',
      );
    }
    if (budget > const Duration(minutes: 10)) {
      return AddressBookMutationOutcome(
        AddressBookMutationState.notSent,
        id,
        'invalid_budget',
      );
    }
    if (!_isDigest(scope) || !_sameScope(scope)) {
      return AddressBookMutationOutcome(
        AddressBookMutationState.notSent,
        id,
        'context_changed',
      );
    }
    final pending = PendingAddressBookOperation(
      id,
      scope,
      DateTime.now().toUtc().millisecondsSinceEpoch,
    );
    final watch = Stopwatch()..start();
    var sendStarted = false;
    Duration remaining() {
      final left = budget - watch.elapsed;
      if (left <= Duration.zero) {
        throw const AddressBookMutationException('deadline');
      }
      return left;
    }

    try {
      try {
        await journal.reserve(pending).timeout(remaining());
      } catch (_) {
        // A timed-out disk write may finish later. Never send, never guess that
        // the reservation is absent, and never auto-remove a different writer.
        return AddressBookMutationOutcome(
          AddressBookMutationState.notSent,
          id,
          'journal_unavailable',
          pendingCleanup: true,
        );
      }
      var allowed = true;
      try {
        if (beforeSend != null) {
          allowed = await beforeSend!().timeout(remaining());
        }
      } catch (_) {
        allowed = false;
      }
      if (!allowed || !_sameScope(scope) || watch.elapsed >= budget) {
        try {
          await journal.acknowledge(pending).timeout(remaining());
        } catch (_) {
          return AddressBookMutationOutcome(
            AddressBookMutationState.notSent,
            id,
            'context_changed',
            pendingCleanup: true,
          );
        }
        return AddressBookMutationOutcome(
          AddressBookMutationState.notSent,
          id,
          'context_changed',
        );
      }
      final AddressBookMutationReceipt receipt;
      try {
        // Set the uncertainty boundary before invoking transport, including a
        // synchronous throw. No automatic retry and no ID replacement occurs.
        final sendBudget = remaining();
        sendStarted = true;
        final response = await send(command).timeout(sendBudget);
        receipt = AddressBookMutationReceipt.verify(command, response);
      } catch (error) {
        final code =
            error is AddressBookMutationException &&
                const {
                  'invalid_receipt',
                  'deadline',
                  'cancelled',
                  'response_too_large',
                  'redirect_rejected',
                  'transport_failed',
                }.contains(error.code)
            ? error.code
            : error is TimeoutException
            ? 'deadline'
            : 'transport_failed';
        return AddressBookMutationOutcome(
          sendStarted
              ? AddressBookMutationState.unknown
              : AddressBookMutationState.notSent,
          id,
          code,
          pendingCleanup: !sendStarted,
        );
      }
      var pendingCleanup = false;
      try {
        await journal.acknowledge(pending).timeout(remaining());
      } catch (_) {
        pendingCleanup = true;
      }
      // Even if account/UI changed, the original immutable receipt remains a
      // confirmed outcome; callers must separately guard cache/UI publication.
      return AddressBookMutationOutcome(
        receipt.succeeded
            ? AddressBookMutationState.confirmed
            : AddressBookMutationState.rejected,
        id,
        receipt.rejectionCode ?? 'confirmed',
        receipt: receipt,
        pendingCleanup: pendingCleanup,
      );
    } catch (_) {
      return AddressBookMutationOutcome(
        sendStarted
            ? AddressBookMutationState.unknown
            : AddressBookMutationState.notSent,
        id,
        'internal_failed',
        pendingCleanup: true,
      );
    }
  }
}
