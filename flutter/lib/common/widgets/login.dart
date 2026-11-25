import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camellia_remote_app/common/hbbs/hbbs.dart';
import 'package:camellia_remote_app/models/management_api_contract.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/models/user_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../common.dart';
import './dialog.dart';

const kOpSvgList = [
  'github',
  'gitlab',
  'google',
  'apple',
  'okta',
  'facebook',
  'azure',
  'auth0',
  'microsoft',
];

class _OidcProviderBranding {
  final String label;
  final String iconKey;

  const _OidcProviderBranding({required this.label, required this.iconKey});
}

_OidcProviderBranding _oidcProviderBranding(String op) {
  switch (op.toLowerCase()) {
    case 'azure':
      return const _OidcProviderBranding(
        label: 'Microsoft',
        iconKey: 'microsoft',
      );
    default:
      return _OidcProviderBranding(
        label:
            {'github': 'GitHub', 'gitlab': 'GitLab'}[op.toLowerCase()] ??
            toCapitalized(op),
        iconKey: op.toLowerCase(),
      );
  }
}

class _IconOP extends StatelessWidget {
  final String op;
  final String? icon;
  final EdgeInsets margin;
  const _IconOP({
    required this.op,
    required this.icon,
    this.margin = const EdgeInsets.symmetric(horizontal: 4.0),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      child: icon == null || icon!.trim().isEmpty
          ? Icon(
              CamelliaIcons.authProviderIcon(op),
              size: 18,
              color: Theme.of(context).colorScheme.onSurface,
            )
          : SvgPicture.string(icon!, width: 18, height: 18),
    );
  }
}

class ButtonOP extends StatelessWidget {
  final String op;
  final RxString curOP;
  final String? icon;
  final Color primaryColor;
  final double height;
  final Function() onTap;

