import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/shared_state.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/input_model.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/desktop/pages/remote_page.dart';
import 'package:camellia_remote_app/desktop/widgets/remote_toolbar.dart';
import 'package:camellia_remote_app/desktop/widgets/tabbar_widget.dart';
import 'package:camellia_remote_app/utils/multi_window_manager.dart';
import 'package:camellia_remote_app/utils/sanitizer.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:get/get.dart';

import '../../common/widgets/dialog.dart';
import '../../models/platform_model.dart';

class ConnectionTabPage extends StatefulWidget {
  final Map<String, dynamic> params;

  const ConnectionTabPage({Key? key, required this.params}) : super(key: key);

  @override
  State<ConnectionTabPage> createState() => _ConnectionTabPageState(params);
}

class _ConnectionTabPageState extends State<ConnectionTabPage> {
  final tabController = Get.put(
    DesktopTabController(tabType: DesktopTabType.remoteScreen),
  );
  final contentKey = UniqueKey();
  static const IconData selectedIcon = CamelliaIcons.screen;
  static const IconData unselectedIcon = CamelliaIcons.screen;

  String? peerId;
  bool _isScreenRectSet = false;
  int? _display;

  var connectionMap = RxList<Widget>.empty(growable: true);

  _ConnectionTabPageState(Map<String, dynamic> params) {
    RemoteCountState.init();
    peerId = params['id'];
    final sessionId = params['session_id'];
    final tabWindowId = params['tab_window_id'];
    final display = params['display'];
    final displays = params['displays'];
    final screenRect = parseParamScreenRect(params);
    _isScreenRectSet = screenRect != null;
    _display = display as int?;
    tryMoveToScreenAndSetFullscreen(screenRect);
    if (peerId != null) {
      ConnectionTypeState.init(peerId!);
      tabController.onSelected = (id) {
        final remotePage = tabController.widget(id);
        if (remotePage is RemotePage) {
          final ffi = remotePage.ffi;
          bind.setCurSessionId(sessionId: ffi.sessionId);
          bind.sessionSetCustomFps(sessionId: ffi.sessionId, fps: 0);
          bind.sessionRefresh(sessionId: ffi.sessionId, display: _display ?? 0);
        }
        for (final tab in tabController.state.value.tabs) {
          if (tab.key != id) {
            final page = tabController.widget(tab.key);
            if (page is RemotePage) {
              bind.sessionSetCustomFps(sessionId: page.ffi.sessionId, fps: 2);
            }
          }
        }
        WindowController.fromWindowId(
          params['windowId'],
        ).setTitle(getWindowNameWithId(id));
        UnreadChatCountState.find(id).value = 0;
      };
      tabController.add(
        TabInfo(
          key: peerId!,
          label: peerId!,
          selectedIcon: selectedIcon,
          unselectedIcon: unselectedIcon,
          onTabCloseButton: () async {
            if (await desktopTryShowTabAuditDialogCloseCancelled(
              id: peerId!,
              tabController: tabController,
            )) {
              return;
            }
            tabController.closeBy(peerId!);
          },
          page: RemotePage(
            key: ValueKey(peerId),
            id: peerId!,
            sessionId: sessionId == null ? null : SessionID.fromString(sessionId),
            tabWindowId: tabWindowId,
            display: display,
            displays: displays?.cast<int>(),
            password: params['password'],
            toolbarState: ToolbarState(),
            tabController: tabController,
            switchUuid: params['switch_uuid'],
            forceRelay: params['forceRelay'],
            isSharedPassword: params['isSharedPassword'],
          ),
        ),
      );
      _update_remote_count();
      // CRED-006: Redact transient credentials immediately after consumption
      params['password'] = null;
    }
    tabController.onRemoved = (_, id) => onRemoveId(id);
    rustDeskWinManager.setMethodHandler(_remoteMethodHandler);
  }

