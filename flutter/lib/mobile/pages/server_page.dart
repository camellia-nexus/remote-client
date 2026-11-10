import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common/widgets/adaptive_layout.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_home_page.dart';
import 'package:camellia_remote_app/mobile/widgets/dialog.dart';
import 'package:camellia_remote_app/models/chat_model.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../common/widgets/dialog.dart';
import '../../consts.dart';
import '../../models/platform_model.dart';
import '../../models/server_model.dart';
import 'home_page.dart';

class ServerPage extends StatefulWidget implements PageShape {
  @override
  final title = translate("Share screen");

  @override
  final icon = const Icon(Icons.mobile_screen_share_outlined);

  @override
  final appBarActions =
      (!bind.isDisableSettings() &&
          bind.mainGetBuildinOption(key: kOptionHideSecuritySetting) != 'Y')
      ? [const ServerAccessMenuButton()]
      : [];

  ServerPage({Key? key}) : super(key: key);

  @override
  State<StatefulWidget> createState() => _ServerPageState();
}

class ServerAccessMenuButton extends StatelessWidget {
  const ServerAccessMenuButton({super.key});

  // should only have one action
  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: "",
      icon: const Icon(Icons.more_vert),
      itemBuilder: (context) {
        listTile(String text, bool checked) {
          return ListTile(
            title: Text(translate(text)),
            trailing: Icon(
              Icons.check,
              color: checked ? null : Colors.transparent,
            ),
          );
        }

        final approveMode = gFFI.serverModel.approveMode;
        final verificationMethod = gFFI.serverModel.verificationMethod;
        final showPasswordOption = approveMode != 'click';
        final isApproveModeFixed = isOptionFixed(kOptionApproveMode);
        final isNumericOneTimePasswordFixed = isOptionFixed(
          kOptionAllowNumericOneTimePassword,
        );
        final isAllowNumericOneTimePassword =
            gFFI.serverModel.allowNumericOneTimePassword;
        return [
          if (!isChangeIdDisabled())
            PopupMenuItem(
              enabled: gFFI.serverModel.connectStatus > 0,
              value: "changeID",
              child: Text(translate("Change ID")),
            ),
          if (!isChangeIdDisabled()) const PopupMenuDivider(),
          PopupMenuItem(
            value: 'AcceptSessionsViaPassword',
            child: listTile(
              'Accept sessions via password',
              approveMode == 'password',
            ),
            enabled: !isApproveModeFixed,
          ),
          PopupMenuItem(
            value: 'AcceptSessionsViaClick',
            child: listTile(
              'Accept sessions via click',
              approveMode == 'click',
            ),
            enabled: !isApproveModeFixed,
          ),
          PopupMenuItem(
            value: "AcceptSessionsViaBoth",
            child: listTile(
              "Accept sessions via both",
              approveMode != 'password' && approveMode != 'click',
            ),
            enabled: !isApproveModeFixed,
          ),
          if (showPasswordOption) const PopupMenuDivider(),
          if (showPasswordOption &&
              verificationMethod != kUseTemporaryPassword &&
              !isChangePermanentPasswordDisabled())
            PopupMenuItem(
              value: "setPermanentPassword",
              child: Text(translate("Set permanent password")),
            ),
          if (showPasswordOption && verificationMethod != kUsePermanentPassword)
            PopupMenuItem(
              value: "setTemporaryPasswordLength",
              child: Text(translate("One-time password length")),
            ),
          if (showPasswordOption && verificationMethod != kUsePermanentPassword)
            PopupMenuItem(
              value: "allowNumericOneTimePassword",
              child: listTile(
                translate("Numeric one-time password"),
                isAllowNumericOneTimePassword,
              ),
              enabled: !isNumericOneTimePasswordFixed,
            ),
          if (showPasswordOption) const PopupMenuDivider(),
          if (showPasswordOption)
            PopupMenuItem(
              value: kUseTemporaryPassword,
              child: listTile(
                'Use one-time password',
                verificationMethod == kUseTemporaryPassword,
              ),
            ),
          if (showPasswordOption)
            PopupMenuItem(
              value: kUsePermanentPassword,
              child: listTile(
                'Use permanent password',
                verificationMethod == kUsePermanentPassword,
              ),
            ),
          if (showPasswordOption)
            PopupMenuItem(
              value: kUseBothPasswords,
              child: listTile(
                'Use both passwords',
                verificationMethod != kUseTemporaryPassword &&
                    verificationMethod != kUsePermanentPassword,
              ),
            ),
        ];
      },
      onSelected: (value) async {
        if (value == "changeID") {
          changeIdDialog();
        } else if (value == "setPermanentPassword") {
          setPasswordDialog();
        } else if (value == "setTemporaryPasswordLength") {
          setTemporaryPasswordLengthDialog(gFFI.dialogManager);
        } else if (value == "allowNumericOneTimePassword") {
          gFFI.serverModel.switchAllowNumericOneTimePassword();
          gFFI.serverModel.updatePasswordModel();
        } else if (value == kUsePermanentPassword ||
            value == kUseTemporaryPassword ||
            value == kUseBothPasswords) {
          callback() {
            bind.mainSetOption(key: kOptionVerificationMethod, value: value);
            gFFI.serverModel.updatePasswordModel();
          }

          if (value == kUsePermanentPassword &&
              (await bind.mainGetCommon(key: "permanent-password-set")) !=
                  "true") {
            if (isChangePermanentPasswordDisabled()) {
              callback();
              return;
            }
            setPasswordDialog(notEmptyCallback: callback);
          } else {
            callback();
          }
        } else if (value.startsWith("AcceptSessionsVia")) {
          value = value.substring("AcceptSessionsVia".length);
          if (value == "Password") {
            gFFI.serverModel.setApproveMode('password');
          } else if (value == "Click") {
            gFFI.serverModel.setApproveMode('click');
          } else {
            gFFI.serverModel.setApproveMode(defaultOptionApproveMode);
          }
        }
      },
    );
  }
}

