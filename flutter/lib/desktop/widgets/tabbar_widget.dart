import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:bot_toast/bot_toast.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide TabBarTheme;
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/desktop/pages/remote_page.dart';
import 'package:camellia_remote_app/desktop/pages/view_camera_page.dart';
import 'package:camellia_remote_app/main.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:get/get.dart';
import 'package:get/get_rx/src/rx_workers/utils/debouncer.dart';
import 'package:scroll_pos/scroll_pos.dart';
import 'package:window_manager/window_manager.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../utils/multi_window_manager.dart';

const double _kTabBarHeight = 40.0;
const double _kIconSize = 16.0;
const double _kActionIconSize = 15.0;

class TabInfo {
  final String key; // Notice: cm use client_id.toString() as key
  final String label;
  final IconData? selectedIcon;
  final IconData? unselectedIcon;
  final bool closable;
  final VoidCallback? onTabCloseButton;
  final VoidCallback? onTap;
  final Widget page;

  TabInfo({
    required this.key,
    required this.label,
    this.selectedIcon,
    this.unselectedIcon,
    this.closable = true,
    this.onTabCloseButton,
    this.onTap,
    required this.page,
  });
}

enum DesktopTabType {
  main,
  cm,
  remoteScreen,
  fileTransfer,
  viewCamera,
  portForward,
  terminal,
  install,
}

class DesktopTabState {
  final List<TabInfo> tabs = [];
  final ScrollPosController scrollController = ScrollPosController(
    itemCount: 0,
  );
  final PageController pageController = PageController();
  int selected = 0;

  TabInfo get selectedTabInfo => tabs[selected];

  DesktopTabState() {
    scrollController.itemCount = tabs.length;
  }
}

CancelFunc showRightMenu(
  ToastBuilder builder, {
  BuildContext? context,
  Offset? target,
}) {
  return BotToast.showAttachedWidget(
    target: target,
    targetContext: context,
    verticalOffset: 4.0,
    horizontalOffset: 0.0,
    duration: const Duration(seconds: 300),
    animationDuration: const Duration(milliseconds: 120),
    animationReverseDuration: const Duration(milliseconds: 90),
    preferDirection: PreferDirection.rightTop,
    ignoreContentClick: false,
    onlyOne: true,
    allowClick: true,
    enableSafeArea: true,
    backgroundColor: Colors.transparent,
    attachedBuilder: builder,
  );
}

/// Frosted 36px-row context menu card matching Precision Studio Architecture.
class FrostedPopupMenuCard extends StatelessWidget {
  const FrostedPopupMenuCard({
    super.key,
    required this.children,
    this.minWidth = 200,
    this.maxWidth = 280,
  });