  const ButtonOP({
    super.key,
    required this.op,
    required this.curOP,
    required this.icon,
    required this.primaryColor,
    required this.height,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final branding = _oidcProviderBranding(op);
    final buttonLabel = translate('Continue with {${branding.label}}');
    return SizedBox(
      width: double.infinity,
      child: Obx(
        () => GlassButton(
          variant: GlassButtonVariant.secondary,
          expand: true,
          minHeight: height < 42 ? 42 : height,
          loading: curOP.value == op,
          icon: _IconOP(
            op: branding.iconKey,
            icon: icon,
            margin: const EdgeInsets.only(right: 2),
          ),
          onPressed: curOP.value.isEmpty ? onTap : null,
          child: Text(
            buttonLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

class ConfigOP {
  final String op;
  final String? icon;
  ConfigOP({required this.op, required this.icon});
}

class WidgetOP extends StatefulWidget {
  final ConfigOP config;
  final RxString curOP;
  final Function(Map<String, dynamic> authBody, int requestGen) cbLogin;
  const WidgetOP({
    super.key,
    required this.config,
    required this.curOP,
    required this.cbLogin,
  });

  @override
  State<StatefulWidget> createState() => _WidgetOPState();
}

class _WidgetOPState extends State<WidgetOP> {
  Timer? _updateTimer;
  String _stateMsg = '';
  String _failedMsg = '';
  String _url = '';
  bool _queryInFlight = false;
  int _attemptGen = 0;

  @override
  void dispose() {
    _attemptGen++;
    _updateTimer?.cancel();
    _updateTimer = null;
    super.dispose();
  }

  void _beginQueryState(int requestGen) {
    _updateTimer?.cancel();
    final myAttemptGen = ++_attemptGen;
    _updateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted ||
          requestGen != AuthGenerationTracker.currentAuthGen ||
          myAttemptGen != _attemptGen) {
        timer.cancel();
        if (identical(_updateTimer, timer)) {
          _updateTimer = null;
        }
        return;
      }
      _updateState(requestGen, myAttemptGen);
    });
  }

  void _updateState(int requestGen, int myAttemptGen) {
    if (!mounted ||
        requestGen != AuthGenerationTracker.currentAuthGen ||
        myAttemptGen != _attemptGen) {
      _updateTimer?.cancel();
      _updateTimer = null;
      return;
    }
    if (_queryInFlight) return;
    _queryInFlight = true;

    bind.mainAccountAuthResult().then((result) {
      _queryInFlight = false;
      if (!mounted ||
          requestGen != AuthGenerationTracker.currentAuthGen ||
          myAttemptGen != _attemptGen) {
        _updateTimer?.cancel();
        _updateTimer = null;
        return;
      }
      if (result.isEmpty) {
        return;
      }
      final resultMap = jsonDecode(result);
      if (resultMap == null) {
        return;
      }
      final String stateMsg = resultMap['state_msg'] ?? '';
      final String failedMsg = resultMap['failed_msg'] ?? '';
      final String? url = resultMap['url'];
      final bool urlLaunched = (resultMap['url_launched'] as bool?) ?? false;
      final authBody = resultMap['auth_body'];
      if (_stateMsg != stateMsg || _failedMsg != failedMsg) {
        if (_url.isEmpty && url != null && url.isNotEmpty) {
          if (!urlLaunched) {
            launchUrl(
              Uri.parse(url),
              mode: isWeb
                  ? LaunchMode.platformDefault
                  : LaunchMode.externalApplication,
            );
          }
          _url = url;
        }
        if (authBody != null) {
          _updateTimer?.cancel();
          _updateTimer = null;
          widget.curOP.value = '';
          widget.cbLogin(authBody as Map<String, dynamic>, requestGen);
        }

        if (mounted &&
            requestGen == AuthGenerationTracker.currentAuthGen &&
            myAttemptGen == _attemptGen) {
          setState(() {
            _stateMsg = stateMsg;
            _failedMsg = failedMsg;
            if (failedMsg.isNotEmpty) {
              widget.curOP.value = '';
              _updateTimer?.cancel();
              _updateTimer = null;
              showToast(formatUserFriendlyError(failedMsg));
            }
          });
        }
      }
    }).catchError((e) {
      _queryInFlight = false;
      debugPrint('OIDC query failed: $e');
    });
  }

  void _resetState() {
    _stateMsg = '';
    _failedMsg = '';
    _url = '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        ButtonOP(
          op: widget.config.op,
          curOP: widget.curOP,
          icon: widget.config.icon,
          primaryColor: str2color(widget.config.op, 0x7f),
          height: 42,
          onTap: () async {
            if (widget.curOP.value.isNotEmpty) return;
            _resetState();
            final requestGen = AuthGenerationTracker.nextGen();
            widget.curOP.value = widget.config.op;
            try {
              await bind.mainAccountAuth(op: widget.config.op, rememberMe: true);
              if (requestGen != AuthGenerationTracker.currentAuthGen ||
                  !mounted) {
                return;
              }
              _beginQueryState(requestGen);
            } catch (e) {
              if (requestGen != AuthGenerationTracker.currentAuthGen) return;
              widget.curOP.value = '';
              final friendly = friendlyAuthErrorMessage(e);
              showToast(friendly);
              if (mounted) {
                setState(() {
                  _failedMsg = friendly;
                });
              }
            }
          },
        ),
        Obx(() {
          if (widget.curOP.isNotEmpty &&
              widget.curOP.value != widget.config.op) {
            _failedMsg = '';
          }
          return Offstage(
            offstage:
                _failedMsg.isEmpty && widget.curOP.value != widget.config.op,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_stateMsg.isNotEmpty && _failedMsg.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: SelectableText(
                      translate(_stateMsg),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (_failedMsg.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: _AuthErrorBanner(
                      message: formatUserFriendlyError(_failedMsg),
                    ),
                  ),
              ],
            ),
          );
        }),
        Obx(
          () => Offstage(
            offstage: widget.curOP.value != widget.config.op,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: GlassButton(
                variant: GlassButtonVariant.subtle,
                minHeight: 34,
                onPressed: () {
                  _attemptGen++;
                  widget.curOP.value = '';
                  _updateTimer?.cancel();
                  _updateTimer = null;
                  _resetState();
                  AuthGenerationTracker.invalidate();
                  bind.mainAccountAuthCancel();
                },
                child: Text(translate('Cancel')),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class LoginWidgetOP extends StatelessWidget {
  final List<ConfigOP> ops;
  final RxString curOP;
  final Function(Map<String, dynamic> authBody, int requestGen) cbLogin;

  const LoginWidgetOP({
    super.key,
    required this.ops,
    required this.curOP,
    required this.cbLogin,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < ops.length; i++) ...[
          WidgetOP(config: ops[i], curOP: curOP, cbLogin: cbLogin),
          if (i < ops.length - 1) const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class LoginWidgetUserPass extends StatefulWidget {
  final TextEditingController username;
  final TextEditingController pass;
  final String? usernameMsg;
  final String? passMsg;
  final bool isInProgress;
  final RxString curOP;
  final Function() onLogin;
  final FocusNode? userFocusNode;

  const LoginWidgetUserPass({
    super.key,
    this.userFocusNode,
    required this.username,
    required this.pass,
    required this.usernameMsg,
    required this.passMsg,
    required this.isInProgress,
    required this.curOP,
    required this.onLogin,
  });

  @override
  State<LoginWidgetUserPass> createState() => _LoginWidgetUserPassState();
}

class _LoginWidgetUserPassState extends State<LoginWidgetUserPass> {
  final FocusNode _passFocusNode = FocusNode();
  final GlassShakeController _shakeController = GlassShakeController();
  bool _passwordVisible = false;

  @override
  void didUpdateWidget(covariant LoginWidgetUserPass oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextErr = widget.passMsg?.trim() ?? '';
    final prevErr = oldWidget.passMsg?.trim() ?? '';
    if (nextErr.isNotEmpty && nextErr != prevErr) {
      _shakeController.shake();
    }
  }

  @override
  void dispose() {
    _passFocusNode.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassInput(
          labelText: translate(DialogTextField.kUsernameTitle),
          hintText: translate('Enter account or email'),
          prefixIcon: Icons.person_outline_rounded,
          controller: widget.username,
          focusNode: widget.userFocusNode,
          errorText: widget.usernameMsg,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => _passFocusNode.requestFocus(),
        ),
        const SizedBox(height: 12),
        GlassShakeBox(
          controller: _shakeController,
          child: GlassInput(
            labelText: translate(DialogTextField.kPasswordTitle),
            hintText: translate('Enter your password'),
            prefixIcon: CamelliaIcons.lock,
            controller: widget.pass,
            focusNode: _passFocusNode,
            obscureText: !_passwordVisible,
            showClearButton: false,
            errorText: widget.passMsg,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) {
              if (!widget.isInProgress &&
                  (widget.curOP.value.isEmpty ||
                      widget.curOP.value == 'rustdesk')) {
                widget.onLogin();
              }
            },
            trailing: Tooltip(
              message: translate(
                _passwordVisible ? 'Hide password' : 'Show password',
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(CamelliaRadius.pill),
                onTap: () => setState(() {
                  _passwordVisible = !_passwordVisible;
                }),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    _passwordVisible ? CamelliaIcons.eye : CamelliaIcons.eyeOff,
                    size: 17,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Obx(
          () => GlassButton(
            variant: GlassButtonVariant.primary,
            expand: true,
            loading: widget.isInProgress,
            icon: const Icon(Icons.login_rounded, size: 17),
            onPressed:
                !widget.isInProgress &&
                    (widget.curOP.value.isEmpty ||
                        widget.curOP.value == 'rustdesk')
                ? () => widget.onLogin()
                : null,
            child: Text(translate('Login')),
          ),
        ),
      ],
    );
  }
}

class _AuthErrorBanner extends StatelessWidget {
  const _AuthErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final dark = theme.brightness == Brightness.dark;
    final alertColor = glass.statusAlert;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: alertColor.withValues(alpha: dark ? 0.16 : 0.09),
        borderRadius: BorderRadius.circular(CamelliaRadius.control),
        border: Border.all(
          color: alertColor.withValues(alpha: dark ? 0.34 : 0.24),
          width: 0.85,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                Icons.error_outline_rounded,
                size: 17,
                color: alertColor,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w500,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const kAuthReqTypeOidc = 'oidc/';

class AuthGenerationTracker {
  static int _currentAuthGen = 0;
  static int get currentAuthGen => _currentAuthGen;

  static int nextGen() => ++_currentAuthGen;

  static void invalidate() {
    _currentAuthGen++;
  }

  @visibleForTesting
  static void resetForTesting() {
    _currentAuthGen = 0;
  }
}

String friendlyAuthErrorMessage(dynamic err) {
  if (err is ManagementApiException) {
    if (err.statusCode == 401 ||
        err.code == 'invalid_credentials' ||
        err.code == 'unauthorized') {
      return translate('Invalid account or password');
    }
    if (err.statusCode == 403 || err.code == 'forbidden') {
      return translate('Access denied. Please contact administrator.');
    }
    if (err.statusCode == 404) {
      return translate(
        'Authentication endpoint not found. Please check your API server address.',
      );
    }
    if (err.statusCode == 429 || err.code == 'too_many_requests') {
      return translate('Too many login attempts. Please try again later.');
    }
    if (err.statusCode >= 500) {
      return translate('Authentication server error. Please try again later.');
    }
    return translate(err.message.isNotEmpty ? err.message : 'Login failed');
  } else if (err is RequestException) {
    final cause = err.cause.trim();
    if (cause == 'invalid_credentials' ||
        cause.toLowerCase().contains('password') ||
        cause.toLowerCase().contains('username')) {
      return translate('Invalid account or password');
    }
    return formatUserFriendlyError(cause);
  } else if (err is SocketException) {
    return translate(
      'Cannot connect to server. Please check your network connection.',
    );
  } else if (err is TimeoutException) {
    return translate(
      'Connection timed out. Please check your network and try again.',
    );
  } else if (err is http.ClientException) {
    return translate(
      'Network connection failed. Please check your network or server address.',
    );
  } else {
    final str = err.toString();
    if (str.contains('SocketException') ||
        str.contains('Connection refused') ||
        str.contains('Failed host lookup')) {
      return translate(
        'Cannot connect to server. Please check your network connection.',
      );
    }
    if (str.contains('TimeoutException') || str.contains('timed out')) {
      return translate(
        'Connection timed out. Please check your network and try again.',
      );
    }
    if (str.contains('401') || str.contains('invalid_credentials')) {
      return translate('Invalid account or password');
    }
    if (str.contains('API server is empty') || str.contains('No host specified')) {
      return translate(
        'API server is not configured. Please configure ID/Relay Server in Network settings.',
      );
    }
    return translate(
      'Login failed. Please check credentials and server status.',
    );
  }
}

@visibleForTesting
Future<bool> handleLoginResponseStatic({
  required LoginResponse resp,
  required bool storeIfAccessToken,
  required int requestGen,
  void Function([dynamic])? closeCallback,
  void Function(String)? onPasswordMsg,
  Future<bool?> Function(UserPayload?, String?, bool)? showVerifyDialog,
  bool Function()? isMounted,
  void Function()? onProgressFinished,
}) async {
  if (requestGen != AuthGenerationTracker.currentAuthGen) return false;
  switch (resp.type) {
    case HttpType.kAuthResTypeToken:
      if (resp.access_token != null) {
        if (storeIfAccessToken) {
          if (requestGen != AuthGenerationTracker.currentAuthGen) return false;
          await bind.mainSetLocalOption(
            key: 'access_token',
            value: resp.access_token!,
          );
          if (requestGen != AuthGenerationTracker.currentAuthGen) return false;
          await bind.mainSetLocalOption(
            key: 'user_info',
            value: jsonEncode(resp.user ?? {}),
          );
        }
        if (requestGen != AuthGenerationTracker.currentAuthGen) return false;
        closeCallback?.call(true);
        return true;
      }
      break;
    case HttpType.kAuthResTypeEmailCheck:
      if (requestGen != AuthGenerationTracker.currentAuthGen) return false;
      bool? isEmailVerification;
      if (resp.tfa_type == null ||
          resp.tfa_type == HttpType.kAuthResTypeEmailCheck) {
        isEmailVerification = true;
      } else if (resp.tfa_type == HttpType.kAuthResTypeTfaCheck) {
        isEmailVerification = false;
      } else {
        if (requestGen == AuthGenerationTracker.currentAuthGen) {
          onPasswordMsg?.call(translate('Failed, bad tfa type from server'));
        }
      }
      if (isEmailVerification != null) {
        final verifyFunc = showVerifyDialog ?? verificationCodeDialog;
        if (isMobile) {
          closeCallback?.call(null);
          if (requestGen == AuthGenerationTracker.currentAuthGen) {
            verifyFunc(resp.user, resp.secret, isEmailVerification);
          }
        } else {
          if ((isMounted == null || isMounted()) &&
              requestGen == AuthGenerationTracker.currentAuthGen) {
            onProgressFinished?.call();
          }
          if (isWeb && closeCallback != null) closeCallback(null);
          if (requestGen != AuthGenerationTracker.currentAuthGen) return false;
          final res = await verifyFunc(
            resp.user,
            resp.secret,
            isEmailVerification,
          );
          if (res == true) {
            if (!isWeb && closeCallback != null) closeCallback(false);
            return true;
          }
        }
      }
      break;
    default:
      if (requestGen == AuthGenerationTracker.currentAuthGen) {
        onPasswordMsg?.call(translate('Failed, bad response from server'));
      }
      break;
  }
  return false;
}

// call this directly
Future<bool?> loginDialog() async {
  final username = TextEditingController(
    text: UserModel.getLocalUserInfo()?['name'] ?? '',
  );
  final password = TextEditingController();
  final userFocusNode = FocusNode()..requestFocus();
  Timer(const Duration(milliseconds: 100), () {
    if (userFocusNode.canRequestFocus) {
      userFocusNode.requestFocus();
    }
  });

  String? usernameMsg;
  String? passwordMsg;
  String? authBannerMsg;
  var isInProgress = false;
  final RxString curOP = ''.obs;

  void Function(void Function())? dialogSetState;
  void onUsernameChanged() {
    if (usernameMsg != null || authBannerMsg != null) {
      dialogSetState?.call(() {
        usernameMsg = null;
        authBannerMsg = null;
      });
    }
  }

  void onPasswordChanged() {
    if (passwordMsg != null || authBannerMsg != null) {
      dialogSetState?.call(() {
        passwordMsg = null;
        authBannerMsg = null;
      });
    }
  }

  username.addListener(onUsernameChanged);
  password.addListener(onPasswordChanged);

  final loginOptions = [].obs;
  Future.delayed(Duration.zero, () async {
    loginOptions.value = await UserModel.queryOidcLoginOptions();
  });

  bool dialogClosed = false;

  try {
    final res = await gFFI.dialogManager.show<bool>((setState, close, context) {
      dialogSetState = setState;

      void safeClose([dynamic result]) {
        if (!dialogClosed) {
          dialogClosed = true;
          AuthGenerationTracker.invalidate();
          close(result is bool ? result : null);
        }
      }

      void onDialogCancel() {
        isInProgress = false;
        safeClose(false);
      }

      Future<void> handleLoginResponse(
        LoginResponse resp,
        bool storeIfAccessToken,
        void Function([dynamic])? closeCallback,
        int requestGen,
      ) async {
        await handleLoginResponseStatic(
          resp: resp,
          storeIfAccessToken: storeIfAccessToken,
          closeCallback: closeCallback,
          requestGen: requestGen,
          onPasswordMsg: (msg) {
            authBannerMsg = msg;
            showToast(msg);
            if (context.mounted) {
              setState(() {});
            }
          },
          isMounted: () => context.mounted,
          onProgressFinished: () {
            setState(() => isInProgress = false);
          },
        );
      }

      Future<void> onLogin() async {
        if (username.text.trim().isEmpty) {
          if (context.mounted) {
            setState(() => usernameMsg = translate('Username missed'));
          }
          return;
        }
        if (password.text.isEmpty) {
          if (context.mounted) {
            setState(() => passwordMsg = translate('Password missed'));
          }
          return;
        }
        final requestGen = AuthGenerationTracker.nextGen();
        curOP.value = 'rustdesk';
        if (context.mounted) {
          setState(() {
            authBannerMsg = null;
            isInProgress = true;
          });
        }
        try {
          final myId = await bind.mainGetMyId();
          if (requestGen != AuthGenerationTracker.currentAuthGen) return;
          final myUuid = await bind.mainGetUuid();
          if (requestGen != AuthGenerationTracker.currentAuthGen) return;
          final resp = await gFFI.userModel.login(
            LoginRequest(
              username: username.text.trim(),
              password: password.text,
              id: myId,
              uuid: myUuid,
              autoLogin: true,
              type: HttpType.kAuthReqTypeAccount,
            ),
          );
          if (requestGen != AuthGenerationTracker.currentAuthGen) return;
          await handleLoginResponse(resp, true, safeClose, requestGen);
        } catch (err) {
          if (requestGen == AuthGenerationTracker.currentAuthGen) {
            final friendly = friendlyAuthErrorMessage(err);
            authBannerMsg = friendly;
            passwordMsg = friendly;
            showToast(friendly);
          }
        }
        if (requestGen == AuthGenerationTracker.currentAuthGen) {
          curOP.value = '';
          if (context.mounted) {
            setState(() => isInProgress = false);
          }
        }
      }

      Widget thirdAuthWidget() => Obx(() {
        if (loginOptions.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final glass = CamelliaGlassTokens.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Divider(
                    height: 1,
                    thickness: 0.85,
                    color: glass.specularBottom,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    translate('or'),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Divider(
                    height: 1,
                    thickness: 0.85,
                    color: glass.specularBottom,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            LoginWidgetOP(
              ops: loginOptions
                  .map((e) => ConfigOP(op: e['name'], icon: e['icon']))
                  .toList(),
              curOP: curOP,
              cbLogin: (Map<String, dynamic> authBody, int requestGen) async {
                if (requestGen != AuthGenerationTracker.currentAuthGen) {
                  return;
                }
                LoginResponse? resp;
                try {
                  // access_token is already stored in the rust side.
                  resp = gFFI.userModel.getLoginResponseFromAuthBody(authBody);
                } catch (e) {
                  debugPrint(
                    'Failed to parse oidc login body: keys=${authBody.keys.toList()}',
                  );
                }
                if (requestGen != AuthGenerationTracker.currentAuthGen) {
                  return;
                }

                if (resp != null) {
                  await handleLoginResponse(
                    resp,
                    false,
                    safeClose,
                    requestGen,
                  );
                } else {
                  safeClose(true);
                }
              },
            ),
          ],
        );
      });

      final title = ModernDialogHeader(
        icon: CamelliaIcons.shield,
        title: translate('Login'),
        subtitle: translate('Sign in to sync devices and address book'),
        onClose: onDialogCancel,
      );

      return CustomAlertDialog(
        title: title,
        contentBoxConstraints: const BoxConstraints(
          minWidth: 360,
          maxWidth: 420,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (authBannerMsg != null && authBannerMsg!.isNotEmpty) ...[
              _AuthErrorBanner(message: authBannerMsg!),
              const SizedBox(height: 12),
            ],
            LoginWidgetUserPass(
              username: username,
              pass: password,
              usernameMsg: usernameMsg,
              passMsg: authBannerMsg != null ? null : passwordMsg,
              isInProgress: isInProgress,
              curOP: curOP,
              onLogin: onLogin,
              userFocusNode: userFocusNode,
            ),
            thirdAuthWidget(),
          ],
        ),
        onCancel: onDialogCancel,
        onSubmit: onLogin,
      );
    });

    if (res != null) {
      await UserModel.updateOtherModels();
    }

    return res;
  } finally {
    AuthGenerationTracker.invalidate();
    username.removeListener(onUsernameChanged);
    password.removeListener(onPasswordChanged);
    username.dispose();
    password.dispose();
    userFocusNode.dispose();
  }
}

@visibleForTesting
Future<bool> handleVerifyResponseStatic({
  required LoginResponse resp,
  required int verifyGen,
  void Function([bool?])? closeCallback,
  void Function(String)? onErrorText,
}) async {
  if (verifyGen != AuthGenerationTracker.currentAuthGen) return false;
  switch (resp.type) {
    case HttpType.kAuthResTypeToken:
      if (resp.access_token != null) {
        if (verifyGen != AuthGenerationTracker.currentAuthGen) return false;
        await bind.mainSetLocalOption(
          key: 'access_token',
          value: resp.access_token!,
        );
        if (verifyGen != AuthGenerationTracker.currentAuthGen) return false;
        closeCallback?.call(true);
        return true;
      }
      break;
    default:
      if (verifyGen == AuthGenerationTracker.currentAuthGen) {
        onErrorText?.call(translate('Failed, bad response from server'));
      }
      break;
  }
  return false;
}

Future<bool?> verificationCodeDialog(
  UserPayload? user,
  String? secret,
  bool isEmailVerification,
) async {
  var autoLogin = true;
  var isInProgress = false;
  String? errorText;

  final code = TextEditingController();
  final emailCtrl = TextEditingController(text: user?.email ?? '');
  bool dialogClosed = false;

  try {
    final res = await gFFI.dialogManager.show<bool>((setState, close, context) {
      void safeClose([bool? result]) {
        if (!dialogClosed) {
          dialogClosed = true;
          AuthGenerationTracker.invalidate();
          close(result);
        }
      }

      void onVerify() async {
        final verifyGen = AuthGenerationTracker.nextGen();
        if (context.mounted) {
          setState(() {
            errorText = null;
            isInProgress = true;
          });
        }

        try {
          final myId = await bind.mainGetMyId();
          if (verifyGen != AuthGenerationTracker.currentAuthGen) return;
          final myUuid = await bind.mainGetUuid();
          if (verifyGen != AuthGenerationTracker.currentAuthGen) return;
          final resp = await gFFI.userModel.login(
            LoginRequest(
              verificationCode: code.text.trim(),
              tfaCode: isEmailVerification ? null : code.text.trim(),
              secret: secret,
              username: user?.name,
              id: myId,
              uuid: myUuid,
              autoLogin: autoLogin,
              type: HttpType.kAuthReqTypeEmailCode,
            ),
          );
          if (verifyGen != AuthGenerationTracker.currentAuthGen) return;

          switch (resp.type) {
            case HttpType.kAuthResTypeToken:
              if (resp.access_token != null) {
                if (verifyGen != AuthGenerationTracker.currentAuthGen) return;
                await bind.mainSetLocalOption(
                  key: 'access_token',
                  value: resp.access_token!,
                );
                if (verifyGen != AuthGenerationTracker.currentAuthGen) return;
                safeClose(true);
                return;
              }
              break;
            default:
              errorText = translate('Failed, bad response from server');
              showToast(errorText!);
              break;
          }
        } catch (err) {
          if (verifyGen == AuthGenerationTracker.currentAuthGen) {
            errorText = friendlyAuthErrorMessage(err);
            showToast(errorText!);
          }
        }

        if (context.mounted &&
            verifyGen == AuthGenerationTracker.currentAuthGen) {
          setState(() => isInProgress = false);
        }
      }

      final codeField = isEmailVerification
          ? DialogEmailCodeField(
              controller: code,
              errorText: errorText,
              readyCallback: onVerify,
              onChanged: () {
                if (context.mounted) setState(() => errorText = null);
              },
            )
          : Dialog2FaField(
              controller: code,
              errorText: errorText,
              readyCallback: onVerify,
              onChanged: () {
                if (context.mounted) setState(() => errorText = null);
              },
            );

      VoidCallback? getOnSubmit() => codeField.isReady ? onVerify : null;

      return CustomAlertDialog(
        title: ModernDialogHeader(
          icon: CamelliaIcons.shield,
          title: translate('Verification code'),
          subtitle: translate(
            isEmailVerification
                ? 'Enter the verification code sent to your email'
                : 'Enter the 6-digit code from your authenticator app',
          ),
          onClose: safeClose,
        ),
        contentBoxConstraints: const BoxConstraints(
          minWidth: 340,
          maxWidth: 400,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isEmailVerification &&
                user?.email != null &&
                user!.email.isNotEmpty) ...[
              GlassInput(
                labelText: translate('Email'),
                prefixIcon: Icons.alternate_email_rounded,
                controller: emailCtrl,
                readOnly: true,
                showClearButton: false,
              ),
              const SizedBox(height: 12),
            ],
            codeField,
          ],
        ),
        onCancel: safeClose,
        onSubmit: getOnSubmit(),
        actions: [
          GlassButton(
            variant: GlassButtonVariant.secondary,
            minHeight: 38,
            onPressed: safeClose,
            child: Text(translate('Cancel')),
          ),
          GlassButton(
            variant: GlassButtonVariant.primary,
            loading: isInProgress,
            minHeight: 38,
            onPressed: isInProgress ? null : getOnSubmit(),
            child: Text(translate('Verify')),
          ),
        ],
      );
    });
    // For verification code, desktop updates other models in login dialog; mobile closes login dialog first.
    if (isMobile && res == true) {
      await UserModel.updateOtherModels();
    }

    return res;
  } finally {
    AuthGenerationTracker.invalidate();
    code.clear();
    code.dispose();
    emailCtrl.dispose();
  }
}

void logOutConfirmDialog() {
  gFFI.dialogManager.show((setState, close, context) {
    void submit() {
      close();
      gFFI.userModel.logOut();
    }

    return CustomAlertDialog(
      title: ModernDialogHeader.warning(
        title: translate('Logout'),
        subtitle: translate('Sign out of your account on this device'),
        onClose: close,
      ),
      content: Text(translate('logout_tip')),
      actions: [
        dialogButton('Cancel', onPressed: close, isOutline: true),
        dialogButton('OK', onPressed: submit, isDestructive: true),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}
