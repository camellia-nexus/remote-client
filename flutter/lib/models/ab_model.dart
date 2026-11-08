import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/hbbs/hbbs.dart';
import 'package:camellia_remote_app/common/widgets/peers_view.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:get/get.dart';
import 'package:bot_toast/bot_toast.dart';

import '../utils/http_service.dart' as http;
import '../common.dart';
import 'address_book_snapshot.dart';
import 'address_book_mutations.dart';
import 'address_book_journal.dart';

String? parseSharedCredentialResponse(String body, int statusCode) {
  if (statusCode != 200) {
    return null;
  }
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    final password = decoded['password'];
    return password is String && password.isNotEmpty && password.length <= 60
        ? password
        : null;
  } catch (_) {
    return null;
  }
}

final syncAbOption = 'sync-ab-with-recent-sessions';
bool shouldSyncAb() {
  return bind.mainGetLocalOption(key: syncAbOption) == 'Y';
}

final sortAbTagsOption = 'sync-ab-tags';
bool shouldSortTags() {
  return bind.mainGetLocalOption(key: sortAbTagsOption) == 'Y';
}

final filterAbTagOption = 'filter-ab-by-intersection';
bool filterAbTagByIntersection() {
  return bind.mainGetLocalOption(key: filterAbTagOption) == 'Y';
}

const _personalAddressBookName = "My address book";

const kUntagged = "Untagged";

bool _isPersonalGuid(String? guid) {
  if (guid == null) {
    return false;
  }
  return guid.startsWith('personal-');
}

enum ForcePullAb { listAndCurrent, current }

class AbModel {
  final addressbooks = Map<String, BaseAb>.fromEntries([]).obs;
  final RxString _currentName = ''.obs;
  RxString get currentName => _currentName;
  final _dummyAb = DummyAb();
  BaseAb get current => addressbooks[_currentName.value] ?? _dummyAb;

  RxList<Peer> get currentAbPeers => current.peers;
  RxList<String> get currentAbTags => current.tags;
  RxList<String> get selectedTags => current.selectedTags;

  RxBool get currentAbLoading => current.abLoading;
  bool get currentAbEmpty => current.peers.isEmpty && current.tags.isEmpty;
  final _listPullError = ''.obs;
  RxString get abPullError =>
      _listPullError.value.isNotEmpty ? _listPullError : current.pullError;
  RxString get currentAbPushError => current.pushError;
  String? _personalAbGuid;
  String _personalAbName = _personalAddressBookName;
  int? _personalAbGeneration;
  String? _personalAbApi;
  String? _personalAbToken;
  int _listEpoch = 0;
  int _mutationViewEpoch = 0;
  int _journalReadEpoch = 0;
  AddressBookMutationJournal? _mutationJournal;
  http.HttpCancellation? _mutationCancellation;
  AddressBookMutationJournal get _journal =>
      _mutationJournal ??= createAddressBookMutationJournal();
  final mutationBusy = false.obs;
  final mutationJournalReady = false.obs;
  final mutationJournalError = ''.obs;
  final mutationStatus = ''.obs;
  final pendingMutations = <PendingAddressBookOperation>[].obs;

  bool get mutationsBlocked =>
      mutationBusy.value ||
      !mutationJournalReady.value ||
      mutationJournalError.value.isNotEmpty ||
      pendingMutations.isNotEmpty;

  Future<void> refreshMutationJournal() async {
    final epoch = ++_journalReadEpoch;
    try {
      final pending = await _journal.readPending().timeout(
        const Duration(seconds: 5),
      );
      if (epoch != _journalReadEpoch) return;
      pendingMutations.assignAll(pending);
      mutationJournalError.value = '';
      mutationJournalReady.value = true;
    } catch (_) {
      if (epoch != _journalReadEpoch) return;
      mutationJournalReady.value = false;
      mutationJournalError.value =
          'Address book operation storage is unavailable. Writes are disabled.';
    }
  }

  String _apiIdentity(String api) => api.replaceFirst(RegExp(r'/+$'), '');
  Future<String> _currentMutationApi() async => _apiIdentity(
    await bind.mainGetApiServer().timeout(const Duration(seconds: 5)),
  );

  /// One admission owner for every book and all GUI/background entry points.
  /// Never publish receipt generations onto old content: refresh one complete
  /// snapshot after the whole batch, not after each child.
  Future<AddressBookMutationBatchOutcome?> _mutate(
    Ab book,
    List<AddressBookMutationInput> inputs,
  ) async {
    if (!book.canWrite() || inputs.isEmpty) return null;
    final generation = book._snapshotGeneration!;
    final snapshotApi = book._snapshotApi!;
    final token = bind.mainGetLocalOption(key: 'access_token');
    final personalGuid = _personalAbGuid;
    final guid = book.profile.guid;
    final listEpoch = _listEpoch;
    final viewEpoch = _mutationViewEpoch;
    mutationBusy.value = true;
    mutationStatus.value = '';
    book.invalidateSnapshot();
    final snapshotEpoch = book._snapshotEpoch;
    bool ownsContext() =>
        listEpoch == _listEpoch &&
        viewEpoch == _mutationViewEpoch &&
        personalGuid != null &&
        personalGuid == _personalAbGuid &&
        _personalAbApi == snapshotApi &&
        _personalAbToken == token &&
        token.isNotEmpty &&
        token == bind.mainGetLocalOption(key: 'access_token') &&
        book.profile.guid == guid &&
        book._snapshotEpoch == snapshotEpoch &&
        addressbooks.values.any((value) => identical(value, book));
    var ownsResult = false;
    final cancellation = http.HttpCancellation();
    _mutationCancellation = cancellation;
    AddressBookMutationBatchOutcome? outcome;
    try {
      // Freeze payloads synchronously, before endpoint lookup or persistence.
      final base = Uri.parse(snapshotApi);
      final scope = addressBookMutationScope(base, personalGuid ?? '');
      final batch = AddressBookMutationBatch(
        apiBase: base,
        guid: guid,
        expectedGeneration: generation,
        inputs: inputs,
      );
      final api = await _currentMutationApi();
      if (!ownsContext() || api != snapshotApi) {
        if (ownsContext()) {
          mutationStatus.value =
              'Address book context changed. Refresh before editing.';
        }
        return null;
      }
      final service = AddressBookMutationService(
        journal: _journal,
        cancelTransport: cancellation.cancel,
        currentScope: () => ownsContext() ? scope : '',
        beforeSend: () async {
          final currentApi = await _currentMutationApi();
          return ownsContext() && api == currentApi;
        },
        send: (command) async {
          final response = await http.HttpService().sendRequest(
            command.uri,
            switch (command.kind.method) {
              'POST' => http.HttpMethod.post,
              'PUT' => http.HttpMethod.put,
              'DELETE' => http.HttpMethod.delete,
              _ => throw const AddressBookMutationException('invalid_request'),
            },
            headers: command.headers(token),
            body: command.body,
            cancellation: cancellation,
          );
          return AddressBookMutationResponse(
            response.statusCode,
            response.headers,
            response.bodyBytes,
          );
        },
      );
      outcome = await service.executeBatch(batch, scope: scope);
      final currentApi = await _currentMutationApi();
      ownsResult = ownsContext() && api == currentApi;
      if (ownsResult) {
        final unknown = outcome.unknownOperationIds;
        mutationStatus.value = outcome.fullyConfirmed && !outcome.pendingCleanup
            ? ''
            : 'Address book batch: ${outcome.confirmed} confirmed, ${outcome.rejected} rejected, '
                  '${unknown.length} unknown, ${outcome.notAttempted} not sent.'
                  '${unknown.isEmpty ? '' : ' Operation ID: ${unknown.single}.'}'
                  '${outcome.pendingCleanup ? ' Operation storage requires attention.' : ''}'
                  ' ${outcome.outcomes.last.code}';
      }
    } catch (error) {
      if (ownsContext()) {
        mutationStatus.value =
            'Address book write could not be completed: '
            '${error is AddressBookMutationException ? error.code : 'operation_unavailable'}';
      }
    } finally {
      cancellation.cancel();
      if (identical(_mutationCancellation, cancellation)) {
        _mutationCancellation = null;
      }
      await refreshMutationJournal();
      mutationBusy.value = false;
    }
    try {
      if (ownsResult &&
          ownsContext() &&
          snapshotApi == await _currentMutationApi() &&
          ownsContext()) {
        await book.pullAb(quiet: false);
        if (listEpoch == _listEpoch &&
            viewEpoch == _mutationViewEpoch &&
            token == bind.mainGetLocalOption(key: 'access_token')) {
          _refreshTab();
          _callbackPeerUpdate();
          _saveCache();
        } else {
          ownsResult = false;
        }
      } else {
        ownsResult = false;
      }
    } catch (_) {
      // The write's immutable receipt is still true if refresh fails. Keep the
      // snapshot non-editable; never retry the write to repair a read failure.
      if (listEpoch != _listEpoch ||
          viewEpoch != _mutationViewEpoch ||
          token != bind.mainGetLocalOption(key: 'access_token')) {
        ownsResult = false;
      }
    }
    return ownsResult ? outcome : null;
  }

