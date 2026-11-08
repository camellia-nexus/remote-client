import 'package:flutter/widgets.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/hbbs/hbbs.dart';
import 'package:camellia_remote_app/common/widgets/peers_view.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/models/user_model.dart';
import 'package:get/get.dart';
import 'dart:convert';
import '../utils/http_service.dart' as http;

class PeerPaginationState {
  PeerPaginationState({required this.pageSize});

  static const maxCursorLength = 2048;

  final int pageSize;
  final Set<String> _seenCursors = {};
  int current = 0;
  int total = 0;
  bool _cursorContractSeen = false;
  String _cursor = '';

  Map<String, String> nextQueryParameters() {
    current += 1;
    return {
      'current': current.toString(),
      'pageSize': pageSize.toString(),
      if (_cursorContractSeen && _cursor.isNotEmpty) 'cursor': _cursor,
    };
  }

  void accept(Map<String, dynamic> response) {
    final responseTotal = response['total'];
    if (responseTotal is! int || responseTotal < 0) {
      throw const FormatException('Invalid peer inventory total');
    }
    total = responseTotal;

    if (!response.containsKey('nextCursor')) {
      if (_cursorContractSeen) {
        throw const FormatException('Peer inventory cursor disappeared');
      }
      return;
    }
    final nextCursor = response['nextCursor'];
    if (nextCursor is! String ||
        nextCursor.length > maxCursorLength ||
        nextCursor.codeUnits.any(
          (codeUnit) => codeUnit < 33 || codeUnit > 126,
        )) {
      throw const FormatException('Invalid peer inventory cursor');
    }
    _cursorContractSeen = true;
    if (nextCursor.isNotEmpty && !_seenCursors.add(nextCursor)) {
      throw const FormatException('Peer inventory cursor repeated');
    }
    _cursor = nextCursor;
  }

  bool get hasMore =>
      _cursorContractSeen ? _cursor.isNotEmpty : current * pageSize < total;
}

class GroupModel {
  final RxBool groupLoading = false.obs;
  final RxString groupLoadError = "".obs;
  final RxList<DeviceGroupPayload> deviceGroups = RxList.empty(growable: true);
  final RxList<UserPayload> users = RxList.empty(growable: true);
  final RxList<Peer> peers = RxList.empty(growable: true);
  final RxBool isSelectedDeviceGroup = false.obs;
  final RxString selectedAccessibleItemName = ''.obs;
  final RxString searchAccessibleItemNameText = ''.obs;
  WeakReference<FFI> parent;
  var initialized = false;
  var _cacheLoadOnceFlag = false;
  var _statusCode = 200;

  final Map<String, VoidCallback> _peerIdUpdateListeners = {};

  bool get emtpy => deviceGroups.isEmpty && users.isEmpty && peers.isEmpty;

  late final Peers peersModel;

  GroupModel(this.parent) {
    peersModel = Peers(
      name: PeersModelName.group,
      getInitPeers: () => peers,
      loadEvent: LoadEvent.group,
    );
  }

  Future<void> pull({force = true, quiet = false}) async {
    if (!gFFI.userModel.isLogin || groupLoading.value) return;
    if (gFFI.userModel.networkError.isNotEmpty) return;
    if (!force && initialized) return;
    final requestGen = UserModel.currentAccountGen;
    final expectedToken = bind.mainGetLocalOption(key: 'access_token');
    if (expectedToken.isEmpty) return;

    if (!quiet) {
      groupLoading.value = true;
      groupLoadError.value = "";
    }
    bool pullSucceeded = false;
    try {
      pullSucceeded = await _pull(requestGen);
      if (requestGen != UserModel.currentAccountGen) return;
      _tryHandlePullError();
    } catch (e) {
      print("pull accessibles error: $e");
    } finally {
      if (requestGen == UserModel.currentAccountGen) {
        groupLoading.value = false;
      }
    }
    if (requestGen != UserModel.currentAccountGen) return;
    if (pullSucceeded) {
      initialized = true;
    }
    platformFFI.tryHandle({'name': LoadEvent.group});
    if (_statusCode == 401) {
      gFFI.userModel.reset(resetOther: true);
    } else if (pullSucceeded) {
      _saveCache(expectedToken);
    }
  }

