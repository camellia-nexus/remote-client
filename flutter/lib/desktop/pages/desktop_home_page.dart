import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/adaptive_layout.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/common/widgets/custom_password.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/common/widgets/peer_tab_page.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/desktop/pages/connection_page.dart';
import 'package:camellia_remote_app/desktop/pages/desktop_setting_page.dart';
import 'package:camellia_remote_app/desktop/widgets/desktop_shell.dart';
import 'package:camellia_remote_app/desktop/widgets/identity_board_widgets.dart';
import 'package:camellia_remote_app/desktop/widgets/titlebar_widget.dart';
import 'package:camellia_remote_app/common/widgets/address_book.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/plugin/ui_manager.dart';
import 'package:camellia_remote_app/utils/multi_window_manager.dart';
import 'package:camellia_remote_app/utils/platform_channel.dart';
import 'package:camellia_remote_app/utils/sanitizer.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_size/window_size.dart' as window_size;

class DesktopHomePage extends StatefulWidget {
  const DesktopHomePage({super.key});

  static Widget buildDevicesWorkspace(BuildContext context) {
    return LayoutBuilder(
      key: const ValueKey('desktop-devices-workspace'),
      builder: (context, constraints) {
        final content = const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: PeerTabPage(),
        );
        final hasBoundedHeight = constraints.hasBoundedHeight;
        final hasBoundedWidth = constraints.hasBoundedWidth;

        if (hasBoundedHeight && hasBoundedWidth) {
          return SizedBox.expand(child: content);
        } else if (hasBoundedHeight) {
          return SizedBox(
            height: constraints.maxHeight,
            child: content,
          );
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
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: AddressBook(menuPadding: kDesktopMenuPadding),
        );
        final hasBoundedHeight = constraints.hasBoundedHeight;
        final hasBoundedWidth = constraints.hasBoundedWidth;

        if (hasBoundedHeight && hasBoundedWidth) {
          return SizedBox.expand(child: content);
        } else if (hasBoundedHeight) {
          return SizedBox(
            height: constraints.maxHeight,
            child: content,
          );
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

class _DesktopHomePageState extends State<DesktopHomePage>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  final _leftPaneScrollController = ScrollController();

  @override
  bool get wantKeepAlive => true;
  var systemError = '';
  StreamSubscription? _uniLinksSubscription;
  var svcStopped = false.obs;
  var watchIsCanScreenRecording = false;
  var watchIsProcessTrust = false;
  var watchIsInputMonitoring = false;
  var watchIsCanRecordAudio = false;
  Timer? _updateTimer;
  bool isCardClosed = false;
  final RxBool _block = false.obs;
  DesktopNavDestination _currentDestination = DesktopNavDestination.connect;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        DesktopTitleBar(
          labels: DesktopTitleBarLabels(
            minimize: translate('Minimize'),
            maximize: translate('Maximize'),
            restore: translate('Restore'),
            close: translate('Close'),
          ),
        ),
        Expanded(
          child: _buildBlock(
            child: CamelliaDesktopShell(
              currentDestination: _currentDestination,
              onDestinationChanged: (dest) {
                if (_currentDestination != dest) {
                  setState(() => _currentDestination = dest);
                }
              },
              connectBuilder: (context) => _buildConnectWorkspace(context),
              devicesBuilder: (context) => _buildDevicesWorkspace(context),
              addressBookBuilder: (context) =>
                  _buildAddressBookWorkspace(context),
              settingsBuilder: (context) => _buildSettingsWorkspace(context),
              statusWidget:
                  const OnlineStatusWidget().marginOnly(bottom: 6, right: 6),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConnectWorkspace(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return CamelliaBackdrop(
          child: FocusTraversalGroup(
            policy: WidgetOrderTraversalPolicy(),
            child: (constraints.maxWidth >= 840 && constraints.maxHeight >= 660)
                ? _buildExpandedWorkspace(context)
                : _buildStackedWorkspace(context),
          ),
        );
      },
    );
  }

  Widget _buildExpandedWorkspace(BuildContext context) {
    final incomingOnly = bind.isIncomingOnly();
    final outgoingOnly = bind.isOutgoingOnly();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!outgoingOnly)
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 296, maxWidth: 336),
            child: SizedBox(
              width: 320,
              child: _buildAccessPane(context, scrollable: true),
            ),
          ),
        if (!outgoingOnly)
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: AppVisual.border(context),
          ),
        if (!incomingOnly)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: LayoutBuilder(
                builder: (context, rightConstraints) {
                  const minDevicesHeight = 240.0;
                  const connectionPageHeight = 450.0;
                  const gap = 16.0;
                  final neededHeight =
                      connectionPageHeight + gap + minDevicesHeight;
                  if (rightConstraints.maxHeight < neededHeight) {
                    return SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const ConnectionPage(showDevices: false),
                          const SizedBox(height: 16),
                          SizedBox(
                            height: minDevicesHeight,
                            child: _buildDevicesWorkspace(context),
                          ),
                        ],
                      ),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const ConnectionPage(showDevices: false),
                      const SizedBox(height: 16),
                      Expanded(child: _buildDevicesWorkspace(context)),
                    ],
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildStackedWorkspace(BuildContext context) {
    final incomingOnly = bind.isIncomingOnly();
    final outgoingOnly = bind.isOutgoingOnly();
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        bottom: MediaQuery.paddingOf(context).bottom + 24,
      ),
      child: AdaptiveContent(
        maxWidth: 900,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!incomingOnly) const ConnectionPage(showDevices: false),
            if (!incomingOnly && !outgoingOnly) const SizedBox(height: 16),
            if (!outgoingOnly) _buildAccessPane(context, scrollable: false),
            if (!incomingOnly) ...[
              const SizedBox(height: 16),
              SizedBox(
                height: (MediaQuery.sizeOf(context).height * 0.58).clamp(
                  380.0,
                  640.0,
                ),
                child: _buildDevicesWorkspace(context),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDevicesWorkspace(BuildContext context) {
    return DesktopHomePage.buildDevicesWorkspace(context);
  }

  Widget _buildAddressBookWorkspace(BuildContext context) {
    return DesktopHomePage.buildAddressBookWorkspace(context);
  }

  Widget _buildSettingsWorkspace(BuildContext context) {
    return DesktopSettingPage(initialTabkey: SettingsTabKey.general);
  }

  Widget _buildAccessPane(BuildContext context, {required bool scrollable}) {
    final pane = buildLeftPane(context, scrollable: scrollable);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CamelliaRadius.surface),
        side: BorderSide(color: AppVisual.border(context)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: scrollable ? MainAxisSize.max : MainAxisSize.min,
        children: [
          if (scrollable) Expanded(child: pane) else pane,
          if (!bind.isDisableSettings()) ...[
            Divider(height: 1, color: AppVisual.border(context)),
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    setState(
                      () => _currentDestination = DesktopNavDestination.settings,
                    );
                  },
                  icon: const Icon(Icons.settings_outlined, size: 19),
                  label: Text(translate('Settings')),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBlock({required Widget child}) {
    return buildRemoteBlock(
      block: _block,
      mask: true,
      use: canBeBlocked,
      child: child,
    );
  }

  Widget buildLeftPane(
    BuildContext context, {
    double? width,
    bool scrollable = true,
  }) {
    final isIncomingOnly = bind.isIncomingOnly();
    final isOutgoingOnly = bind.isOutgoingOnly();
    final children = <Widget>[
      if (!isOutgoingOnly) buildPresetPasswordWarning(),
      if (bind.isCustomClient())
        Align(alignment: Alignment.center, child: loadPowered(context)),
      buildTip(context),
      if (!isOutgoingOnly) const IdentityIdBoard(),
      if (!isOutgoingOnly) const IdentityPasswordBoard(),
      buildHelpCards(),
      buildPluginEntry(),
    ];
    if (isIncomingOnly) {
      children.addAll([
        Divider(),
        const OnlineStatusWidget().marginOnly(bottom: 6, right: 6),
      ]);
    }
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
    return ChangeNotifierProvider.value(
      value: gFFI.serverModel,
      child: AnimatedContainer(
        duration: AppMotion.duration(context, AppMotion.stateChange),
        curve: Curves.easeOutCubic,
        width: width,
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        child: scrollable
            ? SingleChildScrollView(
                controller: _leftPaneScrollController,
                child: content,
              )
            : content,
      ),
    );
  }

  Widget buildIDBoard(BuildContext context) => const IdentityIdBoard();

  Widget buildPasswordBoard(BuildContext context) =>
      const IdentityPasswordBoard();

  Widget buildTip(BuildContext context) {
    final isOutgoingOnly = bind.isOutgoingOnly();
    return Padding(
      padding: const EdgeInsets.only(
        left: 14.0,
        right: 14,
        top: 16.0,
        bottom: 5,
      ),
      child: AppSectionHeader(
        icon: isOutgoingOnly ? null : Icons.desktop_windows_rounded,
        colors: AppVisual.connectGradient,
        title: isOutgoingOnly
            ? bind.mainGetAppNameSync()
            : translate("Your Desktop"),
        subtitle: translate(
          isOutgoingOnly ? "outgoing_only_desk_tip" : "desk_tip",
        ),
      ),
    );
  }

  Widget _buildCardButton(
    String text,
    GestureTapCallback onPressed, {
    bool outline = false,
  }) {
    return SizedBox(
      height: 44,
      child: outline
          ? OutlinedButton(
              onPressed: onPressed,
              child: Text(text, overflow: TextOverflow.ellipsis),
            )
          : FilledButton(
              onPressed: onPressed,
              child: Text(text, overflow: TextOverflow.ellipsis),
            ),
    );
  }

  Widget _buildInstallActionRow(
    String btnText,
    GestureTapCallback onPressed,
    String? help,
    String? link,
  ) {
    if (btnText.isEmpty && help == null) {
      return const SizedBox.shrink();
    }
    return Row(
      children: [
        if (btnText.isNotEmpty)
          Expanded(child: _buildCardButton(translate(btnText), onPressed)),
        if (help != null) ...[
          if (btnText.isNotEmpty) const SizedBox(width: 8),
          Expanded(
            child: _buildCardButton(
              translate(help),
              () async => await launchUrl(Uri.parse(link!)),
              outline: true,
            ),
          ),
        ],
      ],
    );
  }

  Widget buildHelpCards() {
    if (systemError.isNotEmpty) {
      return buildInstallCard("", systemError, "", () {}, tone: AppTone.danger);
    }

    if (isWindows && !bind.isDisableInstallation()) {
      if (!bind.mainIsInstalled()) {
        return buildInstallCard(
          "",
          bind.isOutgoingOnly() ? "" : "install_tip",
          "Install",
          () async {
            await rustDeskWinManager.closeAllSubWindows();
            bind.mainGotoInstall();
          },
        );
      } else if (bind.mainIsInstalledLowerVersion()) {
        return buildInstallCard(
          "Status",
          "Your installation is lower version.",
          "Click to upgrade",
          () async {
            await rustDeskWinManager.closeAllSubWindows();
            bind.mainUpdateMe();
          },
        );
      }
    } else if (isMacOS) {
      final isOutgoingOnly = bind.isOutgoingOnly();
      if (!(isOutgoingOnly || bind.mainIsCanScreenRecording(prompt: false))) {
        return buildInstallCard(
          "Permissions",
          "config_screen",
          "Configure",
          () async {
            bind.mainIsCanScreenRecording(prompt: true);
            watchIsCanScreenRecording = true;
          },
          help: 'Help',
          link: translate("doc_mac_permission"),
        );
      } else if (!isOutgoingOnly && !bind.mainIsProcessTrusted(prompt: false)) {
        return buildInstallCard(
          "Permissions",
          "config_acc",
          "Configure",
          () async {
            bind.mainIsProcessTrusted(prompt: true);
            watchIsProcessTrust = true;
          },
          help: 'Help',
          link: translate("doc_mac_permission"),
        );
      } else if (!bind.mainIsCanInputMonitoring(prompt: false)) {
        return buildInstallCard(
          "Permissions",
          "config_input",
          "Configure",
          () async {
            bind.mainIsCanInputMonitoring(prompt: true);
            watchIsInputMonitoring = true;
          },
          help: 'Help',
          link: translate("doc_mac_permission"),
        );
      } else if (!isOutgoingOnly &&
          !svcStopped.value &&
          bind.mainIsInstalled() &&
          !bind.mainIsInstalledDaemon(prompt: false)) {
        return buildInstallCard("", "install_daemon_tip", "Install", () async {
          bind.mainIsInstalledDaemon(prompt: true);
        });
      }
      //// Disable microphone configuration for macOS. We will request the permission when needed.
      // else if ((await osxCanRecordAudio() !=
      //     PermissionAuthorizeType.authorized)) {
      //   return buildInstallCard("Permissions", "config_microphone", "Configure",
      //       () async {
      //     osxRequestAudio();
      //     watchIsCanRecordAudio = true;
      //   });
      // }
    } else if (isLinux) {
      if (bind.isOutgoingOnly()) {
        return Container();
      }
      final LinuxCards = <Widget>[];
      if (bind.isSelinuxEnforcing()) {
        // Check is SELinux enforcing, but show user a tip of is SELinux enabled for simple.
        final keyShowSelinuxHelpTip = "show-selinux-help-tip";
        if (bind.mainGetLocalOption(key: keyShowSelinuxHelpTip) != 'N') {
          LinuxCards.add(
            buildInstallCard(
              "Warning",
              "selinux_tip",
              "",
              () async {},
              marginTop: LinuxCards.isEmpty ? 20.0 : 5.0,
              help: 'Help',
              link:
                  'https://github.com/camellia-computing/remote-client/blob/main/docs/platform-notes.md#linux-display-requirements',
              closeButton: true,
              closeOption: keyShowSelinuxHelpTip,
            ),
          );
        }
      }
      if (bind.mainCurrentIsWayland()) {
        LinuxCards.add(
          buildInstallCard(
            "Warning",
            "wayland_experiment_tip",
            "",
            () async {},
            marginTop: LinuxCards.isEmpty ? 20.0 : 5.0,
            help: 'Help',
            link:
                'https://github.com/camellia-computing/remote-client/blob/main/docs/platform-notes.md#linux-display-requirements',
          ),
        );
      } else if (bind.mainIsLoginWayland()) {
        LinuxCards.add(
          buildInstallCard(
            "Warning",
            "Login screen using Wayland is not supported",
            "",
            () async {},
            marginTop: LinuxCards.isEmpty ? 20.0 : 5.0,
            help: 'Help',
            link:
                'https://github.com/camellia-computing/remote-client/blob/main/docs/platform-notes.md#linux-display-requirements',
          ),
        );
      }
      if (LinuxCards.isNotEmpty) {
        return Column(children: LinuxCards);
      }
    }
    if (bind.isIncomingOnly()) {
      return Align(
        alignment: Alignment.centerRight,
        child: OutlinedButton(
          onPressed: () {
            SystemNavigator.pop(); // Close the application
            // https://github.com/flutter/flutter/issues/66631
            if (isWindows) {
              exit(0);
            }
          },
          child: Text(translate('Quit')),
        ),
      ).marginAll(14);
    }
    return Container();
  }

  Widget buildInstallCard(
    String title,
    String content,
    String btnText,
    GestureTapCallback onPressed, {
    double marginTop = 20.0,
    String? help,
    String? link,
    bool? closeButton,
    String? closeOption,
    AppTone? tone,
  }) {
    if (bind.mainGetBuildinOption(key: kOptionHideHelpCards) == 'Y' &&
        content != 'install_daemon_tip') {
      return const SizedBox();
    }
    void closeCard() async {
      if (closeOption != null) {
        await bind.mainSetLocalOption(key: closeOption, value: 'N');
        if (bind.mainGetLocalOption(key: closeOption) == 'N') {
          setState(() {
            isCardClosed = true;
          });
        }
      } else {
        setState(() {
          isCardClosed = true;
        });
      }
    }

    final theme = Theme.of(context);
    final cardTone =
        tone ??
        switch (title) {
          'Warning' => AppTone.warning,
          'Permissions' => AppTone.info,
          'Status' => AppTone.brand,
          _ => AppTone.info,
        };
    final toneColor = AppVisual.tone(context, cardTone);
    final toneIcon = switch (cardTone) {
      AppTone.warning => Icons.warning_rounded,
      AppTone.danger => Icons.error_rounded,
      AppTone.brand => Icons.campaign_rounded,
      _ => Icons.info_rounded,
    };
    return Stack(
      children: [
        Container(
          margin: EdgeInsets.fromLTRB(
            14,
            marginTop,
            14,
            bind.isIncomingOnly() ? marginTop : 0,
          ),
          child: AppSurface(
            padding: const EdgeInsets.all(14),
            color: AppVisual.toneContainer(context, cardTone),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      toneIcon,
                      size: 18,
                      color: toneColor,
                    ).marginOnly(top: 1),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (title.isNotEmpty)
                            Text(
                              translate(title),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall,
                            ).marginOnly(bottom: content.isEmpty ? 0 : 4),
                          if (content.isNotEmpty)
                            Text(
                              translate(content),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.82,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ).marginOnly(bottom: btnText.isEmpty && help == null ? 0 : 12),
                _buildInstallActionRow(btnText, onPressed, help, link),
              ],
            ),
          ),
        ),
        if (closeButton != null && closeButton == true)
          Positioned(
            top: marginTop + 2,
            right: 16,
            child: IconButton(
              icon: Icon(
                Icons.close,
                color: AppVisual.subduedText(context),
                size: 18,
              ),
              onPressed: closeCard,
            ),
          ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    _updateTimer = periodic_immediate(const Duration(seconds: 1), () async {
      await gFFI.serverModel.fetchID();
      final error = await bind.mainGetError();
      if (systemError != error) {
        systemError = error;
        setState(() {});
      }
      final v = await mainGetBoolOption(kOptionStopService);
      if (v != svcStopped.value) {
        svcStopped.value = v;
        setState(() {});
      }
      if (watchIsCanScreenRecording) {
        if (bind.mainIsCanScreenRecording(prompt: false)) {
          watchIsCanScreenRecording = false;
          setState(() {});
        }
      }
      if (watchIsProcessTrust) {
        if (bind.mainIsProcessTrusted(prompt: false)) {
          watchIsProcessTrust = false;
          setState(() {});
        }
      }
      if (watchIsInputMonitoring) {
        if (bind.mainIsCanInputMonitoring(prompt: false)) {
          watchIsInputMonitoring = false;
          // Do not notify for now.
          // Monitoring may not take effect until the process is restarted.
          // rustDeskWinManager.call(
          //     WindowType.RemoteDesktop, kWindowDisableGrabKeyboard, '');
          setState(() {});
        }
      }
      if (watchIsCanRecordAudio) {
        if (isMacOS) {
          Future.microtask(() async {
            if ((await osxCanRecordAudio() ==
                PermissionAuthorizeType.authorized)) {
              watchIsCanRecordAudio = false;
              setState(() {});
            }
          });
        } else {
          watchIsCanRecordAudio = false;
          setState(() {});
        }
      }
    });
    Get.put<RxBool>(svcStopped, tag: 'stop-service');
    rustDeskWinManager.registerActiveWindowListener(onActiveWindowChanged);

    screenToMap(window_size.Screen screen) => {
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
        await rustDeskWinManager.registerActiveWindow(call.arguments["id"]);
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
  }

  @override
  void dispose() {
    _uniLinksSubscription?.cancel();
    Get.delete<RxBool>(tag: 'stop-service');
    _updateTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _leftPaneScrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      shouldBeBlocked(_block, canBeBlocked);
    }
  }

  Widget buildPluginEntry() {
    final entries = PluginUiManager.instance.entries.entries;
    return Offstage(
      offstage: entries.isEmpty,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...entries.map((entry) {
            return entry.value;
          }),
        ],
      ),
    );
  }
}

void setPasswordDialog({VoidCallback? notEmptyCallback}) async {
  final p0 = TextEditingController(text: "");
  final p1 = TextEditingController(text: "");
  var errMsg0 = "";
  var errMsg1 = "";
  final localPasswordSet =
      (await bind.mainGetCommon(key: "local-permanent-password-set")) == "true";
  final permanentPasswordSet =
      (await bind.mainGetCommon(key: "permanent-password-set")) == "true";
  final presetPassword = permanentPasswordSet && !localPasswordSet;
  var canSubmit = false;
  var submitting = false;
  final RxString rxPass = "".obs;
  final rules = [
    DigitValidationRule(),
    UppercaseValidationRule(),
    LowercaseValidationRule(),
    // SpecialCharacterValidationRule(),
    MinCharactersValidationRule(8),
  ];
  final maxLength = bind.mainMaxEncryptLen();
  final statusTip = localPasswordSet
      ? translate('password-hidden-tip')
      : (presetPassword ? translate('preset-password-in-use-tip') : '');

  try {
    await gFFI.dialogManager.show((setState, close, context) {
      updateCanSubmit() {
        canSubmit = p0.text.trim().isNotEmpty || p1.text.trim().isNotEmpty;
      }

      submit() async {
        if (!canSubmit || submitting) {
          return;
        }
        setState(() {
          errMsg0 = "";
          errMsg1 = "";
        });
        final pass = p0.text.trim();
        if (pass.isNotEmpty) {
          final Iterable violations = rules.where((r) => !r.validate(pass));
          if (violations.isNotEmpty) {
            setState(() {
              errMsg0 =
                  '${translate('Prompt')}: ${violations.map((r) => r.name).join(', ')}';
            });
            return;
          }
        }
        if (p1.text.trim() != pass) {
          setState(() {
            errMsg1 =
                '${translate('Prompt')}: ${translate("The confirmation is not identical.")}';
          });
          return;
        }
        setState(() => submitting = true);
        final ok = await bind.mainSetPermanentPasswordWithResult(
          password: pass,
        );
        if (!ok) {
          setState(() {
            submitting = false;
            errMsg0 = '${translate('Prompt')}: ${translate("Failed")}';
          });
          return;
        }
        if (pass.isNotEmpty) {
          notEmptyCallback?.call();
        }
        close();
      }

      remove() async {
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
            errMsg0 = '${translate('Prompt')}: ${translate("Failed")}';
          });
          return;
        }
        close();
      }

      final scheme = Theme.of(context).colorScheme;
      Widget actionButton(Widget child) => SizedBox(width: 132, child: child);

      return CustomAlertDialog(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppIconBadge(
              icon: Icons.key_rounded,
              colors: AppVisual.securityGradient,
              size: 48,
              iconSize: 24,
            ),
            const SizedBox(height: 14),
            Text(
              translate('Set permanent password'),
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              translate('Use permanent password'),
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        contentBoxConstraints: const BoxConstraints(maxWidth: 460),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (statusTip.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppVisual.toneContainer(context, AppTone.warning),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppVisual.tone(
                        context,
                        AppTone.warning,
                      ).withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        color: AppVisual.tone(context, AppTone.warning),
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          statusTip,
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PasswordWidget(
                      controller: p0,
                      maxLength: maxLength,
                      errorText: errMsg0.isEmpty ? null : errMsg0,
                      onChanged: (value) {
                        rxPass.value = value.trim();
                        setState(() {
                          errMsg0 = '';
                          updateCanSubmit();
                        });
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 4, 14),
                      child: PasswordStrengthIndicator(password: rxPass),
                    ),
                    PasswordWidget(
                      controller: p1,
                      autoFocus: false,
                      title: translate('Confirmation'),
                      maxLength: maxLength,
                      errorText: errMsg1.isEmpty ? null : errMsg1,
                      onChanged: (_) {
                        setState(() {
                          errMsg1 = '';
                          updateCanSubmit();
                        });
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Obx(
                () => Wrap(
                  runSpacing: 8,
                  spacing: 8,
                  children: rules.map((rule) {
                    final checked = rule.validate(rxPass.value.trim());
                    final tone = checked ? AppTone.success : AppTone.danger;
                    final color = AppVisual.tone(context, tone);
                    return Chip(
                      avatar: Icon(
                        checked ? Icons.check_rounded : Icons.close_rounded,
                        size: 16,
                        color: color,
                      ),
                      label: Text(rule.name),
                      labelStyle: Theme.of(
                        context,
                      ).textTheme.labelMedium?.copyWith(color: color),
                      side: BorderSide(color: color.withValues(alpha: 0.35)),
                      backgroundColor: AppVisual.toneContainer(context, tone),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          actionButton(
            dialogButton(
              'Cancel',
              icon: const Icon(Icons.close_rounded),
              onPressed: submitting ? null : close,
              isOutline: true,
            ),
          ),
          if (localPasswordSet)
            actionButton(
              dialogButton(
                'Remove',
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: submitting ? null : remove,
                buttonStyle: ButtonStyle(
                  backgroundColor: WidgetStatePropertyAll(scheme.error),
                  foregroundColor: WidgetStatePropertyAll(scheme.onError),
                ),
              ),
            ),
          actionButton(
            dialogButton(
              'OK',
              icon: submitting
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.done_rounded),
              onPressed: canSubmit && !submitting ? submit : null,
            ),
          ),
        ],
        onSubmit: canSubmit && !submitting ? submit : null,
        onCancel: submitting ? null : close,
      );
    });
  } finally {
    p0.dispose();
    p1.dispose();
    rxPass.close();
  }
}
