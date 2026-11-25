import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/shared_state.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/input_model.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/desktop/pages/view_camera_page.dart';
import 'package:camellia_remote_app/desktop/widgets/remote_toolbar.dart';
import 'package:camellia_remote_app/desktop/widgets/tabbar_widget.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:camellia_remote_app/utils/multi_window_manager.dart';
import 'package:camellia_remote_app/utils/sanitizer.dart';
import 'package:get/get.dart';

import '../../models/platform_model.dart';

class ViewCameraTabPage extends StatefulWidget {
  final Map<String, dynamic> params;

  const ViewCameraTabPage({Key? key, required this.params}) : super(key: key);

  @override
  State<ViewCameraTabPage> createState() => _ViewCameraTabPageState(params);
}

class _ViewCameraTabPageState extends State<ViewCameraTabPage> {
  final tabController = Get.put(
    DesktopTabController(tabType: DesktopTabType.viewCamera),
  );
  final contentKey = UniqueKey();
  static const IconData selectedIcon = CamelliaIcons.camera;
  static const IconData unselectedIcon = CamelliaIcons.camera;

  String? peerId;
  bool _isScreenRectSet = false;
  int? _display;

  var connectionMap = RxList<Widget>.empty(growable: true);

  _ViewCameraTabPageState(Map<String, dynamic> params) {
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
        final viewCameraPage = tabController.widget(id);
        if (viewCameraPage is ViewCameraPage) {
          final ffi = viewCameraPage.ffi;
          bind.setCurSessionId(sessionId: ffi.sessionId);
          bind.sessionSetCustomFps(sessionId: ffi.sessionId, fps: 0);
          bind.sessionRefresh(sessionId: ffi.sessionId, display: _display ?? 0);
        }
        // Throttle unselected camera tabs so background streams don't waste decode cycles.
        for (final tab in tabController.state.value.tabs) {
          if (tab.key != id) {
            final page = tabController.widget(tab.key);
            if (page is ViewCameraPage) {
              bind.sessionSetCustomFps(sessionId: page.ffi.sessionId, fps: 1);
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
          page: ViewCameraPage(
            key: ValueKey(peerId),
            id: peerId!,
            sessionId: sessionId == null
                ? null
                : SessionID.fromString(sessionId),
            tabWindowId: tabWindowId,
            display: display,
            displays: displays?.cast<int>(),
            password: params['password'],
            toolbarState: ToolbarState(),
            tabController: tabController,
            connToken: params['connToken'],
            forceRelay: params['forceRelay'],
            isSharedPassword: params['isSharedPassword'],
          ),
        ),
      );
      _update_remote_count();
      // CRED-006: Redact transient credentials immediately after consumption
      params['password'] = null;
      params['connToken'] = null;
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
          WindowType.ViewCamera,
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
        tail: const AddButton(),
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
                final matched = tabController.state.value.tabs.firstWhereOrNull(
                  (tab) => tab.key == key,
                );
                if (matched == null || matched.page is! ViewCameraPage) {
                  return;
                }
                final viewCameraPage = matched.page as ViewCameraPage;
                if (viewCameraPage.ffi.ffiModel.pi.isSet.isTrue &&
                    e.buttons == 2) {
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
    if (matched == null || matched.page is! ViewCameraPage) {
      return const [];
    }
    final viewCameraPage = matched.page as ViewCameraPage;
    final ffi = viewCameraPage.ffi;
    final sessionId = ffi.sessionId;
    final toolbarState = viewCameraPage.toolbarState;
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
              '${windowId()},$key,$sessionId,ViewCamera',
            );
          },
        ),
      );
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
          debugPrint("Failed to notify main window on camera window close: $e");
        }
        final windowController = WindowController.fromWindowId(wId);
        try {
          await windowController.setPreventClose(false);
        } catch (_) {}
        while (c < 20 &&
            tabController.state.value.tabs.isEmpty &&
            (!await windowController.isHidden())) {
          try {
            await windowController.close();
          } catch (_) {
            break;
          }
          await Future.delayed(const Duration(milliseconds: 100));
          c++;
        }
      }

      loopCloseWindow();
    }
    ConnectionTypeState.delete(id);
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
      "[View Camera Page] call ${call.method} with args ${LogSanitizer.sanitize(call.arguments.toString())} from window $fromWindowId",
    );

    dynamic returnValue;
    if (call.method == kWindowEventNewViewCamera) {
      final args = jsonDecode(call.arguments);
      final id = args['id'];
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
          WindowType.ViewCamera,
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
          page: ViewCameraPage(
            key: ValueKey(id),
            id: id,
            sessionId: sessionId == null
                ? null
                : SessionID.fromString(sessionId),
            tabWindowId: tabWindowId,
            display: display,
            displays: displays?.cast<int>(),
            password: args['password'],
            toolbarState: ToolbarState(),
            tabController: tabController,
            connToken: args['connToken'],
            forceRelay: args['forceRelay'],
            isSharedPassword: args['isSharedPassword'],
          ),
        ),
      );
      args['password'] = null;
      args['connToken'] = null;
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
      final jumpOk = tabController.jumpToByKeyAndDisplay(
        id,
        display,
        isCamera: true,
      );
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
          .map((e) => '${e.key},${(e.page as ViewCameraPage).ffi.sessionId}')
          .toList()
          .join(';');
    } else if (call.method == kWindowEventGetCachedSessionData) {
      final args = jsonDecode(call.arguments);
      final id = args['id'];
      final close = args['close'];
      try {
        final viewCameraPage =
            tabController.state.value.tabs
                    .firstWhere((tab) => tab.key == id)
                    .page
                as ViewCameraPage;
        returnValue = viewCameraPage.ffi.ffiModel.cachedPeerData.toString();
      } catch (e) {
        debugPrint('Failed to get cached session data: $e');
      }
      if (close == true && returnValue != null) {
        closeSessionOnDispose[id] = false;
        tabController.closeBy(id);
      }
    } else if (call.method == kWindowEventCommitTabTransfer) {
      final args = jsonDecode(call.arguments);
      final id = args['id'];
      try {
        tabController.state.value.tabs.firstWhere((tab) => tab.key == id);
        closeSessionOnDispose[id] = false;
        tabController.closeBy(id);
      } catch (e) {
        debugPrint('Failed to find view camera tab for commit transfer: $e');
      }
      return true;
    } else if (call.method == kWindowEventRemoteWindowCoords) {
      final viewCameraPage =
          tabController.state.value.selectedTabInfo.page as ViewCameraPage;
      final ffi = viewCameraPage.ffi;
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