  Future<void> recoverMutation(PendingAddressBookOperation pending) async {
    if (mutationBusy.value) return;
    final token = bind.mainGetLocalOption(key: 'access_token');
    final personalGuid = _personalAbGuid;
    final epoch = _listEpoch;
    final cancellation = http.HttpCancellation();
    _mutationCancellation = cancellation;
    mutationBusy.value = true;
    try {
      final api = await _currentMutationApi();
      if (personalGuid == null ||
          epoch != _listEpoch ||
          personalGuid != _personalAbGuid ||
          token.isEmpty ||
          token != bind.mainGetLocalOption(key: 'access_token') ||
          _personalAbApi != api ||
          _personalAbToken != token) {
        if (epoch == _listEpoch &&
            token == bind.mainGetLocalOption(key: 'access_token')) {
          mutationStatus.value =
              'Refresh the account and address book before looking up the original operation.';
        }
        return;
      }
      final base = Uri.parse(api);
      final scope = addressBookMutationScope(base, personalGuid);
      final service = AddressBookMutationService(
        journal: _journal,
        cancelTransport: cancellation.cancel,
        currentScope: () =>
            epoch == _listEpoch &&
                token == bind.mainGetLocalOption(key: 'access_token') &&
                personalGuid == _personalAbGuid
            ? scope
            : '',
        send: (_) => throw StateError('Recovery cannot send a mutation'),
      );
      final result = await service.recover(
        pending,
        apiBase: base,
        read: (uri) async {
          if (api != await _currentMutationApi() ||
              epoch != _listEpoch ||
              token != bind.mainGetLocalOption(key: 'access_token')) {
            throw const AddressBookMutationException('context_changed');
          }
          final response = await http.get(
            uri,
            headers: {'Authorization': 'Bearer $token'},
            cancellation: cancellation,
          );
          return AddressBookMutationResponse(
            response.statusCode,
            response.headers,
            response.bodyBytes,
          );
        },
      );
      if (epoch == _listEpoch &&
          token == bind.mainGetLocalOption(key: 'access_token') &&
          api == await _currentMutationApi()) {
        mutationStatus.value = result.resolved
            ? 'Operation ${pending.operationId}: ${result.code}.'
                  '${result.pendingCleanup ? ' Operation storage requires attention.' : ''}'
            : 'Operation ${pending.operationId} remains unresolved: ${result.code}. '
                  'Use the original account and server; a missing receipt does not prove the write failed.';
      }
    } catch (_) {
      if (epoch == _listEpoch) {
        mutationStatus.value =
            'Operation recovery is unavailable. The original operation is retained.';
      }
    } finally {
      cancellation.cancel();
      if (identical(_mutationCancellation, cancellation)) {
        _mutationCancellation = null;
      }
      await refreshMutationJournal();
      mutationBusy.value = false;
    }
    // Read current truth, never relabel cached content with an old receipt.
    if (epoch == _listEpoch &&
        token == bind.mainGetLocalOption(key: 'access_token')) {
      await pullAb(force: ForcePullAb.current, quiet: false);
    }
  }

  Future<void> reconcileMutation(
    PendingAddressBookOperation pending, {
    required String confirmedId,
    required bool verifiedOriginalState,
  }) async {
    if (mutationBusy.value ||
        !verifiedOriginalState ||
        confirmedId != pending.operationId) {
      return;
    }
    mutationBusy.value = true;
    try {
      await _journal.acknowledge(pending).timeout(const Duration(seconds: 5));
      mutationStatus.value =
          'Operation ${pending.operationId} cleared after explicit manual reconciliation. No write was retried.';
    } catch (_) {
      mutationStatus.value =
          'Operation record could not be cleared. No write was retried.';
    } finally {
      await refreshMutationJournal();
      mutationBusy.value = false;
    }
  }

  // Only handles peers add/remove
  final Map<String, VoidCallback> _peerIdUpdateListeners = {};

  final sortTags = shouldSortTags().obs;
  final filterByIntersection = filterAbTagByIntersection().obs;

  var _syncAllFromRecent = true;
  var _syncFromRecentLock = false;
  var _timerCounter = 0;
  var _cacheLoadOnceFlag = false;
  var _pulledOnce = false;
  var listInitialized = false;
  var _maxPeerOneAb = 0;

  late final Peers peersModel;

  WeakReference<FFI> parent;

  Timer? _pollerTimer;
  bool _disposed = false;
  bool _isStopped = false;
  bool _inFlight = false;
  int _generation = 0;

