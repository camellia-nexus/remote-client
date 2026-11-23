import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/address_book.dart';
import 'package:camellia_remote_app/common/widgets/custom_password.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/common/widgets/peer_tab_page.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/desktop/pages/connection_page.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';
import 'package:camellia_remote_app/desktop/widgets/desktop_shell.dart';
import 'package:camellia_remote_app/desktop/widgets/identity_board_widgets.dart';
import 'package:camellia_remote_app/desktop/widgets/titlebar_widget.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/plugin/ui_manager.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:camellia_remote_app/utils/multi_window_manager.dart';
import 'package:camellia_remote_app/utils/platform_channel.dart';
import 'package:camellia_remote_app/utils/sanitizer.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import 'package:window_size/window_size.dart' as window_size;

const _kLinuxDisplayDocsUrl =
    'https://github.com/camellia-computing/remote-client/blob/main/docs/platform-notes.md#linux-display-requirements';

const String kOptionCloseToTray = 'close-to-tray';

class DesktopHomePage extends StatefulWidget {
  const DesktopHomePage({super.key});

  static Widget buildDevicesWorkspace(BuildContext context) {
    return LayoutBuilder(
      key: const ValueKey('desktop-devices-workspace'),
      builder: (context, constraints) {
        const content = Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: PeerTabPage(),
        );
        final hasBoundedHeight = constraints.hasBoundedHeight;
        final hasBoundedWidth = constraints.hasBoundedWidth;

        if (hasBoundedHeight && hasBoundedWidth) {
          return const SizedBox.expand(child: content);
        } else if (hasBoundedHeight) {
          return SizedBox(height: constraints.maxHeight, child: content);
        } else {
          return SizedBox(
            height: (MediaQuery.sizeOf(context).height * 0.58).clamp(
              380.0,
              640.0,
            ),
            child: content,
          );
        }
      },
    );
  }

  static Widget buildAddressBookWorkspace(BuildContext context) {
    return LayoutBuilder(
      key: const ValueKey('desktop-address-book-workspace'),
      builder: (context, constraints) {
        final content = Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: AddressBook(menuPadding: kDesktopMenuPadding),
        );
        final hasBoundedHeight = constraints.hasBoundedHeight;
        final hasBoundedWidth = constraints.hasBoundedWidth;

        if (hasBoundedHeight && hasBoundedWidth) {
          return SizedBox.expand(child: content);
        } else if (hasBoundedHeight) {
          return SizedBox(height: constraints.maxHeight, child: content);
        } else {
          return SizedBox(
            height: (MediaQuery.sizeOf(context).height * 0.58).clamp(
              380.0,
              640.0,
            ),
            child: content,
          );
        }
      },
    );
  }

  @override
  State<DesktopHomePage> createState() => _DesktopHomePageState();
}

class _SystemChecklistItem {
  const _SystemChecklistItem({
    required this.title,
    required this.description,
    required this.badgeLabel,
    required this.tone,
    this.actionLabel,
    this.onAction,
    this.helpLabel,
    this.helpUrl,
    this.onDismiss,
  });

  final String title;
  final String description;
  final String badgeLabel;
  final GlassBadgeTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? helpLabel;
  final String? helpUrl;
  final VoidCallback? onDismiss;
}