class _ServerPageState extends State<ServerPage> {
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: gFFI.serverModel.controller,
      child: const AdaptiveContent(
        maxWidth: 760,
        child: ServerWorkspaceSection(),
      ),
    );
  }
}

/// Embeddable incoming-access area used by the single mobile workspace.
class ServerWorkspaceSection extends StatefulWidget {
  const ServerWorkspaceSection({super.key});

  @override
  State<ServerWorkspaceSection> createState() => _ServerWorkspaceSectionState();
}

class _ServerWorkspaceSectionState extends State<ServerWorkspaceSection> {
  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    _updateTimer = periodic_immediate(const Duration(seconds: 3), () async {
      await gFFI.serverModel.fetchID();
    });
    gFFI.serverModel.checkAndroidPermission();
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    checkService();
    return ChangeNotifierProvider.value(
      value: gFFI.serverModel,
      child: Consumer<ServerModel>(
        builder: (context, serverModel, child) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              buildPresetPasswordWarningMobile(),
              AppStateTransition(
                stateKey: serverModel.isStart,
                child: serverModel.isStart
                    ? ServerInfo()
                    : ServiceNotRunningNotification(),
              ),
              const ConnectionManager(),
              const PermissionChecker(),
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }
}

void checkService() async {
  gFFI.invokeMethod("check_service");
  // for Android 10/11, request MANAGE_EXTERNAL_STORAGE permission from system setting page
  if (AndroidPermissionManager.isWaitingFile() && !gFFI.serverModel.fileOk) {
    AndroidPermissionManager.complete(
      kManageExternalStorage,
      await AndroidPermissionManager.check(kManageExternalStorage),
    );
    debugPrint("file permission finished");
  }
}

class ServiceNotRunningNotification extends StatelessWidget {
  ServiceNotRunningNotification({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final serverModel = Provider.of<ServerModel>(context);

    final warning = AppVisual.tone(context, AppTone.warning);
    return PaddingCard(
      title: translate("Service is not running"),
      titleIcon: Icon(Icons.warning_amber_rounded, color: warning),
      tone: AppTone.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            translate("android_start_service_tip"),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: AppVisual.subduedText(context),
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow_rounded),
            onPressed: serverModel.toggleService,
            label: Text(translate("Start service")),
          ),
        ],
      ),
    );
  }
}

class ServerInfo extends StatelessWidget {
  final model = gFFI.serverModel;