  bool get isPolling =>
      _pollerTimer != null &&
      _pollerTimer!.isActive &&
      !_isStopped &&
      !_disposed;
  bool get isDisposed => _disposed;

  void startPoller() {
    if (_disposed) return;
    if (!_isStopped && _pollerTimer != null && _pollerTimer!.isActive) return;
    _isStopped = false;
    if (desktopType != null && desktopType != DesktopType.main) return;
    _scheduleNextTick(Duration.zero);
  }

  void _scheduleNextTick([Duration delay = const Duration(milliseconds: 500)]) {
    if (_disposed || _isStopped) return;
    _pollerTimer?.cancel();
    _pollerTimer = Timer(delay, () async {
      if (_disposed || _isStopped) return;
      if (_inFlight) {
        _scheduleNextTick(const Duration(milliseconds: 50));
        return;
      }
      _inFlight = true;
      final currentGen = _generation;
      try {
        if (_timerCounter++ % 6 == 0) {
          if (gFFI.userModel.isLogin &&
              listInitialized &&
              current.initialized &&
              current.canWrite()) {
            if (!_disposed && !_isStopped && _generation == currentGen) {
              await _syncFromRecent();
            }
          }
        }
      } catch (e) {
        debugPrint("AbModel poller error: $e");
      } finally {
        _inFlight = false;
        if (!_disposed && !_isStopped) {
          _scheduleNextTick();
        }
      }
    });
  }

  Future<void> stopPoller() async {
    _isStopped = true;
    _generation++;
    _pollerTimer?.cancel();
    _pollerTimer = null;
    int waitMs = 0;
    while (_inFlight && waitMs < 1000) {
      await Future.delayed(const Duration(milliseconds: 25));
      waitMs += 25;
    }
  }

  void dispose() {
    _disposed = true;
    _isStopped = true;
    _generation++;
    _pollerTimer?.cancel();
    _pollerTimer = null;
  }

  AbModel(this.parent) {
    addressbooks.clear();
    peersModel = Peers(
      name: PeersModelName.addressBook,
      getInitPeers: () => currentAbPeers,
      loadEvent: LoadEvent.addressBook,
    );
    if (desktopType == DesktopType.main) {
      startPoller();
    }
  }

  reset() async {
    print("reset ab model");
    _listEpoch++;
    _mutationViewEpoch++;
    _mutationCancellation?.cancel();
    _personalAbGuid = null;
    _personalAbGeneration = null;
    _personalAbApi = null;
    _personalAbToken = null;
    mutationStatus.value = '';
    for (final book in addressbooks.values.whereType<Ab>()) {
      book.invalidateSnapshot();
    }
    addressbooks.clear();
    _currentName.value = '';
    _listPullError.value = '';
    _pulledOnce = false;
    await bind.mainClearAb();
    listInitialized = false;
  }

  void clearPullErrors() {
    _listPullError.value = '';
    current.pullError.value = '';
  }

  // #region ab
  /// Pulls the address book data from the server.
  ///
  /// If `force` is `ForcePullAb.listAndCurrent`, the function will pull the list of address books, current address book, and try initialize personal address book.
  /// If `force` is `ForcePullAb.current`, the function will only pull the current address book.
  /// If `quiet` is true, the function will not display any notifications or errors.
  var _pulling = false;
  Future<void> pullAb({
    required ForcePullAb? force,
    required bool quiet,
  }) async {
    if (mutationBusy.value) return;
    if (!gFFI.userModel.isLogin) return;
    if (gFFI.userModel.networkError.isNotEmpty) return;
    if (_pulling) return;
    if (force == null && _pulledOnce) {
      return;
    }
    _pulling = true;
    if (!quiet) {
      _listPullError.value = '';
      current.pullError.value = '';
    }
    try {
      await _pullAb(force: force, quiet: quiet);
      _refreshTab();
    } catch (_) {}
    _pulling = false;
    _pulledOnce = true;
  }

  Future<void> _pullAb({
    required ForcePullAb? force,
    required bool quiet,
  }) async {
    if (!mutationBusy.value) await refreshMutationJournal();
    if (force == null && listInitialized && current.initialized) return;
    debugPrint("pullAb, force: $force, quiet: $quiet");
    if (!listInitialized || force == ForcePullAb.listAndCurrent) {
      try {
        final epoch = _listEpoch;
        final token = bind.mainGetLocalOption(key: 'access_token');
        final api = await bind.mainGetApiServer();
        // Refresh personal address book metadata on each list pull.
        _personalAbGuid = null;
        _personalAbName = _personalAddressBookName;
        _personalAbGeneration = null;
        _personalAbApi = null;
        _personalAbToken = null;
        // `true`: continue init. `false`: stop, error already recorded.
        if (!await _getPersonalAbGuid(quiet: quiet)) {
          return;
        }
        if (_maxPeerOneAb == 0) {
          await _getAbSettings(quiet: quiet);
        }
        debugPrint("pull ab list");
        List<AbProfile> abProfiles = List.empty(growable: true);
        abProfiles.add(
          AbProfile(
            _personalAbGuid!,
            _personalAbName,
            gFFI.userModel.userName.value,
            null,
            ShareRule.read.value,
            null,
            authorizationGeneration: _personalAbGeneration,
          ),
        );
        // get all address book name
        if (!await _getSharedAbProfiles(abProfiles, quiet: quiet)) {
          return;
        }
        final currentApi = await bind.mainGetApiServer();
        if (epoch != _listEpoch ||
            api != currentApi ||
            token != bind.mainGetLocalOption(key: 'access_token')) {
          throw const AddressBookSnapshotException('context_changed');
        }
        addressbooks.removeWhere((key, value) {
          final removed =
              abProfiles.firstWhereOrNull((e) => e.name == key) == null;
          if (removed && value is Ab) value.invalidateSnapshot();
          return removed;
        });
        for (int i = 0; i < abProfiles.length; i++) {
          AbProfile p = abProfiles[i];
          if (addressbooks[p.name]?.sharedProfile()?.guid == p.guid) {
            addressbooks[p.name]?.setSharedProfile(p);
          } else {
            final previous = addressbooks[p.name];
            if (previous is Ab) previous.invalidateSnapshot();
            addressbooks[p.name] = Ab(p, p.guid == _personalAbGuid);
          }
        }
        // set current address book name
        if (!listInitialized) {
          listInitialized = true;
          trySetCurrentToLast();
        }
        if (!addressbooks.containsKey(_currentName.value)) {
          setCurrentName(_personalAbName);
        }
        // pull current address book
        await current.pullAb(quiet: quiet);
        // try initialize personal address book
        if (!current.isPersonal()) {
          final personalAb = addressbooks[_personalAbName];
          if (personalAb != null && !personalAb.initialized) {
            await personalAb.pullAb(quiet: quiet);
          }
        }
      } catch (e) {
        debugPrint("pull ab list error: $e");
        _setListPullError(e, quiet: quiet);
      }
    } else if (listInitialized &&
        (!current.initialized || force == ForcePullAb.current)) {
      try {
        await current.pullAb(quiet: quiet);
      } catch (e) {
        debugPrint("pull current Ab error: $e");
      }
    }
    _callbackPeerUpdate();
    if (listInitialized && current.initialized) {
      _saveCache();
    }
  }