class _DesktopHomePageState extends State<DesktopHomePage>
    with
        AutomaticKeepAliveClientMixin,
        WidgetsBindingObserver,
        WindowListener {
  @override
  bool get wantKeepAlive => true;

  var systemError = '';
  StreamSubscription? _uniLinksSubscription;
  var svcStopped = false.obs;
  var watchIsCanScreenRecording = false;
  var watchIsProcessTrust = false;
  var watchIsInputMonitoring = false;
  Timer? _updateTimer;
  final RxBool _block = false.obs;
  DesktopNavDestination _currentDestination = DesktopNavDestination.connect;

  void _openSecuritySettings() {
    DesktopSettingPage.pendingInitialTabKey = SettingsTabKey.safety;
    if (_currentDestination != DesktopNavDestination.settings) {
      setState(() => _currentDestination = DesktopNavDestination.settings);
    }
    DesktopSettingPage.switch2page(SettingsTabKey.safety);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final checklistItems = _collectChecklistItems();
    return _buildBlock(
      child: CamelliaDesktopShell(
        destinations: const [
          DesktopNavDestination.connect,
          DesktopNavDestination.settings,
        ],
        currentDestination: _currentDestination,
        onDestinationChanged: (dest) {
          if (_currentDestination != dest) {
            setState(() => _currentDestination = dest);
          }
        },
        topBar: DesktopTitleBar(
          showBrand: false,
          transparent: true,
          labels: DesktopTitleBarLabels(
            minimize: translate('Minimize'),
            maximize: translate('Maximize'),
            restore: translate('Restore'),
            close: translate('Close'),
          ),
        ),
        connectBuilder: (context) => _buildConnectWorkspace(context),
        settingsBuilder: (context) => _buildSettingsWorkspace(context),
        statusWidget: _PassiveRelayStatusPill(svcStopped: svcStopped),
        warningWidget: _buildSidebarWarningBadge(context, checklistItems),
      ),
    );
  }

  Widget _buildConnectWorkspace(BuildContext context) {
    final incomingOnly = bind.isIncomingOnly();
    final outgoingOnly = bind.isOutgoingOnly();
    final checklistItems = _collectChecklistItems();

    return FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wideHero = constraints.maxWidth >= 900;
          final pad = constraints.maxWidth < 680 ? 16.0 : 24.0;
          final hasSpaciousVertical =
              !incomingOnly &&
              wideHero &&
              constraints.maxHeight >= 720 &&
              checklistItems.isEmpty &&
              PluginUiManager.instance.entries.isEmpty;

          final heroSection = _buildBentoHero(
            context,
            wideHero: wideHero,
            incomingOnly: incomingOnly,
            outgoingOnly: outgoingOnly,
          );

          final topBlocks = <Widget>[
            if (!outgoingOnly) buildPresetPasswordWarning(),
            if (bind.isCustomClient())
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Align(
                  alignment: Alignment.center,
                  child: loadPowered(context),
                ),
              ),
            heroSection,
            if (PluginUiManager.instance.entries.isNotEmpty) ...[
              const SizedBox(height: 12),
              buildPluginEntry(),
            ],
            if (incomingOnly) ...[
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: GlassButton(
                  variant: GlassButtonVariant.secondary,
                  onPressed: () {
                    SystemNavigator.pop();
                    if (isWindows) {
                      exit(0);
                    }
                  },
                  child: Text(translate('Quit')),
                ),
              ),
            ],
          ];

          if (hasSpaciousVertical) {
            return Padding(
              padding: EdgeInsets.fromLTRB(pad, pad + 8, pad, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...topBlocks,
                  const SizedBox(height: 20),
                  const Expanded(child: PeerTabPage()),
                ],
              ),
            );
          }

          final devicePanelHeight = (MediaQuery.sizeOf(context).height * 0.56)
              .clamp(380.0, 620.0);

          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              pad,
              pad + 8,
              pad,
              MediaQuery.paddingOf(context).bottom + 24,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...topBlocks,
                if (!incomingOnly) ...[
                  const SizedBox(height: 20),
                  SizedBox(height: devicePanelHeight, child: const PeerTabPage()),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBentoHero(
    BuildContext context, {
    required bool wideHero,
    required bool incomingOnly,
    required bool outgoingOnly,
  }) {
    if (incomingOnly) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: UnifiedIdentityCard(
            showStatus: true,
            onOpenSecuritySettings: _openSecuritySettings,
          ),
        ),
      );
    }

    if (outgoingOnly) {
      return const ConnectionPage(showDevices: false, showStatus: true);
    }

    // Both Quick Connect Hero and Local Identity Card side-by-side on wide
    // canvases (flex 6 : flex 5), stacking cleanly below 900px.
    // Only UnifiedIdentityCard mounts OnlineStatusWidget -> single FFI timer!
    final quickConnect = const ConnectionPage(
      showDevices: false,
      showStatus: false,
    );
    final identityCard = UnifiedIdentityCard(
      showStatus: true,
      onOpenSecuritySettings: _openSecuritySettings,
    );

    if (wideHero) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 6, child: quickConnect),
          const SizedBox(width: 16),
          Expanded(flex: 5, child: identityCard),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [quickConnect, const SizedBox(height: 16), identityCard],
    );
  }

  List<_SystemChecklistItem> _collectChecklistItems() {
    final items = <_SystemChecklistItem>[];
    final hideHelpCards =
        bind.mainGetBuildinOption(key: kOptionHideHelpCards) == 'Y';

    if (systemError.isNotEmpty) {
      items.add(
        _SystemChecklistItem(
          title: translate('Error'),
          description: formatUserFriendlyError(systemError),
          badgeLabel: translate('Error'),
          tone: GlassBadgeTone.danger,
        ),
      );
    }

    if (isWindows && !bind.isDisableInstallation() && !hideHelpCards) {
      if (!bind.mainIsInstalled()) {
        items.add(
          _SystemChecklistItem(
            title: translate('Install'),
            description: bind.isOutgoingOnly() ? '' : translate('install_tip'),
            badgeLabel: translate('Required'),
            tone: GlassBadgeTone.brand,
            actionLabel: translate('Install'),
            onAction: () async {
              await rustDeskWinManager.closeAllSubWindows();
              bind.mainGotoInstall();
            },
          ),
        );
      } else if (bind.mainIsInstalledLowerVersion()) {
        items.add(
          _SystemChecklistItem(
            title: translate('Status'),
            description: translate('Your installation is lower version.'),
            badgeLabel: translate('Update'),
            tone: GlassBadgeTone.warning,
            actionLabel: translate('Click to upgrade'),
            onAction: () async {
              await rustDeskWinManager.closeAllSubWindows();
              bind.mainUpdateMe();
            },
          ),
        );
      }
    } else if (isMacOS) {
      final isOutgoingOnly = bind.isOutgoingOnly();
      if (!hideHelpCards) {
        if (!isOutgoingOnly && !bind.mainIsCanScreenRecording(prompt: false)) {
          items.add(
            _SystemChecklistItem(
              title: translate('Permissions'),
              description: translate('config_screen'),
              badgeLabel: translate('Required'),
              tone: GlassBadgeTone.warning,
              actionLabel: translate('Configure'),
              onAction: () {
                bind.mainIsCanScreenRecording(prompt: true);
                watchIsCanScreenRecording = true;
              },
              helpLabel: translate('Help'),
              helpUrl: translate('doc_mac_permission'),
            ),
          );
        }
        if (!isOutgoingOnly && !bind.mainIsProcessTrusted(prompt: false)) {
          items.add(
            _SystemChecklistItem(
              title: translate('Permissions'),
              description: translate('config_acc'),
              badgeLabel: translate('Required'),
              tone: GlassBadgeTone.warning,
              actionLabel: translate('Configure'),
              onAction: () {
                bind.mainIsProcessTrusted(prompt: true);
                watchIsProcessTrust = true;
              },
              helpLabel: translate('Help'),
              helpUrl: translate('doc_mac_permission'),
            ),
          );
        }
        if (!bind.mainIsCanInputMonitoring(prompt: false)) {
          items.add(
            _SystemChecklistItem(
              title: translate('Permissions'),
              description: translate('config_input'),
              badgeLabel: translate('Required'),
              tone: GlassBadgeTone.warning,
              actionLabel: translate('Configure'),
              onAction: () {
                bind.mainIsCanInputMonitoring(prompt: true);
                watchIsInputMonitoring = true;
              },
              helpLabel: translate('Help'),
              helpUrl: translate('doc_mac_permission'),
            ),
          );
        }
      }
      if (!isOutgoingOnly &&
          !svcStopped.value &&
          bind.mainIsInstalled() &&
          !bind.mainIsInstalledDaemon(prompt: false)) {
        items.add(
          _SystemChecklistItem(
            title: translate('Service'),
            description: translate('install_daemon_tip'),
            badgeLabel: translate('Required'),
            tone: GlassBadgeTone.brand,
            actionLabel: translate('Install'),
            onAction: () {
              bind.mainIsInstalledDaemon(prompt: true);
            },
          ),
        );
      }
    } else if (isLinux && !bind.isOutgoingOnly() && !hideHelpCards) {
      if (bind.isSelinuxEnforcing()) {
        const keyShowSelinuxHelpTip = 'show-selinux-help-tip';
        if (bind.mainGetLocalOption(key: keyShowSelinuxHelpTip) != 'N') {
          items.add(
            _SystemChecklistItem(
              title: translate('Warning'),
              description: translate('selinux_tip'),
              badgeLabel: 'SELinux',
              tone: GlassBadgeTone.warning,
              helpLabel: translate('Help'),
              helpUrl: _kLinuxDisplayDocsUrl,
              onDismiss: () async {
                await bind.mainSetLocalOption(
                  key: keyShowSelinuxHelpTip,
                  value: 'N',
                );
                if (mounted) setState(() {});
              },
            ),
          );
        }
      }
      if (bind.mainCurrentIsWayland()) {
        items.add(
          _SystemChecklistItem(
            title: translate('Warning'),
            description: translate('wayland_experiment_tip'),
            badgeLabel: 'Wayland',
            tone: GlassBadgeTone.warning,
            helpLabel: translate('Help'),
            helpUrl: _kLinuxDisplayDocsUrl,
          ),
        );
      } else if (bind.mainIsLoginWayland()) {
        items.add(
          _SystemChecklistItem(
            title: translate('Warning'),
            description: translate(
              'Login screen using Wayland is not supported',
            ),
            badgeLabel: 'Wayland',
            tone: GlassBadgeTone.warning,
            helpLabel: translate('Help'),
            helpUrl: _kLinuxDisplayDocsUrl,
          ),
        );
      }
    }

    return items;
  }

  Widget? _buildSidebarWarningBadge(
    BuildContext context,
    List<_SystemChecklistItem> items,
  ) {
    if (items.isEmpty) return null;
    final hasError = items.any((item) => item.tone == GlassBadgeTone.danger);
    return Tooltip(
      message: translate('Permissions'),
      child: GlassIconButton(
        key: const ValueKey('desktop-sidebar-warning-badge'),
        size: 30,
        icon: hasError ? Icons.error_outline : Icons.warning_amber_rounded,
        accentColor: hasError
            ? CamelliaColors.statusAlertLight
            : CamelliaColors.statusHighLatencyLight,
        tooltip: translate('Permissions'),
        onPressed: () => _showPermissionsDialog(context, items),
      ),
    );
  }

  void _showPermissionsDialog(
    BuildContext context,
    List<_SystemChecklistItem> items,
  ) {
    showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 500),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: GlassCard(
                layer: CamelliaGlassLayer.modal,
                title: translate('Permissions'),
                subtitle: items.length == 1
                    ? items.first.title
                    : '${items.length} ${translate('Status')}',
                trailing: IconButton(
                  icon: const Icon(Icons.close_rounded, size: 20),
                  tooltip: translate('Close'),
                  onPressed: () => Navigator.of(dialogCtx).pop(),
                ),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < items.length; i++) ...[
                        if (i > 0) const Divider(height: 16),
                        _ChecklistRow(item: items[i]),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSettingsWorkspace(BuildContext context) {
    return DesktopSettingPage(initialTabkey: SettingsTabKey.general);
  }

  Future<bool> _shouldUseBlock() async =>
      await canBeBlocked() && stateGlobal.videoConnCount > 0;

  Widget _buildBlock({required Widget child}) {
    return buildRemoteBlock(
      block: _block,
      mask: true,
      use: _shouldUseBlock,
      child: child,
    );
  }

  Widget buildIDBoard(BuildContext context) => const IdentityIdBoard();

  Widget buildPasswordBoard(BuildContext context) =>
      const IdentityPasswordBoard();

  @override
  void initState() {
    super.initState();
    _updateTimer = periodic_immediate(const Duration(seconds: 1), () async {
      await gFFI.serverModel.fetchID();
      final error = await bind.mainGetError();
      if (systemError != error) {
        systemError = error;
        if (mounted) setState(() {});
      }
      final v = await mainGetBoolOption(kOptionStopService);
      if (v != svcStopped.value) {
        svcStopped.value = v;
        if (mounted) setState(() {});
      }
      if (watchIsCanScreenRecording) {
        if (bind.mainIsCanScreenRecording(prompt: false)) {
          watchIsCanScreenRecording = false;
          if (mounted) setState(() {});
        }
      }
      if (watchIsProcessTrust) {
        if (bind.mainIsProcessTrusted(prompt: false)) {
          watchIsProcessTrust = false;
          if (mounted) setState(() {});
        }
      }
      if (watchIsInputMonitoring) {
        if (bind.mainIsCanInputMonitoring(prompt: false)) {
          watchIsInputMonitoring = false;
          if (mounted) setState(() {});
        }
      }
    });
    Get.put<RxBool>(svcStopped, tag: 'stop-service');
    rustDeskWinManager.registerActiveWindowListener(onActiveWindowChanged);

    Map<String, dynamic> screenToMap(window_size.Screen screen) => {
      'frame': {
        'l': screen.frame.left,
        't': screen.frame.top,
        'r': screen.frame.right,
        'b': screen.frame.bottom,
      },
      'visibleFrame': {
        'l': screen.visibleFrame.left,
        't': screen.visibleFrame.top,
        'r': screen.visibleFrame.right,
        'b': screen.visibleFrame.bottom,
      },
      'scaleFactor': screen.scaleFactor,
    };

    bool isChattyMethod(String methodName) {
      switch (methodName) {
        case kWindowBumpMouse:
          return true;
      }
      return false;
    }

    rustDeskWinManager.setMethodHandler((call, fromWindowId) async {
      if (!isChattyMethod(call.method)) {
        debugPrint(
          "[Main] call ${call.method} with args ${LogSanitizer.sanitize(call.arguments.toString())} from window $fromWindowId",
        );
      }
      if (call.method == kWindowMainWindowOnTop) {
        windowOnTop(null);
      } else if (call.method == kWindowRefreshCurrentUser) {
        gFFI.userModel.refreshCurrentUser();
      } else if (call.method == kWindowGetWindowInfo) {
        final screen = (await window_size.getWindowInfo()).screen;
        if (screen == null) {
          return '';
        } else {
          return jsonEncode(screenToMap(screen));
        }
      } else if (call.method == kWindowGetScreenList) {
        return jsonEncode(
          (await window_size.getScreenList()).map(screenToMap).toList(),
        );
      } else if (call.method == kWindowActionRebuild) {
        reloadCurrentWindow();
      } else if (call.method == kWindowEventShow) {
        await rustDeskWinManager.registerActiveWindow(call.arguments['id']);
      } else if (call.method == kWindowEventHide) {
        await rustDeskWinManager.unregisterActiveWindow(call.arguments['id']);
      } else if (call.method == kWindowConnect) {
        await connectMainDesktop(
          call.arguments['id'],
          isFileTransfer: call.arguments['isFileTransfer'],
          isViewCamera: call.arguments['isViewCamera'],
          isTerminal: call.arguments['isTerminal'],
          isTcpTunneling: call.arguments['isTcpTunneling'],
          isRDP: call.arguments['isRDP'],
          password: call.arguments['password'],
          forceRelay: call.arguments['forceRelay'],
          connToken: call.arguments['connToken'],
          isTerminalRunAsAdmin: call.arguments['isTerminalRunAsAdmin'] ?? false,
        );
      } else if (call.method == kWindowBumpMouse) {
        return RdPlatformChannel.instance.bumpMouse(
          dx: call.arguments['dx'],
          dy: call.arguments['dy'],
        );
      } else if (call.method == kWindowEventMoveTabToNewWindow) {
        final args = call.arguments.split(',');
        int? windowId;
        try {
          windowId = int.parse(args[0]);
        } catch (e) {
          debugPrint("Failed to parse window id '${call.arguments}': $e");
        }
        WindowType? windowType;
        try {
          windowType = WindowType.values.byName(args[3]);
        } catch (e) {
          debugPrint("Failed to parse window type '${call.arguments}': $e");
        }
        if (windowId != null && windowType != null) {
          await rustDeskWinManager.moveTabToNewWindow(
            windowId,
            args[1],
            args[2],
            windowType,
          );
        }
      } else if (call.method == kWindowEventOpenMonitorSession) {
        final args = jsonDecode(call.arguments);
        final windowId = args['window_id'] as int;
        final peerId = args['peer_id'] as String;
        final display = args['display'] as int;
        final displayCount = args['display_count'] as int;
        final windowType = args['window_type'] as int;
        final screenRect = parseParamScreenRect(args);
        await rustDeskWinManager.openMonitorSession(
          windowId,
          peerId,
          display,
          displayCount,
          screenRect,
          windowType,
        );
      } else if (call.method == kWindowEventRemoteWindowCoords) {
        final windowId = int.tryParse(call.arguments);
        if (windowId != null) {
          return jsonEncode(
            await rustDeskWinManager.getOtherRemoteWindowCoords(windowId),
          );
        }
      }
    });
    _uniLinksSubscription = listenUniLinks();

    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _uniLinksSubscription?.cancel();
    if (Get.isRegistered<RxBool>(tag: 'stop-service')) {
      Get.delete<RxBool>(tag: 'stop-service');
    }
    _updateTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    await _handleApplicationClose();
  }

  Future<void> _handleApplicationClose() async {
    final closeToTray = option2bool(
      kOptionCloseToTray,
      bind.mainGetLocalOption(key: kOptionCloseToTray),
    );
    if (closeToTray && isDesktop) {
      await windowManager.hide();
    } else {
      await rustDeskWinManager.closeAllSubWindows();
      await windowManager.setPreventClose(false);
      await windowManager.close();
      if (isMacOS) {
        supervisedMacOSTerminate();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      shouldBeBlocked(_block, _shouldUseBlock);
      if (isMacOS && mounted) {
        if (bind.mainIsCanScreenRecording(prompt: false)) {
          watchIsCanScreenRecording = false;
        }
        if (bind.mainIsProcessTrusted(prompt: false)) {
          watchIsProcessTrust = false;
        }
        if (bind.mainIsCanInputMonitoring(prompt: false)) {
          watchIsInputMonitoring = false;
        }
        setState(() {});
      }
    }
  }

  Widget buildPluginEntry() {
    final entries = PluginUiManager.instance.entries.entries;
    return Offstage(
      offstage: entries.isEmpty,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [...entries.map((entry) => entry.value)],
      ),
    );
  }
}