  @override
  void initState() {
    super.initState();

    if (!_isScreenRectSet) {
      Future.delayed(Duration.zero, () {
        restoreWindowPosition(
          WindowType.RemoteDesktop,
          windowId: windowId(),
          peerId: tabController.state.value.tabs.isEmpty
              ? null
              : tabController.state.value.tabs[0].key,
          display: _display,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens =
        Theme.of(context).extension<AppDesignTokens>() ??
        AppVisual.tokens(context);
    final child = Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: DesktopTab(
        controller: tabController,
        onWindowCloseButton: handleWindowCloseButton,
        onTabDetach: (index, tab) async {
          if (tabController.state.value.tabs.length <= 1) return;
          final key = tab.key;
          final remotePage = tabController.widget(key);
          final sessionId = (remotePage is RemotePage) ? remotePage.sessionId : 0;
          await DesktopMultiWindow.invokeMethod(
            kMainWindowId,
            kWindowEventMoveTabToNewWindow,
            '${windowId()},$key,$sessionId,RemoteDesktop',
          );
        },
        tail: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _RelativeMouseModeHint(tabController: tabController),
            const AddButton(),
          ],
        ),
        selectedBorderColor: Theme.of(context).colorScheme.primary,
        pageViewBuilder: (pageView) => pageView,
        labelGetter: DesktopTab.tablabelGetter,
        tabBuilder: (key, icon, label, themeConf) => Obx(() {
          final connectionType = ConnectionTypeState.find(key);
          if (!connectionType.isValid()) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [icon, label],
            );
          } else {
            final secure =
                connectionType.secure.value == ConnectionType.strSecure;
            final direct =
                connectionType.direct.value == ConnectionType.strDirect;
            final msgConn = getConnectionText(
              secure,
              direct,
              connectionType.stream_type.value,
            );
            var msgFingerprint = '${translate('Fingerprint')}:\n';
            var fingerprint = FingerprintState.find(key).value;
            if (fingerprint.isEmpty) {
              fingerprint = 'N/A';
            }
            if (fingerprint.length > 5 * 8) {
              final first = fingerprint.substring(0, 39);
              final second = fingerprint.substring(40);
              msgFingerprint += '$first\n$second';
            } else {
              msgFingerprint += fingerprint;
            }

            final tab = Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                icon,
                Tooltip(
                  message: '$msgConn\n$msgFingerprint',
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: CamelliaIcons.securityBadge(
                      secure: secure,
                      direct: direct,
                      size: 15,
                    ),
                  ),
                ),
                label,
                unreadMessageCountBuilder(
                  UnreadChatCountState.find(key),
                ).marginOnly(left: 4),
              ],
            );

            return Listener(
              onPointerDown: (e) {
                if (e.kind != ui.PointerDeviceKind.mouse) {
                  return;
                }
                final matchedTab = tabController.state.value.tabs
                    .firstWhereOrNull((tab) => tab.key == key);
                if (matchedTab == null || matchedTab.page is! RemotePage) {
                  return;
                }
                final remotePage = matchedTab.page as RemotePage;
                if (remotePage.ffi.ffiModel.pi.isSet.isTrue && e.buttons == 2) {
                  showFrostedContextMenu(
                    context: context,
                    globalPosition: e.position,
                    itemsBuilder: (closeMenu) =>
                        _buildTabContextMenuItems(key, closeMenu),
                  );
                }
              },
              child: tab,
            );
          }
        }),
      ),
    );
    final tabWidget = isLinux
        ? buildVirtualWindowFrame(context, child)
        : workaroundWindowBorder(
            context,
            Obx(
              () => Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: tokens.border,
                    width: stateGlobal.windowBorderWidth.value,
                  ),
                ),
                child: child,
              ),
            ),
          );
    return isMacOS
        ? tabWidget
        : Obx(
            () => SubWindowDragToResizeArea(
              key: contentKey,
              child: tabWidget,
              childPadding: kDragToResizeAreaPadding,
              resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
              enableResizeEdges: subWindowManagerEnableResizeEdges,
              windowId: stateGlobal.windowId,
            ),
          );
  }

  List<Widget> _buildTabContextMenuItems(String key, VoidCallback closeMenu) {
    final matched = tabController.state.value.tabs.firstWhereOrNull(
      (tab) => tab.key == key,
    );
    if (matched == null || matched.page is! RemotePage) {
      return const [];
    }
    final remotePage = matched.page as RemotePage;
    final ffi = remotePage.ffi;
    final pi = ffi.ffiModel.pi;
    final perms = ffi.ffiModel.permissions;
    final sessionId = ffi.sessionId;
    final toolbarState = remotePage.toolbarState;
    final items = <Widget>[
      Obx(
        () => FrostedMenuItem(
          label: translate(
            toolbarState.hide.isTrue ? 'Show Toolbar' : 'Hide Toolbar',
          ),
          icon: toolbarState.hide.isTrue
              ? CamelliaIcons.eye
              : CamelliaIcons.eyeOff,
          onTap: () {
            closeMenu();
            toolbarState.switchHide(sessionId);
          },
        ),
      ),
    ];

    if (tabController.state.value.tabs.length > 1) {
      items.add(
        FrostedMenuItem(
          label: translate('Move tab to new window'),
          icon: Icons.open_in_new_rounded,
          onTap: () async {
            closeMenu();
            await DesktopMultiWindow.invokeMethod(
              kMainWindowId,
              kWindowEventMoveTabToNewWindow,
              '${windowId()},$key,$sessionId,RemoteDesktop',
            );
          },
        ),
      );
    }

    if (perms['restart'] != false &&
        (pi.platform == kPeerPlatformLinux ||
            pi.platform == kPeerPlatformWindows ||
            pi.platform == kPeerPlatformMacOS)) {
      items.add(
        FrostedMenuItem(
          label: translate('Restart remote device'),
          icon: Icons.restart_alt_rounded,
          onTap: () {
            closeMenu();
            showRestartRemoteDevice(
              pi,
              peerId ?? key,
              sessionId,
              ffi.dialogManager,
            );
          },
        ),
      );
    }

    if (perms['keyboard'] != false && !ffi.ffiModel.viewOnly) {
      items.add(
        FrostedMenuItem(
          label: translate('Insert Lock'),
          icon: CamelliaIcons.lock,
          onTap: () {
            closeMenu();
            bind.sessionLockScreen(sessionId: sessionId);
          },
        ),
      );
      if (pi.platform == kPeerPlatformLinux || pi.sasEnabled) {
        items.add(
          FrostedMenuItem(
            label: translate('Insert Ctrl + Alt + Del'),
            icon: Icons.keyboard_command_key_rounded,
            onTap: () {
              closeMenu();
              bind.sessionCtrlAltDel(sessionId: sessionId);
            },
          ),
        );
      }
    }

    items.addAll([
      const FrostedMenuDivider(),
      FrostedMenuItem(
        label: translate('Copy Fingerprint'),
        icon: Icons.fingerprint_rounded,
        onTap: () {
          closeMenu();
          onCopyFingerprint(FingerprintState.find(key).value);
        },
      ),
      FrostedMenuItem(
        label: translate('Close'),
        icon: CamelliaIcons.close,
        destructive: true,
        onTap: () async {
          closeMenu();
          if (await desktopTryShowTabAuditDialogCloseCancelled(
            id: key,
            tabController: tabController,
          )) {
            return;
          }
          tabController.closeBy(key);
        },
      ),
    ]);
    return items;
  }

  void onRemoveId(String id) async {
    if (tabController.state.value.tabs.isEmpty) {
      Future<void> loopCloseWindow() async {
        int c = 0;
        final wId = windowId();
        try {
          await rustDeskWinManager.call(WindowType.Main, kWindowEventHide, {
            "id": wId,
          });
        } catch (e) {
          debugPrint("Failed to notify main window on remote window close: $e");
        }
        final windowController = WindowController.fromWindowId(wId);
        try {
          await windowController.setPreventClose(false);
        } catch (e) {
          debugPrint("Failed to setPreventClose in loopCloseWindow: $e");
        }
        while (c < 20 && tabController.state.value.tabs.isEmpty) {
          try {
            await windowController.close();
          } catch (e) {
            debugPrint("Failed to close in loopCloseWindow: $e");
            break;
          }
          await Future.delayed(const Duration(milliseconds: 100));
          c++;
        }
      }

      loopCloseWindow();
    }
    ConnectionTypeState.delete(id);
    // Clean up relative mouse mode state for this peer.
    stateGlobal.relativeMouseModeState.remove(id);
    _update_remote_count();
  }

  int windowId() {
    return widget.params["windowId"];
  }

  Future<bool> handleWindowCloseButton() async {
    final connLength = tabController.length;
    if (connLength == 1) {
      if (await desktopTryShowTabAuditDialogCloseCancelled(
        id: tabController.state.value.tabs[0].key,
        tabController: tabController,
      )) {
        return false;
      }
      tabController.clear();
      return true;
    }
    if (connLength <= 0) {
      tabController.clear();
      return true;
    }
    final bool res;
    if (!option2bool(
      kOptionEnableConfirmClosingTabs,
      bind.mainGetLocalOption(key: kOptionEnableConfirmClosingTabs),
    )) {
      res = true;
    } else {
      res = await closeConfirmDialog(isSessionWindow: true);
    }
    if (res) {
      tabController.clear();
    }
    return res;
  }

  _update_remote_count() =>
      RemoteCountState.find().value = tabController.length;

  Future<dynamic> _remoteMethodHandler(call, fromWindowId) async {
    debugPrint(
      "[Remote Page] call ${call.method} with args ${LogSanitizer.sanitize(call.arguments.toString())} from window $fromWindowId",
    );

    dynamic returnValue;
    if (call.method == kWindowEventNewRemoteDesktop) {
      final args = jsonDecode(call.arguments);
      final id = args['id'];
      final switchUuid = args['switch_uuid'];
      final sessionId = args['session_id'];
      final tabWindowId = args['tab_window_id'];
      final display = args['display'];
      final displays = args['displays'];
      final screenRect = parseParamScreenRect(args);
      final prePeerCount = tabController.length;
      Future.delayed(Duration.zero, () async {
        if (stateGlobal.fullscreen.isTrue) {
          await WindowController.fromWindowId(windowId()).setFullscreen(false);
          stateGlobal.setFullscreen(false, procWnd: false);
        }
        await setNewConnectWindowFrame(
          windowId(),
          id!,
          prePeerCount,
          WindowType.RemoteDesktop,
          display,
          screenRect,
        );
        Future.delayed(Duration(milliseconds: isWindows ? 100 : 0), () async {
          await windowOnTop(windowId());
        });
      });
      ConnectionTypeState.init(id);
      tabController.add(
        TabInfo(
          key: id,
          label: id,
          selectedIcon: selectedIcon,
          unselectedIcon: unselectedIcon,
          onTabCloseButton: () async {
            if (await desktopTryShowTabAuditDialogCloseCancelled(
              id: id,
              tabController: tabController,
            )) {
              return;
            }
            tabController.closeBy(id);
          },
          page: RemotePage(
            key: ValueKey(id),
            id: id,
            sessionId: sessionId == null ? null : SessionID.fromString(sessionId),
            tabWindowId: tabWindowId,
            display: display,
            displays: displays?.cast<int>(),
            password: args['password'],
            toolbarState: ToolbarState(),
            tabController: tabController,
            switchUuid: switchUuid,
            forceRelay: args['forceRelay'],
            isSharedPassword: args['isSharedPassword'],
          ),
        ),
      );
      args['password'] = null;
    } else if (call.method == kWindowDisableGrabKeyboard) {
      // no-op
    } else if (call.method == "onDestroy") {
      tabController.clear();
    } else if (call.method == kWindowActionRebuild) {
      reloadCurrentWindow();
    } else if (call.method == kWindowEventActiveSession) {
      final jumpOk = tabController.jumpToByKey(call.arguments);
      if (jumpOk) {
        windowOnTop(windowId());
      }
      return jumpOk;
    } else if (call.method == kWindowEventActiveDisplaySession) {
      final args = jsonDecode(call.arguments);
      final id = args['id'];
      final display = args['display'];
      final jumpOk = tabController.jumpToByKeyAndDisplay(id, display);
      if (jumpOk) {
        windowOnTop(windowId());
      }
      return jumpOk;
    } else if (call.method == kWindowEventGetRemoteList) {
      return tabController.state.value.tabs
          .map((e) => e.key)
          .toList()
          .join(',');
    } else if (call.method == kWindowEventGetSessionIdList) {
      return tabController.state.value.tabs
          .map((e) => '${e.key},${(e.page as RemotePage).ffi.sessionId}')
          .toList()
          .join(';');
    } else if (call.method == kWindowEventGetCachedSessionData) {
      final args = jsonDecode(call.arguments);
      final id = args['id'];
      final close = args['close'];
      RemotePage? remotePage;
      try {
        remotePage =
            tabController.state.value.tabs
                    .firstWhere((tab) => tab.key == id)
                    .page
                as RemotePage;
        returnValue = remotePage.ffi.ffiModel.cachedPeerData.toString();
      } catch (e) {
        debugPrint('Failed to get cached session data: $e');
      }
      if (close == true && returnValue != null && remotePage != null) {
        remotePage.releaseMacOSInputForTabTransfer();
        closeSessionOnDispose[id] = false;
        tabController.closeBy(id);
      }
    } else if (call.method == kWindowEventCommitTabTransfer) {
      final args = jsonDecode(call.arguments);
      final id = args['id'];
      RemotePage? remotePage;
      try {
        remotePage =
            tabController.state.value.tabs
                    .firstWhere((tab) => tab.key == id)
                    .page
                as RemotePage;
      } catch (e) {
        debugPrint('Failed to find tab for commit transfer: $e');
      }
      if (remotePage != null) {
        remotePage.releaseMacOSInputForTabTransfer();
        closeSessionOnDispose[id] = false;
        tabController.closeBy(id);
      }
      return true;
    } else if (call.method == kWindowEventRemoteWindowCoords) {
      final remotePage =
          tabController.state.value.selectedTabInfo.page as RemotePage;
      final ffi = remotePage.ffi;
      final displayRect = ffi.ffiModel.displaysRect();
      if (displayRect != null) {
        final wc = WindowController.fromWindowId(windowId());
        Rect? frame;
        try {
          frame = await wc.getFrame();
        } catch (e) {
          debugPrint(
            "Failed to get frame of window $windowId, it may be hidden",
          );
        }
        if (frame != null) {
          ffi.cursorModel.moveLocal(0, 0);
          final coords = RemoteWindowCoords(
            frame,
            CanvasCoords.fromCanvasModel(ffi.canvasModel),
            CursorCoords.fromCursorModel(ffi.cursorModel),
            displayRect,
          );
          returnValue = jsonEncode(coords.toJson());
        }
      }
    } else if (call.method == kWindowEventSetFullscreen) {
      stateGlobal.setFullscreen(call.arguments == 'true');
    }
    _update_remote_count();
    return returnValue;
  }
}