  ServerInfo({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final serverModel = Provider.of<ServerModel>(context);

    void copyToClipboard(String value) {
      Clipboard.setData(ClipboardData(text: value));
      showToast(translate('Copied'));
    }

    Widget connectionState() {
      if (serverModel.connectStatus == -1) {
        return AppStatusPill(
          label: translate('not_ready_status'),
          color: AppVisual.tone(context, AppTone.danger),
          icon: Icons.error_outline_rounded,
        );
      } else if (serverModel.connectStatus == 0) {
        return AppStatusPill(
          label: translate('connecting_status'),
          color: AppVisual.tone(context, AppTone.info),
          icon: Icons.sync_rounded,
          busy: true,
        );
      } else {
        return AppStatusPill(
          label: translate('Ready'),
          color: AppVisual.tone(context, AppTone.success),
          icon: Icons.check_circle_outline_rounded,
        );
      }
    }

    final showOneTime =
        serverModel.approveMode != 'click' &&
        serverModel.verificationMethod != kUsePermanentPassword;
    return PaddingCard(
      title: translate('Your Device'),
      titleIcon: Icon(
        Icons.devices_rounded,
        color: Theme.of(context).colorScheme.primary,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(alignment: Alignment.centerLeft, child: connectionState()),
          const SizedBox(height: 14),
          _CredentialRow(
            icon: Icons.fingerprint_rounded,
            label: translate('ID'),
            value: model.serverId.value.text,
            actions: [
              IconButton(
                tooltip: translate('Copy to clipboard'),
                icon: const Icon(Icons.copy_outlined),
                onPressed: () =>
                    copyToClipboard(model.serverId.value.text.trim()),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _CredentialRow(
            icon: Icons.key_rounded,
            label: translate('One-time Password'),
            value: showOneTime ? model.serverPasswd.value.text : '-',
            tone: AppTone.warning,
            actions: showOneTime
                ? [
                    IconButton(
                      tooltip: translate('Refresh'),
                      icon: const Icon(Icons.refresh_rounded),
                      onPressed: bind.mainUpdateTemporaryPassword,
                    ),
                    IconButton(
                      tooltip: translate('Copy to clipboard'),
                      icon: const Icon(Icons.copy_outlined),
                      onPressed: () =>
                          copyToClipboard(model.serverPasswd.value.text.trim()),
                    ),
                  ]
                : const [],
          ),
        ],
      ),
    );
  }
}

class _CredentialRow extends StatelessWidget {
  const _CredentialRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.actions,
    this.tone = AppTone.info,
  });

  final IconData icon;
  final String label;
  final String value;
  final List<Widget> actions;
  final AppTone tone;

  @override
  Widget build(BuildContext context) {
    final color = AppVisual.tone(context, tone);
    return AppSurface(
      color: AppVisual.toneContainer(context, tone),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, color: color, size: 21),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.labelMedium),
                const SizedBox(height: 2),
                SelectableText(
                  value,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
          if (actions.isNotEmpty) ...actions,
        ],
      ),
    );
  }
}

class PermissionChecker extends StatefulWidget {
  const PermissionChecker({Key? key}) : super(key: key);

  @override
  State<PermissionChecker> createState() => _PermissionCheckerState();
}

class _PermissionCheckerState extends State<PermissionChecker> {
  @override
  Widget build(BuildContext context) {
    final serverModel = Provider.of<ServerModel>(context);
    final hasAudioPermission = androidVersion >= 30;
    final hideStopService =
        isAndroid &&
        bind.mainGetBuildinOption(key: kOptionHideStopService) == 'Y';
    final allowPermChangeInAcceptWindow = option2bool(
      kOptionEnablePermChangeInAcceptWindow,
      bind.mainGetBuildinOption(key: kOptionEnablePermChangeInAcceptWindow),
    );
    final permissionChangeLocked =
        isAndroid &&
        serverModel.clients.any((c) => !c.disconnected) &&
        !allowPermChangeInAcceptWindow;
    return PaddingCard(
      title: translate("Permissions"),
      titleIcon: Icon(
        Icons.admin_panel_settings_outlined,
        color: AppVisual.tone(context, AppTone.secondary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          serverModel.mediaOk && !hideStopService
              ? FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppVisual.tone(context, AppTone.danger),
                  ),
                  icon: const Icon(Icons.stop_rounded),
                  onPressed: serverModel.toggleService,
                  label: Text(translate("Stop service")),
                ).marginOnly(bottom: 12)
              : SizedBox.shrink(),
          if (!hideStopService || !serverModel.mediaOk)
            PermissionRow(
              translate("Screen Capture"),
              serverModel.mediaOk,
              serverModel.toggleService,
            ),
          PermissionRow(
            translate("Input Control"),
            serverModel.inputOk,
            serverModel.toggleInput,
          ),
          PermissionRow(
            translate("Transfer file"),
            serverModel.fileOk,
            serverModel.toggleFile,
            enabled: !permissionChangeLocked,
          ),
          hasAudioPermission
              ? PermissionRow(
                  translate("Audio Capture"),
                  serverModel.audioOk,
                  serverModel.toggleAudio,
                  enabled: !permissionChangeLocked,
                )
              : Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: AppVisual.tone(context, AppTone.info),
                    ).marginOnly(right: 15),
                    Expanded(
                      child: Text(
                        translate("android_version_audio_tip"),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
          PermissionRow(
            translate("Enable clipboard"),
            serverModel.clipboardOk,
            serverModel.toggleClipboard,
            enabled: !permissionChangeLocked,
          ),
        ],
      ),
    );
  }
}