class _ChecklistRow extends StatelessWidget {
  const _ChecklistRow({required this.item});

  final _SystemChecklistItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.spaceBetween,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 200, maxWidth: 640),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlassBadge(
                label: item.badgeLabel,
                tone: item.tone,
                showDot: true,
                compact: true,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (item.description.isNotEmpty)
                      Text(
                        item.description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      )
                    else
                      Text(item.title, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (item.actionLabel != null && item.onAction != null)
              GlassButton(
                variant: GlassButtonVariant.primary,
                minHeight: 34,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                onPressed: item.onAction,
                child: Text(item.actionLabel!),
              ),
            if (item.helpLabel != null && item.helpUrl != null) ...[
              if (item.actionLabel != null) const SizedBox(width: 8),
              GlassButton(
                variant: GlassButtonVariant.secondary,
                minHeight: 34,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                onPressed: () async {
                  final uri = Uri.tryParse(item.helpUrl!);
                  if (uri != null) {
                    await launchUrl(uri);
                  }
                },
                child: Text(item.helpLabel!),
              ),
            ],
            if (item.onDismiss != null) ...[
              const SizedBox(width: 4),
              IconButton(
                tooltip: translate('Close'),
                icon: Icon(
                  CamelliaIcons.close,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                onPressed: item.onDismiss,
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Passive reactive sidebar status pill reading [stateGlobal.svcStatus] and
/// [svcStopped] without spawning an extra FFI polling timer.
class _PassiveRelayStatusPill extends StatelessWidget {
  const _PassiveRelayStatusPill({required this.svcStopped});

  final RxBool svcStopped;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final stopped = svcStopped.value;
      final status = stateGlobal.svcStatus.value;
      final tone = stopped
          ? GlassBadgeTone.warning
          : switch (status) {
              SvcStatus.ready => GlassBadgeTone.online,
              SvcStatus.connecting => GlassBadgeTone.connecting,
              SvcStatus.notReady => GlassBadgeTone.danger,
            };
      final label = stopped
          ? translate('Service is not running')
          : switch (status) {
              SvcStatus.ready => translate('Ready'),
              SvcStatus.connecting => translate('connecting_status'),
              SvcStatus.notReady => translate('not_ready_status'),
            };
      return GlassBadge(
        label: label,
        tone: tone,
        showDot: true,
        pulse: false,
        compact: true,
      );
    });
  }
}

void setPasswordDialog({VoidCallback? notEmptyCallback}) async {
  final p0 = TextEditingController(text: '');
  final p1 = TextEditingController(text: '');
  final shakeController = GlassShakeController();
  var errMsg0 = '';
  var errMsg1 = '';
  var obscure0 = true;
  var obscure1 = true;
  final localPasswordSet =
      (await bind.mainGetCommon(key: 'local-permanent-password-set')) == 'true';
  final permanentPasswordSet =
      (await bind.mainGetCommon(key: 'permanent-password-set')) == 'true';
  final presetPassword = permanentPasswordSet && !localPasswordSet;
  var canSubmit = false;
  var submitting = false;
  final RxString rxPass = ''.obs;
  final rules = [
    DigitValidationRule(),
    UppercaseValidationRule(),
    LowercaseValidationRule(),
    MinCharactersValidationRule(8),
  ];
  final maxLength = bind.mainMaxEncryptLen();
  final statusTip = localPasswordSet
      ? translate('password-hidden-tip')
      : (presetPassword ? translate('preset-password-in-use-tip') : '');

  try {
    await gFFI.dialogManager.show((setState, close, context) {
      void updateCanSubmit() {
        canSubmit = p0.text.trim().isNotEmpty || p1.text.trim().isNotEmpty;
      }

      Future<void> submit() async {
        if (!canSubmit || submitting) return;
        setState(() {
          errMsg0 = '';
          errMsg1 = '';
        });
        final pass = p0.text.trim();
        if (pass.isNotEmpty) {
          final violations = rules.where((r) => !r.validate(pass));
          if (violations.isNotEmpty) {
            setState(() {
              errMsg0 =
                  '${translate('Prompt')}: ${violations.map((r) => r.name).join(', ')}';
            });
            shakeController.shake();
            return;
          }
        }
        if (p1.text.trim() != pass) {
          setState(() {
            errMsg1 =
                '${translate('Prompt')}: ${translate('The confirmation is not identical.')}';
          });
          shakeController.shake();
          return;
        }
        setState(() => submitting = true);
        final ok = await bind.mainSetPermanentPasswordWithResult(
          password: pass,
        );
        if (!ok) {
          setState(() {
            submitting = false;
            errMsg0 = '${translate('Prompt')}: ${translate('Failed')}';
          });
          shakeController.shake();
          return;
        }
        if (pass.isNotEmpty) {
          notEmptyCallback?.call();
        }
        close();
      }

      Future<void> remove() async {
        if (submitting) return;
        setState(() {
          submitting = true;
          errMsg0 = '';
          errMsg1 = '';
        });
        final ok = await bind.mainSetPermanentPasswordWithResult(password: '');
        if (!ok) {
          setState(() {
            submitting = false;
            errMsg0 = '${translate('Prompt')}: ${translate('Failed')}';
          });
          shakeController.shake();
          return;
        }
        close();
      }

      final theme = Theme.of(context);
      final glass = CamelliaGlassTokens.of(context);
      final limitFormatters = maxLength > 0
          ? <TextInputFormatter>[LengthLimitingTextInputFormatter(maxLength)]
          : const <TextInputFormatter>[];

      return CustomAlertDialog(
        title: ModernDialogHeader(
          icon: Icons.key_rounded,
          title: translate('Set permanent password'),
          subtitle: translate('Use permanent password'),
          onClose: submitting ? null : close,
        ),
        contentBoxConstraints: const BoxConstraints(maxWidth: 460),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: GlassShakeBox(
            controller: shakeController,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (statusTip.isNotEmpty) ...[
                  GlassSurface(
                    layer: CamelliaGlassLayer.floating,
                    showShadow: false,
                    enableBlur: false,
                    padding: const EdgeInsets.all(12),
                    borderRadius: BorderRadius.circular(CamelliaRadius.control),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          color: glass.statusHighLatency,
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            statusTip,
                            style: theme.textTheme.bodySmall?.copyWith(
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                GlassSurface(
                  layer: CamelliaGlassLayer.floating,
                  showShadow: false,
                  enableBlur: false,
                  padding: const EdgeInsets.all(14),
                  borderRadius: BorderRadius.circular(CamelliaRadius.surface),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      GlassInput(
                        controller: p0,
                        autofocus: true,
                        obscureText: obscure0,
                        labelText: translate('Password'),
                        hintText: translate('Password'),
                        errorText: errMsg0.isEmpty ? null : errMsg0,
                        showClearButton: false,
                        inputFormatters: limitFormatters,
                        trailing: IconButton(
                          tooltip: obscure0
                              ? translate('Show Password')
                              : translate('Hide Password'),
                          icon: Icon(
                            obscure0 ? CamelliaIcons.eye : CamelliaIcons.eyeOff,
                            size: 18,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          onPressed: () =>
                              setState(() => obscure0 = !obscure0),
                        ),
                        onChanged: (value) {
                          rxPass.value = value.trim();
                          setState(() {
                            errMsg0 = '';
                            updateCanSubmit();
                          });
                        },
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(2, 10, 2, 14),
                        child: PasswordStrengthIndicator(password: rxPass),
                      ),
                      GlassInput(
                        controller: p1,
                        obscureText: obscure1,
                        labelText: translate('Confirmation'),
                        hintText: translate('Confirmation'),
                        errorText: errMsg1.isEmpty ? null : errMsg1,
                        showClearButton: false,
                        inputFormatters: limitFormatters,
                        trailing: IconButton(
                          tooltip: obscure1
                              ? translate('Show Password')
                              : translate('Hide Password'),
                          icon: Icon(
                            obscure1 ? CamelliaIcons.eye : CamelliaIcons.eyeOff,
                            size: 18,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          onPressed: () =>
                              setState(() => obscure1 = !obscure1),
                        ),
                        onChanged: (_) {
                          setState(() {
                            errMsg1 = '';
                            updateCanSubmit();
                          });
                        },
                        onSubmitted: (_) => submit(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Obx(
                  () => Wrap(
                    runSpacing: 8,
                    spacing: 8,
                    children: rules.map((rule) {
                      final trimmed = rxPass.value.trim();
                      final checked = rule.validate(trimmed);
                      return GlassBadge(
                        label: rule.name,
                        icon: checked
                            ? CamelliaIcons.check
                            : CamelliaIcons.close,
                        tone: checked
                            ? GlassBadgeTone.online
                            : (trimmed.isEmpty
                                  ? GlassBadgeTone.neutral
                                  : GlassBadgeTone.danger),
                        compact: true,
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          GlassButton(
            variant: GlassButtonVariant.secondary,
            onPressed: submitting ? null : close,
            icon: const Icon(CamelliaIcons.close, size: 17),
            child: Text(translate('Cancel')),
          ),
          if (localPasswordSet)
            GlassButton(
              variant: GlassButtonVariant.danger,
              onPressed: submitting ? null : remove,
              icon: const Icon(CamelliaIcons.trash, size: 17),
              child: Text(translate('Remove')),
            ),
          GlassButton(
            variant: GlassButtonVariant.primary,
            loading: submitting,
            onPressed: canSubmit && !submitting ? submit : null,
            icon: const Icon(CamelliaIcons.check, size: 17),
            child: Text(translate('OK')),
          ),
        ],
        onSubmit: canSubmit && !submitting ? submit : null,
        onCancel: submitting ? null : close,
      );
    });
  } finally {
    p0.dispose();
    p1.dispose();
    shakeController.dispose();
    rxPass.close();
  }
}