  final List<Widget> children;
  final double minWidth;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth, maxWidth: maxWidth),
      child: GlassSurface(
        layer: CamelliaGlassLayer.modal,
        elevated: true,
        borderRadius: BorderRadius.circular(CamelliaRadius.surface),
        strokeWidth: 0.85,
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
        child: Material(
          type: MaterialType.transparency,
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

class FrostedMenuDivider extends StatelessWidget {
  const FrostedMenuDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens =
        Theme.of(context).extension<AppDesignTokens>() ??
        AppVisual.tokens(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: ColoredBox(
        color: tokens.border.withValues(alpha: 0.72),
        child: const SizedBox(height: 0.85),
      ),
    );
  }
}

class FrostedMenuItem extends StatefulWidget {
  const FrostedMenuItem({
    super.key,
    required this.label,
    this.icon,
    this.trailing,
    this.shortcut,
    this.destructive = false,
    this.onTap,
  });

  final String label;
  final IconData? icon;
  final Widget? trailing;
  final String? shortcut;
  final bool destructive;
  final VoidCallback? onTap;

  @override
  State<FrostedMenuItem> createState() => _FrostedMenuItemState();
}

class _FrostedMenuItemState extends State<FrostedMenuItem> {
  bool _hovered = false;

  bool get _enabled => widget.onTap != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final fg = !_enabled
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.45)
        : widget.destructive
        ? glass.statusAlert
        : theme.colorScheme.onSurface;
    final iconColor = !_enabled
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.40)
        : widget.destructive
        ? glass.statusAlert
        : (theme.brightness == Brightness.dark
              ? theme.colorScheme.secondary
              : theme.colorScheme.primary);

    return MouseRegion(
      cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (mounted) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (mounted) setState(() => _hovered = false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
          curve: CamelliaMotion.standard,
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: _hovered && _enabled
                ? (widget.destructive
                      ? glass.statusAlert.withValues(alpha: 0.14)
                      : glass.hoverOverlay)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(CamelliaRadius.control),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 16, color: iconColor),
                const SizedBox(width: 9),
              ],
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: fg,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (widget.shortcut != null) ...[
                const SizedBox(width: 12),
                Text(
                  widget.shortcut!,
                  style: CamelliaTypography.tabular(
                    theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              if (widget.trailing != null) ...[
                const SizedBox(width: 8),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class FrostedMenuToggleItem extends StatefulWidget {
  const FrostedMenuToggleItem({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.icon,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final IconData? icon;

  @override
  State<FrostedMenuToggleItem> createState() => _FrostedMenuToggleItemState();
}

class _FrostedMenuToggleItemState extends State<FrostedMenuToggleItem> {
  late bool _checked = widget.value;

  @override
  void didUpdateWidget(covariant FrostedMenuToggleItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _checked = widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.brightness == Brightness.dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    return FrostedMenuItem(
      label: widget.label,
      icon: widget.icon,
      onTap: widget.onChanged == null
          ? null
          : () {
              final next = !_checked;
              setState(() => _checked = next);
              widget.onChanged!(next);
            },
      trailing: AnimatedContainer(
        duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: _checked ? accent : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: _checked ? accent : theme.colorScheme.outline,
            width: 1.1,
          ),
        ),
        child: _checked
            ? const Icon(CamelliaIcons.check, size: 13, color: Colors.white)
            : null,
      ),
    );
  }
}

/// Presents a frosted glass popup menu anchored at [globalPosition].
Future<void> showFrostedContextMenu({
  required BuildContext context,
  required Offset globalPosition,
  required List<Widget> Function(VoidCallback close) itemsBuilder,
  double minWidth = 200,
  double maxWidth = 280,
}) {
  final completer = Completer<void>();
  late final CancelFunc cancel;
  void closeMenu() {
    cancel();
    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  cancel = showRightMenu(
    (_) => FrostedPopupMenuCard(
      minWidth: minWidth,
      maxWidth: maxWidth,
      children: itemsBuilder(closeMenu),
    ),
    target: globalPosition,
  );
  return completer.future;
}

class DesktopTabController {
  final state = DesktopTabState().obs;
  final DesktopTabType tabType;

  /// index, key
  Function(int, String)? onRemoved;
  Function(String)? onSelected;
  Future<void> Function()? onCloseWindow;
  Future<void> Function(List<TabInfo> tabs)? onTeardownTabs;
  bool suppressEmptyWindowClose = false;
  Future<void> Function({bool skipConfirm})? _windowCloseHandler;

  DesktopTabController({
    required this.tabType,
    this.onRemoved,
    this.onSelected,
  });

  void bindWindowCloseHandler(
    Future<void> Function({bool skipConfirm}) handler,
  ) {
    _windowCloseHandler = handler;
  }

  void unbindWindowCloseHandler(
    Future<void> Function({bool skipConfirm}) handler,
  ) {
    if (identical(_windowCloseHandler, handler)) {
      _windowCloseHandler = null;
    }
  }

  Future<void> closeWindow({bool skipConfirm = false}) async {
    final handler = _windowCloseHandler;
    if (handler != null) {
      await handler(skipConfirm: skipConfirm);
      return;
    }
    final wId = kWindowId;
    if (wId == null) return;
    final activeTabs = List<TabInfo>.from(state.value.tabs);
    suppressEmptyWindowClose = true;
    try {
      if (onTeardownTabs != null) {
        await onTeardownTabs!(activeTabs).timeout(
          const Duration(seconds: 4),
          onTimeout: () {},
        );
      }
    } catch (e) {
      debugPrint('[DesktopTabController] Fallback teardown error: $e');
    }
    if (state.value.tabs.isNotEmpty) {
      clear();
    }
    try {
      await rustDeskWinManager.call(WindowType.Main, kWindowEventHide, {
        "id": wId,
      });
    } catch (e) {
      debugPrint('[DesktopTabController] Failed to notify main window hide: $e');
    }
    final wc = WindowController.fromWindowId(wId);
    try {
      await wc.setPreventClose(false);
    } catch (_) {}
    try {
      await wc.close();
    } catch (e) {
      debugPrint('[DesktopTabController] Failed to close window $wId: $e');
    }
  }

  int get length => state.value.tabs.length;

  void add(TabInfo tab) {
    if (!isDesktop) return;
    final index = state.value.tabs.indexWhere((e) => e.key == tab.key);
    int toIndex;
    if (index >= 0) {
      toIndex = index;
    } else {
      state.update((val) {
        val!.tabs.add(tab);
      });
      state.value.scrollController.itemCount = state.value.tabs.length;
      toIndex = state.value.tabs.length - 1;
      assert(toIndex >= 0);
    }
    try {
      // tabPage has not been initialized, call `onSelected` at the end of initState
      jumpTo(toIndex, callOnSelected: false);
    } catch (e) {
      // call before binding controller will throw
      debugPrint("Failed to jumpTo: $e");
    }
  }

  void remove(int index) {
    if (!isDesktop) return;
    final len = state.value.tabs.length;
    if (index < 0 || index > len - 1) return;
    final key = state.value.tabs[index].key;
    final currentSelected = state.value.selected;
    int toIndex = 0;
    if (index == len - 1) {
      toIndex = max(0, currentSelected - 1);
    } else if (index < len - 1 && index < currentSelected) {
      toIndex = max(0, currentSelected - 1);
    }
    state.value.tabs.removeAt(index);
    state.value.scrollController.itemCount = state.value.tabs.length;
    jumpTo(toIndex);
    onRemoved?.call(index, key);
  }

  int _jumpToken = 0;
  Timer? _jumpTimer;

  void dispose() {
    _jumpTimer?.cancel();
    _jumpTimer = null;
    _jumpToken++;
  }

  /// For addTab, tabPage has not been initialized, set [callOnSelected] to false,
  /// and call [onSelected] at the end of initState
  bool jumpTo(int index, {bool callOnSelected = true}) {
    if (!isDesktop || index < 0) {
      return false;
    }
    _jumpTimer?.cancel();
    final currentToken = ++_jumpToken;
    state.update((val) {
      if (val != null) {
        val.selected = index;
        _jumpTimer = Timer(const Duration(milliseconds: 100), () {
          if (currentToken != _jumpToken) return;
          if (val.pageController.hasClients) {
            val.pageController.jumpToPage(index);
          }
          val.scrollController.itemCount = val.tabs.length;
          if (currentToken == _jumpToken &&
              val.scrollController.hasClients &&
              val.scrollController.itemCount > index) {
            val.scrollController.scrollToItem(
              index,
              center: false,
              animate: true,
            );
          }
        });
      }
    });
    if ((isDesktop && (bind.isIncomingOnly() || bind.isOutgoingOnly())) ||
        callOnSelected) {
      if (state.value.tabs.length > index) {
        final key = state.value.tabs[index].key;
        onSelected?.call(key);
      }
    }
    return true;
  }

  bool jumpToByKey(String key, {bool callOnSelected = true}) => jumpTo(
    state.value.tabs.indexWhere((tab) => tab.key == key),
    callOnSelected: callOnSelected,
  );

  bool jumpToByKeyAndDisplay(String key, int display, {bool isCamera = false}) {
    for (int i = 0; i < state.value.tabs.length; i++) {
      final tab = state.value.tabs[i];
      if (tab.key == key) {
        final ffi = isCamera
            ? (tab.page as ViewCameraPage).ffi
            : (tab.page as RemotePage).ffi;
        if (ffi.ffiModel.pi.currentDisplay == display) {
          return jumpTo(i, callOnSelected: true);
        }
      }
    }
    return false;
  }

  void closeBy(String? key) {
    if (!isDesktop) return;
    assert(onRemoved != null);
    if (key == null) {
      if (state.value.selected < state.value.tabs.length) {
        remove(state.value.selected);
      }
    } else {
      final index = state.value.tabs.indexWhere((tab) => tab.key == key);
      remove(index);
    }
  }

  void clear() {
    if (!isDesktop) return;
    final tabsToClear = List<TabInfo>.from(state.value.tabs);
    state.value.tabs.clear();
    state.value.selected = 0;
    state.value.scrollController.itemCount = 0;
    for (int i = tabsToClear.length - 1; i >= 0; i--) {
      try {
        onRemoved?.call(i, tabsToClear[i].key);
      } catch (e) {
        debugPrint('Error invoking onRemoved during clear: $e');
      }
    }
    state.refresh();
  }

  Widget? widget(String key) {
    return state.value.tabs.firstWhereOrNull((tab) => tab.key == key)?.page;
  }
}

class TabThemeConf {
  double iconSize;

  TabThemeConf({required this.iconSize});
}

typedef TabBuilder =
    Widget Function(
      String key,
      Widget icon,
      Widget label,
      TabThemeConf themeConf,
    );
typedef TabMenuBuilder = Widget Function(String key);
typedef LabelGetter = Rx<String> Function(String key);

/// [_lastClickTime], help to handle double click
int _lastClickTime = 0;

class DesktopTab extends StatefulWidget {
  final bool showLogo;
  final bool showTitle;
  final bool showMinimize;
  final bool showMaximize;
  final bool showClose;
  final Widget Function(Widget pageView)? pageViewBuilder;
  // Right click tab menu
  final TabMenuBuilder? tabMenuBuilder;
  final Widget? tail;
  final Future<bool> Function()? onWindowCloseButton;
  final TabBuilder? tabBuilder;
  final LabelGetter? labelGetter;
  final double? maxLabelWidth;
  final Color? selectedTabBackgroundColor;
  final Color? unSelectedTabBackgroundColor;
  final Color? selectedBorderColor;
  final void Function(int index, TabInfo tab)? onTabDetach;

  final DesktopTabController controller;

  final _scrollDebounce = Debouncer(delay: const Duration(milliseconds: 50));

  final RxList<String> invisibleTabKeys = RxList.empty();

  DesktopTab({
    Key? key,
    required this.controller,
    this.showLogo = true,
    this.showTitle = false,
    this.showMinimize = true,
    this.showMaximize = true,
    this.showClose = true,
    this.pageViewBuilder,
    this.tabMenuBuilder,
    this.tail,
    this.onWindowCloseButton,
    this.tabBuilder,
    this.labelGetter,
    this.maxLabelWidth,
    this.selectedTabBackgroundColor,
    this.unSelectedTabBackgroundColor,
    this.selectedBorderColor,
    this.onTabDetach,
  }) : super(key: key);

  static RxString tablabelGetter(String peerId) {
    final alias = bind.mainGetPeerOptionSync(id: peerId, key: 'alias');
    return RxString(getDesktopTabLabel(peerId, alias));
  }

  @override
  State<DesktopTab> createState() {
    return _DesktopTabState();
  }
}

// ignore: must_be_immutable
class _DesktopTabState extends State<DesktopTab>
    with MultiWindowListener, WindowListener {
  Timer? _macOSCheckRestoreTimer;
  Timer? _macOSFollowupCloseTimer;
  int _macOSCheckRestoreCounter = 0;
  int _macOSCloseGeneration = 0;
  bool _isClosingWindow = false;

  bool get showLogo => widget.showLogo;
  bool get showTitle => widget.showTitle;
  bool get showMinimize => widget.showMinimize;
  bool get showMaximize => widget.showMaximize;
  bool get showClose => widget.showClose;
  Widget Function(Widget pageView)? get pageViewBuilder =>
      widget.pageViewBuilder;
  TabMenuBuilder? get tabMenuBuilder => widget.tabMenuBuilder;
  Widget? get tail => widget.tail;
  Future<bool> Function()? get onWindowCloseButton =>
      widget.onWindowCloseButton;
  TabBuilder? get tabBuilder => widget.tabBuilder;
  LabelGetter? get labelGetter => widget.labelGetter;
  double? get maxLabelWidth => widget.maxLabelWidth;
  Color? get selectedTabBackgroundColor => widget.selectedTabBackgroundColor;
  Color? get unSelectedTabBackgroundColor =>
      widget.unSelectedTabBackgroundColor;
  Color? get selectedBorderColor => widget.selectedBorderColor;
  DesktopTabController get controller => widget.controller;
  RxList<String> get invisibleTabKeys => widget.invisibleTabKeys;
  Debouncer get _scrollDebounce => widget._scrollDebounce;

  Rx<DesktopTabState> get state => controller.state;

  DesktopTabType get tabType => controller.tabType;
  bool get isMainWindow =>
      tabType == DesktopTabType.main ||
      tabType == DesktopTabType.cm ||
      tabType == DesktopTabType.install;

  _DesktopTabState() : super();

  @override
  void initState() {
    super.initState();
    DesktopMultiWindow.addListener(this);
    windowManager.addListener(this);
    if (!isMainWindow) {
      controller.bindWindowCloseHandler(_closeSubWindow);
      controller.onCloseWindow ??= () =>
          controller.closeWindow(skipConfirm: true);
    }

    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      if (isMainWindow) {
        windowManager.isMaximized().then((maximized) {
          if (!mounted) return;
          if (stateGlobal.isMaximized.value != maximized) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() => stateGlobal.setMaximized(maximized));
              }
            });
          }
        });
      } else if (kWindowId != null) {
        final wc = WindowController.fromWindowId(kWindowId!);
        wc.isMaximized().then((maximized) {
          if (!mounted) return;
          if (stateGlobal.isMaximized.value != maximized) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() => stateGlobal.setMaximized(maximized));
              }
            });
          }
        });
      }
    });
  }

  @override
  void dispose() {
    controller.unbindWindowCloseHandler(_closeSubWindow);
    DesktopMultiWindow.removeListener(this);
    windowManager.removeListener(this);
    _macOSCloseGeneration++;
    _macOSCheckRestoreTimer?.cancel();
    _macOSCheckRestoreTimer = null;
    _macOSFollowupCloseTimer?.cancel();
    _macOSFollowupCloseTimer = null;
    super.dispose();
  }

  void _setMaximized(bool maximize) {
    stateGlobal.setMaximized(maximize);
    _saveFrame();
    setState(() {});
  }

  @override
  void onWindowFocus() {
    stateGlobal.isFocused.value = true;
  }

  @override
  void onWindowBlur() {
    stateGlobal.isFocused.value = false;
  }

  @override
  void onWindowMinimize() {
    stateGlobal.setMinimized(true);
    stateGlobal.setMaximized(false);
    super.onWindowMinimize();
  }

  @override
  void onWindowMaximize() {
    stateGlobal.setMinimized(false);
    _setMaximized(true);
    super.onWindowMaximize();
  }

  @override
  void onWindowUnmaximize() {
    stateGlobal.setMinimized(false);
    _setMaximized(false);
    super.onWindowUnmaximize();
  }

  _saveFrame({bool? flush}) async {
    try {
      if (tabType == DesktopTabType.main) {
        await saveWindowPosition(WindowType.Main, flush: flush);
      } else if (kWindowType != null && kWindowId != null) {
        await saveWindowPosition(
          kWindowType!,
          windowId: kWindowId,
          flush: flush,
        );
      }
    } catch (e) {
      debugPrint('Error saving window position: $e');
    }
  }

  @override
  void onWindowMoved() {
    _saveFrame();
    super.onWindowMoved();
  }

  @override
  void onWindowResized() {
    _saveFrame();
    super.onWindowResized();
  }

  Future<void> _exitMacOSFullScreenIfNeeded(WindowController wc) async {
    try {
      if (!await wc.isFullScreen()) return;
      await wc.setFullscreen(false);
      stateGlobal.setFullscreen(false, procWnd: false);
      for (int i = 0; i < 30; i++) {
        await Future.delayed(const Duration(milliseconds: 30));
        if (!mounted) return;
        if (!await wc.isFullScreen()) break;
      }
      if (!mounted) return;
      await Future.delayed(const Duration(milliseconds: 700));
    } catch (e) {
      debugPrint('[DesktopTab] Failed to exit macOS fullscreen: $e');
    }
  }

  Future<void> _defaultTeardownTabs(List<TabInfo> tabs) async {
    final futures = <Future<void>>[];
    for (final tab in tabs) {
      final page = tab.page;
      if (page is RemotePage) {
        futures.add(page.teardown());
      } else if (page is ViewCameraPage) {
        futures.add(page.teardown());
      }
    }
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }
  }

  Future<void> _closeSubWindow({
    bool skipConfirm = false,
    bool bringToFront = false,
  }) async {
    if (_isClosingWindow) return;
    final wId = kWindowId;
    if (wId == null) return;
    _isClosingWindow = true;

    try {
      final wc = WindowController.fromWindowId(wId);
      if (!skipConfirm && onWindowCloseButton != null && controller.length > 0) {
        if (bringToFront && (isWindows || isLinux)) {
          try {
            await wc.show();
            await wc.focus();
          } catch (_) {}
        }
        final confirmed = await onWindowCloseButton!();
        if (!confirmed) {
          _isClosingWindow = false;
          return;
        }
      }

      await _saveFrame(flush: true);

      if (isMacOS) {
        await _exitMacOSFullScreenIfNeeded(wc);
      }

      final activeTabs = List<TabInfo>.from(controller.state.value.tabs);
      controller.suppressEmptyWindowClose = true;
      try {
        if (controller.onTeardownTabs != null) {
          await controller.onTeardownTabs!(activeTabs).timeout(
            const Duration(seconds: 4),
            onTimeout: () {
              debugPrint('[DesktopTab] Tab teardown timed out on window $wId');
            },
          );
        } else {
          await _defaultTeardownTabs(activeTabs).timeout(
            const Duration(seconds: 4),
            onTimeout: () {
              debugPrint(
                '[DesktopTab] Default tab teardown timed out on window $wId',
              );
            },
          );
        }
      } catch (e) {
        debugPrint('[DesktopTab] Tab teardown error on window $wId: $e');
      }

      if (controller.state.value.tabs.isNotEmpty) {
        controller.clear();
      }

      try {
        await rustDeskWinManager.call(WindowType.Main, kWindowEventHide, {
          "id": wId,
        });
      } catch (e) {
        debugPrint('[DesktopTab] Failed to notify main window on close: $e');
      }

      try {
        await wc.setPreventClose(false);
      } catch (e) {
        debugPrint('[DesktopTab] Failed to setPreventClose(false): $e');
      }
      try {
        await wc.close();
      } catch (e) {
        debugPrint('[DesktopTab] Failed to close window $wId: $e');
      }
    } catch (e) {
      debugPrint('[DesktopTab] Error in _closeSubWindow: $e');
      _isClosingWindow = false;
    }
  }

  @override
  void onWindowClose() async {
    mainWindowClose() async => await windowManager.hide();

    macOSWindowClose(
      Future<bool> Function() checkFullscreen,
      Future<void> Function() closeFunc,
    ) async {
      _macOSCheckRestoreTimer?.cancel();
      _macOSFollowupCloseTimer?.cancel();
      final myGen = ++_macOSCloseGeneration;
      _macOSCheckRestoreCounter = 0;
      _macOSCheckRestoreTimer = Timer.periodic(
        const Duration(milliseconds: 30),
        (timer) async {
          if (myGen != _macOSCloseGeneration || !mounted) {
            timer.cancel();
            return;
          }
          _macOSCheckRestoreCounter++;
          final isFs = await checkFullscreen();
          if (myGen != _macOSCloseGeneration || !mounted) {
            timer.cancel();
            return;
          }
          if (!isFs || _macOSCheckRestoreCounter >= 30) {
            timer.cancel();
            if (_macOSCheckRestoreTimer == timer) {
              _macOSCheckRestoreTimer = null;
            }
            _macOSFollowupCloseTimer?.cancel();
            _macOSFollowupCloseTimer = Timer(
              const Duration(milliseconds: 700),
              () async {
                if (myGen == _macOSCloseGeneration && mounted) {
                  await closeFunc();
                }
              },
            );
          }
        },
      );
    }

    if (isMainWindow) {
      await _saveFrame(flush: true);
      if (rustDeskWinManager.getActiveWindows().contains(kMainWindowId)) {
        await rustDeskWinManager.unregisterActiveWindow(kMainWindowId);
      }
      if (isMacOS && await windowManager.isFullScreen()) {
        await windowManager.setFullScreen(false);
        await macOSWindowClose(
          () async => await windowManager.isFullScreen(),
          mainWindowClose,
        );
      } else {
        await mainWindowClose();
      }
    } else if (kWindowId != null) {
      await _closeSubWindow(bringToFront: true);
    }
    super.onWindowClose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens =
        Theme.of(context).extension<AppDesignTokens>() ??
        AppVisual.tokens(context);
    final glass = CamelliaGlassTokens.of(context);
    return Column(
      children: [
        Obx(() {
          if (stateGlobal.showTabBar.isTrue) {
            return Container(
              height: _kTabBarHeight,
              decoration: BoxDecoration(
                color: glass.sidebarTint,
                border: Border(
                  bottom: BorderSide(
                    color: tokens.border.withValues(alpha: 0.72),
                    width: 0.85,
                  ),
                ),
              ),
              child: _buildBar(),
            );
          } else {
            return const Offstage();
          }
        }),
        Expanded(
          child: pageViewBuilder != null
              ? pageViewBuilder!(_buildPageView())
              : _buildPageView(),
        ),
      ],
    );
  }

  List<Widget> _tabWidgets = [];
  Widget _buildPageView() {
    final child = Obx(
      () => PageView(
        controller: state.value.pageController,
        physics: const NeverScrollableScrollPhysics(),
        children: () {
          if (DesktopTabType.cm == tabType) {
            return state.value.tabs.map((tab) {
              return tab.page;
            }).toList();
          }

          final tabLen = state.value.tabs.length;
          if (tabLen == _tabWidgets.length) {
            return _tabWidgets;
          } else if (_tabWidgets.isNotEmpty &&
              tabLen == _tabWidgets.length + 1) {
            _tabWidgets.add(state.value.tabs.last.page);
            return _tabWidgets;
          } else {
            final newList = state.value.tabs.map((v) => v.page).toList();
            _tabWidgets = newList;
            return newList;
          }
        }(),
      ),
    );
    if (tabType == DesktopTabType.remoteScreen) {
      return ColoredBox(color: kColorCanvas, child: child);
    } else {
      return child;
    }
  }

  bool isHideSingleItem() {
    return state.value.tabs.length == 1 &&
        (controller.tabType == DesktopTabType.main ||
            controller.tabType == DesktopTabType.install);
  }

  Widget _buildBar() {
    final isIncomingHomePage = bind.isIncomingOnly() && isInHomePage();
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: !isIncomingHomePage && showMaximize
                ? () {
                    final current = DateTime.now().millisecondsSinceEpoch;
                    final elapsed = current - _lastClickTime;
                    _lastClickTime = current;
                    if (elapsed < bind.getDoubleClickTime()) {
                      toggleMaximize(
                        isMainWindow,
                      ).then((value) => stateGlobal.setMaximized(value));
                    }
                  }
                : (isIncomingHomePage ? () {} : null),
            onPanStart: (_) => startDragging(isMainWindow),
            onPanCancel: () {
              if (isMacOS) {
                setMovable(isMainWindow, false);
              }
            },
            onPanEnd: (_) {
              if (isMacOS) {
                setMovable(isMainWindow, false);
              }
            },
            child: Row(
              children: [
                if (isMacOS)
                  const SizedBox(width: 78)
                else
                  Padding(
                    padding: const EdgeInsets.only(left: 10, right: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (showLogo) loadIcon(18),
                        if (showTitle)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text(
                              'Camellia',
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                      ],
                    ),
                  ),
                Expanded(
                  child: Listener(
                    onPointerSignal: (e) {
                      if (e is PointerScrollEvent) {
                        final sc = controller.state.value.scrollController;
                        if (!sc.canScroll) return;
                        _scrollDebounce.call(() {
                          const double adjust = 2.5;
                          sc.animateTo(
                            sc.offset + e.scrollDelta.dy * adjust,
                            duration: const Duration(milliseconds: 180),
                            curve: CamelliaMotion.standard,
                          );
                        });
                      }
                    },
                    child: _ListView(
                      controller: controller,
                      invisibleTabKeys: invisibleTabKeys,
                      tabBuilder: tabBuilder,
                      tabMenuBuilder: tabMenuBuilder,
                      labelGetter: labelGetter,
                      maxLabelWidth: maxLabelWidth,
                      selectedTabBackgroundColor: selectedTabBackgroundColor,
                      unSelectedTabBackgroundColor:
                          unSelectedTabBackgroundColor,
                      selectedBorderColor: selectedBorderColor,
                      onTabDetach: widget.onTabDetach,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        WindowActionPanel(
          isMainWindow: isMainWindow,
          state: state,
          tabController: controller,
          invisibleTabKeys: invisibleTabKeys,
          tail: tail,
          showMinimize: showMinimize,
          showMaximize: showMaximize,
          showClose: showClose,
          onClose: onWindowCloseButton,
          onSubWindowClose: isMainWindow ? null : () => _closeSubWindow(),
          labelGetter: labelGetter,
        ).paddingOnly(left: 6),
      ],
    );
  }
}

class WindowActionPanel extends StatefulWidget {
  final bool isMainWindow;
  final Rx<DesktopTabState> state;
  final DesktopTabController tabController;

  final bool showMinimize;
  final bool showMaximize;
  final bool showClose;
  final Widget? tail;
  final Future<bool> Function()? onClose;
  final Future<void> Function()? onSubWindowClose;

  final RxList<String> invisibleTabKeys;
  final LabelGetter? labelGetter;

  const WindowActionPanel({
    Key? key,
    required this.isMainWindow,
    required this.state,
    required this.tabController,
    required this.invisibleTabKeys,
    this.tail,
    this.showMinimize = true,
    this.showMaximize = true,
    this.showClose = true,
    this.onClose,
    this.onSubWindowClose,
    this.labelGetter,
  }) : super(key: key);

  @override
  State<StatefulWidget> createState() {
    return WindowActionPanelState();
  }
}

class WindowActionPanelState extends State<WindowActionPanel> {
  bool showTabDowndown() {
    return widget.tabController.state.value.tabs.length > 1 &&
        (widget.tabController.tabType == DesktopTabType.remoteScreen ||
            widget.tabController.tabType == DesktopTabType.fileTransfer ||
            widget.tabController.tabType == DesktopTabType.viewCamera ||
            widget.tabController.tabType == DesktopTabType.portForward ||
            widget.tabController.tabType == DesktopTabType.terminal ||
            widget.tabController.tabType == DesktopTabType.cm);
  }

  List<String> existingInvisibleTab() {
    return widget.invisibleTabKeys
        .where(
          (key) => widget.tabController.state.value.tabs.any(
            (tab) => tab.key == key,
          ),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Obx(() {
          if (showTabDowndown() && existingInvisibleTab().isNotEmpty) {
            return _TabDropDownButton(
              controller: widget.tabController,
              labelGetter: widget.labelGetter,
              tabkeys: existingInvisibleTab(),
            );
          } else {
            return const Offstage();
          }
        }),
        if (widget.tail != null) widget.tail!,
        if (!isMacOS) ...[
          const SizedBox(width: 4),
          Row(
            children: [
              if (widget.showMinimize)
                ActionIcon(
                  message: 'Minimize',
                  icon: CamelliaIcons.minimize,
                  onTap: () {
                    if (widget.isMainWindow) {
                      windowManager.minimize();
                    } else if (kWindowId != null) {
                      WindowController.fromWindowId(kWindowId!).minimize();
                    }
                  },
                  isClose: false,
                ),
              if (widget.showMaximize)
                Obx(
                  () => ActionIcon(
                    message: stateGlobal.isMaximized.isTrue
                        ? 'Restore'
                        : 'Maximize',
                    icon: stateGlobal.isMaximized.isTrue
                        ? CamelliaIcons.restore
                        : CamelliaIcons.maximize,
                    onTap: bind.isIncomingOnly() && isInHomePage()
                        ? null
                        : _toggleMaximize,
                    isClose: false,
                  ),
                ),
              if (widget.showClose)
                ActionIcon(
                  message: 'Close',
                  icon: CamelliaIcons.close,
                  onTap: () async {
                    if (!widget.isMainWindow &&
                        widget.onSubWindowClose != null) {
                      await widget.onSubWindowClose!();
                      return;
                    }
                    final res = await widget.onClose?.call() ?? true;
                    if (res) {
                      Future.delayed(Duration.zero, () async {
                        if (widget.isMainWindow) {
                          await windowManager.close();
                        } else {
                          await widget.tabController.closeWindow(
                            skipConfirm: true,
                          );
                        }
                      });
                    }
                  },
                  isClose: true,
                ),
            ],
          ),
        ],
      ],
    );
  }

  void _toggleMaximize() {
    toggleMaximize(widget.isMainWindow).then((maximize) {
      stateGlobal.setMaximized(maximize);
    });
  }
}

void startDragging(bool isMainWindow) {
  if (isMainWindow) {
    windowManager.startDragging();
  } else if (kWindowId != null) {
    WindowController.fromWindowId(kWindowId!).startDragging();
  }
}

void setMovable(bool isMainWindow, bool movable) {
  if (isMainWindow) {
    windowManager.setMovable(movable);
  } else if (kWindowId != null) {
    WindowController.fromWindowId(kWindowId!).setMovable(movable);
  }
}

/// return true -> window will be maximize
/// return false -> window will be unmaximize
Future<bool> toggleMaximize(bool isMainWindow) async {
  if (isMainWindow) {
    if (await windowManager.isMaximized()) {
      windowManager.unmaximize();
      return false;
    } else {
      windowManager.maximize();
      return true;
    }
  } else {
    final wc = WindowController.fromWindowId(kWindowId!);
    if (await wc.isMaximized()) {
      wc.unmaximize();
      return false;
    } else {
      wc.maximize();
      return true;
    }
  }
}

/// Studio confirmation dialog for closing multiple tabs.
/// Session subwindows NEVER offer "Minimize to Tray" (hiding a subwindow orphans it).
Future<bool> closeConfirmDialog({bool isSessionWindow = true}) async {
  var confirm = true;
  final isSubwindow =
      isSessionWindow || (kWindowId != null && kWindowId != kMainWindowId);
  final supportsMainTray =
      !isSubwindow && isDesktop && (isWindows || isLinux || isMacOS);
  final useGlobalOverlay = globalKey.currentState?.overlay != null;

  try {
    final res = await gFFI.dialogManager.show<bool>(
      (setState, close, context) {
        final theme = Theme.of(context);
        final tokens =
            theme.extension<AppDesignTokens>() ?? AppVisual.tokens(context);
        final accent = theme.brightness == Brightness.dark
            ? theme.colorScheme.secondary
            : theme.colorScheme.primary;

        void submit() {
          final value = bool2option(kOptionEnableConfirmClosingTabs, confirm);
          bind.mainSetLocalOption(
            key: kOptionEnableConfirmClosingTabs,
            value: value,
          );
          close(true);
        }

        Future<void> minimizeToTray() async {
          close(false);
          await windowManager.hide();
        }

        return CustomAlertDialog(
          title: ModernDialogHeader.warning(
            title: translate('Close all sessions?'),
            subtitle: translate(
              'All active sessions in this window will be disconnected.',
            ),
            onClose: () => close(false),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => confirm = !confirm),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: tokens.surfaceContainer.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(
                        CamelliaRadius.control,
                      ),
                      border: Border.all(
                        color: tokens.border.withValues(alpha: 0.8),
                        width: 0.85,
                      ),
                    ),
                    child: Row(
                      children: [
                        AnimatedContainer(
                          duration: CamelliaMotion.resolve(
                            context,
                            CamelliaMotion.hover,
                          ),
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            color: confirm ? accent : Colors.transparent,
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                              color: confirm ? accent : tokens.border,
                              width: 1.2,
                            ),
                          ),
                          child: confirm
                              ? const Icon(
                                  CamelliaIcons.check,
                                  size: 13,
                                  color: Colors.white,
                                )
                              : null,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            translate('Confirm before closing multiple tabs'),
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            GlassButton(
              variant: GlassButtonVariant.secondary,
              minHeight: 40,
              onPressed: () => close(false),
              child: Text(translate('Cancel')),
            ),
            if (supportsMainTray)
              GlassButton(
                variant: GlassButtonVariant.secondary,
                minHeight: 40,
                icon: const Icon(CamelliaIcons.minimize, size: 16),
                onPressed: minimizeToTray,
                child: Text(translate('Minimize to Tray')),
              ),
            GlassButton(
              variant: GlassButtonVariant.danger,
              minHeight: 40,
              icon: const Icon(CamelliaIcons.close, size: 16),
              onPressed: submit,
              child: Text(translate('Disconnect All')),
            ),
          ],
          onSubmit: submit,
          onCancel: () => close(false),
        );
      },
      forceGlobal: useGlobalOverlay,
    );
    return res == true;
  } catch (e) {
    debugPrint('closeConfirmDialog fallback close on missing overlay: $e');
    return true;
  }
}