  void _setListPullError(Object err, {required bool quiet, int? statusCode}) {
    if (!quiet) {
      _listPullError.value =
          '${translate('pull_ab_failed_tip')}: ${translate(err.toString())}';
    }
    if (statusCode == 401) {
      gFFI.userModel.reset(resetOther: true);
    }
  }

  Future<bool> _getAbSettings({required bool quiet}) async {
    int? statusCode;
    try {
      final api = "${await bind.mainGetApiServer()}/api/ab/settings";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      _setEmptyBody(headers);
      final resp = await http.post(Uri.parse(api), headers: headers);
      statusCode = resp.statusCode;
      if (statusCode == 404) {
        debugPrint("HTTP 404, api server doesn't support shared address book");
        return false;
      }
      Map<String, dynamic> json = _jsonDecodeRespMap(
        decode_http_response(resp),
        resp.statusCode,
      );
      if (json.containsKey('error')) {
        throw json['error'];
      }
      if (statusCode != 200) {
        throw 'HTTP $statusCode';
      }
      _maxPeerOneAb = json['max_peer_one_ab'] ?? 0;
      return true;
    } catch (err) {
      debugPrint('get ab settings err: ${err.toString()}');
      _setListPullError(err, quiet: quiet, statusCode: statusCode);
    }
    return false;
  }

  /// Loads `/api/ab/personal`.
  /// Returns `true` to continue init, `false` to stop after a real error.
  Future<bool> _getPersonalAbGuid({required bool quiet}) async {
    int? statusCode;
    final token = bind.mainGetLocalOption(key: 'access_token');
    final epoch = _listEpoch;
    try {
      final apiBase = await _currentMutationApi();
      final api = '$apiBase/api/ab/personal';
      var headers = <String, String>{'Authorization': 'Bearer $token'};
      headers['Content-Type'] = "application/json";
      _setEmptyBody(headers);
      final resp = await http.post(Uri.parse(api), headers: headers);
      statusCode = resp.statusCode;
      if (statusCode == 404) {
        throw 'HTTP 404';
      }
      Map<String, dynamic> json = _jsonDecodeRespMap(
        decode_http_response(resp),
        resp.statusCode,
      );
      if (json.containsKey('error')) {
        throw json['error'];
      }
      if (statusCode != 200) {
        throw 'HTTP $statusCode';
      }
      final guid = json['guid'];
      if (guid is! String || guid.trim().isEmpty) {
        throw 'invalid personal address book guid';
      }
      final snapshot = AddressBookSnapshotIdentity.parse(json);
      if (epoch != _listEpoch ||
          token != bind.mainGetLocalOption(key: 'access_token') ||
          apiBase != await _currentMutationApi()) {
        throw const AddressBookSnapshotException('context_changed');
      }
      _personalAbGuid = guid.trim();
      _personalAbGeneration = snapshot.generation;
      _personalAbApi = apiBase;
      _personalAbToken = token;
      final name = json['name'];
      if (name is String && name.trim().isNotEmpty) {
        _personalAbName = name.trim();
      } else {
        _personalAbName = _personalAddressBookName;
      }
      return true;
    } catch (err) {
      debugPrint('get personal ab err: ${err.toString()}');
      if (epoch == _listEpoch &&
          token == bind.mainGetLocalOption(key: 'access_token')) {
        _setListPullError(err, quiet: quiet, statusCode: statusCode);
      }
    }
    // Real error: stop the current pull.
    return false;
  }

  Future<bool> _getSharedAbProfiles(
    List<AbProfile> profiles, {
    required bool quiet,
  }) async {
    final api = "${await bind.mainGetApiServer()}/api/ab/shared/profiles";
    int? statusCode;
    try {
      var uri0 = Uri.parse(api);
      final pageSize = 100;
      var total = 0;
      int current = 0;
      do {
        current += 1;
        var uri = Uri(
          scheme: uri0.scheme,
          host: uri0.host,
          path: uri0.path,
          port: uri0.port,
          queryParameters: {
            'current': current.toString(),
            'pageSize': pageSize.toString(),
          },
        );
        var headers = getHttpHeaders();
        headers['Content-Type'] = "application/json";
        _setEmptyBody(headers);
        final resp = await http.post(uri, headers: headers);
        statusCode = resp.statusCode;
        if (statusCode == 404) {
          throw 'HTTP 404';
        }
        Map<String, dynamic> json = _jsonDecodeRespMap(
          decode_http_response(resp),
          resp.statusCode,
        );
        if (json.containsKey('error')) {
          throw json['error'];
        }
        if (statusCode != 200) {
          throw 'HTTP $statusCode';
        }
        if (json['address_book_snapshot_version'] != 1) {
          throw const AddressBookSnapshotException('unsupported_version');
        }
        if (json.containsKey('total')) {
          if (total == 0) total = json['total'];
          if (json.containsKey('data')) {
            final data = json['data'];
            if (data is List) {
              for (final profile in data) {
                AddressBookSnapshotIdentity.parse(profile);
                final u = AbProfile.fromJson(profile);
                int index = profiles.indexWhere((e) => e.name == u.name);
                if (index < 0) {
                  profiles.add(u);
                } else {
                  profiles[index] = u;
                }
              }
            }
          }
        }
      } while (current * pageSize < total);
      return true;
    } catch (err) {
      debugPrint('_getSharedAbProfiles err: ${err.toString()}');
      _setListPullError(err, quiet: quiet, statusCode: statusCode);
    }
    return false;
  }

  // #endregion

  // #region rule
  List<String> addressBooksCanWrite() {
    List<String> list = [];
    addressbooks.forEach((key, value) async {
      if (value.canWrite()) {
        list.add(key);
      }
    });
    return list;
  }

  // #endregion

  // #region peer
  Future<String?> addIdToCurrent(
    String id,
    String alias,
    String password,
    List<dynamic> tags,
    String note,
  ) async {
    if (currentAbPeers.where((element) => element.id == id).isNotEmpty) {
      return "$id already exists in address book $_currentName";
    }
    Map<String, dynamic> peer = {'id': id, 'alias': alias, 'tags': tags};
    // avoid set existing password to empty
    if (password.isNotEmpty) {
      peer['password'] = password;
    }
    if (note.isNotEmpty) {
      peer['note'] = note;
    }
    final ret = await addPeersTo([peer], _currentName.value);
    _syncAllFromRecent = true;
    return ret;
  }

