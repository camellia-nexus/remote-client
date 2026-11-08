import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/hbbs/hbbs.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/models/user_model.dart';
import 'package:get/get.dart';
import 'package:flutter_svg/flutter_svg.dart';
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
      return _OidcProviderBranding(label: 'Microsoft', iconKey: 'microsoft');
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
    Key? key,
    required this.op,
    required this.icon,
    this.margin = const EdgeInsets.symmetric(horizontal: 4.0),
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final svgFile = kOpSvgList.contains(op.toLowerCase())
        ? op.toLowerCase()
        : 'default';
    return Container(
      margin: margin,
      child: icon == null
          ? SvgPicture.asset('assets/auth-$svgFile.svg', width: 20)
          : SvgPicture.string(icon!, width: 20),
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
    Key? key,
    required this.op,
    required this.curOP,
    required this.icon,
    required this.primaryColor,
    required this.height,
    required this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final branding = _oidcProviderBranding(op);
    final buttonLabel = translate("Continue with {${branding.label}}");
    return Row(
      children: [
        Container(
          height: height,
          width: 200,
          child: Obx(
            () => ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: curOP.value.isEmpty || curOP.value == op
                    ? primaryColor
                    : Colors.grey,
              ).copyWith(elevation: ButtonStyleButton.allOrNull(0.0)),
              onPressed: curOP.value.isEmpty
                  ? onTap
                  : null,
              child: Row(
                children: [
                  SizedBox(
                    width: 30,
                    child: _IconOP(
                      op: branding.iconKey,
                      icon: icon,
                      margin: EdgeInsets.only(right: 5),
                    ),
                  ),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Center(child: Text(buttonLabel)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
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
    Key? key,
    required this.config,
    required this.curOP,
    required this.cbLogin,
  }) : super(key: key);

  @override
  State<StatefulWidget> createState() {
    return _WidgetOPState();
  }
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

  _beginQueryState(int requestGen) {
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

  _updateState(int requestGen, int myAttemptGen) {
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
      final String stateMsg = resultMap['state_msg'];
      String failedMsg = resultMap['failed_msg'];
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
            }
          });
        }
      }
    }).catchError((e) {
      _queryInFlight = false;
      debugPrint('OIDC query failed: $e');
    });
  }

  _resetState() {
    _stateMsg = '';
    _failedMsg = '';
    _url = '';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ButtonOP(
          op: widget.config.op,
          curOP: widget.curOP,
          icon: widget.config.icon,
          primaryColor: str2color(widget.config.op, 0x7f),
          height: 36,
          onTap: () async {
            if (widget.curOP.value.isNotEmpty) return;
            _resetState();
            final requestGen = AuthGenerationTracker.nextGen();
            widget.curOP.value = widget.config.op;
            try {
              await bind.mainAccountAuth(op: widget.config.op, rememberMe: true);
              if (requestGen != AuthGenerationTracker.currentAuthGen || !mounted) {
                return;
              }
              _beginQueryState(requestGen);
            } catch (e) {
              if (requestGen != AuthGenerationTracker.currentAuthGen) return;
              widget.curOP.value = '';
              if (mounted) {
                setState(() {
                  _failedMsg = e.toString();
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
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (_stateMsg.isNotEmpty && _failedMsg.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: SelectableText(
                      translate(_stateMsg),
                      style: DefaultTextStyle.of(
                        context,
                      ).style.copyWith(fontSize: 12),
                    ),
                  ),
                if (_failedMsg.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Builder(
                      builder: (context) {
                        final errorColor = Theme.of(context).colorScheme.error;
                        final bgColor = Theme.of(
                          context,
                        ).colorScheme.errorContainer.withValues(alpha: 0.3);
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8.0,
                            vertical: 6.0,
                          ),
                          decoration: BoxDecoration(
                            color: bgColor,
                            borderRadius: BorderRadius.circular(4.0),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.error_outline,
                                color: errorColor,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: SelectableText(
                                  translate(_failedMsg),
                                  style: DefaultTextStyle.of(context).style
                                      .copyWith(
                                        fontSize: 13,
                                        color: errorColor,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        }),
        Obx(
          () => Offstage(
            offstage: widget.curOP.value != widget.config.op,
            child: const SizedBox(height: 5.0),
          ),
        ),
        Obx(
          () => Offstage(
            offstage: widget.curOP.value != widget.config.op,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: 20),
              child: ElevatedButton(
                onPressed: () {
                  _attemptGen++;
                  widget.curOP.value = '';
                  _updateTimer?.cancel();
                  _updateTimer = null;
                  _resetState();
                  AuthGenerationTracker.invalidate();
                  bind.mainAccountAuthCancel();
                },
                child: Text(
                  translate('Cancel'),
                  style: TextStyle(fontSize: 15),
                ),
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

  LoginWidgetOP({
    Key? key,
    required this.ops,
    required this.curOP,
    required this.cbLogin,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var children = ops
        .map(
          (op) => [
            WidgetOP(config: op, curOP: curOP, cbLogin: cbLogin),
            const Divider(indent: 5, endIndent: 5),
          ],
        )
        .expand((i) => i)
        .toList();
    if (children.isNotEmpty) {
      children.removeLast();
    }
    return SingleChildScrollView(
      child: Container(
        width: 200,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: children,
        ),
      ),
    );
  }
}

class LoginWidgetUserPass extends StatelessWidget {
  final TextEditingController username;
  final TextEditingController pass;
  final String? usernameMsg;
  final String? passMsg;
  final bool isInProgress;
  final RxString curOP;
  final Function() onLogin;
  final FocusNode? userFocusNode;
  const LoginWidgetUserPass({
    Key? key,
    this.userFocusNode,
    required this.username,
    required this.pass,
    required this.usernameMsg,
    required this.passMsg,
    required this.isInProgress,
    required this.curOP,
    required this.onLogin,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 8.0),
          DialogTextField(
            title: translate(DialogTextField.kUsernameTitle),
            controller: username,
            focusNode: userFocusNode,
            prefixIcon: DialogTextField.kUsernameIcon,
            errorText: usernameMsg,
          ),
          PasswordWidget(
            controller: pass,
            autoFocus: false,
            reRequestFocus: true,
            errorText: passMsg,
          ),
          // NOT use Offstage to wrap LinearProgressIndicator
          if (isInProgress) const LinearProgressIndicator(),
          const SizedBox(height: 12.0),
          FittedBox(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  height: 38,
                  width: 200,
                  child: Obx(
                    () => ElevatedButton(
                      child: Text(
                        translate('Login'),
                        style: TextStyle(fontSize: 16),
                      ),
                      onPressed:
                          curOP.value.isEmpty || curOP.value == 'rustdesk'
                          ? () {
                              onLogin();
                            }
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
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
          onPasswordMsg?.call("Failed, bad tfa type from server");
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
        onPasswordMsg?.call("Failed, bad response from server");
      }
      break;
  }
  return false;
}

// call this directly
Future<bool?> loginDialog() async {
  var username = TextEditingController(
    text: UserModel.getLocalUserInfo()?['name'] ?? '',
  );
  var password = TextEditingController();
  final userFocusNode = FocusNode()..requestFocus();
  Timer(const Duration(milliseconds: 100), () => userFocusNode.requestFocus());

  String? usernameMsg;
  String? passwordMsg;
  var isInProgress = false;
  final RxString curOP = ''.obs;
  // Track hover state for the close icon
  bool isCloseHovered = false;

  void Function(void Function())? dialogSetState;
  void onUsernameChanged() {
    if (usernameMsg != null) {
      dialogSetState?.call(() => usernameMsg = null);
    }
  }

  void onPasswordChanged() {
    if (passwordMsg != null) {
      dialogSetState?.call(() => passwordMsg = null);
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

      onDialogCancel() {
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
            passwordMsg = msg;
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

      onLogin() async {
        // validate
        if (username.text.isEmpty) {
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
          setState(() => isInProgress = true);
        }
        try {
          final myId = await bind.mainGetMyId();
          if (requestGen != AuthGenerationTracker.currentAuthGen) return;
          final myUuid = await bind.mainGetUuid();
          if (requestGen != AuthGenerationTracker.currentAuthGen) return;
          final resp = await gFFI.userModel.login(
            LoginRequest(
              username: username.text,
              password: password.text,
              id: myId,
              uuid: myUuid,
              autoLogin: true,
              type: HttpType.kAuthReqTypeAccount,
            ),
          );
          if (requestGen != AuthGenerationTracker.currentAuthGen) return;
          await handleLoginResponse(resp, true, safeClose, requestGen);
        } on RequestException catch (err) {
          if (requestGen == AuthGenerationTracker.currentAuthGen) {
            passwordMsg = translate(err.cause);
          }
        } catch (err) {
          if (requestGen == AuthGenerationTracker.currentAuthGen) {
            passwordMsg = "Unknown Error: $err";
          }
        }
        if (requestGen == AuthGenerationTracker.currentAuthGen) {
          curOP.value = '';
          if (context.mounted) {
            setState(() => isInProgress = false);
          }
        }
      }

      thirdAuthWidget() => Obx(() {
        return Offstage(
          offstage: loginOptions.isEmpty,
          child: Column(
            children: [
              const SizedBox(height: 8.0),
              Center(
                child: Text(translate('or'), style: TextStyle(fontSize: 16)),
              ),
              const SizedBox(height: 8.0),
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
                    resp = gFFI.userModel.getLoginResponseFromAuthBody(
                      authBody,
                    );
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
          ),
        );
      });

      final title = Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(translate('Login')).marginOnly(top: MyTheme.dialogPadding),
          MouseRegion(
            onEnter: (_) {
              if (context.mounted) {
                setState(() => isCloseHovered = true);
              }
            },
            onExit: (_) {
              if (context.mounted) {
                setState(() => isCloseHovered = false);
              }
            },
            child: InkWell(
              child: Icon(
                Icons.close,
                size: 25,
                // No need to handle the branch of null.
                // Because we can ensure the color is not null when debug.
                color: isCloseHovered
                    ? Colors.white
                    : Theme.of(
                        context,
                      ).textTheme.titleLarge?.color?.withValues(alpha: 0.55),
              ),
              onTap: onDialogCancel,
              hoverColor: Colors.red,
              borderRadius: BorderRadius.circular(5),
            ),
          ).marginOnly(top: 10, right: 15),
        ],
      );
      final titlePadding = EdgeInsets.fromLTRB(MyTheme.dialogPadding, 0, 0, 0);

      return CustomAlertDialog(
        title: title,
        titlePadding: titlePadding,
        contentBoxConstraints: BoxConstraints(minWidth: 400),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 8.0),
            LoginWidgetUserPass(
              username: username,
              pass: password,
              usernameMsg: usernameMsg,
              passMsg: passwordMsg,
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
        onErrorText?.call("Failed, bad response from server");
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
  bool dialogClosed = false;

  try {
    final res = await gFFI.dialogManager.show<bool>((setState, close, context) {
      safeClose([bool? result]) {
        if (!dialogClosed) {
          dialogClosed = true;
          AuthGenerationTracker.invalidate();
          close(result);
        }
      }

      void onVerify() async {
        final verifyGen = AuthGenerationTracker.nextGen();
        if (context.mounted) {
          setState(() => isInProgress = true);
        }

        try {
          final myId = await bind.mainGetMyId();
          if (verifyGen != AuthGenerationTracker.currentAuthGen) return;
          final myUuid = await bind.mainGetUuid();
          if (verifyGen != AuthGenerationTracker.currentAuthGen) return;
          final resp = await gFFI.userModel.login(
            LoginRequest(
              verificationCode: code.text,
              tfaCode: isEmailVerification ? null : code.text,
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
              errorText = "Failed, bad response from server";
              break;
          }
        } on RequestException catch (err) {
          if (verifyGen == AuthGenerationTracker.currentAuthGen) {
            errorText = translate(err.cause);
          }
        } catch (err) {
          if (verifyGen == AuthGenerationTracker.currentAuthGen) {
            errorText = "Unknown Error: $err";
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
              onChanged: () => errorText = null,
            )
          : Dialog2FaField(
              controller: code,
              errorText: errorText,
              readyCallback: onVerify,
              onChanged: () => errorText = null,
            );

      getOnSubmit() => codeField.isReady ? onVerify : null;

      return CustomAlertDialog(
        title: Text(translate("Verification code")),
        contentBoxConstraints: BoxConstraints(maxWidth: 300),
        content: Column(
          children: [
            Offstage(
              offstage: !isEmailVerification || user?.email == null,
              child: TextField(
                decoration: InputDecoration(
                  labelText: "Email",
                  prefixIcon: Icon(Icons.email),
                ),
                readOnly: true,
                controller: TextEditingController(text: user?.email),
              ).workaroundFreezeLinuxMint(),
            ),
            isEmailVerification ? const SizedBox(height: 8) : const Offstage(),
            codeField,
            /*
              CheckboxListTile(
                contentPadding: const EdgeInsets.all(0),
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: Row(children: [
                  Expanded(child: Text(translate("Trust this device")))
                ]),
                value: trustThisDevice,
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => trustThisDevice = !trustThisDevice);
                },
              ),
              */
            // NOT use Offstage to wrap LinearProgressIndicator
            if (isInProgress) const LinearProgressIndicator(),
          ],
        ),
        onCancel: safeClose,
        onSubmit: getOnSubmit(),
        actions: [
          dialogButton("Cancel", onPressed: safeClose, isOutline: true),
          dialogButton("Verify", onPressed: getOnSubmit()),
        ],
      );
    });
    // For verification code, desktop update other models in login dialog, mobile need to close login dialog first,
    // otherwise the soft keyboard will jump out on each key press, so mobile update in verification code dialog.
    if (isMobile && res == true) {
      await UserModel.updateOtherModels();
    }

    return res;
  } finally {
    AuthGenerationTracker.invalidate();
    code.clear();
    code.dispose();
  }
}

void logOutConfirmDialog() {
  gFFI.dialogManager.show((setState, close, context) {
    submit() {
      close();
      gFFI.userModel.logOut();
    }

    return CustomAlertDialog(
      content: Text(translate("logout_tip")),
      actions: [
        dialogButton(translate("Cancel"), onPressed: close, isOutline: true),
        dialogButton(translate("OK"), onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}
