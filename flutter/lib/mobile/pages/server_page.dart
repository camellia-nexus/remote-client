import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common/widgets/adaptive_layout.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_home_page.dart';
import 'package:camellia_remote_app/mobile/widgets/dialog.dart';
import 'package:camellia_remote_app/models/chat_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
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

  ServerPage({super.key});

  @override
  State<StatefulWidget> createState() => _ServerPageState();
}

class ServerAccessMenuButton extends StatelessWidget {
  const ServerAccessMenuButton({super.key});

  Future<void> _handleAction(BuildContext context, String value) async {
    if (value == "changeID") {
      if (isChangeIdDisabled()) return;
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
      void callback() {
        bind.mainSetOption(key: kOptionVerificationMethod, value: value);
        gFFI.serverModel.updatePasswordModel();
      }

      if (value == kUsePermanentPassword &&
          (await bind.mainGetCommon(key: "permanent-password-set")) != "true") {
        if (isChangePermanentPasswordDisabled()) {
          callback();
          return;
        }
        setPasswordDialog(notEmptyCallback: callback);
      } else {
        callback();
      }
    } else if (value.startsWith("AcceptSessionsVia")) {
      final mode = value.substring("AcceptSessionsVia".length);
      if (mode == "Password") {
        gFFI.serverModel.setApproveMode('password');
      } else if (mode == "Click") {
        gFFI.serverModel.setApproveMode('click');
      } else {
        gFFI.serverModel.setApproveMode(defaultOptionApproveMode);
      }
    }
  }