  // Preserve absent fields and caller-owned selections; the service freezes the
  // whole batch before its first await.
  Future<String?> addPeersTo(List<Map<String, dynamic>> ps, String name) async {
    final book = addressbooks[name];
    if (book == null) return 'Address book is unavailable.';
    final selection = ps.map((peer) => Map<String, dynamic>.of(peer)).toList();
    for (final peer in selection) {
      book.removeNonExistentTags(peer);
    }
    final error = await book.addPeers(selection);
    if (error == null &&
        addressbooks.values.any((value) => identical(value, book))) {
      _syncAllFromRecent = true;
    }
    return error;
  }

  Future<bool> changeTagForPeers(List<String> ids, List<dynamic> tags) =>
      current.changeTagForPeers(ids, tags);

  Future<bool> changeAlias({required String id, required String alias}) =>
      current.changeAlias(id: id, alias: alias);

  Future<bool> changeNote({required String id, required String note}) =>
      current.changeNote(id: id, note: note);

  Future<bool> changePersonalHashPassword(String id, String hash) async {
    final book = addressbooks[_personalAbName];
    return book == null ? false : book.changePersonalHashPassword(id, hash);
  }

  Future<bool> changeSharedPassword(
    String abName,
    String id,
    String password,
  ) async {
    final book = addressbooks[abName];
    return book == null ? false : book.changeSharedPassword(id, password);
  }

  Future<bool> deletePeers(List<String> ids) => current.deletePeers(ids);

  Future<bool> addTags(List<String> tags) =>
      current.addTags(tags.where((tag) => tag != kUntagged).toList(), {});

  Future<bool> renameTag(String oldTag, String newTag) async {
    final book = current;
    final epoch = _mutationViewEpoch;
    final result = await book.renameTag(oldTag, newTag);
    if (result && epoch == _mutationViewEpoch && identical(book, current)) {
      book.selectedTags.value = book.selectedTags
          .map((tag) => tag == oldTag ? newTag : tag)
          .toList();
    }
    return result;
  }

  Future<bool> setTagColor(String tag, Color color) =>
      current.setTagColor(tag, color);

  Future<bool> deleteTag(String tag) async {
    final book = current;
    final epoch = _mutationViewEpoch;
    final result = await book.deleteTag(tag);
    if (result && epoch == _mutationViewEpoch && identical(book, current)) {
      book.selectedTags.value = book.selectedTags
          .where((t) => t != tag)
          .toList();
    }
    return result;
  }

  // #region sync from recent
  Future<void> _syncFromRecent({bool push = true}) async {
    if (!_syncFromRecentLock) {
      _syncFromRecentLock = true;
      try {
        await _syncFromRecentWithoutLock(push: push);
      } finally {
        _syncFromRecentLock = false;
      }
    }
  }

  Future<void> _syncFromRecentWithoutLock({bool push = true}) async {
    Future<List<Peer>> getRecentPeers() async {
      try {
        List<String> filteredPeerIDs;
        if (_syncAllFromRecent) {
          _syncAllFromRecent = false;
          filteredPeerIDs = [];
        } else {
          final new_stored_str = await bind.mainGetNewStoredPeers();
          if (new_stored_str.isEmpty) return [];
          filteredPeerIDs = (jsonDecode(new_stored_str) as List<dynamic>)
              .map((e) => e.toString())
              .toList();
          if (filteredPeerIDs.isEmpty) return [];
        }
        final loadStr = await bind.mainLoadRecentPeersForAb(
          filter: jsonEncode(filteredPeerIDs),
        );
        if (loadStr.isEmpty) {
          return [];
        }
        List<dynamic> mapPeers = jsonDecode(loadStr);
        List<Peer> recents = List.empty(growable: true);
        for (var m in mapPeers) {
          if (m is Map<String, dynamic>) {
            recents.add(Peer.fromJson(m));
          }
        }
        return recents;
      } catch (e) {
        debugPrint('getRecentPeers: $e');
      }
      return [];
    }

    try {
      if (!shouldSyncAb()) return;
      final book = current;
      final epoch = _mutationViewEpoch;
      final token = bind.mainGetLocalOption(key: 'access_token');
      final recents = await getRecentPeers();
      if (epoch != _mutationViewEpoch ||
          !identical(book, current) ||
          token != bind.mainGetLocalOption(key: 'access_token')) {
        return;
      }
      if (recents.isEmpty) return;
      debugPrint("sync from recent, len: ${recents.length}");
      if (book.canWrite() && book.initialized) {
        await book.syncFromRecent(recents);
      }
    } catch (e) {
      debugPrint('_syncFromRecentWithoutLock: $e');
    }
  }

  void setShouldAsync(bool v) async {
    await bind.mainSetLocalOption(
      key: syncAbOption,
      value: v ? 'Y' : defaultOptionNo,
    );
    _syncAllFromRecent = true;
    _timerCounter = 0;
  }

  // #endregion

  // #region cache
  _saveCache() {
    try {
      var ab_entries = _serializeCache();
      Map<String, dynamic> m = <String, dynamic>{
        "access_token": bind.mainGetLocalOption(key: 'access_token'),
        "ab_entries": ab_entries,
      };
      bind.mainSaveAb(json: jsonEncode(m));
    } catch (e) {
      debugPrint('ab save:$e');
    }
  }

  List<dynamic> _serializeCache() {
    var res = [];
    addressbooks.forEach((key, value) {
      if (!value.isPersonal() && key != current.name()) return;
      res.add({
        "guid": value.sharedProfile()?.guid ?? '',
        "name": key,
        "tags": value.tags,
        "peers": value.peers
            .map((e) => e.toCustomJson(includingHash: value.isPersonal()))
            .toList(),
        "tag_colors": jsonEncode(value.tagColors),
      });
    });
    return res;
  }

  trySetCurrentToLast() {
    final name = bind.getLocalFlutterOption(k: kOptionCurrentAbName);
    if (addressbooks.containsKey(name)) {
      _currentName.value = name;
    }
  }

  Future<void> loadCache() async {
    try {
      if (_cacheLoadOnceFlag || currentAbLoading.value) return;
      _cacheLoadOnceFlag = true;
      final access_token = bind.mainGetLocalOption(key: 'access_token');
      if (access_token.isEmpty) return;
      final cache = await bind.mainLoadAb();
      if (currentAbLoading.value) return;
      final data = jsonDecode(cache);
      if (data == null || data['access_token'] != access_token) return;
      _deserializeCache(data);
      trySetCurrentToLast();
    } catch (e) {
      debugPrint("load ab cache: $e");
    }
  }

