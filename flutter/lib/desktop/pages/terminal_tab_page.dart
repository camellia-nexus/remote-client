import 'dart:convert';
import 'dart:ui' as ui;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/desktop/widgets/tabbar_widget.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:camellia_remote_app/utils/multi_window_manager.dart';
import 'package:camellia_remote_app/utils/sanitizer.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:get/get.dart';

import '../../models/platform_model.dart';
import 'terminal_page.dart';
import 'terminal_connection_manager.dart';

class TerminalTabPage extends StatefulWidget {
  final Map<String, dynamic> params;

  const TerminalTabPage({Key? key, required this.params}) : super(key: key);

  @override
  State<TerminalTabPage> createState() => _TerminalTabPageState(params);
}

class _TerminalTabPageState extends State<TerminalTabPage> {
  DesktopTabController get tabController => Get.find<DesktopTabController>();

  static const IconData selectedIcon = CamelliaIcons.terminal;
  static const IconData unselectedIcon = CamelliaIcons.terminal;
  int _nextTerminalId = 1;
  // Lightweight idempotency guard for async close operations
  final Set<String> _closingTabs = {};
  // When true, all session cleanup should persist (window-level close in progress)
  bool _windowClosing = false;

  _TerminalTabPageState(Map<String, dynamic> params) {
    Get.put(DesktopTabController(tabType: DesktopTabType.terminal));
    tabController.onSelected = (id) {
      final parsed = _parseTabKey(id);
      final titleId = parsed?.$1 ?? id;
      WindowController.fromWindowId(
        windowId(),
      ).setTitle(getWindowNameWithId(titleId));
    };
    tabController.onRemoved = (_, id) => onRemoveId(id);
    tabController.onCloseWindow = _closeWindowFromConnection;
    final terminalId = params['terminalId'] ?? _nextTerminalId++;
    final isTerminalRunAsAdmin = params['isTerminalRunAsAdmin'] ?? false;
    tabController.add(
      _createTerminalTab(
        peerId: params['id'],
        terminalId: terminalId,
        password: params['password'],
        isSharedPassword: params['isSharedPassword'],
        forceRelay: params['forceRelay'],
        connToken: params['connToken'],
        isTerminalRunAsAdmin: isTerminalRunAsAdmin,
      ),
    );
    // CRED-006: Redact transient credentials immediately after consumption
    params['password'] = null;
    params['connToken'] = null;
  }

  TabInfo _createTerminalTab({
    required String peerId,
    required int terminalId,
    String? password,
    bool? isSharedPassword,
    bool? forceRelay,
    String? connToken,
    bool isTerminalRunAsAdmin = false,
  }) {
    final tabKey = '${peerId}_$terminalId';
    final alias = bind.mainGetPeerOptionSync(id: peerId, key: 'alias');
    final tabLabel = alias.isNotEmpty
        ? '$alias #$terminalId'
        : '$peerId #$terminalId';
    return TabInfo(
      key: tabKey,
      label: tabLabel,
      selectedIcon: selectedIcon,
      unselectedIcon: unselectedIcon,
      onTabCloseButton: () => _closeTab(tabKey),
      page: TerminalPage(
        key: ValueKey(tabKey),
        id: peerId,
        terminalId: terminalId,
        tabKey: tabKey,
        password: password,
        isSharedPassword: isSharedPassword,
        tabController: tabController,
        forceRelay: forceRelay,
        connToken: connToken,
        isTerminalRunAsAdmin: isTerminalRunAsAdmin,
      ),
    );
  }

  /// Resolves the active [FFI] instance for a terminal tab safely via
  /// [TerminalConnectionManager] or the tab's [TerminalPage] without assuming
  /// a bare `terminal_$peerId` Get tag (which previously crashed on right-click).
  FFI? _resolveFfiForTabKey(String tabKey) {
    final matchingTab = tabController.state.value.tabs.firstWhereOrNull(
      (t) => t.key == tabKey,
    );
    bool isAdmin = false;
    if (matchingTab != null && matchingTab.page is TerminalPage) {
      final page = matchingTab.page as TerminalPage;
      isAdmin = page.isTerminalRunAsAdmin;
      try {
        return page.ffi;
      } catch (_) {}
    }
    final parsed = _parseTabKey(tabKey);
    if (parsed == null) return null;
    final (peerId, _) = parsed;
    return TerminalConnectionManager.getExistingConnection(
          peerId,
          isTerminalRunAsAdmin: isAdmin,
        ) ??
        TerminalConnectionManager.getExistingConnection(
          peerId,
          isTerminalRunAsAdmin: !isAdmin,
        );
  }