class _ListView extends StatelessWidget {
  final DesktopTabController controller;
  final RxList<String> invisibleTabKeys;

  final TabBuilder? tabBuilder;
  final TabMenuBuilder? tabMenuBuilder;
  final LabelGetter? labelGetter;
  final double? maxLabelWidth;
  final Color? selectedTabBackgroundColor;
  final Color? selectedBorderColor;
  final Color? unSelectedTabBackgroundColor;
  final void Function(int index, TabInfo tab)? onTabDetach;

  Rx<DesktopTabState> get state => controller.state;

  const _ListView({
    required this.controller,
    required this.invisibleTabKeys,
    this.tabBuilder,
    this.tabMenuBuilder,
    this.labelGetter,
    this.maxLabelWidth,
    this.selectedTabBackgroundColor,
    this.unSelectedTabBackgroundColor,
    this.selectedBorderColor,
    this.onTabDetach,
  });

  bool isHideSingleItem() {
    return (state.value.tabs.length == 1 &&
            controller.tabType == DesktopTabType.main) ||
        controller.tabType == DesktopTabType.install;
  }

  void onVisibilityChanged(VisibilityInfo info) {
    final key = (info.key as ValueKey).value;
    if (info.visibleFraction < 0.75) {
      if (!invisibleTabKeys.contains(key)) {
        invisibleTabKeys.add(key);
      }
      invisibleTabKeys.removeWhere(
        (key) => controller.state.value.tabs.where((e) => e.key == key).isEmpty,
      );
    } else {
      invisibleTabKeys.remove(key);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => ListView(
        controller: state.value.scrollController,
        scrollDirection: Axis.horizontal,
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        physics: const BouncingScrollPhysics(),
        children: isHideSingleItem()
            ? List.empty()
            : state.value.tabs.asMap().entries.map((e) {
                final index = e.key;
                final tab = e.value;
                final label = labelGetter == null
                    ? Rx<String>(tab.label)
                    : labelGetter!(tab.label);
                final child = VisibilityDetector(
                  key: ValueKey(tab.key),
                  onVisibilityChanged: onVisibilityChanged,
                  child: _Tab(
                    key: ValueKey(tab.key),
                    index: index,
                    tabInfoKey: tab.key,
                    label: label,
                    tabType: controller.tabType,
                    selectedIcon: tab.selectedIcon,
                    unselectedIcon: tab.unselectedIcon,
                    closable: tab.closable,
                    selected: state.value.selected,
                    onClose: () {
                      if (tab.onTabCloseButton != null) {
                        tab.onTabCloseButton!();
                      } else {
                        controller.remove(index);
                      }
                    },
                    onTap: () {
                      controller.jumpTo(index);
                      tab.onTap?.call();
                    },
                    tabBuilder: tabBuilder,
                    tabMenuBuilder: tabMenuBuilder,
                    maxLabelWidth: maxLabelWidth,
                    selectedTabBackgroundColor:
                        selectedTabBackgroundColor ??
                        MyTheme.tabbar(context).selectedTabBackgroundColor,
                    unSelectedTabBackgroundColor: unSelectedTabBackgroundColor,
                    selectedBorderColor: selectedBorderColor,
                  ),
                );
                if (onTabDetach == null) {
                  return child;
                }
                double dragOffsetY = 0.0;
                bool detached = false;
                return GestureDetector(
                  onPanStart: (e) {
                    dragOffsetY = 0.0;
                    detached = false;
                  },
                  onPanUpdate: (details) {
                    if (detached) return;
                    dragOffsetY += details.delta.dy;
                    if (dragOffsetY > 65.0) {
                      detached = true;
                      dragOffsetY = 0.0;
                      onTabDetach!(index, tab);
                    }
                  },
                  onPanEnd: (details) {
                    if (detached) return;
                    if (details.velocity.pixelsPerSecond.dy > 120) {
                      detached = true;
                      onTabDetach!(index, tab);
                    }
                  },
                  onPanCancel: () {
                    dragOffsetY = 0.0;
                    detached = false;
                  },
                  child: child,
                );
              }).toList(),
      ),
    );
  }
}