/// A widget that displays a hint in the tab bar when relative mouse mode is active.
class _RelativeMouseModeHint extends StatelessWidget {
  final DesktopTabController tabController;

  const _RelativeMouseModeHint({Key? key, required this.tabController})
    : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (tabController.state.value.tabs.isEmpty) {
        return const SizedBox.shrink();
      }
      final selectedTabInfo = tabController.state.value.selectedTabInfo;
      if (selectedTabInfo.page is! RemotePage) {
        return const SizedBox.shrink();
      }
      final remotePage = selectedTabInfo.page as RemotePage;
      final String peerId = remotePage.id;
      final isRelativeMouseMode =
          stateGlobal.relativeMouseModeState[peerId] ?? false;
      if (!isRelativeMouseMode) {
        return const SizedBox.shrink();
      }

      final glass = CamelliaGlassTokens.of(context);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
        margin: const EdgeInsets.only(right: 6),
        decoration: BoxDecoration(
          color: glass.statusHighLatency.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(CamelliaRadius.control - 2),
          border: Border.all(
            color: glass.statusHighLatency.withValues(alpha: 0.36),
            width: 0.85,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CamelliaIcons.mouse, size: 13, color: glass.statusHighLatency),
            const SizedBox(width: 5),
            Text(
              translate(
                'rel-mouse-exit-{${isMacOS ? "Cmd+G" : "Ctrl+Alt"}}-tip',
              ),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: glass.statusHighLatency,
              ),
            ),
          ],
        ),
      );
    });
  }
}