  Future<void> _closeTab(String tabKey) async {
    if (_closingTabs.contains(tabKey)) return;
    _closingTabs.add(tabKey);

    try {
      int? snapshotPeerTabCount;
      final parsed = _parseTabKey(tabKey);
      if (parsed != null) {
        final (peerId, _) = parsed;
        snapshotPeerTabCount = tabController.state.value.tabs.where((t) {
          final p = _parseTabKey(t.key);
          return p != null && p.$1 == peerId;
        }).length;
      }

      if (await desktopTryShowTabAuditDialogCloseCancelled(
        id: tabKey,
        tabController: tabController,
      )) {
        return;
      }

      try {
        await _closeTerminalSessionIfNeeded(
          tabKey,
          peerTabCount: snapshotPeerTabCount,
        );
      } catch (e) {
        debugPrint('[TerminalTabPage] Session cleanup failed for $tabKey: $e');
      }
      tabController.closeBy(tabKey);
    } catch (e) {
      debugPrint('[TerminalTabPage] Error closing tab $tabKey: $e');
    } finally {
      _closingTabs.remove(tabKey);
    }
  }

  Future<void> _closeAllTabs() async {
    _windowClosing = true;
    final tabPages = <String, bool>{};
    for (final tab in tabController.state.value.tabs) {
      if (tab.page is TerminalPage) {
        tabPages[tab.key] = (tab.page as TerminalPage).isTerminalRunAsAdmin;
      }
    }
    final tabKeys = tabController.state.value.tabs.map((t) => t.key).toList();
    tabController.clear();
    final futures = tabKeys
        .where((tabKey) => !_closingTabs.contains(tabKey))
        .map((tabKey) async {
          try {
            await _closeTerminalSessionIfNeeded(
              tabKey,
              persistAll: true,
              knownAdminMode: tabPages[tabKey],
            );
          } catch (e) {
            debugPrint(
              '[TerminalTabPage] Session cleanup failed for $tabKey: $e',
            );
          }
        })
        .toList();
    if (futures.isNotEmpty) {
      await Future.wait(futures).timeout(
        const Duration(seconds: 4),
        onTimeout: () {
          debugPrint(
            '[TerminalTabPage] Session cleanup timed out for batch close',
          );
          return [];
        },
      );
    }
  }

  Future<void> _closeTerminalSessionIfNeeded(
    String tabKey, {
    bool persistAll = false,
    int? peerTabCount,
    bool? knownAdminMode,
  }) async {
    if (_windowClosing) {
      persistAll = true;
    }
    final parsed = _parseTabKey(tabKey);
    if (parsed == null) return;
    final (peerId, terminalId) = parsed;

    bool isTerminalRunAsAdmin = knownAdminMode ?? false;
    final matchingTabs = tabController.state.value.tabs.where(
      (t) => t.key == tabKey,
    );
    if (matchingTabs.isNotEmpty && matchingTabs.first.page is TerminalPage) {
      isTerminalRunAsAdmin =
          (matchingTabs.first.page as TerminalPage).isTerminalRunAsAdmin;
    }

    final ffi =
        TerminalConnectionManager.getExistingConnection(
          peerId,
          isTerminalRunAsAdmin: isTerminalRunAsAdmin,
        ) ??
        TerminalConnectionManager.getExistingConnection(
          peerId,
          isTerminalRunAsAdmin: !isTerminalRunAsAdmin,
        );
    if (ffi == null) return;

    final isPersistent = bind.sessionGetToggleOptionSync(
      sessionId: ffi.sessionId,
      arg: kOptionTerminalPersistent,
    );

    if (isPersistent) {
      if (persistAll) {
        return;
      }
      final effectivePeerTabCount =
          peerTabCount ??
          tabController.state.value.tabs.where((t) {
            final p = _parseTabKey(t.key);
            return p != null && p.$1 == peerId;
          }).length;
      if (effectivePeerTabCount <= 1) {
        return;
      }
    }

    final terminalModel = ffi.terminalModels[terminalId];
    if (terminalModel != null) {
      await terminalModel.closeTerminal();
    }
  }

  (String peerId, int terminalId)? _parseTabKey(String tabKey) {
    final lastUnderscore = tabKey.lastIndexOf('_');
    if (lastUnderscore <= 0) {
      debugPrint('[TerminalTabPage] Invalid tabKey format: $tabKey');
      return null;
    }
    final terminalIdStr = tabKey.substring(lastUnderscore + 1);
    final terminalId = int.tryParse(terminalIdStr);
    if (terminalId == null) {
      debugPrint('[TerminalTabPage] Invalid terminalId in tabKey: $tabKey');
      return null;
    }
    final peerId = tabKey.substring(0, lastUnderscore);
    return (peerId, terminalId);
  }