class _Tab extends StatefulWidget {
  final int index;
  final String tabInfoKey;
  final Rx<String> label;
  final DesktopTabType tabType;
  final IconData? selectedIcon;
  final IconData? unselectedIcon;
  final bool closable;
  final int selected;
  final Function() onClose;
  final Function() onTap;
  final TabBuilder? tabBuilder;
  final TabMenuBuilder? tabMenuBuilder;
  final double? maxLabelWidth;
  final Color? selectedTabBackgroundColor;
  final Color? unSelectedTabBackgroundColor;
  final Color? selectedBorderColor;

  const _Tab({
    Key? key,
    required this.index,
    required this.tabInfoKey,
    required this.label,
    required this.tabType,
    this.selectedIcon,
    this.unselectedIcon,
    this.tabBuilder,
    this.tabMenuBuilder,
    required this.closable,
    required this.selected,
    required this.onClose,
    required this.onTap,
    this.maxLabelWidth,
    this.selectedTabBackgroundColor,
    this.unSelectedTabBackgroundColor,
    this.selectedBorderColor,
  }) : super(key: key);

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> with RestorationMixin {
  final RestorableBool restoreHover = RestorableBool(false);
  bool _hovered = false;

  Widget _buildTabContent(BuildContext context, bool isSelected) {
    final showIcon =
        widget.selectedIcon != null && widget.unselectedIcon != null;
    final tabbarTheme = MyTheme.tabbar(context);

    final icon = Offstage(
      offstage: !showIcon,
      child: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Icon(
          isSelected ? widget.selectedIcon : widget.unselectedIcon,
          size: _kIconSize,
          color: isSelected
              ? tabbarTheme.selectedTabIconColor
              : tabbarTheme.unSelectedTabIconColor,
        ),
      ),
    );

    final labelWidget = Obx(() {
      final textStyle = CamelliaTypography.tabular(
        Theme.of(context).textTheme.labelMedium?.copyWith(
          fontSize: 12.5,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
          color: isSelected
              ? tabbarTheme.selectedTextColor
              : tabbarTheme.unSelectedTextColor,
        ),
      );
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxLabelWidth ?? 188),
        child: Tooltip(
          message: widget.tabType == DesktopTabType.main
              ? ''
              : widget.label.value,
          child: Text(
            widget.tabType == DesktopTabType.main
                ? translate(widget.label.value)
                : widget.label.value,
            textAlign: TextAlign.center,
            style: textStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    });

    Widget getWidgetWithBuilder() {
      if (widget.tabBuilder == null) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [icon, labelWidget],
        );
      } else {
        return widget.tabBuilder!(
          widget.tabInfoKey,
          icon,
          labelWidget,
          TabThemeConf(iconSize: _kIconSize),
        );
      }
    }