class PermissionRow extends StatelessWidget {
  const PermissionRow(
    this.name,
    this.isOk,
    this.onPressed, {
    Key? key,
    this.enabled = true,
  }) : super(key: key);

  final String name;
  final bool isOk;
  final VoidCallback onPressed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      visualDensity: VisualDensity.compact,
      contentPadding: EdgeInsets.zero,
      title: Text(name),
      value: isOk,
      onChanged: enabled ? (_) => onPressed() : null,
    );
  }
}

class ConnectionManager extends StatelessWidget {
  const ConnectionManager({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final serverModel = Provider.of<ServerModel>(context);
    return Column(
      children: serverModel.clients
          .map(
            (client) => PaddingCard(
              title: translate(
                client.isFileTransfer ? "Transfer file" : "Share screen",
              ),
              titleIcon: client.isFileTransfer
                  ? Icon(Icons.folder_outlined)
                  : Icon(Icons.mobile_screen_share),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(child: ClientInfo(client)),
                      Expanded(
                        flex: -1,
                        child: client.isFileTransfer || !client.authorized
                            ? const SizedBox.shrink()
                            : IconButton(
                                onPressed: () {
                                  gFFI.chatModel.changeCurrentKey(
                                    MessageKey(client.peerId, client.id),
                                  );
                                  HomePage.homeKey.currentState
                                      ?.selectChatPage();
                                },
                                icon: unreadTopRightBuilder(
                                  client.unreadChatMessageCount,
                                ),
                              ),
                      ),
                    ],
                  ),
                  client.authorized
                      ? const SizedBox.shrink()
                      : Text(
                          translate("android_new_connection_tip"),
                          style: Theme.of(context).textTheme.bodyMedium,
                        ).marginOnly(bottom: 5),
                  client.authorized
                      ? _buildDisconnectButton(context, client)
                      : _buildNewConnectionHint(context, serverModel, client),
                  if (client.incomingVoiceCall && !client.inVoiceCall)
                    ..._buildNewVoiceCallHint(context, serverModel, client),
                ],
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildDisconnectButton(BuildContext context, Client client) {
    final disconnectButton = FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: AppVisual.tone(context, AppTone.danger),
      ),
      icon: const Icon(Icons.close_rounded),
      onPressed: () {
        bind.cmCloseConnection(connId: client.id);
        gFFI.invokeMethod("cancel_notification", client.id);
      },
      label: Text(translate("Disconnect")),
    );
    final buttons = [disconnectButton];
    if (client.inVoiceCall) {
      buttons.insert(
        0,
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: AppVisual.tone(context, AppTone.danger),
          ),
          icon: const Icon(Icons.phone),
          label: Text(translate("Stop")),
          onPressed: () {
            bind.cmCloseVoiceCall(id: client.id);
            gFFI.invokeMethod("cancel_notification", client.id);
          },
        ),
      );
    }

    return Align(
      alignment: Alignment.centerRight,
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 10,
        runSpacing: 8,
        children: buttons,
      ),
    );
  }

  Widget _buildNewConnectionHint(
    BuildContext context,
    ServerModel serverModel,
    Client client,
  ) {
    return Align(
      alignment: Alignment.centerRight,
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 10,
        runSpacing: 8,
        children: [
          TextButton(
            child: Text(translate("Dismiss")),
            onPressed: () {
              serverModel.sendLoginResponse(client, false);
            },
          ),
          if (serverModel.approveMode != 'password')
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppVisual.tone(context, AppTone.success),
              ),
              icon: const Icon(Icons.check),
              label: Text(translate("Accept")),
              onPressed: () {
                serverModel.sendLoginResponse(client, true);
              },
            ),
        ],
      ),
    );
  }

  List<Widget> _buildNewVoiceCallHint(
    BuildContext context,
    ServerModel serverModel,
    Client client,
  ) {
    return [
      Text(
        translate("android_new_voice_call_tip"),
        style: Theme.of(context).textTheme.bodyMedium,
      ).marginOnly(bottom: 5),
      Align(
        alignment: Alignment.centerRight,
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: 10,
          runSpacing: 8,
          children: [
            TextButton(
              child: Text(translate("Dismiss")),
              onPressed: () {
                serverModel.handleVoiceCall(client, false);
              },
            ),
            if (serverModel.approveMode != 'password')
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppVisual.tone(context, AppTone.success),
                ),
                icon: const Icon(Icons.check),
                label: Text(translate("Accept")),
                onPressed: () {
                  serverModel.handleVoiceCall(client, true);
                },
              ),
          ],
        ),
      ),
    ];
  }
}

