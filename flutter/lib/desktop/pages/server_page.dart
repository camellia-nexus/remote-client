import 'dart:async';

import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/widgets/audio_input.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/desktop/widgets/tabbar_widget.dart';
import 'package:camellia_remote_app/models/chat_model.dart';
import 'package:camellia_remote_app/models/cm_file_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:camellia_remote_app/utils/platform_channel.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../common.dart';
import '../../common/widgets/chat_page.dart';
import '../../models/file_model.dart';
import '../../models/platform_model.dart';
import '../../models/server_model.dart';

class DesktopServerPage extends StatefulWidget {
  const DesktopServerPage({Key? key}) : super(key: key);

  @override
  State<DesktopServerPage> createState() => _DesktopServerPageState();
}

class _DesktopServerPageState extends State<DesktopServerPage>
    with WindowListener, AutomaticKeepAliveClientMixin {
  final tabController = gFFI.serverModel.tabController;

  _DesktopServerPageState() {
    gFFI.ffiModel.updateEventListener(gFFI.sessionId, "");
    Get.put<DesktopTabController>(tabController);
    tabController.onRemoved = (_, id) {
      onRemoveId(id);
    };
  }

  @override
  void initState() {
    windowManager.addListener(this);
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    Future.wait([gFFI.serverModel.closeAll(), gFFI.close()]).then((_) {
      if (isMacOS) {
        RdPlatformChannel.instance.terminate();
      } else {
        windowManager.setPreventClose(false);
        windowManager.close();
      }
    });
    super.onWindowClose();
  }

  void onRemoveId(String id) {
    if (tabController.state.value.tabs.isEmpty) {
      windowManager.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: gFFI.serverModel),
        ChangeNotifierProvider.value(value: gFFI.chatModel),
      ],
      child: Consumer<ServerModel>(
        builder: (context, serverModel, child) {
          final body = Scaffold(
            backgroundColor: Colors.transparent,
            body: CamelliaBackdrop(child: ConnectionManager()),
          );
          return isLinux
              ? buildVirtualWindowFrame(context, body)
              : workaroundWindowBorder(
                  context,
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: body,
                  ),
                );
        },
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}

class ConnectionManager extends StatefulWidget {
  const ConnectionManager({super.key});

  @override
  State<StatefulWidget> createState() => ConnectionManagerState();
}

