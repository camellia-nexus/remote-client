import 'dart:async';
import 'dart:convert';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/hbbs/hbbs.dart';
import 'package:camellia_remote_app/models/ab_model.dart';
import 'package:get/get.dart';

import '../common.dart';
import '../utils/http_service.dart' as http;
import 'model.dart';
import 'platform_model.dart';

enum UserAccountState { disabled, signedOut, loading, ready, offline, error }

class UserModel {
  final RxString userName = ''.obs;
  final RxString displayName = ''.obs;
  final RxString avatar = ''.obs;
  final RxString email = ''.obs;
  final RxString note = ''.obs;
  final RxBool isAdmin = false.obs;
  final RxString networkError = ''.obs;
  final Rx<UserAccountState> accountState = UserAccountState.signedOut.obs;
  Future<void>? _refreshOperation;
  bool get isLogin => userName.isNotEmpty;
  String get displayNameOrUserName =>
      displayName.value.trim().isEmpty ? userName.value : displayName.value;
  String get accountLabelWithHandle {
    final username = userName.value.trim();
    if (username.isEmpty) {
      return '';
    }
    final preferred = displayName.value.trim();
    if (preferred.isEmpty || preferred == username) {
      return username;
    }
    return '$preferred (@$username)';
  }

  WeakReference<FFI> parent;

  UserModel(this.parent) {
    userName.listen((p0) {
      // When user name becomes empty, show login button
      // When user name becomes non-empty:
      //  For _updateLocalUserInfo, network error will be set later
      //  For login success, should clear network error
      networkError.value = '';
    });
  }

  Future<void> refreshCurrentUser() {
    final active = _refreshOperation;
    if (active != null) return active;
    final operation = _refreshCurrentUser();
    _refreshOperation = operation;
    return operation.whenComplete(() {
      if (identical(_refreshOperation, operation)) {
        _refreshOperation = null;
      }
    });
  }

  Future<void> _refreshCurrentUser() async {
    if (bind.isDisableAccount()) {
      accountState.value = UserAccountState.disabled;
      return;
    }
    networkError.value = '';
    final token = bind.mainGetLocalOption(key: 'access_token');
    if (token == '') {
      _clearReactiveUser();
      accountState.value = UserAccountState.signedOut;
      await updateOtherModels();
      return;
    }
    final cached = _updateLocalUserInfo();
    accountState.value = cached
        ? UserAccountState.offline
        : UserAccountState.loading;
    final url = await bind.mainGetApiServer();
    final body = {
      'id': await bind.mainGetMyId(),
      'uuid': await bind.mainGetUuid(),
    };
    try {
      final http.Response response;
      try {
        response = await http.post(
          Uri.parse('$url/api/currentUser'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: json.encode(body),
        );
      } catch (e) {
        networkError.value = e.toString();
        rethrow;
      }
      final status = response.statusCode;
      if (status == 401 || status == 400) {
        await reset(resetOther: status == 401);
        accountState.value = status == 401
            ? UserAccountState.signedOut
            : UserAccountState.error;
        return;
      }
      final decoded = json.decode(decode_http_response(response));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid current user response');
      }
      final data = _mergeWithCachedUser(decoded, getLocalUserInfo());
      final error = data['error'];
      if (error != null) {
        throw error;
      }

      final user = UserPayload.fromJson(data);
      _parseAndUpdateUser(user);
    } catch (e) {
      networkError.value = e.toString();
      accountState.value = isLogin
          ? UserAccountState.offline
          : UserAccountState.error;
      debugPrint('Failed to refreshCurrentUser: $e');
    } finally {
      await updateOtherModels();
    }
  }

  static Map<String, dynamic> _mergeWithCachedUser(
    Map<String, dynamic> remote,
    Map<String, dynamic>? cached,
  ) {
    if (cached == null) return remote;
    final merged = Map<String, dynamic>.from(remote);
    for (final key in ['name', 'display_name', 'avatar', 'email', 'note']) {
      final remoteValue = (merged[key] ?? '').toString().trim();
      final cachedValue = (cached[key] ?? '').toString().trim();
      if (remoteValue.isEmpty && cachedValue.isNotEmpty) {
        merged[key] = cached[key];
      }
    }
    for (final key in ['is_admin', 'status', 'verifier']) {
      if (!merged.containsKey(key) && cached.containsKey(key)) {
        merged[key] = cached[key];
      }
    }
    return merged;
  }

  static Map<String, dynamic>? getLocalUserInfo() {
    final userInfo = bind.mainGetLocalOption(key: 'user_info');
    if (userInfo == '') {
      return null;
    }
    try {
      return json.decode(userInfo);
    } catch (e) {
      debugPrint('Failed to parse local user info: $e');
    }
    return null;
  }

  bool _updateLocalUserInfo() {
    final userInfo = getLocalUserInfo();
    if (userInfo != null) {
      userName.value = (userInfo['name'] ?? '').toString();
      displayName.value = (userInfo['display_name'] ?? '').toString();
      avatar.value = (userInfo['avatar'] ?? '').toString();
      email.value = (userInfo['email'] ?? '').toString();
      note.value = (userInfo['note'] ?? '').toString();
      isAdmin.value = userInfo['is_admin'] == true;
      return userName.value.isNotEmpty;
    }
    return false;
  }