  _deserializeCache(dynamic data) {
    if (data == null) return;
    reset();
    final abEntries = data['ab_entries'];
    if (abEntries is List) {
      for (var i = 0; i < abEntries.length; i++) {
        var abEntry = abEntries[i];
        if (abEntry is Map<String, dynamic>) {
          var guid = abEntry['guid'];
          var name = abEntry['name'];
          if (name == null) {
            continue;
          }
          final nameStr = name.toString();
          if (guid == null) {
            continue;
          }
          final guidStr = guid.toString();
          final isPersonal = _isPersonalGuid(guidStr);
          if (isPersonal) {
            _personalAbName = nameStr;
          }
          final BaseAb ab = Ab(
            AbProfile(guidStr, nameStr, '', '', ShareRule.read.value, null),
            isPersonal,
          );
          addressbooks[nameStr] = ab;
          if (abEntry['tags'] is List) {
            ab.tags.value = (abEntry['tags'] as List)
                .map((e) => e.toString())
                .toList();
          }
          if (abEntry['peers'] is List) {
            for (var peer in abEntry['peers']) {
              ab.peers.add(Peer.fromJson(peer));
            }
          }
          if (abEntry['tag_colors'] is String) {
            Map<String, dynamic> map = jsonDecode(abEntry['tag_colors']);
            ab.tagColors.value = Map<String, int>.from(map);
          }
        }
      }
      if (abEntries.isNotEmpty) {
        _callbackPeerUpdate();
      }
    }
  }

  // #endregion

  // #region tools
  Peer? find(String id) {
    return currentAbPeers.firstWhereOrNull((e) => e.id == id);
  }

  bool idContainByCurrent(String id) {
    return currentAbPeers.where((element) => element.id == id).isNotEmpty;
  }

  void unsetSelectedTags() {
    selectedTags.clear();
  }

  List<dynamic> getPeerTags(String id) {
    final it = currentAbPeers.where((p0) => p0.id == id);
    if (it.isEmpty) {
      return [];
    } else {
      return it.first.tags;
    }
  }

  String getPeerNote(String id) {
    final it = currentAbPeers.where((p0) => p0.id == id);
    if (it.isEmpty) {
      return '';
    } else {
      return it.first.note;
    }
  }

  Color getCurrentAbTagColor(String tag) {
    if (tag == kUntagged) {
      return MyTheme.accent;
    }
    int? colorValue = current.tagColors[tag];
    if (colorValue != null) {
      return Color(colorValue);
    }
    return str2color2(tag, existing: current.tagColors.values.toList());
  }

  List<String> addressBookNames() {
    return addressbooks.keys.toList();
  }

  String personalAddressBookName() {
    return _personalAbName;
  }

  Future<void> setCurrentName(String name) async {
    final oldName = _currentName.value;
    if (addressbooks.containsKey(name)) {
      _currentName.value = name;
    } else {
      if (addressbooks.containsKey(_personalAbName)) {
        _currentName.value = _personalAbName;
      } else {
        _currentName.value = '';
      }
    }
    if (oldName != _currentName.value) {
      _mutationViewEpoch++;
      _mutationCancellation?.cancel();
      final previous = addressbooks[oldName];
      if (previous is Ab && previous._readCancellation != null) {
        previous.invalidateSnapshot();
      }
    }
    if (!current.initialized) {
      await current.pullAb(quiet: false);
    }
    _refreshTab();
    if (oldName != _currentName.value) {
      _syncAllFromRecent = true;
      _saveCache();
    }
  }

  bool isCurrentAbFull(bool warn) {
    final res = current.isFull();
    if (res && warn) {
      BotToast.showText(
        contentColor: Colors.red,
        text: translate('exceed_max_devices'),
      );
    }
    return res;
  }

  void _refreshTab() {
    platformFFI.tryHandle({'name': LoadEvent.addressBook});
  }

  List<String> idExistIn(String id) {
    List<String> v = [];
    addressbooks.forEach((key, value) {
      if (value.peers.any((e) => e.id == id)) {
        v.add(key);
      }
    });
    return v;
  }

  List<Peer> allPeers() {
    List<Peer> v = [];
    addressbooks.forEach((key, value) {
      v.addAll(value.peers.map((e) => Peer.copy(e)).toList());
    });
    return v;
  }

  String translatedName(String name) {
    if (name == _personalAbName) {
      return translate(name);
    } else {
      return name;
    }
  }

  void _callbackPeerUpdate() {
    for (var listener in _peerIdUpdateListeners.values) {
      listener();
    }
  }

  void addPeerUpdateListener(String key, VoidCallback listener) {
    _peerIdUpdateListeners[key] = listener;
  }

  void removePeerUpdateListener(String key) {
    _peerIdUpdateListeners.remove(key);
  }

  Future<String?> getDefaultSharedPassword(String rid) async {
    if (current.isPersonal()) {
      return null;
    }
    final profile = current.sharedProfile();
    if (profile == null || rid.trim().isEmpty) {
      return null;
    }
    int? statusCode;
    try {
      final api = "${await bind.mainGetApiServer()}/api/ab/shared/credential";
      final headers = getHttpHeaders();
      headers['Content-Type'] = 'application/json';
      final response = await http.post(
        Uri.parse(api),
        headers: headers,
        body: jsonEncode({'guid': profile.guid, 'id': rid}),
      );
      statusCode = response.statusCode;
      return parseSharedCredentialResponse(
        decode_http_response(response),
        response.statusCode,
      );
    } catch (e) {
      debugPrint("getDefaultSharedPassword($statusCode): $e");
      return null;
    }
  }

  // #endregion
}

abstract class BaseAb {
  final peers = List<Peer>.empty(growable: true).obs;
  final RxList<String> tags = <String>[].obs;
  final RxMap<String, int> tagColors = Map<String, int>.fromEntries([]).obs;
  final selectedTags = List<String>.empty(growable: true).obs;

  final pullError = "".obs;
  final pushError = "".obs;
  final abLoading = false
      .obs; // Indicates whether the UI should show a loading state for the address book.
  var abPulling =
      false; // Tracks whether a pull operation is currently in progress to prevent concurrent pulls. Unlike abLoading, this is not tied to UI updates.
  bool initialized = false;

  String name();

  bool isPersonal() {
    return false;
  }

  Future<void> pullAb({quiet = false}) async {
    if (abPulling) return;
    abPulling = true;
    if (!quiet) {
      abLoading.value = true;
      pullError.value = "";
    }
    initialized = false;
    debugPrint("pull ab \"${name()}\"");
    try {
      initialized = await pullAbImpl(quiet: quiet);
    } catch (e) {
      debugPrint("Error occurred while pulling address book: $e");
    } finally {
      abLoading.value = false;
      abPulling = false;
    }
  }

  Future<bool> pullAbImpl({quiet = false});

