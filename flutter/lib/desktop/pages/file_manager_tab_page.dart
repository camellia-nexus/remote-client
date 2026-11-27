import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/desktop/pages/file_manager_page.dart';
import 'package:camellia_remote_app/desktop/widgets/tabbar_widget.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:camellia_remote_app/utils/multi_window_manager.dart';
import 'package:camellia_remote_app/utils/sanitizer.dart';
import 'package:get/get.dart';

import '../../models/platform_model.dart';

/// File Transfer for multi tabs
class FileManagerTabPage extends StatefulWidget {
  final Map<String, dynamic> params;

  const FileManagerTabPage({Key? key, required this.params}) : super(key: key);

  @override
  State<FileManagerTabPage> createState() => _FileManagerTabPageState(params);
}

class _FileManagerTabPageState extends State<FileManagerTabPage> {
  DesktopTabController get tabController => Get.find<DesktopTabController>();

  static const IconData selectedIcon = CamelliaIcons.transfer;
  static const IconData unselectedIcon = CamelliaIcons.transfer;

  _FileManagerTabPageState(Map<String, dynamic> params) {
    Get.put(DesktopTabController(tabType: DesktopTabType.fileTransfer));
    tabController.onSelected = (id) {
      WindowController.fromWindowId(
        windowId(),
      ).setTitle(getWindowNameWithId(id));
    };
    tabController.onRemoved = (_, id) => onRemoveId(id);
    tabController.onTeardownTabs = _teardownTabs;
    tabController.add(
      TabInfo(
        key: params['id'],
        label: params['id'],
        selectedIcon: selectedIcon,
        unselectedIcon: unselectedIcon,
        onTabCloseButton: () => _closeTab(params['id']),
        page: FileManagerPage(
          key: ValueKey(params['id']),
          id: params['id'],
          password: params['password'],
          isSharedPassword: params['isSharedPassword'],
          tabController: tabController,
          forceRelay: params['forceRelay'],
          connToken: params['connToken'],
        ),
      ),
    );
    // CRED-006: Redact transient credentials immediately after consumption
    params['password'] = null;
    params['connToken'] = null;
  }

  @override
  void initState() {
    super.initState();

    rustDeskWinManager.setMethodHandler((call, fromWindowId) async {
      debugPrint(
        "[FileTransfer] call ${call.method} with args ${LogSanitizer.sanitize(call.arguments.toString())} from window $fromWindowId to ${windowId()}",
      );
      if (call.method == kWindowEventNewFileTransfer) {
        final args = jsonDecode(call.arguments);
        final id = args['id'];
        windowOnTop(windowId());
        tabController.add(
          TabInfo(
            key: id,
            label: id,
            selectedIcon: selectedIcon,
            unselectedIcon: unselectedIcon,
            onTabCloseButton: () => _closeTab(id),
            page: FileManagerPage(
              key: ValueKey(id),
              id: id,
              password: args['password'],
              isSharedPassword: args['isSharedPassword'],
              tabController: tabController,
              forceRelay: args['forceRelay'],
              connToken: args['connToken'],
            ),
          ),
        );
        args['password'] = null;
        args['connToken'] = null;
      } else if (call.method == kWindowEventActiveSession) {
        final jumpOk = tabController.jumpToByKey(call.arguments);
        if (jumpOk) {
          windowOnTop(windowId());
        }
        return jumpOk;
      } else if (call.method == "onDestroy") {
        await tabController.closeWindow(skipConfirm: true);
      } else if (call.method == kWindowActionRebuild) {
        reloadCurrentWindow();
      }
    });
    Future.delayed(Duration.zero, () {
      restoreWindowPosition(WindowType.FileTransfer, windowId: windowId());
    });
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
        labelGetter: DesktopTab.tablabelGetter,
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

  Future<void> _teardownTabs(List<TabInfo> tabs) async {
    final futures = <Future<void>>[];
    for (final tab in tabs) {
      final page = tab.page;
      if (page is FileManagerPage) {
        futures.add(
          page.teardown().catchError((e) {
            debugPrint(
              '[FileManagerTabPage] Teardown failed for ${tab.key}: $e',
            );
          }),
        );
      }
    }
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }
  }

  Future<void> _closeTab(String id) async {
    if (await desktopTryShowTabAuditDialogCloseCancelled(
      id: id,
      tabController: tabController,
    )) {
      return;
    }
    final page = tabController.widget(id);
    if (page is FileManagerPage) {
      try {
        await page.teardown().timeout(const Duration(seconds: 3));
      } catch (e) {
        debugPrint('[FileManagerTabPage] Teardown failed for $id: $e');
      }
    }
    tabController.closeBy(id);
  }

  void onRemoveId(String id) {
    if (!tabController.suppressEmptyWindowClose &&
        tabController.state.value.tabs.isEmpty) {
      unawaited(tabController.closeWindow(skipConfirm: true));
    }
  }

  int windowId() {
    return widget.params["windowId"];
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
      return true;
    }
    if (connLength <= 0) {
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