  List<Widget> _buildTabMenuItems(String tabKey, VoidCallback closeMenu) {
    final parsed = _parseTabKey(tabKey);
    if (parsed == null) return const [];
    final (peerId, _) = parsed;
    final ffi = _resolveFfiForTabKey(tabKey);
    final isPersistent = ffi != null
        ? bind.sessionGetToggleOptionSync(
            sessionId: ffi.sessionId,
            arg: kOptionTerminalPersistent,
          )
        : false;

    return [
      FrostedMenuItem(
        label: translate('New tab'),
        icon: CamelliaIcons.add,
        shortcut: isMacOS ? '⌘T' : 'Ctrl+Shift+T',
        onTap: () {
          closeMenu();
          _addNewTerminal(peerId);
        },
      ),
      if (ffi != null) ...[
        const FrostedMenuDivider(),
        FrostedMenuToggleItem(
          label: translate('Keep terminal sessions on disconnect'),
          icon: CamelliaIcons.terminal,
          value: isPersistent,
          onChanged: (_) async {
            await bind.sessionToggleOption(
              sessionId: ffi.sessionId,
              value: kOptionTerminalPersistent,
            );
          },
        ),
      ],
      const FrostedMenuDivider(),
      FrostedMenuItem(
        label: translate('Close'),
        icon: CamelliaIcons.close,
        destructive: true,
        onTap: () {
          closeMenu();
          _closeTab(tabKey);
        },
      ),
    ];
  }