  Future<String?> addPeers(List<Map<String, dynamic>> ps);
  removeHash(Map<String, dynamic> p) {
    p.remove('hash');
  }

  removePassword(Map<String, dynamic> p) {
    p.remove('password');
  }

  removeNonExistentTags(Map<String, dynamic> p) {
    try {
      final oldTags = p.remove('tags');
      if (oldTags is List) {
        final newTags = oldTags.where((e) => tagContainBy(e)).toList();
        p['tags'] = newTags;
      }
    } catch (e) {
      print("removeNonExistentTags: $e");
    }
  }

  Future<bool> changeTagForPeers(List<String> ids, List<dynamic> tags);

  Future<bool> changeAlias({required String id, required String alias});

  Future<bool> changeNote({required String id, required String note});

  Future<bool> changePersonalHashPassword(String id, String hash);

  Future<bool> changeSharedPassword(String id, String password);

  Future<bool> deletePeers(List<String> ids);

  Future<bool> addTags(List<String> tagList, Map<String, int> tagColorMap);

  bool tagContainBy(String tag) {
    return tags.where((element) => element == tag).isNotEmpty;
  }

  Future<bool> renameTag(String oldTag, String newTag);

  Future<bool> setTagColor(String tag, Color color);

  Future<bool> deleteTag(String tag);

  bool isFull();

  void setSharedProfile(AbProfile profile);

  AbProfile? sharedProfile();

  bool canWrite();

  bool fullControl();

  Future<void> syncFromRecent(List<Peer> recents);
}

class Ab extends BaseAb {
  AbProfile profile;
  late final bool personal;
  bool get emtpy => peers.isEmpty && tags.isEmpty;
  int? _snapshotGeneration;
  int _highestSnapshotGeneration = 0;
  String? _snapshotToken;
  String? _snapshotApi;
  http.HttpCancellation? _readCancellation;
  int _snapshotEpoch = 0;

  void invalidateSnapshot() {
    _readCancellation?.cancel();
    _readCancellation = null;
    initialized = false;
    _snapshotEpoch++;
    _snapshotGeneration = null;
    _snapshotToken = null;
    _snapshotApi = null;
  }

  Ab(this.profile, this.personal);

  @override
  String name() {
    if (profile.name.isNotEmpty) {
      return profile.name;
    }
    return _personalAddressBookName;
  }

  @override
  bool isPersonal() {
    return personal;
  }

  @override
  AbProfile? sharedProfile() {
    return profile;
  }

  @override
  void setSharedProfile(AbProfile profile) {
    if (this.profile.guid != profile.guid ||
        _snapshotGeneration != profile.authorizationGeneration) {
      invalidateSnapshot();
    }
    this.profile = profile;
  }

  @override
  bool isFull() {
    return gFFI.abModel._maxPeerOneAb > 0 &&
        peers.length >= gFFI.abModel._maxPeerOneAb;
  }

  @override
  bool canWrite() {
    if (gFFI.abModel.mutationsBlocked ||
        gFFI.abModel._pulling ||
        _snapshotApi == null ||
        gFFI.abModel._personalAbApi != _snapshotApi ||
        gFFI.abModel._personalAbToken != _snapshotToken ||
        _snapshotGeneration == null ||
        _snapshotGeneration != profile.authorizationGeneration ||
        _snapshotToken != bind.mainGetLocalOption(key: 'access_token')) {
      return false;
    }
    if (personal) {
      return true;
    } else {
      return profile.rule == ShareRule.readWrite.value ||
          profile.rule == ShareRule.fullControl.value;
    }
  }

  @override
  bool fullControl() {
    if (personal) {
      return true;
    } else {
      return profile.rule == ShareRule.fullControl.value;
    }
  }

  @override
  Future<bool> pullAbImpl({quiet = false}) async {
    if (gFFI.abModel.mutationBusy.value) return false;
    final cancellation = http.HttpCancellation();
    int? statusCode;
    invalidateSnapshot();
    _readCancellation = cancellation;
    final epoch = _snapshotEpoch;
    final guid = profile.guid;
    final token = bind.mainGetLocalOption(key: 'access_token');
    try {
      final api = (await bind.mainGetApiServer()).replaceFirst(
        RegExp(r'/+$'),
        '',
      );
      final headers = <String, String>{
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };
      _setEmptyBody(headers);
      final snapshot = await AddressBookContentSnapshot.read(
        apiBase: Uri.parse(api),
        guid: guid,
        request: (uri) async {
          final resp = await http.post(
            uri,
            headers: headers,
            cancellation: cancellation,
          );
          statusCode = resp.statusCode;
          return decodeAddressBookSnapshotResponse(
            resp.statusCode,
            resp.headers,
            resp.bodyBytes,
          );
        },
      );
      final currentApi = (await bind.mainGetApiServer()).replaceFirst(
        RegExp(r'/+$'),
        '',
      );
      if (gFFI.abModel.mutationBusy.value ||
          epoch != _snapshotEpoch ||
          guid != profile.guid ||
          token != bind.mainGetLocalOption(key: 'access_token') ||
          api != currentApi) {
        throw const AddressBookSnapshotException('context_changed');
      }
      if (snapshot.identity.generation <
              (profile.authorizationGeneration ?? 0) ||
          snapshot.identity.generation < _highestSnapshotGeneration) {
        throw const AddressBookSnapshotException('stale_snapshot');
      }
      // Parse everything before publishing any part of the new cache.
      final tmpPeers = snapshot.peers.map(Peer.fromJson).toList();
      final tmpTags = snapshot.tags.map(AbTag.fromJson).toList();
      peers.value = tmpPeers;
      tags.value = tmpTags.map((tag) => tag.name).toList();
      tagColors.value = {for (final tag in tmpTags) tag.name: tag.color};
      profile.authorizationGeneration = snapshot.identity.generation;
      _snapshotToken = token;
      _snapshotApi = api;
      _snapshotGeneration = snapshot.identity.generation;
      _highestSnapshotGeneration = snapshot.identity.generation;
      return true;
    } catch (err) {
      if (!quiet) {
        pullError.value =
            '${translate('pull_ab_failed_tip')}: ${err is AddressBookSnapshotException ? err : 'invalid_snapshot'}';
      }
    } finally {
      cancellation.cancel();
      if (identical(_readCancellation, cancellation)) _readCancellation = null;
      if (statusCode == 401 &&
          epoch == _snapshotEpoch &&
          token == bind.mainGetLocalOption(key: 'access_token')) {
        gFFI.userModel.reset(resetOther: true);
      }
    }
    return false;
  }

  // #region Content writes
  Future<bool> _write(List<AddressBookMutationInput> inputs) async {
    final outcome = await gFFI.abModel._mutate(this, inputs);
    return outcome?.fullyConfirmed == true;
  }