class PaddingCard extends StatelessWidget {
  const PaddingCard({
    Key? key,
    required this.child,
    this.title,
    this.titleIcon,
    this.tone,
  }) : super(key: key);

  final String? title;
  final Icon? titleIcon;
  final Widget child;
  final AppTone? tone;

  @override
  Widget build(BuildContext context) {
    final children = [child];
    if (title != null) {
      children.insert(
        0,
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 5, 0, 8),
          child: Row(
            children: [
              titleIcon?.marginOnly(right: 10) ?? const SizedBox.shrink(),
              Expanded(
                child: Text(
                  title!,
                  style: Theme.of(context).textTheme.titleLarge?.merge(
                    TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return SizedBox(
      width: double.maxFinite,
      child: AppSurface(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
        elevated: tone != null,
        color: tone == null
            ? null
            : Color.alphaBlend(
                AppVisual.tone(context, tone!).withValues(alpha: 0.035),
                AppVisual.raisedSurface(context),
              ),
        child: Column(children: children),
      ),
    );
  }
}

class ClientInfo extends StatelessWidget {
  final Client client;
  ClientInfo(this.client);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                flex: -1,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _buildAvatar(context),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      client.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      client.peerId,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(BuildContext context) {
    final fallback = CircleAvatar(
      backgroundColor: str2color(
        client.name,
        Theme.of(context).brightness == Brightness.light ? 255 : 150,
      ),
      child: Text(client.name.isNotEmpty ? client.name[0] : '?'),
    );
    return buildAvatarWidget(
          avatar: client.avatar,
          size: 40,
          fallback: fallback,
        ) ??
        fallback;
  }
}

void androidChannelInit() {
  gFFI.setMethodCallHandler((method, arguments) {
    debugPrint("flutter got android msg,$method,$arguments");
    try {
      switch (method) {
        case "start_capture":
          {
            gFFI.dialogManager.dismissAll();
            gFFI.serverModel.updateClientState();
            break;
          }
        case "on_state_changed":
          {
            var name = arguments["name"] as String;
            var value = arguments["value"] as String == "true";
            debugPrint("from jvm:on_state_changed,$name:$value");
            gFFI.serverModel.changeStatue(name, value);
            break;
          }
        case "on_android_permission_result":
          {
            var type = arguments["type"] as String;
            var result = arguments["result"] as bool;
            var requestId = arguments["request_id"] as String?;
            AndroidPermissionManager.complete(type, result, requestId: requestId);
            break;
          }
        case "on_media_projection_canceled":
          {
            gFFI.serverModel.stopService();
            break;
          }
        case "msgbox":
          {
            var type = arguments["type"] as String;
            var title = arguments["title"] as String;
            var text = arguments["text"] as String;
            var link = (arguments["link"] ?? '') as String;
            msgBox(gFFI.sessionId, type, title, text, link, gFFI.dialogManager);
            break;
          }
        case "stop_service":
          {
            print(
              "stop_service by kotlin, isStart:${gFFI.serverModel.isStart}",
            );
            gFFI.serverModel.stopService();
            break;
          }
      }
    } catch (e) {
      debugPrintStack(label: "MethodCallHandler err:$e");
    }
    return "";
  });
}