  Future<bool> _pull(int requestGen) async {
    List<DeviceGroupPayload> tmpDeviceGroups = List.empty(growable: true);
    if (!await _getDeviceGroups(tmpDeviceGroups, requestGen)) {
      return false;
    }
    if (requestGen != UserModel.currentAccountGen) return false;
    tmpDeviceGroups.sort((a, b) => a.name.compareTo(b.name));
    List<UserPayload> tmpUsers = List.empty(growable: true);
    if (!await _getUsers(tmpUsers, requestGen)) {
      return false;
    }
    if (requestGen != UserModel.currentAccountGen) return false;
    List<Peer> tmpPeers = List.empty(growable: true);
    if (!await _getPeers(tmpPeers, requestGen)) {
      return false;
    }
    if (requestGen != UserModel.currentAccountGen) return false;
    deviceGroups.value = tmpDeviceGroups;
    // me first
    var index = tmpUsers.indexWhere(
      (user) => user.name == gFFI.userModel.userName.value,
    );
    if (index != -1) {
      var user = tmpUsers.removeAt(index);
      tmpUsers.insert(0, user);
    }
    users.value = tmpUsers;
    if (!users.any((u) => u.name == selectedAccessibleItemName.value) &&
        !deviceGroups.any((d) => d.name == selectedAccessibleItemName.value)) {
      selectedAccessibleItemName.value = '';
    }
    // recover online
    final oldOnlineIDs = peers.where((e) => e.online).map((e) => e.id).toList();
    peers.value = tmpPeers;
    peers
        .where((e) => oldOnlineIDs.contains(e.id))
        .map((e) => e.online = true)
        .toList();
    groupLoadError.value = '';
    _callbackPeerUpdate();
    return true;
  }