  @override
  Future<String?> addPeers(List<Map<String, dynamic>> ps) async {
    final existing = peers.map((peer) => peer.id).toSet();
    final selection = <Map<String, dynamic>>[];
    for (final original in ps) {
      if (!existing.add(original['id']?.toString() ?? '')) continue;
      final peer = Map<String, dynamic>.of(original);
      if (personal) {
        removePassword(peer);
      } else {
        removeHash(peer);
      }
      selection.add(peer);
    }
    if (selection.isEmpty) return null;
    final limit = gFFI.abModel._maxPeerOneAb;
    if (limit > 0 && peers.length + selection.length > limit) {
      return translate('exceed_max_devices');
    }
    final success = await _write([
      for (final peer in selection)
        AddressBookMutationInput(AddressBookMutationKind.peerAdd, peer),
    ]);
    return success
        ? null
        : (gFFI.abModel.mutationStatus.value.isNotEmpty
              ? gFFI.abModel.mutationStatus.value
              : 'Address book writes are disabled. Refresh or resolve the pending operation.');
  }

  @override
  Future<bool> changeTagForPeers(List<String> ids, List<dynamic> tags) async {
    if (ids.isEmpty) return true;
    return _write([
      for (final id in ids.toSet())
        AddressBookMutationInput(AddressBookMutationKind.peerUpdate, {
          'id': id,
          'tags': tags,
        }),
    ]);
  }

  @override
  Future<bool> changeAlias({required String id, required String alias}) =>
      _write([
        AddressBookMutationInput(AddressBookMutationKind.peerUpdate, {
          'id': id,
          'alias': alias,
        }),
      ]);

  @override
  Future<bool> changeNote({required String id, required String note}) =>
      _write([
        AddressBookMutationInput(AddressBookMutationKind.peerUpdate, {
          'id': id,
          'note': note,
        }),
      ]);

  @override
  Future<bool> changePersonalHashPassword(String id, String hash) async {
    if (!personal) return false;
    if (!peers.any((peer) => peer.id == id)) return true;
    return _write([
      AddressBookMutationInput(AddressBookMutationKind.peerUpdate, {
        'id': id,
        'hash': hash,
      }),
    ]);
  }

  @override
  Future<bool> changeSharedPassword(String id, String password) async {
    if (personal) return false;
    return _write([
      AddressBookMutationInput(AddressBookMutationKind.peerUpdate, {
        'id': id,
        'password': password,
      }),
    ]);
  }

  @override
  Future<void> syncFromRecent(List<Peer> recents) async {
    final byId = {for (final recent in recents) recent.id: recent};
    final inputs = <AddressBookMutationInput>[];
    for (final peer in peers) {
      final recent = byId[peer.id];
      if (recent == null) continue;
      final patch = peer.addressBookRecentPatch(recent, personal: personal);
      if (patch != null) {
        inputs.add(
          AddressBookMutationInput(AddressBookMutationKind.peerUpdate, patch),
        );
      }
    }
    if (inputs.isNotEmpty) await _write(inputs);
    // A failed/conflicting intent is not silently re-created on a new version.
    // The recent-ID source is consumed once; only new events/user action retry.
  }

  @override
  Future<bool> deletePeers(List<String> ids) async {
    if (ids.isEmpty) return true;
    return _write([
      AddressBookMutationInput(
        AddressBookMutationKind.peerDelete,
        ids.toSet().toList(),
      ),
    ]);
  }

  @override
  Future<bool> addTags(
    List<String> tagList,
    Map<String, int> tagColorMap,
  ) async {
    final selection = tagList
        .toSet()
        .where((tag) => !tags.contains(tag))
        .toList();
    if (selection.isEmpty) return true;
    return _write([
      for (final tag in selection)
        AddressBookMutationInput(AddressBookMutationKind.tagAdd, {
          'name': tag,
          'color':
              tagColorMap[tag] ??
              str2color2(tag, existing: tagColors.values.toList()).toARGB32(),
        }),
    ]);
  }

  @override
  Future<bool> renameTag(String oldTag, String newTag) async {
    if (tags.contains(newTag)) return false;
    return _write([
      AddressBookMutationInput(AddressBookMutationKind.tagRename, {
        'old': oldTag,
        'new': newTag,
      }),
    ]);
  }

  @override
  Future<bool> setTagColor(String tag, Color color) => _write([
    AddressBookMutationInput(AddressBookMutationKind.tagUpdate, {
      'name': tag,
      'color': color.toARGB32(),
    }),
  ]);

  @override
  Future<bool> deleteTag(String tag) => _write([
    AddressBookMutationInput(AddressBookMutationKind.tagDelete, [tag]),
  ]);
  // #endregion
}

// DummyAb is for current ab is null
class DummyAb extends BaseAb {
  @override
  bool isFull() {
    return false;
  }

  @override
  Future<String?> addPeers(List<Map<String, dynamic>> ps) async {
    return "dummpy";
  }

  @override
  Future<bool> addTags(
    List<String> tagList,
    Map<String, int> tagColorMap,
  ) async {
    return false;
  }

  @override
  bool canWrite() {
    return false;
  }

  @override
  bool fullControl() {
    return false;
  }

  @override
  Future<bool> changeAlias({required String id, required String alias}) async {
    return false;
  }

  @override
  Future<bool> changeNote({required String id, required String note}) async {
    return false;
  }

  @override
  Future<bool> changePersonalHashPassword(String id, String hash) async {
    return false;
  }

  @override
  Future<bool> changeSharedPassword(String id, String password) async {
    return false;
  }

  @override
  Future<bool> changeTagForPeers(List<String> ids, List tags) async {
    return false;
  }

  @override
  Future<bool> deletePeers(List<String> ids) async {
    return false;
  }

  @override
  Future<bool> deleteTag(String tag) async {
    return false;
  }

  @override
  String name() {
    return "dummpy";
  }

  @override
  Future<bool> pullAbImpl({quiet = false}) async {
    return false;
  }

  @override
  Future<bool> renameTag(String oldTag, String newTag) async {
    return false;
  }

  @override
  Future<bool> setTagColor(String tag, Color color) async {
    return false;
  }

  @override
  AbProfile? sharedProfile() {
    return null;
  }

  @override
  void setSharedProfile(AbProfile profile) {}

  @override
  Future<void> syncFromRecent(List<Peer> recents) async {}
}

Map<String, dynamic> _jsonDecodeRespMap(String body, int statusCode) {
  try {
    Map<String, dynamic> json = jsonDecode(body);
    return json;
  } catch (e) {
    final err = body.isNotEmpty && body.length < 128 ? body : e.toString();
    if (statusCode != 200) {
      throw 'HTTP $statusCode, $err';
    }
    throw err;
  }
}

// https://github.com/seanmonstar/reqwest/issues/838
void _setEmptyBody(Map<String, String> headers) {
  headers['Content-Length'] = '0';
}