  Future<void> reset({bool resetOther = false}) async {
    await bind.mainAccountLogout();
    await bind.mainSetLocalOption(key: 'access_token', value: '');
    await bind.mainSetLocalOption(key: 'user_info', value: '');
    if (resetOther) {
      await gFFI.abModel.reset();
      await gFFI.groupModel.reset();
    }
    _clearReactiveUser();
    accountState.value = UserAccountState.signedOut;
  }

  void _clearReactiveUser() {
    userName.value = '';
    displayName.value = '';
    avatar.value = '';
    email.value = '';
    note.value = '';
    isAdmin.value = false;
    networkError.value = '';
  }

  void _parseAndUpdateUser(UserPayload user) {
    userName.value = user.name;
    displayName.value = user.displayName;
    avatar.value = user.avatar;
    email.value = user.email;
    note.value = user.note;
    isAdmin.value = user.isAdmin;
    accountState.value = user.status == UserStatus.kDisabled
        ? UserAccountState.disabled
        : UserAccountState.ready;
    bind.mainSetLocalOption(key: 'user_info', value: jsonEncode(user));
    if (isWeb) {
      // ugly here, tmp solution
      bind.mainSetLocalOption(key: 'verifier', value: user.verifier ?? '');
    }
  }

  // update ab and group status
  static Future<void> updateOtherModels() async {
    await Future.wait([
      gFFI.abModel.pullAb(force: ForcePullAb.listAndCurrent, quiet: false),
      gFFI.groupModel.pull(),
    ]);
  }

  Future<void> logOut({String? apiServer}) async {
    final tag = gFFI.dialogManager.showLoading(translate('Waiting'));
    try {
      final url = apiServer ?? await bind.mainGetApiServer();
      final authHeaders = getHttpHeaders();
      authHeaders['Content-Type'] = "application/json";
      await http
          .post(
            Uri.parse('$url/api/logout'),
            body: jsonEncode({
              'id': await bind.mainGetMyId(),
              'uuid': await bind.mainGetUuid(),
            }),
            headers: authHeaders,
          )
          .timeout(Duration(seconds: 2));
    } catch (e) {
      debugPrint("request /api/logout failed: err=$e");
    } finally {
      await reset(resetOther: true);
      gFFI.dialogManager.dismissByTag(tag);
    }
  }

  /// throw [RequestException]
  Future<LoginResponse> login(LoginRequest loginRequest) async {
    final url = await bind.mainGetApiServer();
    final payload = loginRequest.toJson();
    final id = loginRequest.id ?? '';
    final uuid = loginRequest.uuid ?? '';
    if (id.isNotEmpty && uuid.isNotEmpty) {
      final proofBody = await bind.mainGetDeviceProof(
        purpose: 'login',
        id: id,
        uuid: uuid,
        token: '',
      );
      final proof = jsonDecode(proofBody);
      if (proof is! Map<String, dynamic> || proof['error'] != null) {
        throw RequestException(0, proof is Map ? '${proof['error'] ?? 'Device proof failed'}' : 'Device proof failed');
      }
      payload['device_proof'] = proof;
    }
    final resp = await http.post(
      Uri.parse('$url/api/login'),
      body: jsonEncode(payload),
    );

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(decode_http_response(resp));
    } catch (e) {
      debugPrint("login: jsonDecode resp body failed: ${e.toString()}");
      if (resp.statusCode != 200) {
        BotToast.showText(
          contentColor: Colors.red,
          text: 'HTTP ${resp.statusCode}',
        );
      }
      rethrow;
    }
    if (resp.statusCode != 200) {
      throw RequestException(resp.statusCode, body['error'] ?? '');
    }
    if (body['error'] != null) {
      throw RequestException(0, body['error']);
    }

    return getLoginResponseFromAuthBody(body);
  }

  LoginResponse getLoginResponseFromAuthBody(Map<String, dynamic> body) {
    final LoginResponse loginResponse;
    try {
      loginResponse = LoginResponse.fromJson(body);
    } catch (e) {
      debugPrint("login: jsonDecode LoginResponse failed: ${e.toString()}");
      rethrow;
    }

    final isLogInDone =
        loginResponse.type == HttpType.kAuthResTypeToken &&
        loginResponse.access_token != null;
    if (isLogInDone && loginResponse.user != null) {
      _parseAndUpdateUser(loginResponse.user!);
    }

    return loginResponse;
  }

  static Future<List<dynamic>> queryOidcLoginOptions() async {
    try {
      final url = await bind.mainGetApiServer();
      if (url.trim().isEmpty) return [];
      final resp = await http.get(Uri.parse('$url/api/login-options'));
      final List<String> ops = [];
      for (final item in jsonDecode(resp.body)) {
        ops.add(item as String);
      }
      for (final item in ops) {
        if (item.startsWith('common-oidc/')) {
          return jsonDecode(item.substring('common-oidc/'.length));
        }
      }
      return ops
          .where((item) => item.startsWith('oidc/'))
          .map((item) => {'name': item.substring('oidc/'.length)})
          .toList();
    } catch (e) {
      debugPrint(
        "queryOidcLoginOptions: jsonDecode resp body failed: ${e.toString()}",
      );
      return [];
    }
  }
}