  Future<bool> _getDeviceGroups(
    List<DeviceGroupPayload> tmpDeviceGroups,
    int requestGen,
  ) async {
    final api = "${await bind.mainGetApiServer()}/api/device-group/accessible";
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
        final resp = await http.get(uri, headers: getHttpHeaders());
        if (requestGen != UserModel.currentAccountGen) return false;
        _statusCode = resp.statusCode;
        Map<String, dynamic> json = _jsonDecodeResp(
          decode_http_response(resp),
          resp.statusCode,
        );
        if (json.containsKey('error')) {
          throw json['error'];
        }
        if (resp.statusCode != 200) {
          throw 'HTTP ${resp.statusCode}';
        }
        if (json.containsKey('total')) {
          if (total == 0) total = json['total'];
          if (json.containsKey('data')) {
            final data = json['data'];
            if (data is List) {
              for (final user in data) {
                final u = DeviceGroupPayload.fromJson(user);
                int index = tmpDeviceGroups.indexWhere((e) => e.name == u.name);
                if (index < 0) {
                  tmpDeviceGroups.add(u);
                } else {
                  tmpDeviceGroups[index] = u;
                }
              }
            }
          }
        }
      } while (current * pageSize < total);
      return true;
    } catch (err) {
      debugPrint('get accessible device groups: $err');
      groupLoadError.value =
          '${translate('pull_group_failed_tip')}: ${translate(err.toString())}';
    }
    return false;
  }

  Future<bool> _getUsers(
    List<UserPayload> tmpUsers,
    int requestGen,
  ) async {
    final api = "${await bind.mainGetApiServer()}/api/users";
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
            'accessible': '',
            'status': '1',
          },
        );
        final resp = await http.get(uri, headers: getHttpHeaders());
        if (requestGen != UserModel.currentAccountGen) return false;
        _statusCode = resp.statusCode;
        Map<String, dynamic> json = _jsonDecodeResp(
          decode_http_response(resp),
          resp.statusCode,
        );
        if (json.containsKey('error')) {
          if (json['error'] == 'Admin required!' ||
              json['error'].toString().contains(
                'ambiguous column name: status',
              )) {
            throw translate('upgrade_rustdesk_server_pro_to_{1.1.10}_tip');
          } else {
            throw json['error'];
          }
        }
        if (resp.statusCode != 200) {
          throw 'HTTP ${resp.statusCode}';
        }
        if (json.containsKey('total')) {
          if (total == 0) total = json['total'];
          if (json.containsKey('data')) {
            final data = json['data'];
            if (data is List) {
              for (final user in data) {
                final u = UserPayload.fromJson(user);
                int index = tmpUsers.indexWhere((e) => e.name == u.name);
                if (index < 0) {
                  tmpUsers.add(u);
                } else {
                  tmpUsers[index] = u;
                }
              }
            }
          }
        }
      } while (current * pageSize < total);
      return true;
    } catch (err) {
      debugPrint('get accessible users: $err');
      groupLoadError.value =
          '${translate('pull_group_failed_tip')}: ${translate(err.toString())}';
    }
    return false;
  }

  Future<bool> _getPeers(
    List<Peer> tmpPeers,
    int requestGen,
  ) async {
    try {
      final api = "${await bind.mainGetApiServer()}/api/peers";
      var uri0 = Uri.parse(api);
      final pagination = PeerPaginationState(pageSize: 100);
      do {
        var queryParameters = {
          ...pagination.nextQueryParameters(),
          'accessible': '',
          'status': '1',
        };
        var uri = Uri(
          scheme: uri0.scheme,
          host: uri0.host,
          path: uri0.path,
          port: uri0.port,
          queryParameters: queryParameters,
        );
        final resp = await http.get(uri, headers: getHttpHeaders());
        if (requestGen != UserModel.currentAccountGen) return false;
        _statusCode = resp.statusCode;

        Map<String, dynamic> json = _jsonDecodeResp(
          decode_http_response(resp),
          resp.statusCode,
        );
        if (json.containsKey('error')) {
          throw json['error'];
        }
        if (resp.statusCode != 200) {
          throw 'HTTP ${resp.statusCode}';
        }
        pagination.accept(json);
        if (json.containsKey('data')) {
          final data = json['data'];
          if (data is List) {
            for (final p in data) {
              final peerPayload = PeerPayload.fromJson(p);
              final peer = PeerPayload.toPeer(peerPayload);
              int index = tmpPeers.indexWhere((e) => e.id == peer.id);
              if (index < 0) {
                tmpPeers.add(peer);
              } else {
                tmpPeers[index] = peer;
              }
            }
          }
        }
      } while (pagination.hasMore);
      return true;
    } catch (err) {
      debugPrint('get accessible peers: $err');
      groupLoadError.value =
          '${translate('pull_group_failed_tip')}: ${translate(err.toString())}';
    }
    return false;
  }

  Map<String, dynamic> _jsonDecodeResp(String body, int statusCode) {
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

  void _saveCache([String? expectedToken]) {
    try {
      final currentToken = bind.mainGetLocalOption(key: 'access_token');
      if (currentToken.isEmpty ||
          (expectedToken != null && currentToken != expectedToken)) {
        debugPrint('GroupModel: skip saving cache due to token mismatch');
        return;
      }
      final map = (<String, dynamic>{
        "access_token": currentToken,
        "device_groups": deviceGroups.map((e) => e.toGroupCacheJson()).toList(),
        "users": users.map((e) => e.toGroupCacheJson()).toList(),
        'peers': peers.map((e) => e.toGroupCacheJson()).toList(),
      });
      bind.mainSaveGroup(json: jsonEncode(map));
    } catch (e) {
      debugPrint('group save:$e');
    }
  }

  Future<void> loadCache() async {
    try {
      if (_cacheLoadOnceFlag || groupLoading.value || initialized) return;
      _cacheLoadOnceFlag = true;
      final access_token = bind.mainGetLocalOption(key: 'access_token');
      if (access_token.isEmpty) return;
      final cache = await bind.mainLoadGroup();
      if (groupLoading.value) return;
      final currentToken = bind.mainGetLocalOption(key: 'access_token');
      if (currentToken != access_token || currentToken.isEmpty) return;
      final data = jsonDecode(cache);
      if (data == null || data['access_token'] != access_token) return;
      deviceGroups.clear();
      users.clear();
      peers.clear();
      if (data['device_groups'] is List) {
        for (var u in data['device_groups']) {
          deviceGroups.add(DeviceGroupPayload.fromJson(u));
        }
      }
      if (data['users'] is List) {
        for (var u in data['users']) {
          users.add(UserPayload.fromJson(u));
        }
      }
      if (data['peers'] is List) {
        for (final peer in data['peers']) {
          peers.add(Peer.fromJson(peer));
        }
        _callbackPeerUpdate();
      }
    } catch (e) {
      debugPrint("load group cache: $e");
    }
  }

  reset() async {
    initialized = false;
    _cacheLoadOnceFlag = false;
    groupLoading.value = false;
    groupLoadError.value = '';
    deviceGroups.clear();
    users.clear();
    peers.clear();
    selectedAccessibleItemName.value = '';
    await bind.mainClearGroup();
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

  void _tryHandlePullError() {
    String errorMessage = groupLoadError.value;
    // The error message is "Retrieving accessible devices is disabled."
    if (errorMessage.toLowerCase().contains('disabled')) {
      users.clear();
      peers.clear();
      deviceGroups.clear();
    }
  }
}