class ConnectionManagerState extends State<ConnectionManager>
    with WidgetsBindingObserver {
  final RxBool _controlPageBlock = false.obs;
  final RxBool _sidePageBlock = false.obs;

  ConnectionManagerState() {
    gFFI.serverModel.tabController.onSelected = (clientIdStr) {
      _cmPageGeneration++;
      final clientId = int.tryParse(clientIdStr);
      if (clientId != null) {
        final client = gFFI.serverModel.clients.firstWhereOrNull(
          (e) => e.id == clientId,
        );
        if (client != null) {
          gFFI.chatModel.changeCurrentKey(MessageKey(client.peerId, client.id));
          if (client.unreadChatMessageCount.value > 0) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              client.unreadChatMessageCount.value = 0;
              gFFI.chatModel.showChatPage(MessageKey(client.peerId, client.id));
            });
          }
          windowManager.setTitle(getWindowNameWithId(client.peerId));
          gFFI.cmFileModel.updateCurrentClientId(client.id);
        }
      }
    };
    gFFI.chatModel.isConnManager = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      if (!allowRemoteCMModification()) {
        shouldBeBlocked(_controlPageBlock, null);
        shouldBeBlocked(_sidePageBlock, null);
      }
    }
  }

  @override
  void initState() {
    _cmPageGeneration++;
    gFFI.serverModel.updateClientState();
    WidgetsBinding.instance.addObserver(this);
    super.initState();
  }

  @override
  void dispose() {
    _cmPageGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final serverModel = Provider.of<ServerModel>(context);
    final scheme = Theme.of(context).colorScheme;
    void pointerHandler(PointerEvent e) {
      if (serverModel.cmHiddenTimer != null) {
        serverModel.cmHiddenTimer!.cancel();
        serverModel.cmHiddenTimer = null;
        debugPrint("CM hidden timer has been canceled");
      }
    }

    return serverModel.clients.isEmpty
        ? Column(
            children: [
              buildTitleBar(),
              Expanded(
                child: Center(
                  child: GlassBadge(
                    label: translate("Waiting"),
                    tone: GlassBadgeTone.connecting,
                    showDot: true,
                    pulse: false,
                  ),
                ),
              ),
            ],
          )
        : Listener(
            onPointerDown: pointerHandler,
            onPointerMove: pointerHandler,
            child: DesktopTab(
              showTitle: false,
              showMaximize: false,
              showMinimize: true,
              showClose: true,
              onWindowCloseButton: handleWindowCloseButton,
              controller: serverModel.tabController,
              selectedBorderColor: scheme.primary,
              maxLabelWidth: 100,
              tail: null,
              tabBuilder: (key, icon, label, themeConf) {
                final client = serverModel.clients.firstWhereOrNull(
                  (client) => client.id.toString() == key,
                );
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Tooltip(
                      message: client?.peerId ?? key,
                      waitDuration: const Duration(seconds: 1),
                      child: label,
                    ),
                    unreadMessageCountBuilder(
                      client?.unreadChatMessageCount,
                    ).marginOnly(left: 4),
                  ],
                );
              },
              pageViewBuilder: (pageView) => LayoutBuilder(
                builder: (context, constrains) {
                  var borderWidth = 0.0;
                  if (constrains.maxWidth >
                      kConnectionManagerWindowSizeClosedChat.width) {
                    borderWidth =
                        kConnectionManagerWindowSizeOpenChat.width -
                        constrains.maxWidth;
                  } else {
                    borderWidth =
                        kConnectionManagerWindowSizeClosedChat.width -
                        constrains.maxWidth;
                  }
                  if (borderWidth < 0 || borderWidth > 50) {
                    borderWidth = 0;
                  }
                  final realClosedWidth =
                      kConnectionManagerWindowSizeClosedChat.width -
                      borderWidth;
                  final realChatPageWidth =
                      constrains.maxWidth - realClosedWidth;
                  return Row(
                    children: [
                      if (constrains.maxWidth >
                          kConnectionManagerWindowSizeClosedChat.width)
                        Consumer<ChatModel>(
                          builder: (_, model, child) => SizedBox(
                            width: realChatPageWidth,
                            child: allowRemoteCMModification()
                                ? buildSidePage()
                                : buildRemoteBlock(
                                    child: buildSidePage(),
                                    block: _sidePageBlock,
                                    mask: true,
                                  ),
                          ),
                        ),
                      SizedBox(
                        width: realClosedWidth,
                        child: allowRemoteCMModification()
                            ? pageView
                            : buildRemoteBlock(
                                child: _buildKeyEventBlock(pageView),
                                block: _controlPageBlock,
                                mask: false,
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
          );
  }

  Widget buildSidePage() {
    final selected = gFFI.serverModel.tabController.state.value.selected;
    if (selected < 0 || selected >= gFFI.serverModel.clients.length) {
      return const Offstage();
    }
    final tokens =
        Theme.of(context).extension<AppDesignTokens>() ??
        AppVisual.tokens(context);
    final theme = Theme.of(context);
    final client = gFFI.serverModel.clients[selected];
    final isFile = client.type_() == ClientType.file;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: tokens.border, width: 0.85),
        ),
      ),
      child: Column(
        children: [
          Container(
            height: 36,
            padding: const EdgeInsets.fromLTRB(12, 0, 6, 0),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: tokens.border, width: 0.85),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isFile ? CamelliaIcons.transfer : CamelliaIcons.chat,
                  size: 15,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isFile ? translate('Transfer Queue') : translate('Chat'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                GlassIconButton(
                  icon: CamelliaIcons.close,
                  size: 26,
                  iconSize: 14,
                  tooltip: translate('Close'),
                  onPressed: () {
                    if (isFile) {
                      gFFI.chatModel.toggleCMFilePage();
                    } else {
                      gFFI.chatModel.toggleCMChatPage(
                        MessageKey(client.peerId, client.id),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: isFile
                ? const _FileTransferLogPage()
                : ChatPage(type: ChatPageType.desktopCM),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyEventBlock(Widget child) {
    return Obx(
      () => ExcludeFocus(excluding: _controlPageBlock.value, child: child),
    );
  }

  Widget buildTitleBar() {
    return SizedBox(
      height: kDesktopRemoteTabBarHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const _AppIcon(),
          Expanded(
            child: GestureDetector(
              onPanStart: (_) {
                windowManager.startDragging();
              },
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
          const SizedBox(width: 4.0),
          const _CloseButton(),
        ],
      ),
    );
  }

  Widget buildScrollJumper() {
    final offstage = gFFI.serverModel.clients.length < 2;
    final sc = gFFI.serverModel.tabController.state.value.scrollController;
    return Offstage(
      offstage: offstage,
      child: Row(
        children: [
          ActionIcon(icon: Icons.arrow_left, iconSize: 22, onTap: sc.backward),
          ActionIcon(icon: Icons.arrow_right, iconSize: 22, onTap: sc.forward),
        ],
      ),
    );
  }

  Future<bool> handleWindowCloseButton() async {
    final tabController = gFFI.serverModel.tabController;
    final connLength = tabController.length;
    if (connLength <= 1) {
      return true;
    }
    if (!option2bool(
      kOptionEnableConfirmClosingTabs,
      bind.mainGetLocalOption(key: kOptionEnableConfirmClosingTabs),
    )) {
      return true;
    }
    return await closeConfirmDialog(isSessionWindow: true);
  }
}

Widget buildConnectionCard(Client client) {
  return Consumer<ServerModel>(
    builder: (context, value, child) {
      final showPrivileges =
          client.type_() != ClientType.file &&
          client.type_() != ClientType.portForward &&
          client.type_() != ClientType.terminal &&
          !client.disconnected;

      return Padding(
        key: ValueKey(client.id),
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        child: GlassCard(
          layer: CamelliaGlassLayer.modal,
          elevated: true,
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CmHeader(client: client),
              const SizedBox(height: 8),
              Expanded(
                child: showPrivileges
                    ? SingleChildScrollView(
                        child: _PrivilegeBoard(client: client),
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(height: 8),
              _CmControlPanel(client: client),
            ],
          ),
        ),
      );
    },
  );
}

class _AppIcon extends StatelessWidget {
  const _AppIcon({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 6.0),
      child: loadIcon(24),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final glass = CamelliaGlassTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: GlassIconButton(
        icon: CamelliaIcons.close,
        tooltip: translate('Close'),
        size: 30,
        iconSize: 16,
        accentColor: glass.statusAlert,
        onPressed: () {
          windowManager.close();
        },
      ),
    );
  }
}

class _CmHeader extends StatefulWidget {
  final Client client;

  const _CmHeader({Key? key, required this.client}) : super(key: key);

  @override
  State<_CmHeader> createState() => _CmHeaderState();
}

class _CmHeaderState extends State<_CmHeader>
    with AutomaticKeepAliveClientMixin {
  Client get client => widget.client;

  final _time = 0.obs;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (client.authorized && !client.disconnected) {
        _time.value = _time.value + 1;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      gFFI.serverModel.tabController.onSelected?.call(client.id.toString());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  ({String label, IconData icon, GlassBadgeTone tone}) _requestBadgeInfo() {
    switch (client.type_()) {
      case ClientType.file:
        return (
          label: translate('Files'),
          icon: CamelliaIcons.transfer,
          tone: GlassBadgeTone.encrypted,
        );
      case ClientType.camera:
        return (
          label: translate('Camera'),
          icon: CamelliaIcons.camera,
          tone: GlassBadgeTone.brand,
        );
      case ClientType.terminal:
        return (
          label: translate('Terminal'),
          icon: CamelliaIcons.terminal,
          tone: GlassBadgeTone.brand,
        );
      case ClientType.portForward:
        return (
          label: client.portForward.isNotEmpty
              ? '${translate('Port Forward')} ${client.portForward}'
              : translate('Port Forward'),
          icon: CamelliaIcons.tunnel,
          tone: GlassBadgeTone.encrypted,
        );
      case ClientType.remote:
        return (
          label: translate('Desktop'),
          icon: CamelliaIcons.screen,
          tone: GlassBadgeTone.brand,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final badgeInfo = _requestBadgeInfo();
    final canOpenSide =
        client.authorized &&
        (client.type_() == ClientType.remote ||
            client.type_() == ClientType.file ||
            client.type_() == ClientType.camera);

    return GlassSurface(
      layer: CamelliaGlassLayer.floating,
      borderRadius: BorderRadius.circular(CamelliaRadius.control + 2),
      showShadow: false,
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildClientAvatar(context),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      client.name.isNotEmpty ? client.name : client.peerId,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      client.peerId,
                      style: CamelliaTypography.tabular(
                        theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (canOpenSide) ...[
                const SizedBox(width: 6),
                GlassIconButton(
                  icon: client.type_() == ClientType.file
                      ? CamelliaIcons.transfer
                      : CamelliaIcons.chat,
                  tooltip: client.type_() == ClientType.file
                      ? translate('Transfer file')
                      : translate('Chat'),
                  size: 34,
                  iconSize: 17,
                  onPressed: () => checkClickTime(client.id, () {
                    if (client.type_() == ClientType.file) {
                      gFFI.chatModel.toggleCMFilePage();
                    } else {
                      gFFI.chatModel.toggleCMChatPage(
                        MessageKey(client.peerId, client.id),
                      );
                    }
                  }),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              GlassBadge(
                label: badgeInfo.label,
                icon: badgeInfo.icon,
                tone: badgeInfo.tone,
                compact: true,
              ),
              if (client.authorized && !client.disconnected)
                Obx(
                  () => GlassBadge(
                    label:
                        '${translate("Connected")} · ${formatDurationToTime(Duration(seconds: _time.value))}',
                    tone: GlassBadgeTone.online,
                    showDot: true,
                    pulse: false,
                    tabularNums: true,
                    compact: true,
                  ),
                )
              else if (client.authorized && client.disconnected)
                GlassBadge(
                  label: translate("Disconnected"),
                  tone: GlassBadgeTone.offline,
                  showDot: true,
                  compact: true,
                )
              else
                GlassBadge(
                  label: translate("Request access to your device"),
                  tone: GlassBadgeTone.connecting,
                  showDot: true,
                  pulse: false,
                  compact: true,
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;

  Widget _buildClientAvatar(BuildContext context) {
    return buildAvatarWidget(
          avatar: client.avatar,
          size: 46,
          borderRadius: 12,
          fallback: _buildInitialAvatar(context),
        ) ??
        _buildInitialAvatar(context);
  }

  Widget _buildInitialAvatar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = client.name.trim().isNotEmpty
        ? client.name.trim()[0].toUpperCase()
        : '?';
    return Container(
      width: 46,
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: scheme.primary.withValues(alpha: 0.35),
          width: 1,
        ),
      ),
      child: Text(
        initial,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

class _PermissionItem {
  const _PermissionItem({
    required this.name,
    required this.label,
    required this.tooltip,
    required this.icon,
    required this.enabled,
    required this.onToggle,
  });

  final String name;
  final String label;
  final String tooltip;
  final IconData icon;
  final bool enabled;
  final ValueChanged<bool> onToggle;
}

class _PrivilegeBoard extends StatefulWidget {
  final Client client;

  const _PrivilegeBoard({Key? key, required this.client}) : super(key: key);

  @override
  State<StatefulWidget> createState() => _PrivilegeBoardState();
}

class _PrivilegeBoardState extends State<_PrivilegeBoard> {
  Client get client => widget.client;

  void _togglePermission(
    String permName,
    bool enabled,
    VoidCallback applyLocal,
  ) {
    bind.cmSwitchPermission(
      connId: client.id,
      name: permName,
      enabled: enabled,
    );
    setState(applyLocal);
  }

  List<_PermissionItem> _buildPermissions() {
    if (client.type_() == ClientType.camera) {
      return [
        _PermissionItem(
          name: 'audio',
          label: translate('Audio'),
          tooltip: translate('Enable audio'),
          icon: CamelliaIcons.audio,
          enabled: client.audio,
          onToggle: (v) => _togglePermission('audio', v, () => client.audio = v),
        ),
        _PermissionItem(
          name: 'recording',
          label: translate('Recording'),
          tooltip: translate('Enable recording session'),
          icon: CamelliaIcons.record,
          enabled: client.recording,
          onToggle: (v) =>
              _togglePermission('recording', v, () => client.recording = v),
        ),
      ];
    }

    return [
      _PermissionItem(
        name: 'keyboard',
        label: translate('Keyboard & Mouse'),
        tooltip: translate('Enable keyboard/mouse'),
        icon: CamelliaIcons.keyboard,
        enabled: client.keyboard,
        onToggle: (v) =>
            _togglePermission('keyboard', v, () => client.keyboard = v),
      ),
      _PermissionItem(
        name: 'clipboard',
        label: translate('Clipboard'),
        tooltip: translate('Enable clipboard'),
        icon: CamelliaIcons.clipboard,
        enabled: client.clipboard,
        onToggle: (v) =>
            _togglePermission('clipboard', v, () => client.clipboard = v),
      ),
      _PermissionItem(
        name: 'audio',
        label: translate('Audio'),
        tooltip: translate('Enable audio'),
        icon: CamelliaIcons.audio,
        enabled: client.audio,
        onToggle: (v) => _togglePermission('audio', v, () => client.audio = v),
      ),
      _PermissionItem(
        name: 'file',
        label: translate('File Copy'),
        tooltip: translate('Enable file copy and paste'),
        icon: CamelliaIcons.transfer,
        enabled: client.file,
        onToggle: (v) => _togglePermission('file', v, () => client.file = v),
      ),
      _PermissionItem(
        name: 'restart',
        label: translate('Restart'),
        tooltip: translate('Enable remote restart'),
        icon: Icons.restart_alt_rounded,
        enabled: client.restart,
        onToggle: (v) =>
            _togglePermission('restart', v, () => client.restart = v),
      ),
      _PermissionItem(
        name: 'recording',
        label: translate('Recording'),
        tooltip: translate('Enable recording session'),
        icon: CamelliaIcons.record,
        enabled: client.recording,
        onToggle: (v) =>
            _togglePermission('recording', v, () => client.recording = v),
      ),
      if (isWindows)
        _PermissionItem(
          name: 'block_input',
          label: translate('Block Input'),
          tooltip: translate('Enable blocking user input'),
          icon: Icons.block_rounded,
          enabled: client.blockInput,
          onToggle: (v) =>
              _togglePermission('block_input', v, () => client.blockInput = v),
        ),
      if (bind.mainSupportedPrivacyModeImpls() != '[]')
        _PermissionItem(
          name: 'privacy_mode',
          label: translate('Privacy Mode'),
          tooltip: translate('Enable privacy mode'),
          icon: CamelliaIcons.privacy,
          enabled: client.privacyMode,
          onToggle: (v) => _togglePermission(
            'privacy_mode',
            v,
            () => client.privacyMode = v,
          ),
        ),
    ];
  }

  Widget _buildPermissionChip(
    BuildContext context,
    _PermissionItem item, {
    required bool canModify,
    required double width,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final glass = CamelliaGlassTokens.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = dark ? scheme.secondary : scheme.primary;
    final active = item.enabled;

    final bg = active
        ? accent.withValues(alpha: dark ? 0.22 : 0.13)
        : scheme.surfaceContainer.withValues(alpha: 0.6);
    final borderColor = active
        ? accent.withValues(alpha: dark ? 0.55 : 0.42)
        : scheme.outlineVariant.withValues(alpha: 0.72);
    final fgColor = active ? scheme.onSurface : scheme.onSurfaceVariant;

    return Tooltip(
      message: '${item.tooltip}: ${active ? "ON" : "OFF"}',
      waitDuration: const Duration(milliseconds: 250),
      child: SizedBox(
        width: width,
        child: Semantics(
          toggled: active,
          enabled: canModify,
          label: item.tooltip,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(CamelliaRadius.control),
              hoverColor: glass.hoverOverlay,
              onTap: canModify
                  ? () => checkClickTime(
                      client.id,
                      () => item.onToggle(!item.enabled),
                    )
                  : null,
              child: AnimatedContainer(
                duration: CamelliaMotion.resolve(
                  context,
                  CamelliaMotion.feedback,
                ),
                curve: CamelliaMotion.standard,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(CamelliaRadius.control),
                  border: Border.all(color: borderColor, width: 1),
                ),
                child: Row(
                  children: [
                    Icon(
                      item.icon,
                      size: 16,
                      color: active ? accent : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: fgColor,
                          fontWeight: active
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Container(
                      width: 6.5,
                      height: 6.5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: active
                            ? glass.statusOnline
                            : scheme.outlineVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canModifyPermission =
        bind.mainGetBuildinOption(key: kOptionEnablePermChangeInAcceptWindow) !=
        'N';
    final items = _buildPermissions();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Row(
            children: [
              Icon(CamelliaIcons.shield, size: 14, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                translate("Permissions"),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            const spacing = 6.0;
            final tileWidth = ((constraints.maxWidth - spacing) / 2).clamp(
              80.0,
              400.0,
            );
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final item in items)
                  _buildPermissionChip(
                    context,
                    item,
                    canModify: canModifyPermission,
                    width: tileWidth,
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _CmControlPanel extends StatelessWidget {
  final Client client;

  const _CmControlPanel({Key? key, required this.client}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return client.authorized
        ? client.disconnected
              ? _buildDisconnected(context)
              : _buildAuthorized(context)
        : _buildUnAuthorized(context);
  }

  Future<void> _showAudioDeviceMenu(
    BuildContext context,
    Offset globalPosition,
  ) async {
    final devicesInfo = await AudioInput.getDevicesInfo(true, true);
    final List<String> devices = devicesInfo['devices'] as List<String>;
    if (devices.isEmpty) {
      msgBox(
        gFFI.sessionId,
        'custom-nocancel-info',
        'Prompt',
        'no_audio_input_device_tip',
        '',
        gFFI.dialogManager,
      );
      return;
    }

    if (!context.mounted) return;
    final String currentDevice = devicesInfo['current'] as String;
    await showFrostedContextMenu(
      context: context,
      globalPosition: globalPosition,
      minWidth: 220,
      maxWidth: 320,
      itemsBuilder: (closeMenu) => [
        for (final d in devices)
          FrostedMenuItem(
            label: d,
            icon: d == currentDevice
                ? CamelliaIcons.check
                : CamelliaIcons.voiceCall,
            onTap: () {
              closeMenu();
              AudioInput.setDevice(d, true, true);
            },
          ),
      ],
    );
  }

  Widget _buildAuthorized(BuildContext context) {
    final bool canElevate = bind.cmCanElevate();
    final model = Provider.of<ServerModel>(context);
    final showElevation =
        canElevate &&
        model.showElevation &&
        client.type_() == ClientType.remote;
    Offset audioBtnGlobalPos = Offset.zero;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (client.inVoiceCall) ...[
          Row(
            children: [
              Expanded(
                child: Listener(
                  onPointerDown: (e) => audioBtnGlobalPos = e.position,
                  child: GlassButton(
                    variant: GlassButtonVariant.secondary,
                    minHeight: 40,
                    expand: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    icon: const Icon(CamelliaIcons.voiceCall, size: 16),
                    onPressed: () => checkClickTime(
                      client.id,
                      () => _showAudioDeviceMenu(context, audioBtnGlobalPos),
                    ),
                    child: Text(
                      translate("Audio input"),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: GlassButton(
                  variant: GlassButtonVariant.danger,
                  minHeight: 40,
                  expand: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  icon: const Icon(CamelliaIcons.endCall, size: 16),
                  onPressed: () =>
                      checkClickTime(client.id, () => closeVoiceCall()),
                  child: Text(
                    translate("Stop voice call"),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
        ],
        if (client.incomingVoiceCall) ...[
          Row(
            children: [
              Expanded(
                child: GlassButton(
                  variant: GlassButtonVariant.primary,
                  minHeight: 40,
                  expand: true,
                  icon: const Icon(CamelliaIcons.voiceCall, size: 16),
                  onPressed: () =>
                      checkClickTime(client.id, () => handleVoiceCall(true)),
                  child: Text(
                    translate("Accept"),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: GlassButton(
                  variant: GlassButtonVariant.danger,
                  minHeight: 40,
                  expand: true,
                  icon: const Icon(CamelliaIcons.endCall, size: 16),
                  onPressed: () =>
                      checkClickTime(client.id, () => handleVoiceCall(false)),
                  child: Text(
                    translate("Dismiss"),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
        ],
        if (client.fromSwitch) ...[
          GlassButton(
            variant: GlassButtonVariant.secondary,
            minHeight: 40,
            expand: true,
            icon: const Icon(Icons.swap_horiz_rounded, size: 16),
            onPressed: () =>
                checkClickTime(client.id, () => handleSwitchBack(context)),
            child: Text(
              translate("Switch Sides"),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 6),
        ],
        if (showElevation) ...[
          GlassButton(
            variant: GlassButtonVariant.secondary,
            minHeight: 40,
            expand: true,
            icon: const Icon(CamelliaIcons.shield, size: 16),
            onPressed: () => checkClickTime(client.id, () {
              handleElevate(context);
              windowManager.minimize();
            }),
            child: Text(
              translate('Elevate'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 6),
        ],
        GlassButton(
          variant: GlassButtonVariant.danger,
          minHeight: 44,
          expand: true,
          icon: const Icon(Icons.link_off_rounded, size: 17),
          onPressed: () => checkClickTime(client.id, handleDisconnect),
          child: Text(
            translate('Disconnect'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildDisconnected(BuildContext context) {
    return GlassButton(
      variant: GlassButtonVariant.secondary,
      minHeight: 44,
      expand: true,
      icon: const Icon(CamelliaIcons.close, size: 17),
      onPressed: handleClose,
      child: Text(translate('Close')),
    );
  }

  Widget _buildUnAuthorized(BuildContext context) {
    final bool canElevate = bind.cmCanElevate();
    final model = Provider.of<ServerModel>(context);
    final showElevation =
        canElevate &&
        model.showElevation &&
        client.type_() == ClientType.remote;
    final showAccept = model.approveMode != 'password';
    final canModifyPermission =
        bind.mainGetBuildinOption(key: kOptionEnablePermChangeInAcceptWindow) !=
        'N';
    final showViewOnly =
        showAccept &&
        canModifyPermission &&
        client.type_() == ClientType.remote;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showElevation && showAccept) ...[
          GlassButton(
            variant: GlassButtonVariant.secondary,
            minHeight: 40,
            expand: true,
            tooltip: translate('accept_and_elevate_btn_tooltip'),
            icon: const Icon(CamelliaIcons.shield, size: 16),
            onPressed: () => checkClickTime(client.id, () {
              handleAccept(context);
              handleElevate(context);
              windowManager.minimize();
            }),
            child: Text(
              translate('Accept and Elevate'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 6),
        ],
        if (showAccept) ...[
          Row(
            children: [
              Expanded(
                child: GlassButton(
                  variant: GlassButtonVariant.primary,
                  minHeight: 44,
                  expand: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                  icon: const Icon(CamelliaIcons.check, size: 17),
                  onPressed: () => checkClickTime(client.id, () {
                    handleAccept(context);
                    if (!model.hideCm && !gFFI.chatModel.isShowCMSidePage) {
                      windowManager.minimize();
                    }
                  }),
                  child: Text(
                    translate('Accept'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (showViewOnly) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: GlassButton(
                    variant: GlassButtonVariant.secondary,
                    minHeight: 44,
                    expand: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    icon: const Icon(CamelliaIcons.eye, size: 17),
                    onPressed: () => checkClickTime(client.id, () {
                      handleAcceptViewOnly(context);
                      if (!model.hideCm && !gFFI.chatModel.isShowCMSidePage) {
                        windowManager.minimize();
                      }
                    }),
                    child: Text(
                      translate('View Only'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
        ],
        GlassButton(
          variant: GlassButtonVariant.danger,
          minHeight: 44,
          expand: true,
          icon: const Icon(CamelliaIcons.close, size: 17),
          onPressed: () => checkClickTime(client.id, handleDisconnect),
          child: Text(
            translate('Decline'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  void handleDisconnect() {
    bind.cmCloseConnection(connId: client.id);
  }

  void handleAccept(BuildContext context) {
    final model = Provider.of<ServerModel>(context, listen: false);
    model.sendLoginResponse(client, true);
  }

  void handleAcceptViewOnly(BuildContext context) {
    bind.cmSwitchPermission(
      connId: client.id,
      name: "keyboard",
      enabled: false,
    );
    client.keyboard = false;
    final model = Provider.of<ServerModel>(context, listen: false);
    model.sendLoginResponse(client, true);
  }

  void handleElevate(BuildContext context) {
    final model = Provider.of<ServerModel>(context, listen: false);
    model.setShowElevation(false);
    bind.cmElevatePortable(connId: client.id);
  }

  void handleClose() async {
    await bind.cmRemoveDisconnectedConnection(connId: client.id);
    if (await bind.cmGetClientsLength() == 0) {
      windowManager.close();
    }
  }

  void handleSwitchBack(BuildContext context) {
    bind.cmSwitchBack(connId: client.id);
  }

  void handleVoiceCall(bool accept) {
    bind.cmHandleIncomingVoiceCall(id: client.id, accept: accept);
  }

  void closeVoiceCall() {
    bind.cmCloseVoiceCall(id: client.id);
  }
}

int _cmPageGeneration = 1;

void checkClickTime(int id, Function() callback) async {
  if (allowRemoteCMModification()) {
    callback();
    return;
  }
  final currentGen = _cmPageGeneration;
  try {
    final actionId = await bind.cmCreateActionToken(
      connId: id,
      pageGeneration: currentGen,
    );
    final allowed = await bind.cmAuthorizeAction(
      connId: id,
      action: 'cm_sensitive_action',
      actionId: actionId,
      pageGeneration: currentGen,
    );
    if (allowed && currentGen == _cmPageGeneration) {
      callback();
    } else {
      debugPrint(
        'CM action blocked by native action gate for conn $id (actionId=$actionId, gen=$currentGen)',
      );
    }
  } catch (e) {
    debugPrint('CM authorization check error (fail closed): $e');
  }
}

bool allowRemoteCMModification() {
  return option2bool(
    kOptionAllowRemoteCmModification,
    bind.mainGetLocalOption(key: kOptionAllowRemoteCmModification),
  );
}

class _FileTransferLogPage extends StatefulWidget {
  const _FileTransferLogPage({Key? key}) : super(key: key);

  @override
  State<_FileTransferLogPage> createState() => __FileTransferLogPageState();
}

class __FileTransferLogPageState extends State<_FileTransferLogPage> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return statusList();
  }

  Widget _actionBadge(BuildContext context, CmFileLog item) {
    final scheme = Theme.of(context).colorScheme;
    final glass = CamelliaGlassTokens.of(context);
    final ({IconData icon, String label, Color color}) info = switch (item.action) {
      CmFileAction.none => (
        icon: CamelliaIcons.transfer,
        label: '',
        color: scheme.onSurfaceVariant,
      ),
      CmFileAction.remoteToLocal => (
        icon: CamelliaIcons.upload,
        label: translate('Send'),
        color: scheme.primary,
      ),
      CmFileAction.localToRemote => (
        icon: CamelliaIcons.download,
        label: translate('Receive'),
        color: glass.statusEncrypted,
      ),
      CmFileAction.remove => (
        icon: CamelliaIcons.trash,
        label: translate('Delete'),
        color: glass.statusAlert,
      ),
      CmFileAction.createDir => (
        icon: CamelliaIcons.folderNew,
        label: translate('Create Folder'),
        color: glass.statusOnline,
      ),
      CmFileAction.rename => (
        icon: CamelliaIcons.edit,
        label: translate('Rename'),
        color: scheme.primary,
      ),
    };

    return Container(
      width: 56,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      decoration: BoxDecoration(
        color: info.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(CamelliaRadius.control),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(info.icon, size: 18, color: info.color),
          if (info.label.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              info.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: info.color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget statusList() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 8),
      child: Obx(() {
        final jobTable = gFFI.cmFileModel.currentJobTable;
        if (jobTable.isEmpty) {
          return GlassSurface(
            layer: CamelliaGlassLayer.modal,
            borderRadius: BorderRadius.circular(CamelliaRadius.surface),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      CamelliaIcons.transfer,
                      size: 38,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.65),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      translate("No transfers in progress"),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return ListView.separated(
          controller: _scrollController,
          itemCount: jobTable.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (BuildContext context, int index) {
            final item = jobTable[index];
            final progress = item.totalSize > 0
                ? (item.finishedSize / item.totalSize).clamp(0.0, 1.0)
                : 0.0;
            final pct = (progress * 100).toStringAsFixed(0);

            return GlassSurface(
              layer: CamelliaGlassLayer.floating,
              borderRadius: BorderRadius.circular(CamelliaRadius.surface),
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _actionBadge(context, item),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 10,
                          runSpacing: 2,
                          children: [
                            if (item.totalSize > 0)
                              Text(
                                '${translate("Total")} ${readableFileSize(item.totalSize.toDouble())}',
                                style: CamelliaTypography.tabular(
                                  theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            if (item.totalSize > 0 &&
                                item.state == JobState.inProgress)
                              Text(
                                '${translate("Speed")} ${readableFileSize(item.speed)}/s',
                                style: CamelliaTypography.tabular(
                                  theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            if (item.isTransfer() &&
                                item.state != JobState.inProgress)
                              Text(
                                translate(item.display()),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                        if (item.totalSize > 0 &&
                            item.state == JobState.inProgress) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                    CamelliaRadius.pill,
                                  ),
                                  child: LinearProgressIndicator(
                                    value: progress,
                                    minHeight: 7,
                                    backgroundColor:
                                        scheme.surfaceContainerHighest,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      scheme.primary,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '$pct%',
                                style: CamelliaTypography.tabular(
                                  theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurface,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      }),
    );
  }
}