  @override
  void initState() {
    super.initState();

    HardwareKeyboard.instance.addHandler(_handleKeyEvent);

    rustDeskWinManager.setMethodHandler((call, fromWindowId) async {
      debugPrint(
        "[Remote Terminal] call ${call.method} with args ${LogSanitizer.sanitize(call.arguments.toString())} from window $fromWindowId",
      );
      if (call.method == kWindowEventNewTerminal) {
        final args = jsonDecode(call.arguments);
        final id = args['id'];
        windowOnTop(windowId());
        final terminalId = args['terminalId'] ?? _nextTerminalId++;
        final isTerminalRunAsAdmin = args['isTerminalRunAsAdmin'] ?? false;
        tabController.add(
          _createTerminalTab(
            peerId: id,
            terminalId: terminalId,
            password: args['password'],
            isSharedPassword: args['isSharedPassword'],
            forceRelay: args['forceRelay'],
            connToken: args['connToken'],
            isTerminalRunAsAdmin: isTerminalRunAsAdmin,
          ),
        );
        args['password'] = null;
        args['connToken'] = null;
      } else if (call.method == kWindowEventRestoreTerminalSessions) {
        _restoreSessions(call.arguments);
      } else if (call.method == "onDestroy") {
        await _closeAllTabs();
      } else if (call.method == kWindowActionRebuild) {
        reloadCurrentWindow();
      } else if (call.method == kWindowEventActiveSession) {
        if (tabController.state.value.tabs.isEmpty) {
          return false;
        }
        String? targetPeerId;
        bool targetIsAdmin = false;
        if (call.arguments is String) {
          targetPeerId = call.arguments as String;
        } else if (call.arguments is Map) {
          targetPeerId = call.arguments['id']?.toString();
          targetIsAdmin = call.arguments['isTerminalRunAsAdmin'] == true;
        }
        if (targetPeerId == null) return false;
        for (int i = 0; i < tabController.state.value.tabs.length; i++) {
          final tab = tabController.state.value.tabs[i];
          final parsed = _parseTabKey(tab.key);
          if (parsed != null && parsed.$1 == targetPeerId) {
            if (tab.page is TerminalPage) {
              final page = tab.page as TerminalPage;
              if (page.isTerminalRunAsAdmin != targetIsAdmin) {
                continue;
              }
            }
            tabController.jumpTo(i);
            windowOnTop(windowId());
            return true;
          }
        }
        return false;
      }
    });
    Future.delayed(Duration.zero, () {
      restoreWindowPosition(WindowType.Terminal, windowId: windowId());
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    if (Get.isRegistered<DesktopTabController>()) {
      Get.delete<DesktopTabController>();
    }
    super.dispose();
  }

  final TerminalSessionRestoreCoordinator _restoreCoordinator =
      TerminalSessionRestoreCoordinator();

  @visibleForTesting
  bool get isRestoringSessions => _restoreCoordinator.isRestoringSessions;

  @visibleForTesting
  Future<void> restoreSessionsForTesting(String arguments) =>
      _restoreSessions(arguments);

  Future<void> _restoreSessions(String arguments) =>
      _restoreCoordinator.restoreSessions(
        arguments: arguments,
        isMounted: () => mounted,
        tabController: tabController,
        onAddTerminal: (peerId, terminalId) =>
            _addNewTerminal(peerId, terminalId: terminalId),
        parseTabKey: _parseTabKey,
      );

  bool _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.keyT) {
        if (isMacOS &&
            HardwareKeyboard.instance.isMetaPressed &&
            !HardwareKeyboard.instance.isShiftPressed) {
          _addNewTerminalForCurrentPeer();
          return true;
        } else if (!isMacOS &&
            HardwareKeyboard.instance.isControlPressed &&
            HardwareKeyboard.instance.isShiftPressed) {
          _addNewTerminalForCurrentPeer();
          return true;
        }
      }

      if (event.logicalKey == LogicalKeyboardKey.keyW) {
        if (isMacOS &&
            HardwareKeyboard.instance.isMetaPressed &&
            !HardwareKeyboard.instance.isShiftPressed) {
          if (tabController.state.value.tabs.length > 1) {
            final currentTab = tabController.state.value.selectedTabInfo;
            _closeTab(currentTab.key);
            return true;
          }
        } else if (!isMacOS &&
            HardwareKeyboard.instance.isControlPressed &&
            HardwareKeyboard.instance.isShiftPressed) {
          if (tabController.state.value.tabs.length > 1) {
            final currentTab = tabController.state.value.selectedTabInfo;
            _closeTab(currentTab.key);
            return true;
          }
        }
      }

      if (HardwareKeyboard.instance.isAltPressed) {
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          final currentIndex = tabController.state.value.selected;
          if (currentIndex > 0) {
            tabController.jumpTo(currentIndex - 1);
          }
          return true;
        } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          final currentIndex = tabController.state.value.selected;
          if (currentIndex < tabController.length - 1) {
            tabController.jumpTo(currentIndex + 1);
          }
          return true;
        }
      }

      final numberKeys = [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4,
        LogicalKeyboardKey.digit5,
        LogicalKeyboardKey.digit6,
        LogicalKeyboardKey.digit7,
        LogicalKeyboardKey.digit8,
        LogicalKeyboardKey.digit9,
      ];

      for (int i = 0; i < numberKeys.length; i++) {
        if (event.logicalKey == numberKeys[i] &&
            ((isMacOS && HardwareKeyboard.instance.isMetaPressed) ||
                (!isMacOS && HardwareKeyboard.instance.isControlPressed))) {
          if (i < tabController.length) {
            tabController.jumpTo(i);
            return true;
          }
        }
      }
    }
    return false;
  }

  void _addNewTerminal(String peerId, {int? terminalId}) {
    final firstTab = tabController.state.value.tabs.firstWhereOrNull((tab) {
      final last = tab.key.lastIndexOf('_');
      return last > 0 && tab.key.substring(0, last) == peerId;
    });
    if (firstTab != null && firstTab.page is TerminalPage) {
      final page = firstTab.page as TerminalPage;
      final newTerminalId = terminalId ?? _nextTerminalId++;
      if (terminalId != null && terminalId >= _nextTerminalId) {
        _nextTerminalId = terminalId + 1;
      }
      tabController.add(
        _createTerminalTab(
          peerId: peerId,
          terminalId: newTerminalId,
          password: page.password,
          isSharedPassword: page.isSharedPassword,
          forceRelay: page.forceRelay,
          connToken: page.connToken,
          isTerminalRunAsAdmin: page.isTerminalRunAsAdmin,
        ),
      );
    }
  }

  void _addNewTerminalForCurrentPeer({int? terminalId}) {
    if (tabController.state.value.tabs.isEmpty) return;
    final currentTab = tabController.state.value.selectedTabInfo;
    final parsed = _parseTabKey(currentTab.key);
    if (parsed == null) return;
    final (peerId, _) = parsed;
    _addNewTerminal(peerId, terminalId: terminalId);
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
        tail: _buildAddButton(),
        selectedBorderColor: Theme.of(context).colorScheme.primary,
        labelGetter: (label) => RxString(label),
        tabBuilder: (key, icon, label, themeConf) {
          return Listener(
            onPointerDown: (e) {
              if (e.kind == ui.PointerDeviceKind.mouse && e.buttons == 2) {
                showFrostedContextMenu(
                  context: context,
                  globalPosition: e.position,
                  minWidth: 220,
                  maxWidth: 300,
                  itemsBuilder: (closeMenu) =>
                      _buildTabMenuItems(key, closeMenu),
                );
              }
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [icon, label],
            ),
          );
        },
      ),
    );
    final tabWidget = isLinux
        ? buildVirtualWindowFrame(context, child)
        : workaroundWindowBorder(
            context,
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: tokens.border, width: 0.85),
              ),
              child: child,
            ),
          );
    return isMacOS
        ? tabWidget
        : SubWindowDragToResizeArea(
            child: tabWidget,
            resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
            enableResizeEdges: subWindowManagerEnableResizeEdges,
            windowId: stateGlobal.windowId,
          );
  }

  void onRemoveId(String id) async {
    if (tabController.state.value.tabs.isEmpty) {
      final wId = windowId();
      try {
        await rustDeskWinManager.call(WindowType.Main, kWindowEventHide, {
          "id": wId,
        });
      } catch (_) {}
      final wc = WindowController.fromWindowId(wId);
      try {
        await wc.setPreventClose(false);
      } catch (_) {}
      await wc.close();
    }
  }

  Future<void> _closeWindowFromConnection() async {
    await _closeAllTabs();
    final wId = windowId();
    try {
      await rustDeskWinManager.call(WindowType.Main, kWindowEventHide, {
        "id": wId,
      });
    } catch (_) {}
    final wc = WindowController.fromWindowId(wId);
    try {
      await wc.setPreventClose(false);
    } catch (_) {}
    await wc.close();
  }

  int windowId() {
    return widget.params["windowId"];
  }

  Widget _buildAddButton() {
    return ActionIcon(
      message: 'New tab',
      icon: CamelliaIcons.add,
      iconSize: 17,
      onTap: _addNewTerminalForCurrentPeer,
      isClose: false,
    );
  }

  Future<bool> handleWindowCloseButton() async {
    final connLength = tabController.state.value.tabs.length;
    if (connLength == 1) {
      if (await desktopTryShowTabAuditDialogCloseCancelled(
        id: tabController.state.value.tabs[0].key,
        tabController: tabController,
      )) {
        return false;
      }
      await _closeAllTabs();
      return true;
    }
    if (connLength <= 0) {
      await _closeAllTabs();
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
      await _closeAllTabs();
    }
    return res;
  }
}