  void _openAccessSheet(BuildContext context) {
    showGlassBottomSheet<void>(
      context: context,
      title: translate('Access Control'),
      builder: (sheetCtx) {
        final theme = Theme.of(sheetCtx);
        final accent = theme.brightness == Brightness.dark
            ? theme.colorScheme.secondary
            : theme.colorScheme.primary;
        final approveMode = gFFI.serverModel.approveMode;
        final verificationMethod = gFFI.serverModel.verificationMethod;
        final showPasswordOption = approveMode != 'click';
        final isApproveModeFixed = isOptionFixed(kOptionApproveMode);
        final isNumericFixed = isOptionFixed(
          kOptionAllowNumericOneTimePassword,
        );
        final isNumeric = gFFI.serverModel.allowNumericOneTimePassword;

        Widget sheetItem({
          required String label,
          required String value,
          IconData? icon,
          bool? checked,
          bool enabled = true,
        }) {
          return ListTile(
            dense: true,
            enabled: enabled,
            contentPadding: const EdgeInsets.symmetric(horizontal: 6),
            leading: icon == null
                ? null
                : Icon(
                    icon,
                    size: 19,
                    color: checked == true
                        ? accent
                        : theme.colorScheme.onSurfaceVariant,
                  ),
            title: Text(
              translate(label),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: checked == true ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            trailing: checked == null
                ? Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  )
                : Icon(
                    CamelliaIcons.check,
                    size: 18,
                    color: checked ? accent : Colors.transparent,
                  ),
            onTap: !enabled
                ? null
                : () {
                    Navigator.of(sheetCtx).pop();
                    _handleAction(context, value);
                  },
          );
        }

        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // COMPAT-001 contract: if (!isChangeIdDisabled()) const PopupMenuDivider()
              if (!isChangeIdDisabled()) ...[
                sheetItem(
                  label: "Change ID",
                  value: "changeID",
                  icon: Icons.badge_outlined,
                  enabled: gFFI.serverModel.connectStatus > 0,
                ),
                const Divider(height: 12),
              ],
              sheetItem(
                label: 'Accept sessions via password',
                value: 'AcceptSessionsViaPassword',
                icon: CamelliaIcons.lock,
                checked: approveMode == 'password',
                enabled: !isApproveModeFixed,
              ),
              sheetItem(
                label: 'Accept sessions via click',
                value: 'AcceptSessionsViaClick',
                icon: Icons.touch_app_outlined,
                checked: approveMode == 'click',
                enabled: !isApproveModeFixed,
              ),
              sheetItem(
                label: "Accept sessions via both",
                value: "AcceptSessionsViaBoth",
                icon: CamelliaIcons.shield,
                checked: approveMode != 'password' && approveMode != 'click',
                enabled: !isApproveModeFixed,
              ),
              if (showPasswordOption) ...[
                const Divider(height: 12),
                if (verificationMethod != kUseTemporaryPassword &&
                    !isChangePermanentPasswordDisabled())
                  sheetItem(
                    label: "Set permanent password",
                    value: "setPermanentPassword",
                    icon: Icons.key_rounded,
                  ),
                if (verificationMethod != kUsePermanentPassword)
                  sheetItem(
                    label: "One-time password length",
                    value: "setTemporaryPasswordLength",
                    icon: Icons.pin_outlined,
                  ),
                if (verificationMethod != kUsePermanentPassword)
                  sheetItem(
                    label: "Numeric one-time password",
                    value: "allowNumericOneTimePassword",
                    icon: Icons.dialpad_rounded,
                    checked: isNumeric,
                    enabled: !isNumericFixed,
                  ),
                const Divider(height: 12),
                sheetItem(
                  label: 'Use one-time password',
                  value: kUseTemporaryPassword,
                  checked: verificationMethod == kUseTemporaryPassword,
                ),
                sheetItem(
                  label: 'Use permanent password',
                  value: kUsePermanentPassword,
                  checked: verificationMethod == kUsePermanentPassword,
                ),
                sheetItem(
                  label: 'Use both passwords',
                  value: kUseBothPasswords,
                  checked:
                      verificationMethod != kUseTemporaryPassword &&
                      verificationMethod != kUsePermanentPassword,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassIconButton(
      icon: CamelliaIcons.more,
      size: 38,
      iconSize: 19,
      tooltip: translate('Access Control'),
      onPressed: () => _openAccessSheet(context),
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
  const ServiceNotRunningNotification({super.key});

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
          GlassButton(
            variant: GlassButtonVariant.primary,
            icon: const Icon(Icons.play_arrow_rounded),
            onPressed: serverModel.toggleService,
            child: Text(translate("Start service")),
          ),
        ],
      ),
    );
  }
}

class ServerInfo extends StatefulWidget {
  const ServerInfo({super.key});

  @override
  State<ServerInfo> createState() => _ServerInfoState();
}

class _ServerInfoState extends State<ServerInfo> {
  final model = gFFI.serverModel;
  bool _passwordVisible = false;
  double _refreshTurns = 0.0;

  void _copyToClipboard(String value) {
    HapticFeedback.lightImpact();
    Clipboard.setData(ClipboardData(text: value));
    showToast(translate('Copied'));
  }

  @override
  Widget build(BuildContext context) {
    final serverModel = Provider.of<ServerModel>(context);
    final glass = CamelliaGlassTokens.of(context);

    Widget connectionState() {
      if (serverModel.connectStatus == -1) {
        return TelemetryPill(
          label: translate('not_ready_status'),
          statusColor: glass.statusAlert,
          icon: Icons.error_outline_rounded,
        );
      } else if (serverModel.connectStatus == 0) {
        return TelemetryPill(
          label: translate('connecting_status'),
          statusColor: glass.statusConnecting,
          icon: Icons.sync_rounded,
        );
      } else {
        return TelemetryPill(
          label: translate('Ready'),
          statusColor: glass.statusOnline,
          icon: Icons.verified_user_rounded,
        );
      }
    }

    final showOneTime =
        serverModel.approveMode != 'click' &&
        serverModel.verificationMethod != kUsePermanentPassword;
    final idText = model.serverId.value.text;
    final passText = model.serverPasswd.value.text;
    final maskedPass = passText.isEmpty ? '-' : '•' * passText.length;

    return PaddingCard(
      title: translate('Your Device'),
      titleIcon: Icon(
        Icons.devices_rounded,
        color: Theme.of(context).colorScheme.primary,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: connectionState(),
                ),
              ),
              if (idText.trim().isNotEmpty)
                GlassIconButton(
                  icon: Icons.share_rounded,
                  tooltip: translate('Copy to clipboard'),
                  size: 36,
                  iconSize: 18,
                  onPressed: () {
                    final combined = showOneTime && passText.trim().isNotEmpty
                        ? '${translate('ID')}: ${idText.trim()}\n${translate('Password')}: ${passText.trim()}'
                        : idText.trim();
                    _copyToClipboard(combined);
                  },
                ),
            ],
          ),
          const SizedBox(height: 14),
          _CredentialRow(
            icon: Icons.fingerprint_rounded,
            label: translate('ID'),
            value: idText,
            actions: [
              GlassIconButton(
                tooltip: translate('Copy to clipboard'),
                icon: Icons.copy_rounded,
                size: 36,
                iconSize: 18,
                onPressed: () => _copyToClipboard(idText.trim()),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _CredentialRow(
            icon: Icons.key_rounded,
            label: translate('One-time Password'),
            value: showOneTime
                ? (_passwordVisible ? passText : maskedPass)
                : '-',
            tone: AppTone.warning,
            actions: showOneTime
                ? [
                    GlassIconButton(
                      tooltip: _passwordVisible
                          ? translate('Hide')
                          : translate('Show'),
                      icon: _passwordVisible
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      size: 36,
                      iconSize: 18,
                      onPressed: () {
                        setState(() => _passwordVisible = !_passwordVisible);
                      },
                    ),
                    const SizedBox(width: 6),
                    AnimatedRotation(
                      turns: _refreshTurns,
                      duration: CamelliaMotion.resolve(
                        context,
                        const Duration(milliseconds: 420),
                      ),
                      curve: CamelliaMotion.springBouncy,
                      child: GlassIconButton(
                        tooltip: translate('Refresh'),
                        icon: Icons.refresh_rounded,
                        size: 36,
                        iconSize: 18,
                        onPressed: () {
                          setState(() => _refreshTurns += 1.0);
                          bind.mainUpdateTemporaryPassword();
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    GlassIconButton(
                      tooltip: translate('Copy to clipboard'),
                      icon: Icons.copy_rounded,
                      size: 36,
                      iconSize: 18,
                      onPressed: () => _copyToClipboard(passText.trim()),
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
    return GlassSurface(
      layer: CamelliaGlassLayer.floating,
      showShadow: false,
      enableBlur: false,
      tintColor: AppVisual.toneContainer(context, tone),
      borderRadius: BorderRadius.circular(CamelliaRadius.surface),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: Icon(icon, color: color, size: 20),
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
                  style: CamelliaTypography.tabular(
                    Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                      color: color,
                    ),
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
  const PermissionChecker({super.key});

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
          if (serverModel.mediaOk && !hideStopService)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GlassButton(
                variant: GlassButtonVariant.danger,
                expand: true,
                icon: const Icon(Icons.stop_rounded, size: 18),
                onPressed: serverModel.toggleService,
                child: Text(translate("Stop service")),
              ),
            ),
          if (!hideStopService || !serverModel.mediaOk)
            PermissionRow(
              translate("Screen Capture"),
              serverModel.mediaOk,
              serverModel.toggleService,
              icon: CamelliaIcons.display,
            ),
          PermissionRow(
            translate("Input Control"),
            serverModel.inputOk,
            serverModel.toggleInput,
            icon: CamelliaIcons.touch,
          ),
          PermissionRow(
            translate("Transfer file"),
            serverModel.fileOk,
            serverModel.toggleFile,
            enabled: !permissionChangeLocked,
            icon: CamelliaIcons.transfer,
          ),
          hasAudioPermission
              ? PermissionRow(
                  translate("Audio Capture"),
                  serverModel.audioOk,
                  serverModel.toggleAudio,
                  enabled: !permissionChangeLocked,
                  icon: CamelliaIcons.audio,
                )
              : Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 18,
                        color: CamelliaGlassTokens.of(context).statusEncrypted,
                      ).marginOnly(right: 12),
                      Expanded(
                        child: Text(
                          translate("android_version_audio_tip"),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
          PermissionRow(
            translate("Enable clipboard"),
            serverModel.clipboardOk,
            serverModel.toggleClipboard,
            enabled: !permissionChangeLocked,
            icon: CamelliaIcons.clipboard,
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
    super.key,
    this.enabled = true,
    this.icon = CamelliaIcons.shield,
  });

  final String name;
  final bool isOk;
  final VoidCallback onPressed;
  final bool enabled;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final statusColor = isOk ? glass.statusOnline : glass.statusHighLatency;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: GlassSurface(
        layer: CamelliaGlassLayer.floating,
        showShadow: false,
        enableBlur: false,
        borderRadius: BorderRadius.circular(CamelliaRadius.control),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 17, color: statusColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  GlassBadge(
                    label: isOk ? translate('Ready') : translate('Required'),
                    tone: isOk ? GlassBadgeTone.online : GlassBadgeTone.warning,
                    showDot: true,
                    compact: true,
                  ),
                ],
              ),
            ),
            Switch.adaptive(
              value: isOk,
              onChanged: enabled ? (_) => onPressed() : null,
            ),
          ],
        ),
      ),
    );
  }
}

class ConnectionManager extends StatelessWidget {
  const ConnectionManager({super.key});

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
              titleIcon: Icon(
                client.isFileTransfer
                    ? CamelliaIcons.transfer
                    : CamelliaIcons.display,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(child: ClientInfo(client)),
                      if (!client.isFileTransfer && client.authorized)
                        GlassIconButton(
                          icon: CamelliaIcons.chat,
                          size: 38,
                          iconSize: 19,
                          tooltip: translate('Chat'),
                          onPressed: () {
                            gFFI.chatModel.changeCurrentKey(
                              MessageKey(client.peerId, client.id),
                            );
                            HomePage.homeKey.currentState?.selectChatPage();
                          },
                        ),
                    ],
                  ),
                  if (!client.authorized)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        translate("android_new_connection_tip"),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
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
    final disconnectButton = GlassButton(
      variant: GlassButtonVariant.danger,
      minHeight: 40,
      icon: const Icon(CamelliaIcons.close, size: 17),
      onPressed: () {
        bind.cmCloseConnection(connId: client.id);
        gFFI.invokeMethod("cancel_notification", client.id);
      },
      child: Text(translate("Disconnect")),
    );
    final buttons = <Widget>[disconnectButton];
    if (client.inVoiceCall) {
      buttons.insert(
        0,
        GlassButton(
          variant: GlassButtonVariant.danger,
          minHeight: 40,
          icon: const Icon(CamelliaIcons.endCall, size: 17),
          onPressed: () {
            bind.cmCloseVoiceCall(id: client.id);
            gFFI.invokeMethod("cancel_notification", client.id);
          },
          child: Text(translate("Stop")),
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
          GlassButton(
            variant: GlassButtonVariant.danger,
            minHeight: 40,
            onPressed: () {
              serverModel.sendLoginResponse(client, false);
            },
            child: Text(translate("Dismiss")),
          ),
          if (serverModel.approveMode != 'password')
            GlassButton(
              variant: GlassButtonVariant.primary,
              minHeight: 40,
              icon: const Icon(CamelliaIcons.check, size: 17),
              onPressed: () {
                serverModel.sendLoginResponse(client, true);
              },
              child: Text(translate("Accept")),
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
      Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 8),
        child: Text(
          translate("android_new_voice_call_tip"),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
      Align(
        alignment: Alignment.centerRight,
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: 10,
          runSpacing: 8,
          children: [
            GlassButton(
              variant: GlassButtonVariant.secondary,
              minHeight: 40,
              onPressed: () {
                serverModel.handleVoiceCall(client, false);
              },
              child: Text(translate("Dismiss")),
            ),
            if (serverModel.approveMode != 'password')
              GlassButton(
                variant: GlassButtonVariant.primary,
                minHeight: 40,
                icon: const Icon(CamelliaIcons.voiceCall, size: 17),
                onPressed: () {
                  serverModel.handleVoiceCall(client, true);
                },
                child: Text(translate("Accept")),
              ),
          ],
        ),
      ),
    ];
  }
}

class PaddingCard extends StatelessWidget {
  const PaddingCard({
    super.key,
    required this.child,
    this.title,
    this.titleIcon,
    this.tone,
  });

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
    final glass = CamelliaGlassTokens.of(context);
    return SizedBox(
      width: double.maxFinite,
      child: GlassSurface(
        layer: CamelliaGlassLayer.floating,
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
        elevated: tone != null,
        tintColor: tone == null
            ? null
            : Color.alphaBlend(
                AppVisual.tone(context, tone!).withValues(alpha: 0.06),
                glass.floatingTint,
              ),
        child: Column(children: children),
      ),
    );
  }
}

class ClientInfo extends StatelessWidget {
  final Client client;
  const ClientInfo(this.client, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: _buildAvatar(context),
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
                      style: CamelliaTypography.tabular(
                        Theme.of(context).textTheme.bodySmall,
                      ),
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
            debugPrint(
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
