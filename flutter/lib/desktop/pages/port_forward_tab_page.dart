import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/desktop/pages/port_forward_page.dart';
import 'package:camellia_remote_app/desktop/widgets/tabbar_widget.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:camellia_remote_app/utils/multi_window_manager.dart';
import 'package:camellia_remote_app/utils/sanitizer.dart';
import 'package:get/get.dart';

class PortForwardTabPage extends StatefulWidget {
  final Map<String, dynamic> params;

  const PortForwardTabPage({Key? key, required this.params}) : super(key: key);

  @override
  State<PortForwardTabPage> createState() => _PortForwardTabPageState(params);
}

class _PortForwardTabPageState extends State<PortForwardTabPage> {
  late final DesktopTabController tabController;
  late final bool isRDP;

  static const IconData selectedIcon = CamelliaIcons.tunnel;
  static const IconData unselectedIcon = CamelliaIcons.tunnel;

  _PortForwardTabPageState(Map<String, dynamic> params) {
    isRDP = params['isRDP'];
    tabController = Get.put(
      DesktopTabController(tabType: DesktopTabType.portForward),
    );
    tabController.onSelected = (id) {
      WindowController.fromWindowId(
        windowId(),
      ).setTitle(getWindowNameWithId(id));
    };
    tabController.onRemoved = (_, id) => onRemoveId(id);
    tabController.add(
      TabInfo(
        key: params['id'],
        label: params['id'],
        selectedIcon: selectedIcon,
        unselectedIcon: unselectedIcon,
        page: PortForwardPage(
          key: ValueKey(params['id']),
          id: params['id'],
          password: params['password'],
          isSharedPassword: params['isSharedPassword'],
          tabController: tabController,
          isRDP: isRDP,
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
        "[Port Forward] call ${call.method} with args ${LogSanitizer.sanitize(call.arguments.toString())} from window $fromWindowId",
      );
      if (call.method == kWindowEventNewPortForward) {
        final args = jsonDecode(call.arguments);
        final id = args['id'];
        final isRDP = args['isRDP'];
        windowOnTop(windowId());
        if (tabController.state.value.tabs.indexWhere((e) => e.key == id) >=
            0) {
          tabController.jumpToByKey(id);
          return null;
        }
        tabController.add(
          TabInfo(
            key: id,
            label: id,
            selectedIcon: selectedIcon,
            unselectedIcon: unselectedIcon,
            page: PortForwardPage(
              key: ValueKey(args['id']),
              id: id,
              password: args['password'],
              isSharedPassword: args['isSharedPassword'],
              isRDP: isRDP,
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
        tabController.clear();
      } else if (call.method == kWindowActionRebuild) {
        reloadCurrentWindow();
      }
    });
    Future.delayed(Duration.zero, () {
      restoreWindowPosition(WindowType.PortForward, windowId: windowId());
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
        onWindowCloseButton: () async {
          final connLength = tabController.state.value.tabs.length;
          if (connLength <= 1) {
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
        },
        tail: const AddButton(),
        selectedBorderColor: Theme.of(context).colorScheme.primary,
        labelGetter: DesktopTab.tablabelGetter,
      ),
    );
    final tabWidget = isLinux
        ? buildVirtualWindowFrame(
            context,
            Scaffold(
              backgroundColor: Theme.of(context).colorScheme.surface,
              body: child,
            ),
          )
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
        : Obx(
            () => SubWindowDragToResizeArea(
              child: tabWidget,
              resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
              enableResizeEdges: subWindowManagerEnableResizeEdges,
              windowId: stateGlobal.windowId,
            ),
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

  int windowId() {
    return widget.params["windowId"];
  }
}