class TerminalSessionRestoreCoordinator {
  bool _restoringSessions = false;

  bool get isRestoringSessions => _restoringSessions;

  Future<void> restoreSessions({
    required String arguments,
    required bool Function() isMounted,
    required DesktopTabController tabController,
    required void Function(String peerId, int terminalId) onAddTerminal,
    required (String, int)? Function(String tabKey) parseTabKey,
    Future<void> Function(Duration duration)? delayOverride,
  }) async {
    if (!isMounted() || _restoringSessions) return;
    _restoringSessions = true;
    try {
      Map<String, dynamic>? args;
      try {
        args = jsonDecode(arguments) as Map<String, dynamic>;
      } catch (e) {
        debugPrint("Error parsing JSON arguments in _restoreSessions: $e");
        return;
      }
      final persistentSessions =
          args['persistent_sessions'] as List<dynamic>? ?? [];
      final sortedSessions = persistentSessions.whereType<int>().toList()
        ..sort();
      var peerId = args['peer_id'] as String? ?? '';
      if (peerId.isEmpty) {
        if (tabController.state.value.tabs.isEmpty ||
            tabController.state.value.selected >=
                tabController.state.value.tabs.length) {
          debugPrint('[TerminalTabPage] Skip restore: no selected tab');
          return;
        }
        final currentTab = tabController.state.value.selectedTabInfo;
        final parsed = parseTabKey(currentTab.key);
        if (parsed == null) return;
        peerId = parsed.$1;
      }
      final existingTerminalIds = tabController.state.value.tabs
          .map((tab) => parseTabKey(tab.key))
          .where((parsed) => parsed != null && parsed.$1 == peerId)
          .map((parsed) => parsed!.$2)
          .toSet();
      if (existingTerminalIds.isEmpty) {
        debugPrint(
          '[TerminalTabPage] Skip restore: no seed tab for peer $peerId',
        );
        return;
      }
      for (final terminalId in sortedSessions) {
        if (!isMounted()) return;
        if (!existingTerminalIds.add(terminalId)) {
          continue;
        }
        onAddTerminal(peerId, terminalId);
        final delayFunc = delayOverride ?? Future.delayed;
        await delayFunc(const Duration(milliseconds: 300));
        if (!isMounted()) return;
      }
    } finally {
      _restoringSessions = false;
    }
  }
}