    return Listener(
      onPointerDown: (e) {
        if (e.kind != ui.PointerDeviceKind.mouse) {
          return;
        }
        if (e.buttons == 2 && widget.tabMenuBuilder != null) {
          showRightMenu((_) {
            return widget.tabMenuBuilder!(widget.tabInfoKey);
          }, target: e.position);
        }
      },
      child: getWidgetWithBuilder(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.index == widget.selected;
    final glass = CamelliaGlassTokens.of(context);
    final tokens =
        Theme.of(context).extension<AppDesignTokens>() ??
        AppVisual.tokens(context);
    final pillRadius = BorderRadius.circular(CamelliaRadius.control);
    final dark = Theme.of(context).brightness == Brightness.dark;

    final Color bgColor = isSelected
        ? (widget.selectedTabBackgroundColor ?? glass.floatingTint)
        : (_hovered
              ? glass.hoverOverlay
              : (widget.unSelectedTabBackgroundColor ?? Colors.transparent));

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2.5, vertical: 4),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) {
            if (mounted) {
              setState(() => _hovered = true);
              restoreHover.value = true;
            }
          },
          onExit: (_) {
            if (mounted) {
              setState(() => _hovered = false);
              restoreHover.value = false;
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
              curve: CamelliaMotion.standard,
              height: 31,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: pillRadius,
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: glass.ambientShadow.withValues(
                            alpha: dark ? 0.34 : 0.14,
                          ),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : const [],
              ),
              child: CustomPaint(
                foregroundPainter: isSelected
                    ? SpecularEdgePainter(
                        borderRadius: pillRadius,
                        topColor: glass.specularTop,
                        bottomColor: tokens.border.withValues(alpha: 0.75),
                        strokeWidth: 0.85,
                      )
                    : null,
                child: Padding(
                  padding: EdgeInsets.only(
                    left: 11,
                    right: widget.closable ? 6 : 11,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _buildTabContent(context, isSelected),
                      if (widget.closable)
                        _CloseButton(
                          visible: isSelected || _hovered,
                          tabSelected: isSelected,
                          onClose: widget.onClose,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  String? get restorationId => "_Tab${widget.label.value}";

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(restoreHover, 'restoreHover');
  }
}

class _CloseButton extends StatefulWidget {
  final bool visible;
  final bool tabSelected;
  final VoidCallback onClose;

  const _CloseButton({
    Key? key,
    required this.visible,
    required this.tabSelected,
    required this.onClose,
  }) : super(key: key);

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final glass = CamelliaGlassTokens.of(context);
    final tabbarTheme = MyTheme.tabbar(context);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: SizedBox(
        width: 20,
        height: 20,
        child: AnimatedOpacity(
          duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
          opacity: widget.visible ? 1.0 : 0.0,
          child: IgnorePointer(
            ignoring: !widget.visible,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onClose,
                child: AnimatedContainer(
                  duration: CamelliaMotion.resolve(
                    context,
                    CamelliaMotion.hover,
                  ),
                  decoration: BoxDecoration(
                    color: _hovered
                        ? glass.statusAlert.withValues(alpha: 0.16)
                        : Colors.transparent,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Icon(
                      CamelliaIcons.close,
                      size: 13.5,
                      color: _hovered
                          ? glass.statusAlert
                          : (widget.tabSelected
                                ? tabbarTheme.selectedIconColor
                                : tabbarTheme.unSelectedIconColor),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ActionIcon extends StatefulWidget {
  final String? message;
  final IconData icon;
  final GestureTapCallback? onTap;
  final GestureTapDownCallback? onTapDown;
  final bool isClose;
  final double iconSize;
  final double boxSize;

  const ActionIcon({
    Key? key,
    this.message,
    required this.icon,
    this.onTap,
    this.onTapDown,
    this.isClose = false,
    this.iconSize = _kActionIconSize,
    this.boxSize = 32.0,
  }) : super(key: key);

  @override
  State<ActionIcon> createState() => _ActionIconState();
}

class _ActionIconState extends State<ActionIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final glass = CamelliaGlassTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.onTap != null || widget.onTapDown != null;
    final tip = widget.message != null && widget.message!.isNotEmpty
        ? translate(widget.message!)
        : '';

    Widget button = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (mounted) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (mounted) setState(() => _hovered = false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: widget.onTapDown,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: AnimatedContainer(
            duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
            curve: CamelliaMotion.standard,
            height: widget.boxSize,
            width: widget.boxSize,
            decoration: BoxDecoration(
              color: _hovered && enabled
                  ? (widget.isClose ? glass.statusAlert : glass.hoverOverlay)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(CamelliaRadius.control - 2),
            ),
            child: Center(
              child: Icon(
                widget.icon,
                size: widget.iconSize,
                color: !enabled
                    ? scheme.onSurfaceVariant.withValues(alpha: 0.42)
                    : (_hovered && widget.isClose
                          ? Colors.white
                          : MyTheme.tabbar(context).unSelectedIconColor),
              ),
            ),
          ),
        ),
      ),
    );

    if (tip.isEmpty) return button;
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 500),
      child: button,
    );
  }
}

class AddButton extends StatelessWidget {
  const AddButton({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ActionIcon(
      message: 'New Connection',
      icon: CamelliaIcons.add,
      onTap: () =>
          rustDeskWinManager.call(WindowType.Main, kWindowMainWindowOnTop, ""),
      isClose: false,
    );
  }
}

class _TabDropDownButton extends StatefulWidget {
  final DesktopTabController controller;
  final List<String> tabkeys;
  final LabelGetter? labelGetter;

  const _TabDropDownButton({
    required this.controller,
    required this.tabkeys,
    this.labelGetter,
  });

  @override
  State<_TabDropDownButton> createState() => _TabDropDownButtonState();
}

class _TabDropDownButtonState extends State<_TabDropDownButton> {
  Offset _anchor = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final sortedKeys = widget.controller.state.value.tabs
        .where((e) => widget.tabkeys.contains(e.key))
        .map((e) => e.key)
        .toList();
    return ActionIcon(
      message: 'More',
      onTapDown: (details) {
        _anchor = details.globalPosition;
      },
      icon: Icons.keyboard_arrow_down_rounded,
      iconSize: 18,
      onTap: () {
        showFrostedContextMenu(
          context: context,
          globalPosition: _anchor,
          minWidth: 210,
          maxWidth: 280,
          itemsBuilder: (closeMenu) {
            return sortedKeys.map((key) {
              var label = key;
              final tabInfo = widget.controller.state.value.tabs
                  .firstWhereOrNull((element) => element.key == key);
              if (tabInfo != null) {
                label = tabInfo.label;
              }
              if (widget.labelGetter != null) {
                label = widget.labelGetter!(key).value;
              }
              final index = widget.controller.state.value.tabs.indexWhere(
                (t) => t.key == key,
              );
              return FrostedMenuItem(
                label: '${index + 1}. $label',
                icon: tabInfo?.selectedIcon ?? CamelliaIcons.screen,
                onTap: () {
                  closeMenu();
                  widget.controller.jumpToByKey(key);
                },
                trailing: tabInfo?.onTabCloseButton != null
                    ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          closeMenu();
                          tabInfo?.onTabCloseButton?.call();
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            CamelliaIcons.close,
                            size: 14,
                            color: CamelliaGlassTokens.of(context).statusAlert,
                          ),
                        ),
                      )
                    : null,
              );
            }).toList();
          },
        );
      },
    );
  }
}

class TabbarTheme extends ThemeExtension<TabbarTheme> {
  final Color? selectedTabIconColor;
  final Color? unSelectedTabIconColor;
  final Color? selectedTextColor;
  final Color? unSelectedTextColor;
  final Color? selectedIconColor;
  final Color? unSelectedIconColor;
  final Color? dividerColor;
  final Color? hoverColor;
  final Color? closeHoverColor;
  final Color? selectedTabBackgroundColor;

  const TabbarTheme({
    required this.selectedTabIconColor,
    required this.unSelectedTabIconColor,
    required this.selectedTextColor,
    required this.unSelectedTextColor,
    required this.selectedIconColor,
    required this.unSelectedIconColor,
    required this.dividerColor,
    required this.hoverColor,
    required this.closeHoverColor,
    required this.selectedTabBackgroundColor,
  });

  static const light = TabbarTheme(
    selectedTabIconColor: CamelliaColors.indigo,
    unSelectedTabIconColor: CamelliaColors.lightMuted,
    selectedTextColor: CamelliaColors.lightText,
    unSelectedTextColor: CamelliaColors.lightMuted,
    selectedIconColor: CamelliaColors.lightText,
    unSelectedIconColor: CamelliaColors.lightMuted,
    dividerColor: CamelliaColors.lightBorder,
    hoverColor: CamelliaColors.lightAccentWash,
    closeHoverColor: CamelliaColors.lightRaised,
    selectedTabBackgroundColor: CamelliaColors.lightSurface,
  );

  static const dark = TabbarTheme(
    selectedTabIconColor: Color(0xFFAAA7FF),
    unSelectedTabIconColor: CamelliaColors.darkMuted,
    selectedTextColor: CamelliaColors.darkText,
    unSelectedTextColor: CamelliaColors.darkMuted,
    selectedIconColor: CamelliaColors.darkText,
    unSelectedIconColor: CamelliaColors.darkMuted,
    dividerColor: CamelliaColors.darkBorder,
    hoverColor: CamelliaColors.darkAccentWash,
    closeHoverColor: CamelliaColors.darkRaised,
    selectedTabBackgroundColor: CamelliaColors.darkSurface,
  );

  static const midnight = TabbarTheme(
    selectedTabIconColor: CamelliaColors.orchid,
    unSelectedTabIconColor: CamelliaColors.midnightMuted,
    selectedTextColor: CamelliaColors.midnightText,
    unSelectedTextColor: CamelliaColors.midnightMuted,
    selectedIconColor: CamelliaColors.midnightText,
    unSelectedIconColor: CamelliaColors.midnightMuted,
    dividerColor: CamelliaColors.midnightBorder,
    hoverColor: CamelliaColors.midnightAccentWash,
    closeHoverColor: CamelliaColors.midnightRaised,
    selectedTabBackgroundColor: CamelliaColors.midnightSurface,
  );

  static TabbarTheme of(BuildContext context) {
    final ext = Theme.of(context).extension<TabbarTheme>();
    if (ext != null) return ext;
    final glass = CamelliaGlassTokens.of(context);
    if (glass.isMidnight) return TabbarTheme.midnight;
    return Theme.of(context).brightness == Brightness.dark
        ? TabbarTheme.dark
        : TabbarTheme.light;
  }

  static TabbarTheme fromTokens(AppDesignTokens tokens, {required bool isDark}) {
    return TabbarTheme(
      selectedTabIconColor:
          isDark ? const Color(0xFFAAA7FF) : CamelliaColors.indigo,
      unSelectedTabIconColor: tokens.muted,
      selectedTextColor:
          isDark ? CamelliaColors.darkText : CamelliaColors.lightText,
      unSelectedTextColor: tokens.muted,
      selectedIconColor:
          isDark ? CamelliaColors.darkText : CamelliaColors.lightText,
      unSelectedIconColor: tokens.muted,
      dividerColor: tokens.border,
      hoverColor: tokens.accentContainer,
      closeHoverColor: tokens.surfaceElevated,
      selectedTabBackgroundColor: tokens.surface,
    );
  }

  @override
  ThemeExtension<TabbarTheme> copyWith({
    Color? selectedTabIconColor,
    Color? unSelectedTabIconColor,
    Color? selectedTextColor,
    Color? unSelectedTextColor,
    Color? selectedIconColor,
    Color? unSelectedIconColor,
    Color? dividerColor,
    Color? hoverColor,
    Color? closeHoverColor,
    Color? selectedTabBackgroundColor,
  }) {
    return TabbarTheme(
      selectedTabIconColor: selectedTabIconColor ?? this.selectedTabIconColor,
      unSelectedTabIconColor:
          unSelectedTabIconColor ?? this.unSelectedTabIconColor,
      selectedTextColor: selectedTextColor ?? this.selectedTextColor,
      unSelectedTextColor: unSelectedTextColor ?? this.unSelectedTextColor,
      selectedIconColor: selectedIconColor ?? this.selectedIconColor,
      unSelectedIconColor: unSelectedIconColor ?? this.unSelectedIconColor,
      dividerColor: dividerColor ?? this.dividerColor,
      hoverColor: hoverColor ?? this.hoverColor,
      closeHoverColor: closeHoverColor ?? this.closeHoverColor,
      selectedTabBackgroundColor:
          selectedTabBackgroundColor ?? this.selectedTabBackgroundColor,
    );
  }

  @override
  ThemeExtension<TabbarTheme> lerp(
    ThemeExtension<TabbarTheme>? other,
    double t,
  ) {
    if (other is! TabbarTheme) {
      return this;
    }
    return TabbarTheme(
      selectedTabIconColor: Color.lerp(
        selectedTabIconColor,
        other.selectedTabIconColor,
        t,
      ),
      unSelectedTabIconColor: Color.lerp(
        unSelectedTabIconColor,
        other.unSelectedTabIconColor,
        t,
      ),
      selectedTextColor: Color.lerp(
        selectedTextColor,
        other.selectedTextColor,
        t,
      ),
      unSelectedTextColor: Color.lerp(
        unSelectedTextColor,
        other.unSelectedTextColor,
        t,
      ),
      selectedIconColor: Color.lerp(
        selectedIconColor,
        other.selectedIconColor,
        t,
      ),
      unSelectedIconColor: Color.lerp(
        unSelectedIconColor,
        other.unSelectedIconColor,
        t,
      ),
      dividerColor: Color.lerp(dividerColor, other.dividerColor, t),
      hoverColor: Color.lerp(hoverColor, other.hoverColor, t),
      closeHoverColor: Color.lerp(closeHoverColor, other.closeHoverColor, t),
      selectedTabBackgroundColor: Color.lerp(
        selectedTabBackgroundColor,
        other.selectedTabBackgroundColor,
        t,
      ),
    );
  }

  static ColorThemeExtension color(BuildContext context) {
    return Theme.of(context).extension<ColorThemeExtension>()!;
  }
}
