import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common/widgets/audio_input.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/common/widgets/toolbar.dart';
import 'package:camellia_remote_app/models/chat_model.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/utils/multi_window_manager.dart';
import 'package:camellia_remote_app/plugin/widgets/desc_ui.dart';
import 'package:camellia_remote_app/plugin/common.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/remote_ui_models.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:debounce_throttle/debounce_throttle.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:window_size/window_size.dart' as window_size;

import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../../common/shared_state.dart';
import './popup_menu.dart';
import './kb_layout_type_chooser.dart';
import './remote_toolbar_overlay.dart';
import 'package:camellia_remote_app/utils/scale.dart';
import 'package:camellia_remote_app/common/widgets/custom_scale_base.dart';

typedef _ToolbarEdge = RemoteCommandBarEdge;

bool _isHorizontalEdge(_ToolbarEdge edge) => edge.isHorizontal;

double _clampToolbarFraction(double fraction, double left, double right) {
  if (fraction < left) fraction = left;
  if (fraction > right) fraction = right;
  return fraction;
}

Size _toolbarSizeForEdge(_ToolbarEdge edge, Size? measured) {
  final isHorizontal = _isHorizontalEdge(edge);
  final fallback = isHorizontal ? const Size(360, 40) : const Size(40, 360);
  final size = measured ?? fallback;
  final long = size.longestSide;
  final short = size.shortestSide;
  return Size(isHorizontal ? long : short, isHorizontal ? short : long);
}

Offset _toolbarOffsetForEdge({
  required _ToolbarEdge edge,
  required double fraction,
  required Size parentSize,
  required Size toolbarSize,
}) {
  final xTravel = parentSize.width - toolbarSize.width;
  final yTravel = parentSize.height - toolbarSize.height;
  switch (edge) {
    case _ToolbarEdge.top:
      return Offset(xTravel * fraction, 0);
    case _ToolbarEdge.bottom:
      return Offset(xTravel * fraction, yTravel);
    case _ToolbarEdge.left:
      return Offset(0, yTravel * fraction);
    case _ToolbarEdge.right:
      return Offset(xTravel, yTravel * fraction);
  }
}

double _fractionForAlignedDrag({
  required double cursor,
  required double grabOffset,
  required double parentExtent,
  required double toolbarExtent,
  required double left,
  required double right,
}) {
  final travelExtent = parentExtent - toolbarExtent;
  if (travelExtent <= 0) {
    return _clampToolbarFraction(0.5, left, right);
  }
  return _clampToolbarFraction(
    (cursor - grabOffset) / travelExtent,
    left,
    right,
  );
}

({double left, double right}) _fractionBoundsForEdge(
  _ToolbarEdge edge,
  double left,
  double right,
) {
  return _isHorizontalEdge(edge)
      ? (left: left, right: right)
      : (left: 0, right: 1);
}

// Returns the alignment for the wrapper Align that positions the entire
// toolbar against the given edge at the given fraction along that edge.
// Alignment uses [-1, 1] coordinates (0 = center).
Alignment _alignmentForEdge(_ToolbarEdge edge, double fraction) {
  final f = fraction * 2 - 1;
  switch (edge) {
    case _ToolbarEdge.top:
      return Alignment(f, -1);
    case _ToolbarEdge.bottom:
      return Alignment(f, 1);
    case _ToolbarEdge.left:
      return Alignment(-1, f);
    case _ToolbarEdge.right:
      return Alignment(1, f);
  }
}

// The handle is visually separate from the toolbar and keeps the same rounded
// silhouette at every dock edge.
BorderRadius _collapseHandleBorderRadius() {
  return BorderRadius.circular(12);
}

IconData _toolbarCollapseIcon(_ToolbarEdge edge, bool isCollapsed) {
  switch (edge) {
    case _ToolbarEdge.top:
      return isCollapsed ? Icons.expand_more : Icons.expand_less;
    case _ToolbarEdge.bottom:
      return isCollapsed ? Icons.expand_less : Icons.expand_more;
    case _ToolbarEdge.left:
      return isCollapsed ? Icons.chevron_right : Icons.chevron_left;
    case _ToolbarEdge.right:
      return isCollapsed ? Icons.chevron_left : Icons.chevron_right;
  }
}

class _ToolbarDockingOptions {
  _ToolbarDockingOptions({required this.edge, required this.fraction});

  _ToolbarEdge edge;
  double fraction;
}

final _toolbarDockingOptionsBySession = <String, _ToolbarDockingOptions>{};

String _toolbarDockingCacheKey(SessionID sessionId) => sessionId.toString();

_ToolbarDockingOptions? _cachedToolbarDockingOptions(SessionID sessionId) =>
    _toolbarDockingOptionsBySession[_toolbarDockingCacheKey(sessionId)];

void _cacheToolbarDockingOptions({
  required SessionID sessionId,
  required _ToolbarEdge edge,
  required double fraction,
}) {
  final key = _toolbarDockingCacheKey(sessionId);
  final cached = _toolbarDockingOptionsBySession[key];
  if (cached == null) {
    _toolbarDockingOptionsBySession[key] = _ToolbarDockingOptions(
      edge: edge,
      fraction: fraction,
    );
    return;
  }
  cached.edge = edge;
  cached.fraction = fraction;
}

class ToolbarState {
  late RxBool _pin;

  RxBool collapse = false.obs;
  RxBool hide = false.obs;

  // Track initialization state to prevent flickering
  final RxBool initialized = false.obs;
  bool _isInitializing = false;

  ToolbarState() {
    _pin = RxBool(false);
    final s = bind.getLocalFlutterOption(k: remoteCommandBarStateOption);
    if (s.isEmpty) {
      return;
    }

    try {
      final m = jsonDecode(s);
      if (m != null) {
        _pin = RxBool(m['pin'] ?? false);
      }
    } catch (e) {
      debugPrint('Failed to decode toolbar state ${e.toString()}');
    }
  }

  bool get pin => _pin.value;

  /// Initialize all toolbar states from session options.
  /// This should be called once when the toolbar is first created.
  Future<void> init(SessionID sessionId) async {
    if (initialized.value || _isInitializing) return;
    _isInitializing = true;

    try {
      // Load both states in parallel for better performance
      final results = await Future.wait([
        bind.sessionGetToggleOption(
          sessionId: sessionId,
          arg: kOptionCollapseToolbar,
        ),
        bind.sessionGetToggleOption(
          sessionId: sessionId,
          arg: kOptionHideToolbar,
        ),
      ]);

      collapse.value = results[0] ?? false;
      hide.value = results[1] ?? false;
    } finally {
      _isInitializing = false;
      initialized.value = true;
    }
  }

  switchCollapse(SessionID sessionId) async {
    bind.sessionToggleOption(
      sessionId: sessionId,
      value: kOptionCollapseToolbar,
    );
    collapse.value = !collapse.value;
  }

  // Switch hide state for entire toolbar visibility
  switchHide(SessionID sessionId) async {
    bind.sessionToggleOption(sessionId: sessionId, value: kOptionHideToolbar);
    hide.value = !hide.value;
  }

  switchPin() async {
    _pin.value = !_pin.value;
    // Save everytime changed, as this func will not be called frequently
    await _savePin();
  }

  setPin(bool v) async {
    if (_pin.value != v) {
      _pin.value = v;
      // Save everytime changed, as this func will not be called frequently
      await _savePin();
    }
  }

  _savePin() async {
    bind.setLocalFlutterOption(
      k: remoteCommandBarStateOption,
      v: jsonEncode({'pin': _pin.value}),
    );
  }
}

class _ToolbarTheme {
  static const Color blueColor = CamelliaColors.azure;
  static const Color hoverBlueColor = CamelliaColors.indigo;
  static const Color inactiveColor = Color(0xFF6B7284);
  static const Color hoverInactiveColor = CamelliaColors.indigo;

  static const Color redColor = CamelliaColors.coral;
  static const Color hoverRedColor = CamelliaColors.coralStrong;
  static const double height = 40;
  static const double dividerHeight = 18;

  static const double buttonSize = 40;
  static const double buttonHMargin = 1;
  static const double buttonVMargin = 2;
  static const double iconRadius = 8;
  static const double elevation = 8;

  static double dividerSpaceToAction = isWindows ? 8 : 14;

  static const double menuBorderRadius = CamelliaRadius.surface;
  static const EdgeInsets menuPadding = EdgeInsets.symmetric(vertical: 6);
  static const double menuButtonBorderRadius = CamelliaRadius.control;

  static Color borderColor(BuildContext context) =>
      Theme.of(context).colorScheme.outlineVariant;

  static Color? dividerColor(BuildContext context) =>
      MyTheme.color(context).divider;

  static MenuStyle defaultMenuStyle(BuildContext context) {
    final maxHeight = RemoteCommandMenuMetrics.menuHeight(
      MediaQuery.sizeOf(context).height,
    );
    final maxWidth = RemoteCommandMenuMetrics.menuWidth(
      MediaQuery.sizeOf(context).width,
    );
    final minWidth = maxWidth < 168
        ? maxWidth
        : maxWidth.clamp(168.0, 196.0).toDouble();
    return MenuStyle(
      minimumSize: WidgetStatePropertyAll(Size(minWidth, 0)),
      maximumSize: WidgetStatePropertyAll(Size(maxWidth, maxHeight)),
      side: WidgetStatePropertyAll(
        BorderSide(width: 1, color: borderColor(context)),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_ToolbarTheme.menuBorderRadius),
        ),
      ),
      padding: const WidgetStatePropertyAll(_ToolbarTheme.menuPadding),
      elevation: const WidgetStatePropertyAll(10),
      visualDensity: VisualDensity.compact,
    );
  }

  static MenuStyle statusMenuStyle(BuildContext context) {
    final width = RemoteCommandMenuMetrics.statusMenuWidth(
      MediaQuery.sizeOf(context).width,
    );
    return defaultMenuStyle(context).copyWith(
      minimumSize: WidgetStatePropertyAll(Size(width, 0)),
      maximumSize: WidgetStatePropertyAll(
        Size(
          width,
          RemoteCommandMenuMetrics.menuHeight(
            MediaQuery.sizeOf(context).height,
          ),
        ),
      ),
    );
  }

  static Widget borderWrapper(
    BuildContext context,
    Widget child,
    BorderRadius borderRadius,
  ) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: borderColor(context), width: 1),
        borderRadius: borderRadius,
      ),
      child: child,
    );
  }
}

typedef DismissFunc = void Function();

Widget _menuLabel(BuildContext context, IconData icon, String label) {
  return Row(
    children: [
      Icon(icon, size: 17, color: Theme.of(context).colorScheme.primary),
      const SizedBox(width: 8),
      Expanded(
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    ],
  );
}

class RemoteMenuEntry {
  static MenuEntryButton<String> insertLock(
    SessionID sessionId,
    EdgeInsets? padding, {
    DismissFunc? dismissFunc,
    DismissCallback? dismissCallback,
  }) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) =>
          Text(translate('Insert Lock'), style: style),
      proc: () {
        bind.sessionLockScreen(sessionId: sessionId);
        if (dismissFunc != null) {
          dismissFunc();
        }
      },
      padding: padding,
      dismissOnClicked: true,
      dismissCallback: dismissCallback,
    );
  }

  static insertCtrlAltDel(
    SessionID sessionId,
    EdgeInsets? padding, {
    DismissFunc? dismissFunc,
    DismissCallback? dismissCallback,
  }) {
    return MenuEntryButton<String>(
      childBuilder: (TextStyle? style) =>
          Text(translate("Insert Ctrl + Alt + Del"), style: style),
      proc: () {
        bind.sessionCtrlAltDel(sessionId: sessionId);
        if (dismissFunc != null) {
          dismissFunc();
        }
      },
      padding: padding,
      dismissOnClicked: true,
      dismissCallback: dismissCallback,
    );
  }
}

class RemoteToolbar extends StatefulWidget {
  final String id;
  final FFI ffi;
  final ToolbarState state;
  final Function(int, Function(bool)) onEnterOrLeaveImageSetter;
  final Function(int) onEnterOrLeaveImageCleaner;
  final Function(VoidCallback) setRemoteState;

  RemoteToolbar({
    Key? key,
    required this.id,
    required this.ffi,
    required this.state,
    required this.onEnterOrLeaveImageSetter,
    required this.onEnterOrLeaveImageCleaner,
    required this.setRemoteState,
  }) : super(key: key);

  @override
  State<RemoteToolbar> createState() => _RemoteToolbarState();
}

class _RemoteToolbarState extends State<RemoteToolbar> {
  late Debouncer<int> _debouncerHide;
  bool _isCursorOverImage = false;
  final _fraction = 0.5.obs;
  final _edge = _ToolbarEdge.top.obs;
  final _dragging = false.obs;
  // Live drag preview: where the toolbar would dock if the user dropped now.
  final _previewEdge = Rxn<_ToolbarEdge>();
  final _previewFraction = Rxn<double>();
  // Measured size of the live toolbar, so the preview ghost matches reality
  // (collapsed handle vs expanded toolbar). Updated after every layout pass.
  final _toolbarSize = Rxn<Size>();
  final _toolbarKey = GlobalKey(debugLabel: 'remote_toolbar_root');
  final _dockingOptionsInitialized = false.obs;
  bool _measureScheduled = false;

  int get windowId => stateGlobal.windowId;

  void _setFullscreen(bool v) {
    stateGlobal.setFullscreen(v);
    // stateGlobal.fullscreen is RxBool now, no need to call setState.
    // setState(() {});
  }

  RxBool get collapse => widget.state.collapse;
  RxBool get hide => widget.state.hide;
  bool get pin => widget.state.pin;

  PeerInfo get pi => widget.ffi.ffiModel.pi;
  FfiModel get ffiModel => widget.ffi.ffiModel;

  triggerAutoHide() => _debouncerHide.value = _debouncerHide.value + 1;

  void _loadDockingPreferences() {
    final cached = _cachedToolbarDockingOptions(widget.ffi.sessionId);
    final preferences = cached == null
        ? RemoteCommandBarPreferences.decode(
            bind.getLocalFlutterOption(k: remoteCommandBarLayoutOption),
          )
        : RemoteCommandBarPreferences(
            edge: cached.edge,
            fraction: cached.fraction,
          );
    _edge.value = preferences.edge;
    _fraction.value = preferences.fraction;
    _dockingOptionsInitialized.value = true;
    _cacheToolbarDockingOptions(
      sessionId: widget.ffi.sessionId,
      edge: preferences.edge,
      fraction: preferences.fraction,
    );
  }

  void _saveDockingPreferences(_ToolbarEdge edge, double fraction) {
    final preferences = RemoteCommandBarPreferences(
      edge: edge,
      fraction: fraction,
    ).normalized();
    bind.setLocalFlutterOption(
      k: remoteCommandBarLayoutOption,
      v: preferences.encode(),
    );
    _cacheToolbarDockingOptions(
      sessionId: widget.ffi.sessionId,
      edge: preferences.edge,
      fraction: preferences.fraction,
    );
  }

  @override
  initState() {
    super.initState();

    _loadDockingPreferences();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Initialize toolbar states (collapse, hide) from session options
      await widget.state.init(widget.ffi.sessionId);
    });

    _debouncerHide = Debouncer<int>(
      Duration(milliseconds: 5000),
      onChanged: _debouncerHideProc,
      initialValue: 0,
    );

    widget.onEnterOrLeaveImageSetter(identityHashCode(this), (enter) {
      if (enter) {
        triggerAutoHide();
        _isCursorOverImage = true;
      } else {
        _isCursorOverImage = false;
      }
    });
  }

  _debouncerHideProc(int v) {
    if (!pin && collapse.isFalse && _isCursorOverImage && _dragging.isFalse) {
      collapse.value = true;
    }
  }

  @override
  dispose() {
    widget.onEnterOrLeaveImageCleaner(identityHashCode(this));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // Wait for initialization to complete to prevent flickering
      if (!widget.state.initialized.value ||
          !_dockingOptionsInitialized.value) {
        return const SizedBox.shrink();
      }
      // If toolbar is hidden, return empty widget
      if (hide.value) {
        return const SizedBox.shrink();
      }
      final edge = _edge.value;
      final isHorizontal = _isHorizontalEdge(edge);

      // Measure the live toolbar after every layout so the preview ghost can
      // match its actual footprint (collapsed handle vs expanded toolbar).
      if (!_measureScheduled) {
        _measureScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _measureScheduled = false;
          if (!mounted || _dragging.isTrue) return;
          final ro = _toolbarKey.currentContext?.findRenderObject();
          if (ro is RenderBox && ro.hasSize) {
            final s = ro.size;
            if (_toolbarSize.value != s) _toolbarSize.value = s;
          }
        });
      }

      final toolbar = KeyedSubtree(
        key: _toolbarKey,
        child: collapse.isFalse
            ? _buildToolbar(context, edge, isHorizontal)
            : _buildDraggableCollapse(context, edge, isHorizontal),
      );

      // Keep the full-viewport docking layer stable during a drag, but place
      // the fallible toolbar subtree behind a strict cross-axis boundary. A
      // release ErrorWidget from a toolbar child must never cover the canvas.
      return RemoteToolbarOverlaySurface(
        edge: edge,
        fraction: _fraction.value,
        toolbar: toolbar,
        preview: Obx(() {
          final pe = _previewEdge.value;
          final pf = _previewFraction.value;
          if (!_dragging.isTrue || pe == null || pf == null) {
            return const SizedBox.shrink();
          }
          return _buildDragPreview(context, pe, pf, _toolbarSize.value);
        }),
      );
    });
  }

  Widget _buildDragPreview(
    BuildContext context,
    _ToolbarEdge edge,
    double fraction,
    Size? measured,
  ) {
    final color = Theme.of(context).colorScheme.primary;
    // Use the measured live toolbar size so collapsed vs expanded looks
    // right. The current orientation may differ from the preview orientation
    // (e.g. dragging a top-docked toolbar toward the left edge), so swap the
    // long/short axes when previewing a different orientation.
    final previewSize = _toolbarSizeForEdge(edge, measured);
    return Align(
      alignment: _alignmentForEdge(edge, fraction),
      child: Container(
        width: previewSize.width,
        height: previewSize.height,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.55), width: 1.5),
        ),
      ),
    );
  }

  Widget _buildDraggableCollapse(
    BuildContext context,
    _ToolbarEdge edge,
    bool isHorizontal,
  ) {
    return Obx(() {
      if (collapse.isFalse && _dragging.isFalse) {
        triggerAutoHide();
      }
      final borderRadius = _collapseHandleBorderRadius();
      return Offstage(
        offstage: _dragging.isTrue,
        child: Material(
          elevation: _ToolbarTheme.elevation,
          shadowColor: MyTheme.color(context).shadow,
          borderRadius: borderRadius,
          child: _DraggableShowHide(
            id: widget.id,
            ffi: widget.ffi,
            sessionId: widget.ffi.sessionId,
            dragging: _dragging,
            fraction: _fraction,
            edge: _edge,
            previewEdge: _previewEdge,
            previewFraction: _previewFraction,
            toolbarSize: _toolbarSize,
            isHorizontal: isHorizontal,
            onPlacementChanged: _saveDockingPreferences,
            toolbarState: widget.state,
            borderRadius: borderRadius,
          ),
        ),
      );
    });
  }

  Widget _buildToolbar(
    BuildContext context,
    _ToolbarEdge edge,
    bool isHorizontal,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mediaSize = MediaQuery.sizeOf(context);
        final constrainedExtent = isHorizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
        final availableExtent = constrainedExtent.isFinite
            ? constrainedExtent
            : isHorizontal
            ? mediaSize.width
            : mediaSize.height;
        final tier = RemoteCommandBarTier.forExtent(availableExtent);
        final toolbarItems = <Widget>[];
        final overflowItems = <Widget>[];

        Widget divider() => Container(
          width: isHorizontal ? 1 : 20,
          height: isHorizontal ? 20 : 1,
          margin: EdgeInsets.symmetric(
            horizontal: isHorizontal ? 4 : 0,
            vertical: isHorizontal ? 0 : 4,
          ),
          color: Theme.of(context).dividerColor,
        );

        void adaptive(
          RemoteCommandBarTier minimum,
          Widget Function(bool inOverflow) builder,
        ) {
          if (tier.includes(minimum)) {
            toolbarItems.add(builder(false));
          } else {
            overflowItems.add(builder(true));
          }
        }

        toolbarItems.add(
          _SessionStatusMenu(
            id: widget.id,
            quality: widget.ffi.qualityMonitorModel,
          ),
        );
        adaptive(
          RemoteCommandBarTier.full,
          (inOverflow) => _PinMenu(state: widget.state, inOverflow: inOverflow),
        );
        if (!isWebDesktop) {
          adaptive(
            RemoteCommandBarTier.full,
            (inOverflow) =>
                _MobileActionMenu(ffi: widget.ffi, inOverflow: inOverflow),
          );
        }
        toolbarItems.add(
          _ControlMenu(id: widget.id, ffi: widget.ffi, state: widget.state),
        );
        if (widget.ffi.connType == ConnType.defaultConn) {
          adaptive(
            RemoteCommandBarTier.input,
            (inOverflow) => _KeyboardMenu(
              id: widget.id,
              ffi: widget.ffi,
              inOverflow: inOverflow,
            ),
          );
        }
        toolbarItems.add(divider());

        adaptive(
          RemoteCommandBarTier.full,
          (inOverflow) => Obx(() {
            final privacyModeState = PrivacyModeState.find(widget.id);
            if ((privacyModeState.isEmpty ||
                    allowDisplaySwitchInPrivacyMode(
                      pi,
                      privacyModeState.value,
                    )) &&
                pi.displaysCount.value > 1 &&
                mainGetLocalBoolOptionSync(
                  kOptionAllowMonitorSwitchMainToolbar,
                )) {
              return _MainMonitorSwitchButton(
                id: widget.id,
                ffi: widget.ffi,
                inOverflow: inOverflow,
              );
            }
            return const Offstage();
          }),
        );
        adaptive(
          RemoteCommandBarTier.input,
          (inOverflow) => Obx(() {
            final privacyModeState = PrivacyModeState.find(widget.id);
            if ((privacyModeState.isEmpty ||
                    allowDisplaySwitchInPrivacyMode(
                      pi,
                      privacyModeState.value,
                    )) &&
                pi.displaysCount.value > 1) {
              return _MonitorMenu(
                id: widget.id,
                ffi: widget.ffi,
                inOverflow: inOverflow,
              );
            }
            return const Offstage();
          }),
        );
        toolbarItems.add(
          _DisplayMenu(
            id: widget.id,
            ffi: widget.ffi,
            state: widget.state,
            setFullscreen: _setFullscreen,
          ),
        );
        toolbarItems.add(divider());

        adaptive(
          RemoteCommandBarTier.collaboration,
          (inOverflow) =>
              _ChatMenu(id: widget.id, ffi: widget.ffi, inOverflow: inOverflow),
        );
        if (!isWeb) {
          adaptive(
            RemoteCommandBarTier.full,
            (inOverflow) => _VoiceCallMenu(
              id: widget.id,
              ffi: widget.ffi,
              inOverflow: inOverflow,
            ),
          );
          adaptive(
            RemoteCommandBarTier.collaboration,
            (inOverflow) => _RecordMenu(inOverflow: inOverflow),
          );
        }
        if (overflowItems.isNotEmpty) {
          toolbarItems.add(_MoreActionsMenu(children: overflowItems));
        }
        toolbarItems.add(divider());
        toolbarItems.add(_CloseMenu(id: widget.id, ffi: widget.ffi));

        const toolbarBorderRadius = BorderRadius.all(
          Radius.circular(CamelliaRadius.surface),
        );
        final innerAxis = isHorizontal ? Axis.horizontal : Axis.vertical;
        final outerAxis = isHorizontal ? Axis.vertical : Axis.horizontal;
        final spacer = isHorizontal
            ? const SizedBox(width: 2)
            : const SizedBox(height: 2);
        final toolbarMaterial = Material(
          elevation: _ToolbarTheme.elevation,
          shadowColor: MyTheme.color(context).shadow,
          borderRadius: toolbarBorderRadius,
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.96),
          child: Theme(
            data: themeData(),
            child: _ToolbarTheme.borderWrapper(
              context,
              Flex(
                direction: innerAxis,
                mainAxisSize: MainAxisSize.min,
                children: [spacer, ...toolbarItems, spacer],
              ),
              toolbarBorderRadius,
            ),
          ),
        );
        final handle = _buildDraggableCollapse(context, edge, isHorizontal);
        final gap = isHorizontal
            ? const SizedBox(height: 4)
            : const SizedBox(width: 4);
        final children = (edge == _ToolbarEdge.top || edge == _ToolbarEdge.left)
            ? [toolbarMaterial, gap, handle]
            : [handle, gap, toolbarMaterial];
        return Flex(
          direction: outerAxis,
          mainAxisSize: MainAxisSize.min,
          children: children,
        );
      },
    );
  }

  ThemeData themeData() {
    return Theme.of(context).copyWith(
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(
            Size(0, RemoteCommandMenuMetrics.rowHeight),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 8),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontWeight: FontWeight.normal),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(
                _ToolbarTheme.menuButtonBorderRadius,
              ),
            ),
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        space: _ToolbarTheme.dividerSpaceToAction,
        color: _ToolbarTheme.dividerColor(context),
      ),
      menuBarTheme: MenuBarThemeData(
        style:
            MenuStyle(
              padding: const WidgetStatePropertyAll(EdgeInsets.zero),
              elevation: const WidgetStatePropertyAll(0),
              shape: const WidgetStatePropertyAll(BeveledRectangleBorder()),
            ).copyWith(
              backgroundColor: Theme.of(
                context,
              ).menuBarTheme.style?.backgroundColor,
            ),
      ),
    );
  }
}

class _PinMenu extends StatelessWidget {
  final ToolbarState state;
  final bool inOverflow;
  const _PinMenu({Key? key, required this.state, this.inOverflow = false})
    : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => _IconMenuButton(
        icon: Icon(
          state.pin ? Icons.push_pin_rounded : Icons.push_pin_outlined,
        ),
        tooltip: state.pin ? 'Unpin Toolbar' : 'Pin Toolbar',
        inOverflow: inOverflow,
        onPressed: state.switchPin,
        color: state.pin
            ? _ToolbarTheme.blueColor
            : _ToolbarTheme.inactiveColor,
        hoverColor: state.pin
            ? _ToolbarTheme.hoverBlueColor
            : _ToolbarTheme.hoverInactiveColor,
      ),
    );
  }
}

class _MoreActionsMenu extends StatelessWidget {
  const _MoreActionsMenu({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return _IconSubmenuButton(
      tooltip: 'More actions',
      icon: const Icon(Icons.more_horiz_rounded),
      color: _ToolbarTheme.inactiveColor,
      hoverColor: _ToolbarTheme.hoverInactiveColor,
      menuChildrenGetter: (_) => children,
    );
  }
}

class _SessionStatusMenu extends StatelessWidget {
  const _SessionStatusMenu({required this.id, required this.quality});

  final String id;
  final QualityMonitorModel quality;

  SessionStatusSnapshot _snapshot(ConnectionType? connection) {
    final valid = connection?.isValid() ?? false;
    final data = quality.data;
    return SessionStatusSnapshot(
      secure: valid
          ? connection!.secure.value == ConnectionType.strSecure
          : null,
      direct: valid
          ? connection!.direct.value == ConnectionType.strDirect
          : null,
      streamType: valid ? connection!.stream_type.value : null,
      speed: data.speed,
      fps: data.fps,
      delay: data.delay,
      targetBitrate: data.targetBitrate,
      codec: data.codecFormat,
      chroma: data.chroma,
    );
  }

  Widget _buildMenu(BuildContext context, ConnectionType? connection) {
    final snapshot = _snapshot(connection);
    final status = snapshot.secure == null
        ? translate('Connecting')
        : snapshot.secure!
        ? translate('Secure')
        : translate('Insecure');
    final route = snapshot.direct == null
        ? null
        : snapshot.direct!
        ? translate('Direct')
        : translate('Relay');
    final label = route == null ? status : '$status · $route';
    final color = snapshot.secure == null
        ? _ToolbarTheme.inactiveColor
        : snapshot.secure!
        ? CamelliaColors.aqua
        : _ToolbarTheme.redColor;
    return _IconSubmenuButton(
      tooltip: label,
      icon: Icon(
        snapshot.secure == null
            ? Icons.sync_rounded
            : snapshot.secure!
            ? Icons.shield_rounded
            : Icons.gpp_maybe_rounded,
      ),
      color: color,
      hoverColor: color,
      menuStyle: _ToolbarTheme.statusMenuStyle(context),
      menuChildrenGetter: (_) => [_SessionStatusPanel(snapshot: snapshot)],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: quality,
      builder: (context, _) {
        final tag = ConnectionTypeState.tag(id);
        if (!Get.isRegistered<ConnectionType>(tag: tag)) {
          return _buildMenu(context, null);
        }
        final connection = ConnectionTypeState.find(id);
        return Obx(() {
          connection.secure.value;
          connection.direct.value;
          connection.stream_type.value;
          return _buildMenu(context, connection);
        });
      },
    );
  }
}

class _SessionStatusPanel extends StatelessWidget {
  const _SessionStatusPanel({required this.snapshot});

  final SessionStatusSnapshot snapshot;

  String _security() => snapshot.secure == null
      ? translate('Connecting')
      : snapshot.secure!
      ? translate('Secure')
      : translate('Insecure');

  String _route() => snapshot.direct == null
      ? '—'
      : snapshot.direct!
      ? translate('Direct')
      : translate('Relay');

  @override
  Widget build(BuildContext context) {
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final metricWidth = RemoteCommandMenuMetrics.statusMetricWidth(
      viewportWidth,
    );
    return Semantics(
      container: true,
      label: translate('Session status'),
      child: SizedBox(
        width: RemoteCommandMenuMetrics.statusPanelWidth(viewportWidth),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                translate('Session status'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _StatusMetric(
                    width: metricWidth,
                    icon: Icons.shield_outlined,
                    label: translate('Security'),
                    value: _security(),
                  ),
                  _StatusMetric(
                    width: metricWidth,
                    icon: Icons.route_outlined,
                    label: translate('Route'),
                    value: _route(),
                  ),
                  _StatusMetric(
                    width: metricWidth,
                    icon: Icons.swap_horiz_rounded,
                    label: translate('Protocol'),
                    value: snapshot.display(snapshot.streamType),
                  ),
                  _StatusMetric(
                    width: metricWidth,
                    icon: Icons.speed_rounded,
                    label: translate('Latency'),
                    value: snapshot.delayValue,
                  ),
                  _StatusMetric(
                    width: metricWidth,
                    icon: Icons.network_check_rounded,
                    label: translate('Speed'),
                    value: snapshot.display(snapshot.speed),
                  ),
                  _StatusMetric(
                    width: metricWidth,
                    icon: Icons.movie_filter_outlined,
                    label: translate('FPS'),
                    value: snapshot.display(snapshot.fps),
                  ),
                  _StatusMetric(
                    width: metricWidth,
                    icon: Icons.tune_rounded,
                    label: translate('Target Bitrate'),
                    value: snapshot.bitrateValue,
                  ),
                  _StatusMetric(
                    width: metricWidth,
                    icon: Icons.memory_rounded,
                    label: translate('Codec'),
                    value: snapshot.display(snapshot.codec),
                  ),
                  _StatusMetric(
                    width: metricWidth,
                    icon: Icons.palette_outlined,
                    label: translate('Chroma'),
                    value: snapshot.display(snapshot.chroma),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusMetric extends StatelessWidget {
  const _StatusMetric({
    required this.width,
    required this.icon,
    required this.label,
    required this.value,
  });

  final double width;
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      constraints: const BoxConstraints(minHeight: 42),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(CamelliaRadius.control),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 14, color: scheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileActionMenu extends StatelessWidget {
  final FFI ffi;
  final bool inOverflow;
  const _MobileActionMenu({
    Key? key,
    required this.ffi,
    this.inOverflow = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (!ffi.ffiModel.isPeerAndroid) return Offstage();
    return Obx(
      () => _IconMenuButton(
        icon: const Icon(Icons.touch_app_rounded),
        tooltip: 'Mobile Actions',
        inOverflow: inOverflow,
        onPressed: () => ffi.dialogManager.setMobileActionsOverlayVisible(
          !ffi.dialogManager.mobileActionsOverlayVisible.value,
        ),
        color: ffi.dialogManager.mobileActionsOverlayVisible.isTrue
            ? _ToolbarTheme.blueColor
            : _ToolbarTheme.inactiveColor,
        hoverColor: ffi.dialogManager.mobileActionsOverlayVisible.isTrue
            ? _ToolbarTheme.hoverBlueColor
            : _ToolbarTheme.hoverInactiveColor,
      ),
    );
  }
}

class _MonitorCycle {
  final String id;
  final FFI ffi;
  const _MonitorCycle(this.id, this.ffi);

  PeerInfo get _pi => ffi.ffiModel.pi;
  int get total => _pi.displays.length;
  int get _current => CurrentDisplayState.find(id).value;
  bool get _inRange => _current >= 0 && _current < total;

  String get label => _inRange ? '${_current + 1}' : '*';
  String get tooltip => '${translate('Switch display')} ($label/$total)';

  void next() {
    final t = total;
    if (t < 2) return;
    final from = _inRange ? _current : -1;
    final target = (from + 1) % t;
    final isChooseDisplayToOpenInNewWindow =
        _pi.isSupportMultiDisplay &&
        bind.sessionGetDisplaysAsIndividualWindows(sessionId: ffi.sessionId) ==
            'Y';
    if (isChooseDisplayToOpenInNewWindow) {
      openMonitorInNewTabOrWindow(target, ffi.id, _pi);
    } else {
      openMonitorInTheSameTab(target, ffi, _pi, updateCursorPos: false);
    }
  }
}

class _MainMonitorSwitchButton extends StatelessWidget {
  final String id;
  final FFI ffi;
  final bool inOverflow;

  const _MainMonitorSwitchButton({
    Key? key,
    required this.id,
    required this.ffi,
    this.inOverflow = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final cycle = _MonitorCycle(id, ffi);
    return Obx(() {
      if (cycle.total < 2) return const Offstage();
      final label = cycle.label;

      return _IconMenuButton(
        tooltip: cycle.tooltip,
        inOverflow: inOverflow,
        color: _ToolbarTheme.blueColor,
        hoverColor: _ToolbarTheme.hoverBlueColor,
        onPressed: cycle.next,
        icon: Badge(
          label: Text(label),
          offset: const Offset(5, -5),
          child: const Icon(Icons.monitor_rounded),
        ),
      );
    });
  }
}

class _MonitorMenu extends StatelessWidget {
  final String id;
  final FFI ffi;
  final bool inOverflow;
  const _MonitorMenu({
    Key? key,
    required this.id,
    required this.ffi,
    this.inOverflow = false,
  }) : super(key: key);

  bool get supportIndividualWindows =>
      !isWeb && ffi.ffiModel.pi.isSupportMultiDisplay;

  @override
  Widget build(BuildContext context) {
    return Obx(() => buildMonitorMenu(context));
  }

  Widget buildMonitorMenu(BuildContext context) {
    return _IconSubmenuButton(
      tooltip: 'Select Monitor',
      icon: const Icon(Icons.splitscreen_rounded),
      ffi: ffi,
      inOverflow: inOverflow,
      color: _ToolbarTheme.blueColor,
      hoverColor: _ToolbarTheme.hoverBlueColor,
      menuStyle: _ToolbarTheme.defaultMenuStyle(context).copyWith(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 6),
        ),
      ),
      menuChildrenGetter: (_) => [buildMonitorSubmenuWidget(context)],
    );
  }

  Widget buildMonitorSubmenuWidget(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: buildMonitorList(context)),
        supportIndividualWindows ? const Divider() : const Offstage(),
        supportIndividualWindows ? chooseDisplayBehavior() : const Offstage(),
      ],
    );
  }

  Widget chooseDisplayBehavior() {
    final value =
        bind.sessionGetDisplaysAsIndividualWindows(sessionId: ffi.sessionId) ==
        'Y';
    return CkbMenuButton(
      value: value,
      onChanged: (value) async {
        if (value == null) return;
        await bind.sessionSetDisplaysAsIndividualWindows(
          sessionId: ffi.sessionId,
          value: value ? 'Y' : 'N',
        );
      },
      ffi: ffi,
      child: Text(translate('Show displays as individual windows')),
    );
  }

  buildOneMonitorButton(i, curDisplay) => Text(
    '${i + 1}',
    style: TextStyle(
      color: i == curDisplay
          ? _ToolbarTheme.blueColor
          : _ToolbarTheme.inactiveColor,
      fontSize: 12,
      fontWeight: FontWeight.bold,
    ),
  );

  List<Widget> buildMonitorList(BuildContext context) {
    final List<Widget> monitorList = [];
    final pi = ffi.ffiModel.pi;

    buildMonitorButton(int i) => Obx(() {
      RxInt display = CurrentDisplayState.find(id);

      final isAllMonitors = i == kAllDisplayValue;
      final width = SimpleWrapper<double>(0);
      Widget? monitorsIcon;
      if (isAllMonitors) {
        monitorsIcon = globalMonitorsWidget(
          width,
          Colors.white,
          _ToolbarTheme.blueColor,
        );
      }
      return _IconMenuButton(
        tooltip: isAllMonitors ? 'All monitors' : '#{${i + 1}} monitor',
        hMargin: 6,
        vMargin: 12,
        topLevel: false,
        color: i == display.value
            ? _ToolbarTheme.blueColor
            : _ToolbarTheme.inactiveColor,
        hoverColor: i == display.value
            ? _ToolbarTheme.hoverBlueColor
            : _ToolbarTheme.hoverInactiveColor,
        width: isAllMonitors ? width.value : null,
        icon: isAllMonitors
            ? monitorsIcon!
            : Container(
                alignment: AlignmentDirectional.center,
                constraints: const BoxConstraints(
                  minHeight: _ToolbarTheme.height,
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SvgPicture.asset(
                      "assets/screen.svg",
                      colorFilter: const ColorFilter.mode(
                        Colors.white,
                        BlendMode.srcIn,
                      ),
                    ),
                    Obx(() => buildOneMonitorButton(i, display.value)),
                  ],
                ),
              ),
        onPressed: () => onPressed(i, pi),
      );
    });

    for (int i = 0; i < pi.displays.length; i++) {
      monitorList.add(buildMonitorButton(i));
    }
    if (supportIndividualWindows && pi.displays.length > 1) {
      monitorList.add(buildMonitorButton(kAllDisplayValue));
    }
    return monitorList;
  }

  globalMonitorsWidget(
    SimpleWrapper<double> width,
    Color activeTextColor,
    Color activeBgColor,
  ) {
    getMonitors() {
      final pi = ffi.ffiModel.pi;
      RxInt display = CurrentDisplayState.find(id);
      final rect = ffi.ffiModel.globalDisplaysRect();
      if (rect == null) {
        return const Offstage();
      }

      final scale = _ToolbarTheme.buttonSize / rect.height * 0.75;
      final height = rect.height * scale;
      final startY = (_ToolbarTheme.buttonSize - height) * 0.5;
      final startX = startY;

      final children = <Widget>[];
      for (var i = 0; i < pi.displays.length; i++) {
        final d = pi.displays[i];
        double s = d.scale;
        int dWidth = d.width.toDouble() ~/ s;
        int dHeight = d.height.toDouble() ~/ s;
        final fontSize =
            (dWidth * scale < dHeight * scale
                ? dWidth * scale
                : dHeight * scale) *
            0.65;
        children.add(
          Positioned(
            left: (d.x - rect.left) * scale + startX,
            top: (d.y - rect.top) * scale + startY,
            width: dWidth * scale,
            height: dHeight * scale,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey, width: 1.0),
                color: display.value == i ? activeBgColor : Colors.white,
              ),
              child: Center(
                child: Text(
                  '${i + 1}',
                  style: TextStyle(
                    color: display.value == i
                        ? activeTextColor
                        : _ToolbarTheme.inactiveColor,
                    fontSize: fontSize,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        );
      }
      width.value = rect.width * scale + startX * 2;
      return SizedBox(
        width: width.value,
        height: height + startY * 2,
        child: Stack(children: children),
      );
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        SizedBox(height: _ToolbarTheme.buttonSize),
        getMonitors(),
      ],
    );
  }

  onPressed(int i, PeerInfo pi) {
    _menuDismissCallback(ffi);
    RxInt display = CurrentDisplayState.find(id);
    if (display.value != i) {
      final isChooseDisplayToOpenInNewWindow =
          pi.isSupportMultiDisplay &&
          bind.sessionGetDisplaysAsIndividualWindows(
                sessionId: ffi.sessionId,
              ) ==
              'Y';
      if (isChooseDisplayToOpenInNewWindow) {
        openMonitorInNewTabOrWindow(i, ffi.id, pi);
      } else {
        openMonitorInTheSameTab(i, ffi, pi, updateCursorPos: true);
      }
    }
  }
}

class _ControlMenu extends StatelessWidget {
  final String id;
  final FFI ffi;
  final ToolbarState state;
  _ControlMenu({
    Key? key,
    required this.id,
    required this.ffi,
    required this.state,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return _IconSubmenuButton(
      tooltip: 'Control Actions',
      icon: const Icon(Icons.bolt_rounded),
      color: _ToolbarTheme.blueColor,
      hoverColor: _ToolbarTheme.hoverBlueColor,
      ffi: ffi,
      menuChildrenGetter: (_) => toolbarControls(context, id, ffi).map((e) {
        if (e.divider) {
          return Divider();
        } else {
          return MenuButton(
            child: e.child,
            onPressed: e.onPressed,
            ffi: ffi,
            trailingIcon: e.trailingIcon,
          );
        }
      }).toList(),
    );
  }
}

class ScreenAdjustor {
  final String id;
  final FFI ffi;
  final VoidCallback cbExitFullscreen;
  window_size.Screen? _screen;

  ScreenAdjustor({
    required this.id,
    required this.ffi,
    required this.cbExitFullscreen,
  });

  bool get isFullscreen => stateGlobal.fullscreen.isTrue;
  int get windowId => stateGlobal.windowId;

  adjustWindow(BuildContext context) {
    return futureBuilder(
      future: isWindowCanBeAdjusted(),
      hasData: (data) {
        final visible = data as bool;
        if (!visible) return Offstage();
        return Column(
          children: [
            MenuButton(
              child: Text(translate('Adjust Window')),
              onPressed: () => doAdjustWindow(context),
              ffi: ffi,
            ),
            Divider(),
          ],
        );
      },
    );
  }

  doAdjustWindow(BuildContext context) async {
    await updateScreen();
    if (_screen != null) {
      cbExitFullscreen();
      double scale = _screen!.scaleFactor;
      final wndRect = await WindowController.fromWindowId(windowId).getFrame();
      final mediaSize = MediaQueryData.fromView(View.of(context)).size;
      // On windows, wndRect is equal to GetWindowRect and mediaSize is equal to GetClientRect.
      // https://stackoverflow.com/a/7561083
      double magicWidth =
          wndRect.right - wndRect.left - mediaSize.width * scale;
      double magicHeight =
          wndRect.bottom - wndRect.top - mediaSize.height * scale;
      final canvasModel = ffi.canvasModel;
      final width =
          (canvasModel.getDisplayWidth() * canvasModel.scale +
                  CanvasModel.leftToEdge +
                  CanvasModel.rightToEdge) *
              scale +
          magicWidth;
      final height =
          (canvasModel.getDisplayHeight() * canvasModel.scale +
                  CanvasModel.topToEdge +
                  CanvasModel.bottomToEdge) *
              scale +
          magicHeight;
      double left = wndRect.left + (wndRect.width - width) / 2;
      double top = wndRect.top + (wndRect.height - height) / 2;

      Rect frameRect = _screen!.frame;
      if (!isFullscreen) {
        frameRect = _screen!.visibleFrame;
      }
      if (left < frameRect.left) {
        left = frameRect.left;
      }
      if (top < frameRect.top) {
        top = frameRect.top;
      }
      if ((left + width) > frameRect.right) {
        left = frameRect.right - width;
      }
      if ((top + height) > frameRect.bottom) {
        top = frameRect.bottom - height;
      }
      await WindowController.fromWindowId(
        windowId,
      ).setFrame(Rect.fromLTWH(left, top, width, height));
      stateGlobal.setMaximized(false);
    }
  }

  updateScreen() async {
    final String info = isWeb
        ? screenInfo
        : await _getScreenInfoDesktop() ?? '';
    if (info.isEmpty) {
      _screen = null;
    } else {
      final screenMap = jsonDecode(info);
      _screen = window_size.Screen(
        Rect.fromLTRB(
          screenMap['frame']['l'],
          screenMap['frame']['t'],
          screenMap['frame']['r'],
          screenMap['frame']['b'],
        ),
        Rect.fromLTRB(
          screenMap['visibleFrame']['l'],
          screenMap['visibleFrame']['t'],
          screenMap['visibleFrame']['r'],
          screenMap['visibleFrame']['b'],
        ),
        screenMap['scaleFactor'],
      );
    }
  }

  _getScreenInfoDesktop() async {
    final v = await rustDeskWinManager.call(
      WindowType.Main,
      kWindowGetWindowInfo,
      '',
    );
    return v.result;
  }

  Future<bool> isWindowCanBeAdjusted() async {
    final viewStyle =
        await bind.sessionGetViewStyle(sessionId: ffi.sessionId) ?? '';
    if (viewStyle != kRemoteViewStyleOriginal) {
      return false;
    }
    if (!isWeb) {
      final remoteCount = RemoteCountState.find().value;
      if (remoteCount != 1) {
        return false;
      }
    }
    if (_screen == null) {
      return false;
    }
    final scale = kIgnoreDpi ? 1.0 : _screen!.scaleFactor;
    double selfWidth = _screen!.visibleFrame.width;
    double selfHeight = _screen!.visibleFrame.height;
    if (isFullscreen) {
      selfWidth = _screen!.frame.width;
      selfHeight = _screen!.frame.height;
    }

    final canvasModel = ffi.canvasModel;
    final displayWidth = canvasModel.getDisplayWidth();
    final displayHeight = canvasModel.getDisplayHeight();
    final requiredWidth =
        CanvasModel.leftToEdge + displayWidth + CanvasModel.rightToEdge;
    final requiredHeight =
        CanvasModel.topToEdge + displayHeight + CanvasModel.bottomToEdge;
    return selfWidth > (requiredWidth * scale) &&
        selfHeight > (requiredHeight * scale);
  }
}

class _DisplayMenu extends StatefulWidget {
  final String id;
  final FFI ffi;
  final ToolbarState state;
  final Function(bool) setFullscreen;
  final Widget pluginItem;
  _DisplayMenu({
    Key? key,
    required this.id,
    required this.ffi,
    required this.state,
    required this.setFullscreen,
  }) : pluginItem = LocationItem.createLocationItem(
         id,
         ffi,
         kLocationClientRemoteToolbarDisplay,
         true,
       ),
       super(key: key);

  @override
  State<_DisplayMenu> createState() => _DisplayMenuState();
}

class _DisplayMenuState extends State<_DisplayMenu> {
  final RxInt _customPercent = 100.obs;
  late final ScreenAdjustor _screenAdjustor = ScreenAdjustor(
    id: widget.id,
    ffi: widget.ffi,
    cbExitFullscreen: () => widget.setFullscreen(false),
  );

  int get windowId => stateGlobal.windowId;
  Map<String, bool> get perms => widget.ffi.ffiModel.permissions;
  PeerInfo get pi => widget.ffi.ffiModel.pi;
  FfiModel get ffiModel => widget.ffi.ffiModel;
  FFI get ffi => widget.ffi;
  String get id => widget.id;

  @override
  void initState() {
    super.initState();
    // Initialize custom percent from stored option once
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final v = await getSessionCustomScalePercent(widget.ffi.sessionId);
        if (_customPercent.value != v) {
          _customPercent.value = v;
        }
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    _screenAdjustor.updateScreen();
    menuChildrenGetter(_IconSubmenuButtonState state) {
      final menuChildren = <Widget>[
        MenuButton(
          child: Text(
            translate(
              stateGlobal.fullscreen.isTrue ? 'Exit Fullscreen' : 'Fullscreen',
            ),
          ),
          trailingIcon: Icon(
            stateGlobal.fullscreen.isTrue
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            size: 18,
          ),
          onPressed: () => widget.setFullscreen(!stateGlobal.fullscreen.value),
          ffi: widget.ffi,
        ),
        const Divider(),
        _screenAdjustor.adjustWindow(context),
        viewStyle(customPercent: _customPercent),
        scrollStyle(state, colorScheme),
        imageQuality(),
        codec(),
        if (ffi.connType == ConnType.defaultConn)
          _ResolutionsMenu(
            id: widget.id,
            ffi: widget.ffi,
            screenAdjustor: _screenAdjustor,
          ),
        if (showVirtualDisplayMenu(ffi) && ffi.connType == ConnType.defaultConn)
          _SubmenuButton(
            ffi: widget.ffi,
            menuChildren: getVirtualDisplayMenuChildren(ffi, id, null),
            child: Text(translate("Virtual display")),
          ),
        if (ffi.connType == ConnType.defaultConn) cursorToggles(),
        Divider(),
        toggles(),
      ];
      // privacy mode
      final privacyModeState = PrivacyModeState.find(id);
      if (ffi.connType == ConnType.defaultConn &&
          (pi.features.privacyMode || privacyModeState.isNotEmpty) &&
          (ffiModel.keyboard || privacyModeState.isNotEmpty)) {
        final privacyModeList = toolbarPrivacyMode(
          privacyModeState,
          context,
          id,
          ffi,
        );
        if (privacyModeList.length == 1) {
          menuChildren.add(
            CkbMenuButton(
              value: privacyModeList[0].value,
              onChanged: privacyModeList[0].onChanged,
              child: privacyModeList[0].child,
              ffi: ffi,
            ),
          );
        } else if (privacyModeList.length > 1) {
          menuChildren.addAll([
            Divider(),
            _SubmenuButton(
              ffi: widget.ffi,
              child: Text(translate('Privacy mode')),
              menuChildren: privacyModeList
                  .map(
                    (e) => CkbMenuButton(
                      value: e.value,
                      onChanged: e.onChanged,
                      child: e.child,
                      ffi: ffi,
                    ),
                  )
                  .toList(),
            ),
          ]);
        }
      }
      if (ffi.connType == ConnType.defaultConn) {
        menuChildren.add(widget.pluginItem);
      }
      return menuChildren;
    }

    return _IconSubmenuButton(
      tooltip: 'Display Settings',
      icon: const Icon(Icons.display_settings_rounded),
      ffi: widget.ffi,
      color: _ToolbarTheme.blueColor,
      hoverColor: _ToolbarTheme.hoverBlueColor,
      menuChildrenGetter: menuChildrenGetter,
    );
  }

  viewStyle({required RxInt customPercent}) {
    return futureBuilder(
      future: toolbarViewStyle(context, widget.id, widget.ffi),
      hasData: (data) {
        final v = data as List<TRadioMenu<String>>;
        final bool isCustomSelected = v.isNotEmpty
            ? v.first.groupValue == kRemoteViewStyleCustom
            : false;
        return Column(
          children: [
            ...v.map((e) {
              final isCustom = e.value == kRemoteViewStyleCustom;
              final child = isCustom
                  ? Text(translate('Scale custom'))
                  : e.child;
              // Whether the current selection is already custom
              final bool isGroupCustomSelected =
                  e.groupValue == kRemoteViewStyleCustom;
              // Keep menu open when switching INTO custom so the slider is visible immediately
              final bool keepOpenForThisItem =
                  isCustom && !isGroupCustomSelected;
              return RdoMenuButton<String>(
                value: e.value,
                groupValue: e.groupValue,
                onChanged: (value) {
                  // Perform the original change
                  e.onChanged?.call(value);
                  // Only force a rebuild when we keep the menu open to reveal the slider
                  if (keepOpenForThisItem) {
                    setState(() {});
                  }
                },
                child: child,
                ffi: ffi,
                // When entering custom, keep submenu open to show the slider controls
                closeOnActivate: !keepOpenForThisItem,
              );
            }).toList(),
            // Only show a divider when custom is NOT selected
            if (!isCustomSelected) Divider(),
            _customControlsIfCustomSelected(
              onChanged: (v) => customPercent.value = v,
            ),
          ],
        );
      },
    );
  }

  Widget _customControlsIfCustomSelected({ValueChanged<int>? onChanged}) {
    return futureBuilder(
      future: () async {
        final current = await bind.sessionGetViewStyle(
          sessionId: ffi.sessionId,
        );
        return current == kRemoteViewStyleCustom;
      }(),
      hasData: (data) {
        final isCustom = data as bool;
        return AnimatedSwitcher(
          duration: Duration(milliseconds: 220),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: isCustom
              ? _CustomScaleMenuControls(ffi: ffi, onChanged: onChanged)
              : SizedBox.shrink(),
        );
      },
    );
  }

  scrollStyle(_IconSubmenuButtonState state, ColorScheme colorScheme) {
    return futureBuilder(
      future: () async {
        final viewStyle =
            await bind.sessionGetViewStyle(sessionId: ffi.sessionId) ?? '';
        final visible =
            viewStyle == kRemoteViewStyleOriginal ||
            viewStyle == kRemoteViewStyleCustom;
        final scrollStyle =
            await bind.sessionGetScrollStyle(sessionId: ffi.sessionId) ?? '';
        final edgeScrollEdgeThickness = await bind
            .sessionGetEdgeScrollEdgeThickness(sessionId: ffi.sessionId);
        return {
          'visible': visible,
          'scrollStyle': scrollStyle,
          'edgeScrollEdgeThickness': edgeScrollEdgeThickness,
        };
      }(),
      hasData: (data) {
        final visible = data['visible'] as bool;
        if (!visible) return Offstage();
        final groupValue = data['scrollStyle'] as String;
        final edgeScrollEdgeThickness = data['edgeScrollEdgeThickness'] as int;

        onChangeScrollStyle(String? value) async {
          if (value == null) return;
          await bind.sessionSetScrollStyle(
            sessionId: ffi.sessionId,
            value: value,
          );
          widget.ffi.canvasModel.updateScrollStyle();
          state.setState(() {});
        }

        onChangeEdgeScrollEdgeThickness(double? value) async {
          if (value == null) return;
          final newThickness = value.round();
          await bind.sessionSetEdgeScrollEdgeThickness(
            sessionId: ffi.sessionId,
            value: newThickness,
          );
          widget.ffi.canvasModel.updateEdgeScrollEdgeThickness(newThickness);
          state.setState(() {});
        }

        return Obx(
          () => Column(
            children: [
              RdoMenuButton<String>(
                child: Text(translate('ScrollAuto')),
                value: kRemoteScrollStyleAuto,
                groupValue: groupValue,
                onChanged: widget.ffi.canvasModel.imageOverflow.value
                    ? (value) => onChangeScrollStyle(value)
                    : null,
                closeOnActivate: groupValue != kRemoteScrollStyleEdge,
                ffi: widget.ffi,
              ),
              RdoMenuButton<String>(
                child: Text(translate('Scrollbar')),
                value: kRemoteScrollStyleBar,
                groupValue: groupValue,
                onChanged: widget.ffi.canvasModel.imageOverflow.value
                    ? (value) => onChangeScrollStyle(value)
                    : null,
                closeOnActivate: groupValue != kRemoteScrollStyleEdge,
                ffi: widget.ffi,
              ),
              if (!isWeb) ...[
                RdoMenuButton<String>(
                  child: Text(translate('ScrollEdge')),
                  value: kRemoteScrollStyleEdge,
                  groupValue: groupValue,
                  closeOnActivate: false,
                  onChanged: widget.ffi.canvasModel.imageOverflow.value
                      ? (value) => onChangeScrollStyle(value)
                      : null,
                  ffi: widget.ffi,
                ),
                Offstage(
                  offstage: groupValue != kRemoteScrollStyleEdge,
                  child: EdgeThicknessControl(
                    value: edgeScrollEdgeThickness.toDouble(),
                    onChanged: onChangeEdgeScrollEdgeThickness,
                    colorScheme: colorScheme,
                  ),
                ),
              ],
              Divider(),
            ],
          ),
        );
      },
    );
  }

  imageQuality() {
    return futureBuilder(
      future: toolbarImageQuality(context, widget.id, widget.ffi),
      hasData: (data) {
        final v = data as List<TRadioMenu<String>>;
        return _SubmenuButton(
          ffi: widget.ffi,
          child: _menuLabel(
            context,
            Icons.high_quality_outlined,
            translate('Image Quality'),
          ),
          menuChildren: v
              .map(
                (e) => RdoMenuButton<String>(
                  value: e.value,
                  groupValue: e.groupValue,
                  onChanged: e.onChanged,
                  child: e.child,
                  ffi: ffi,
                ),
              )
              .toList(),
        );
      },
    );
  }

  codec() {
    return futureBuilder(
      future: toolbarCodec(context, id, ffi),
      hasData: (data) {
        final v = data as List<TRadioMenu<String>>;
        if (v.isEmpty) return Offstage();

        return _SubmenuButton(
          ffi: widget.ffi,
          child: _menuLabel(
            context,
            Icons.video_settings_outlined,
            translate('Codec'),
          ),
          menuChildren: v
              .map(
                (e) => RdoMenuButton(
                  value: e.value,
                  groupValue: e.groupValue,
                  onChanged: e.onChanged,
                  child: e.child,
                  ffi: ffi,
                ),
              )
              .toList(),
        );
      },
    );
  }

  cursorToggles() {
    return _SubmenuButton(
      ffi: widget.ffi,
      child: _menuLabel(context, Icons.mouse_outlined, translate('Mouse mode')),
      menuChildren: [
        futureBuilder(
          future: toolbarCursor(context, id, ffi),
          hasData: (data) {
            final v = data as List<TToggleMenu>;
            if (v.isEmpty) return const Offstage();
            return Column(
              children: v
                  .map(
                    (e) => CkbMenuButton(
                      value: e.value,
                      onChanged: e.onChanged,
                      child: e.child,
                      ffi: ffi,
                    ),
                  )
                  .toList(),
            );
          },
        ),
      ],
    );
  }

  toggles() {
    return _SubmenuButton(
      ffi: widget.ffi,
      child: _menuLabel(context, Icons.tune_rounded, translate('General')),
      menuChildren: [
        futureBuilder(
          future: toolbarDisplayToggle(context, id, ffi),
          hasData: (data) {
            final v = data as List<TToggleMenu>;
            if (v.isEmpty) return const Offstage();
            return Column(
              children: v
                  .map(
                    (e) => CkbMenuButton(
                      value: e.value,
                      onChanged: e.onChanged,
                      child: e.child,
                      ffi: ffi,
                    ),
                  )
                  .toList(),
            );
          },
        ),
      ],
    );
  }
}

class _CustomScaleMenuControls extends StatefulWidget {
  final FFI ffi;
  final ValueChanged<int>? onChanged;
  const _CustomScaleMenuControls({Key? key, required this.ffi, this.onChanged})
    : super(key: key);

  @override
  State<_CustomScaleMenuControls> createState() =>
      _CustomScaleMenuControlsState();
}

class _CustomScaleMenuControlsState
    extends CustomScaleControls<_CustomScaleMenuControls> {
  @override
  FFI get ffi => widget.ffi;

  @override
  ValueChanged<int>? get onScaleChanged => widget.onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    const smallBtnConstraints = BoxConstraints(minWidth: 28, minHeight: 28);

    final sliderControl = Semantics(
      label: translate('Custom scale slider'),
      value: '$scaleValue%',
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: colorScheme.primary,
          thumbColor: colorScheme.primary,
          overlayColor: colorScheme.primary.withValues(alpha: 0.1),
          showValueIndicator: ShowValueIndicator.never,
          thumbShape: _RectValueThumbShape(
            min: CustomScaleControls.minPercent.toDouble(),
            max: CustomScaleControls.maxPercent.toDouble(),
            width: 52,
            height: 24,
            radius: 4,
            displayValueForNormalized: (t) => mapPosToPercent(t),
          ),
        ),
        child: Slider(
          value: scalePos,
          min: 0.0,
          max: 1.0,
          // Use a wide range of divisions (calculated as (CustomScaleControls.maxPercent - CustomScaleControls.minPercent)) to provide ~1% precision increments.
          // This allows users to set precise scale values. Lower values would require more fine-tuning via the +/- buttons, which is undesirable for big ranges.
          divisions:
              (CustomScaleControls.maxPercent - CustomScaleControls.minPercent)
                  .round(),
          onChanged: onSliderChanged,
        ),
      ),
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0),
          child: Row(
            children: [
              Tooltip(
                message: translate('Decrease'),
                child: IconButton(
                  iconSize: 16,
                  padding: EdgeInsets.all(1),
                  constraints: smallBtnConstraints,
                  splashRadius: 11,
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.remove),
                  onPressed: () => nudgeScale(-1),
                ),
              ),
              Expanded(child: sliderControl),
              Tooltip(
                message: translate('Increase'),
                child: IconButton(
                  iconSize: 16,
                  padding: EdgeInsets.all(1),
                  constraints: smallBtnConstraints,
                  splashRadius: 11,
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.add),
                  onPressed: () => nudgeScale(1),
                ),
              ),
            ],
          ),
        ),
        Divider(),
      ],
    );
  }
}

// Lightweight rectangular thumb that paints the current percentage.
// Stateless and uses only SliderTheme colors; avoids allocations beyond a TextPainter per frame.
class _RectValueThumbShape extends SliderComponentShape {
  final double min;
  final double max;
  final double width;
  final double height;
  final double radius;
  final String unit;
  // Optional mapper to compute display value from normalized position [0,1]
  // If null, falls back to linear interpolation between min and max.
  final int Function(double normalized)? displayValueForNormalized;

  const _RectValueThumbShape({
    required this.min,
    required this.max,
    required this.width,
    required this.height,
    required this.radius,
    this.displayValueForNormalized,
    this.unit = '%',
  });

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return Size(width, height);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final Canvas canvas = context.canvas;

    // Resolve color based on enabled/disabled animation, with safe fallbacks.
    final ColorTween colorTween = ColorTween(
      begin: sliderTheme.disabledThumbColor,
      end: sliderTheme.thumbColor,
    );
    final Color? evaluatedColor = colorTween.evaluate(enableAnimation);
    final Color? thumbColor = sliderTheme.thumbColor;
    final Color fillColor = evaluatedColor ?? thumbColor ?? Colors.blueAccent;

    final RRect rrect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: width, height: height),
      Radius.circular(radius),
    );
    final Paint paint = Paint()..color = fillColor;
    canvas.drawRRect(rrect, paint);

    // Compute displayed value from normalized slider value.
    final int displayValue = displayValueForNormalized != null
        ? displayValueForNormalized!(value)
        : (min + value * (max - min)).round();
    final TextSpan span = TextSpan(
      text: '$displayValue$unit',
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
    final TextPainter tp = TextPainter(
      text: span,
      textAlign: TextAlign.center,
      textDirection: textDirection,
    );
    tp.layout(maxWidth: width - 4);
    tp.paint(
      canvas,
      Offset(center.dx - tp.width / 2, center.dy - tp.height / 2),
    );
  }
}

class _ResolutionsMenu extends StatefulWidget {
  final String id;
  final FFI ffi;
  final ScreenAdjustor screenAdjustor;

  _ResolutionsMenu({
    Key? key,
    required this.id,
    required this.ffi,
    required this.screenAdjustor,
  }) : super(key: key);

  @override
  State<_ResolutionsMenu> createState() => _ResolutionsMenuState();
}

const double _kCustomResolutionEditingWidth = 42;
const _kCustomResolutionValue = 'custom';

class _ResolutionsMenuState extends State<_ResolutionsMenu> {
  String _groupValue = '';
  Resolution? _localResolution;

  late final TextEditingController _customWidth = TextEditingController(
    text: rect?.width.toInt().toString() ?? '',
  );
  late final TextEditingController _customHeight = TextEditingController(
    text: rect?.height.toInt().toString() ?? '',
  );

  FFI get ffi => widget.ffi;
  PeerInfo get pi => widget.ffi.ffiModel.pi;
  FfiModel get ffiModel => widget.ffi.ffiModel;
  Rect? get rect => scaledRect();
  List<Resolution> get resolutions => pi.resolutions;
  bool get isWayland => bind.mainCurrentIsWayland();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _getLocalResolutionWayland();
    });
  }

  Rect? scaledRect() {
    final scale = pi.scaleOfDisplay(pi.currentDisplay);
    final rect = ffiModel.rect;
    if (rect == null) {
      return null;
    }
    return Rect.fromLTWH(
      rect.left,
      rect.top,
      rect.width / scale,
      rect.height / scale,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isVirtualDisplay = ffiModel.isVirtualDisplayResolution;
    final visible =
        ffiModel.keyboard &&
        (isVirtualDisplay || resolutions.length > 1) &&
        pi.currentDisplay != kAllDisplayValue;
    if (!visible) return Offstage();
    final showOriginalBtn =
        ffiModel.isOriginalResolutionSet && !ffiModel.isOriginalResolution;
    final showFitLocalBtn = !_isRemoteResolutionFitLocal();
    _setGroupValue();
    return _SubmenuButton(
      ffi: widget.ffi,
      menuChildren:
          <Widget>[
            _OriginalResolutionMenuButton(context, showOriginalBtn),
            _FitLocalResolutionMenuButton(context, showFitLocalBtn),
            _customResolutionMenuButton(context, isVirtualDisplay),
            _menuDivider(showOriginalBtn, showFitLocalBtn, isVirtualDisplay),
          ] +
          _supportedResolutionMenuButtons(),
      child: _menuLabel(
        context,
        Icons.aspect_ratio_rounded,
        translate("Resolution"),
      ),
    );
  }

  _setGroupValue() {
    if (pi.currentDisplay == kAllDisplayValue) {
      return;
    }
    final lastGroupValue = stateGlobal.getLastResolutionGroupValue(
      widget.id,
      pi.currentDisplay,
    );
    if (lastGroupValue == _kCustomResolutionValue) {
      _groupValue = _kCustomResolutionValue;
    } else {
      _groupValue =
          '${(rect?.width ?? 0).toInt()}x${(rect?.height ?? 0).toInt()}';
    }
  }

  _menuDivider(
    bool showOriginalBtn,
    bool showFitLocalBtn,
    bool isVirtualDisplay,
  ) {
    return Offstage(
      offstage: !(showOriginalBtn || showFitLocalBtn || isVirtualDisplay),
      child: Divider(),
    );
  }

  Timer? _adjustWindowTimer;

  @override
  void dispose() {
    _adjustWindowTimer?.cancel();
    _adjustWindowTimer = null;
    super.dispose();
  }

  Future<void> _getLocalResolutionWayland() async {
    if (!isWayland) return _getLocalResolution();
    final window = await window_size.getWindowInfo();
    if (!mounted) return;
    final screen = window.screen;
    if (screen != null) {
      setState(() {
        _localResolution = Resolution(
          screen.frame.width.toInt(),
          screen.frame.height.toInt(),
        );
      });
    }
  }

  _getLocalResolution() {
    _localResolution = null;
    final String mainDisplay = bind.mainGetMainDisplay();
    if (mainDisplay.isNotEmpty) {
      try {
        final normalized = mainDisplay.trim();
        if (isWeb && !normalized.startsWith('{')) {
          return;
        }
        final display = json.decode(normalized);
        if (display['w'] != null && display['h'] != null) {
          _localResolution = Resolution(display['w'], display['h']);
          if (isWeb) {
            if (display['scaleFactor'] != null) {
              _localResolution = Resolution(
                (display['w'] / display['scaleFactor']).toInt(),
                (display['h'] / display['scaleFactor']).toInt(),
              );
            }
          }
        }
      } catch (e) {
        debugPrint('Failed to decode $mainDisplay, $e');
      }
    }
  }

  // This widget has been unmounted, so the State no longer has a context
  _onChanged(String? value) async {
    if (pi.currentDisplay == kAllDisplayValue) {
      return;
    }
    stateGlobal.setLastResolutionGroupValue(
      widget.id,
      pi.currentDisplay,
      value,
    );
    if (value == null) return;

    int? w;
    int? h;
    if (value == _kCustomResolutionValue) {
      w = int.tryParse(_customWidth.text);
      h = int.tryParse(_customHeight.text);
    } else {
      final list = value.split('x');
      if (list.length == 2) {
        w = int.tryParse(list[0]);
        h = int.tryParse(list[1]);
      }
    }

    if (w != null && h != null) {
      if (w != rect?.width.toInt() || h != rect?.height.toInt()) {
        await _changeResolution(w, h);
      }
    }
  }

  _changeResolution(int w, int h) async {
    if (pi.currentDisplay == kAllDisplayValue) {
      return;
    }
    await bind.sessionChangeResolution(
      sessionId: ffi.sessionId,
      display: pi.currentDisplay,
      width: w,
      height: h,
    );
    _adjustWindowTimer?.cancel();
    _adjustWindowTimer = Timer(const Duration(seconds: 3), () async {
      if (!mounted) return;
      final rect = ffiModel.rect;
      if (rect == null) {
        return;
      }
      if (w == rect.width.toInt() && h == rect.height.toInt()) {
        if (await widget.screenAdjustor.isWindowCanBeAdjusted()) {
          if (!mounted) return;
          widget.screenAdjustor.doAdjustWindow(context);
        }
      }
    });
  }

  Widget _OriginalResolutionMenuButton(
    BuildContext context,
    bool showOriginalBtn,
  ) {
    final display = pi.tryGetDisplayIfNotAllDisplay();
    if (display == null) {
      return Offstage();
    }
    if (!resolutions.any(
      (e) =>
          e.width == display.originalWidth &&
          e.height == display.originalHeight,
    )) {
      return Offstage();
    }
    return Offstage(
      offstage: !showOriginalBtn,
      child: MenuButton(
        onPressed: () =>
            _changeResolution(display.originalWidth, display.originalHeight),
        ffi: widget.ffi,
        child: Text(
          '${translate('resolution_original_tip')} ${display.originalWidth}x${display.originalHeight}',
        ),
      ),
    );
  }

  Widget _FitLocalResolutionMenuButton(
    BuildContext context,
    bool showFitLocalBtn,
  ) {
    return Offstage(
      offstage: !showFitLocalBtn,
      child: MenuButton(
        onPressed: () {
          final resolution = _getBestFitResolution();
          if (resolution != null) {
            _changeResolution(resolution.width, resolution.height);
          }
        },
        ffi: widget.ffi,
        child: Text(
          '${translate('resolution_fit_local_tip')} ${_localResolution?.width ?? 0}x${_localResolution?.height ?? 0}',
        ),
      ),
    );
  }

  Widget _customResolutionMenuButton(BuildContext context, isVirtualDisplay) {
    return Offstage(
      offstage: !isVirtualDisplay,
      child: RdoMenuButton(
        value: _kCustomResolutionValue,
        groupValue: _groupValue,
        onChanged: (String? value) => _onChanged(value),
        ffi: widget.ffi,
        child: Row(
          children: [
            Text('${translate('resolution_custom_tip')} '),
            SizedBox(
              width: _kCustomResolutionEditingWidth,
              child: _resolutionInput(_customWidth),
            ),
            Text(' x '),
            SizedBox(
              width: _kCustomResolutionEditingWidth,
              child: _resolutionInput(_customHeight),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resolutionInput(TextEditingController controller) {
    return TextField(
      decoration: InputDecoration(
        border: InputBorder.none,
        isDense: true,
        contentPadding: EdgeInsets.fromLTRB(3, 3, 3, 3),
      ),
      keyboardType: TextInputType.number,
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(4),
        FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
      ],
      controller: controller,
    ).workaroundFreezeLinuxMint();
  }

  List<Widget> _supportedResolutionMenuButtons() => resolutions
      .map(
        (e) => RdoMenuButton(
          value: '${e.width}x${e.height}',
          groupValue: _groupValue,
          onChanged: (String? value) => _onChanged(value),
          ffi: widget.ffi,
          child: Text('${e.width}x${e.height}'),
        ),
      )
      .toList();

  Resolution? _getBestFitResolution() {
    if (_localResolution == null) {
      return null;
    }

    if (ffiModel.isVirtualDisplayResolution) {
      return _localResolution!;
    }

    for (final r in resolutions) {
      if (r.width == _localResolution!.width &&
          r.height == _localResolution!.height) {
        return r;
      }
    }

    return null;
  }

  bool _isRemoteResolutionFitLocal() {
    if (_localResolution == null) {
      return true;
    }
    final bestFitResolution = _getBestFitResolution();
    if (bestFitResolution == null) {
      return true;
    }
    return bestFitResolution.width == rect?.width.toInt() &&
        bestFitResolution.height == rect?.height.toInt();
  }
}

class _KeyboardMenu extends StatelessWidget {
  final String id;
  final FFI ffi;
  final bool inOverflow;
  _KeyboardMenu({
    Key? key,
    required this.id,
    required this.ffi,
    this.inOverflow = false,
  }) : super(key: key);

  PeerInfo get pi => ffi.ffiModel.pi;

  @override
  Widget build(BuildContext context) {
    var ffiModel = Provider.of<FfiModel>(context);
    if (!ffiModel.keyboard) return Offstage();
    toolbarToggles() {
      final toggles = toolbarKeyboardToggles(ffi)
          .map(
            (e) =>
                CkbMenuButton(
                      value: e.value,
                      onChanged: e.onChanged,
                      child: e.child,
                      ffi: ffi,
                    )
                    as Widget,
          )
          .toList();
      if (toggles.isNotEmpty) {
        toggles.add(Divider());
      }
      return toggles;
    }

    return _IconSubmenuButton(
      tooltip: 'Keyboard Settings',
      icon: const Icon(Icons.keyboard_alt_outlined),
      ffi: ffi,
      inOverflow: inOverflow,
      color: _ToolbarTheme.blueColor,
      hoverColor: _ToolbarTheme.hoverBlueColor,
      menuChildrenGetter: (_) => [
        keyboardMode(),
        localKeyboardType(),
        inputSource(),
        Divider(),
        viewMode(),
        if ([
          kPeerPlatformWindows,
          kPeerPlatformMacOS,
          kPeerPlatformLinux,
        ].contains(pi.platform))
          showMyCursor(),
        Divider(),
        ...toolbarToggles(),
        ...mouseSpeed(),
        ...mobileActions(),
      ],
    );
  }

  mouseSpeed() {
    final speedWidgets = [];
    final sessionId = ffi.sessionId;
    if (isDesktop) {
      if (ffi.ffiModel.keyboard) {
        final enabled = !ffi.ffiModel.viewOnly;
        final trackpad = MenuButton(
          child: Text(translate('Trackpad speed')).paddingOnly(left: 26.0),
          onPressed: enabled ? () => trackpadSpeedDialog(sessionId, ffi) : null,
          ffi: ffi,
        );
        speedWidgets.add(trackpad);
      }
    }
    return speedWidgets;
  }

  keyboardMode() {
    return futureBuilder(
      future: () async {
        return await bind.sessionGetKeyboardMode(sessionId: ffi.sessionId) ??
            kKeyLegacyMode;
      }(),
      hasData: (data) {
        final groupValue = data as String;
        List<InputModeMenu> modes = [
          InputModeMenu(key: kKeyLegacyMode, menu: 'Legacy mode'),
          InputModeMenu(key: kKeyMapMode, menu: 'Map mode'),
          InputModeMenu(key: kKeyTranslateMode, menu: 'Translate mode'),
        ];
        List<RdoMenuButton> list = [];
        final enabled = !ffi.ffiModel.viewOnly;
        onChanged(String? value) async {
          if (value == null) return;
          await bind.sessionSetKeyboardMode(
            sessionId: ffi.sessionId,
            value: value,
          );
          await ffi.inputModel.updateKeyboardMode();
        }

        // If use flutter to grab keys, we can only use one mode.
        // Map mode and Legacy mode, at least one of them is supported.
        String? modeOnly;
        // Flutter-sourced desktop input can expose only one reliable keyboard
        // mode. Keep the capability-selected map/legacy mode until the native
        // bridge reports translate-mode support; the checks below remain the
        // source of truth and avoid presenting a non-functional choice.
        if (isInputSourceFlutter && isDesktop) {
          if (bind.sessionIsKeyboardModeSupported(
            sessionId: ffi.sessionId,
            mode: kKeyMapMode,
          )) {
            modeOnly = kKeyMapMode;
          } else if (bind.sessionIsKeyboardModeSupported(
            sessionId: ffi.sessionId,
            mode: kKeyLegacyMode,
          )) {
            modeOnly = kKeyLegacyMode;
          }
        }

        for (InputModeMenu mode in modes) {
          if (modeOnly != null && mode.key != modeOnly) {
            continue;
          } else if (!bind.sessionIsKeyboardModeSupported(
            sessionId: ffi.sessionId,
            mode: mode.key,
          )) {
            continue;
          }

          if (pi.isWayland && mode.key != kKeyMapMode) {
            continue;
          }

          var text = translate(mode.menu);
          if (mode.key == kKeyTranslateMode) {
            text = '$text beta';
          }
          list.add(
            RdoMenuButton<String>(
              child: Text(text),
              value: mode.key,
              groupValue: groupValue,
              onChanged: enabled ? onChanged : null,
              ffi: ffi,
            ),
          );
        }
        return Column(children: list);
      },
    );
  }

  localKeyboardType() {
    final localPlatform = getLocalPlatformForKBLayoutType(pi.platform);
    final visible = localPlatform != '';
    if (!visible) return Offstage();
    final enabled = !ffi.ffiModel.viewOnly;
    return Column(
      children: [
        Divider(),
        MenuButton(
          child: Text(
            '${translate('Local keyboard type')}: ${KBLayoutType.value}',
          ),
          trailingIcon: const Icon(Icons.settings),
          ffi: ffi,
          onPressed: enabled
              ? () => showKBLayoutTypeChooser(localPlatform, ffi.dialogManager)
              : null,
        ),
      ],
    );
  }

  inputSource() {
    final supportedInputSource = bind.mainSupportedInputSource();
    if (supportedInputSource.isEmpty) return Offstage();
    late final List<dynamic> supportedInputSourceList;
    try {
      supportedInputSourceList = jsonDecode(supportedInputSource);
    } catch (e) {
      debugPrint('Failed to decode $supportedInputSource, $e');
      return;
    }
    if (supportedInputSourceList.length < 2) return Offstage();
    final inputSource = stateGlobal.getInputSource();
    final enabled = !ffi.ffiModel.viewOnly;
    final children = <Widget>[Divider()];
    children.addAll(
      supportedInputSourceList.map((e) {
        final d = e as List<dynamic>;
        return RdoMenuButton<String>(
          child: Text(translate(d[1] as String)),
          value: d[0] as String,
          groupValue: inputSource,
          onChanged: enabled
              ? (v) async {
                  if (v != null) {
                    await stateGlobal.setInputSource(ffi.sessionId, v);
                    // Release native input; see the macOS trade-offs in RemotePage.
                    if (isMacOS) ffi.inputModel.enterOrLeave(false);
                    await ffi.ffiModel.checkDesktopKeyboardMode();
                    await ffi.inputModel.updateKeyboardMode();
                  }
                }
              : null,
          ffi: ffi,
        );
      }),
    );
    return Column(children: children);
  }

  viewMode() {
    final ffiModel = ffi.ffiModel;
    final enabled = versionCmp(pi.version, '1.2.0') >= 0 && ffiModel.keyboard;
    return CkbMenuButton(
      value: ffiModel.viewOnly,
      onChanged: enabled
          ? (value) async {
              if (value == null) return;
              await bind.sessionToggleOption(
                sessionId: ffi.sessionId,
                value: kOptionToggleViewOnly,
              );
              final viewOnly = await bind.sessionGetToggleOption(
                sessionId: ffi.sessionId,
                arg: kOptionToggleViewOnly,
              );
              ffiModel.setViewOnly(id, viewOnly ?? value);
              final showMyCursor = await bind.sessionGetToggleOption(
                sessionId: ffi.sessionId,
                arg: kOptionToggleShowMyCursor,
              );
              ffiModel.setShowMyCursor(showMyCursor ?? value);
            }
          : null,
      ffi: ffi,
      child: Text(translate('View Mode')),
    );
  }

  showMyCursor() {
    final ffiModel = ffi.ffiModel;
    return CkbMenuButton(
      value: ffiModel.showMyCursor,
      onChanged: (value) async {
        if (value == null) return;
        await bind.sessionToggleOption(
          sessionId: ffi.sessionId,
          value: kOptionToggleShowMyCursor,
        );
        final showMyCursor =
            await bind.sessionGetToggleOption(
              sessionId: ffi.sessionId,
              arg: kOptionToggleShowMyCursor,
            ) ??
            value;
        ffiModel.setShowMyCursor(showMyCursor);

        // Also set view only if showMyCursor is enabled and viewOnly is not enabled.
        if (showMyCursor && !ffiModel.viewOnly) {
          await bind.sessionToggleOption(
            sessionId: ffi.sessionId,
            value: kOptionToggleViewOnly,
          );
          final viewOnly = await bind.sessionGetToggleOption(
            sessionId: ffi.sessionId,
            arg: kOptionToggleViewOnly,
          );
          ffiModel.setViewOnly(id, viewOnly ?? value);
        }
      },
      ffi: ffi,
      child: Text(translate('Show my cursor')),
    ).paddingOnly(left: 26.0);
  }

  mobileActions() {
    if (pi.platform != kPeerPlatformAndroid) return [];
    final enabled = versionCmp(pi.version, '1.2.7') >= 0;
    if (!enabled) return [];
    return [
      Divider(),
      MenuButton(
        child: Text(translate('Back')),
        onPressed: () => ffi.inputModel.onMobileBack(),
        ffi: ffi,
      ),
      MenuButton(
        child: Text(translate('Home')),
        onPressed: () => ffi.inputModel.onMobileHome(),
        ffi: ffi,
      ),
      MenuButton(
        child: Text(translate('Apps')),
        onPressed: () => ffi.inputModel.onMobileApps(),
        ffi: ffi,
      ),
      MenuButton(
        child: Text(translate('Volume up')),
        onPressed: () => ffi.inputModel.onMobileVolumeUp(),
        ffi: ffi,
      ),
      MenuButton(
        child: Text(translate('Volume down')),
        onPressed: () => ffi.inputModel.onMobileVolumeDown(),
        ffi: ffi,
      ),
      MenuButton(
        child: Text(translate('Power')),
        onPressed: () => ffi.inputModel.onMobilePower(),
        ffi: ffi,
      ),
    ];
  }
}

class _ChatMenu extends StatefulWidget {
  final String id;
  final FFI ffi;
  final bool inOverflow;
  _ChatMenu({
    Key? key,
    required this.id,
    required this.ffi,
    this.inOverflow = false,
  }) : super(key: key);

  @override
  State<_ChatMenu> createState() => _ChatMenuState();
}

class _ChatMenuState extends State<_ChatMenu> {
  // Using in StatelessWidget got `Looking up a deactivated widget's ancestor is unsafe`.
  final chatButtonKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    if (isWeb) {
      return buildTextChatButton();
    } else {
      return _IconSubmenuButton(
        tooltip: 'Chat',
        key: chatButtonKey,
        icon: const Icon(Icons.chat_bubble_outline_rounded),
        ffi: widget.ffi,
        inOverflow: widget.inOverflow,
        color: _ToolbarTheme.blueColor,
        hoverColor: _ToolbarTheme.hoverBlueColor,
        menuChildrenGetter: (_) => [textChat(), voiceCall()],
      );
    }
  }

  buildTextChatButton() {
    return _IconMenuButton(
      icon: const Icon(Icons.chat_rounded),
      tooltip: 'Text chat',
      key: chatButtonKey,
      inOverflow: widget.inOverflow,
      onPressed: _textChatOnPressed,
      color: _ToolbarTheme.blueColor,
      hoverColor: _ToolbarTheme.hoverBlueColor,
    );
  }

  textChat() {
    return MenuButton(
      child: Text(translate('Text chat')),
      ffi: widget.ffi,
      onPressed: _textChatOnPressed,
    );
  }

  _textChatOnPressed() {
    RenderBox? renderBox =
        chatButtonKey.currentContext?.findRenderObject() as RenderBox?;
    Offset? initPos;
    if (renderBox != null) {
      final pos = renderBox.localToGlobal(Offset.zero);
      initPos = Offset(pos.dx, pos.dy + _ToolbarTheme.dividerHeight);
    }
    widget.ffi.chatModel.changeCurrentKey(
      MessageKey(widget.ffi.id, ChatModel.clientModeID),
    );
    widget.ffi.chatModel.toggleChatOverlay(chatInitPos: initPos);
  }

  voiceCall() {
    return MenuButton(
      child: Text(translate('Voice call')),
      ffi: widget.ffi,
      onPressed: () =>
          bind.sessionRequestVoiceCall(sessionId: widget.ffi.sessionId),
    );
  }
}

class _VoiceCallMenu extends StatelessWidget {
  final String id;
  final FFI ffi;
  final bool inOverflow;
  _VoiceCallMenu({
    Key? key,
    required this.id,
    required this.ffi,
    this.inOverflow = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    menuChildrenGetter(_IconSubmenuButtonState state) {
      final audioInput = AudioInput(
        builder: (devices, currentDevice, setDevice) {
          return Column(
            children: devices
                .map(
                  (d) => RdoMenuButton<String>(
                    child: Container(
                      child: Text(d, overflow: TextOverflow.ellipsis),
                      constraints: BoxConstraints(maxWidth: 250),
                    ),
                    value: d,
                    groupValue: currentDevice,
                    onChanged: (v) {
                      if (v != null) setDevice(v);
                    },
                    ffi: ffi,
                  ),
                )
                .toList(),
          );
        },
        isCm: false,
        isVoiceCall: true,
      );
      return [
        audioInput,
        Divider(),
        MenuButton(
          child: Text(translate('End call')),
          onPressed: () => bind.sessionCloseVoiceCall(sessionId: ffi.sessionId),
          ffi: ffi,
        ),
      ];
    }

    return Obx(() {
      switch (ffi.chatModel.voiceCallStatus.value) {
        case VoiceCallStatus.waitingForResponse:
          return buildCallWaiting(context);
        case VoiceCallStatus.connected:
          return _IconSubmenuButton(
            tooltip: 'Voice call',
            icon: const Icon(Icons.call_rounded),
            inOverflow: inOverflow,
            color: _ToolbarTheme.blueColor,
            hoverColor: _ToolbarTheme.hoverBlueColor,
            menuChildrenGetter: menuChildrenGetter,
            ffi: ffi,
          );
        default:
          return Offstage();
      }
    });
  }

  Widget buildCallWaiting(BuildContext context) {
    return _IconMenuButton(
      icon: const Icon(Icons.call_end_rounded),
      tooltip: "Waiting",
      inOverflow: inOverflow,
      onPressed: () => bind.sessionCloseVoiceCall(sessionId: ffi.sessionId),
      color: _ToolbarTheme.redColor,
      hoverColor: _ToolbarTheme.hoverRedColor,
    );
  }
}

class _RecordMenu extends StatelessWidget {
  final bool inOverflow;
  const _RecordMenu({Key? key, this.inOverflow = false}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var ffi = Provider.of<FfiModel>(context);
    var recordingModel = Provider.of<RecordingModel>(context);
    final hideRecordingButton =
        bind.mainGetLocalOption(key: kOptionHideRecordingButton) == 'Y';
    final visible =
        !hideRecordingButton &&
        (recordingModel.start || ffi.permissions['recording'] != false);
    if (!visible) return Offstage();
    return _IconMenuButton(
      icon: Icon(
        recordingModel.start
            ? Icons.stop_circle_outlined
            : Icons.fiber_manual_record_rounded,
      ),
      inOverflow: inOverflow,
      tooltip: recordingModel.start
          ? 'Stop session recording'
          : 'Start session recording',
      onPressed: () => recordingModel.toggle(),
      color: recordingModel.start
          ? _ToolbarTheme.redColor
          : _ToolbarTheme.blueColor,
      hoverColor: recordingModel.start
          ? _ToolbarTheme.hoverRedColor
          : _ToolbarTheme.hoverBlueColor,
    );
  }
}

class _CloseMenu extends StatelessWidget {
  final String id;
  final FFI ffi;
  const _CloseMenu({Key? key, required this.id, required this.ffi})
    : super(key: key);

  @override
  Widget build(BuildContext context) {
    return _IconMenuButton(
      icon: const Icon(Icons.close_rounded),
      tooltip: 'Close',
      onPressed: () async {
        if (await showConnEndAuditDialogCloseCanceled(ffi: ffi)) {
          return;
        }
        closeConnection(id: id);
      },
      color: _ToolbarTheme.redColor,
      hoverColor: _ToolbarTheme.hoverRedColor,
    );
  }
}

class _IconMenuButton extends StatefulWidget {
  final Widget icon;
  final String tooltip;
  final Color color;
  final Color hoverColor;
  final VoidCallback? onPressed;
  final double? hMargin;
  final double? vMargin;
  final bool topLevel;
  final bool inOverflow;
  final double? width;
  const _IconMenuButton({
    Key? key,
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.hoverColor,
    required this.onPressed,
    this.hMargin,
    this.vMargin,
    this.topLevel = true,
    this.inOverflow = false,
    this.width,
  }) : super(key: key);

  @override
  State<_IconMenuButton> createState() => _IconMenuButtonState();
}

class _IconMenuButtonState extends State<_IconMenuButton> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final tint = hover ? widget.hoverColor : widget.color;
    final label = translate(widget.tooltip);
    final leadingIcon = SizedBox.square(
      dimension: 20,
      child: IconTheme.merge(
        data: IconThemeData(color: tint, size: 20),
        child: FittedBox(fit: BoxFit.contain, child: widget.icon),
      ),
    );
    if (widget.inOverflow) {
      return MenuItemButton(
        leadingIcon: leadingIcon,
        onHover: (value) => setState(() => hover = value),
        onPressed: widget.onPressed,
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      );
    }
    final button = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: widget.hMargin ?? _ToolbarTheme.buttonHMargin,
        vertical: widget.vMargin ?? _ToolbarTheme.buttonVMargin,
      ),
      child: SizedBox(
        width: widget.topLevel
            ? _ToolbarTheme.buttonSize
            : widget.width ?? _ToolbarTheme.buttonSize,
        height: _ToolbarTheme.buttonSize,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(_ToolbarTheme.iconRadius),
            onHover: (value) => setState(() => hover = value),
            onTap: widget.onPressed,
            child: _CommandBarActionSurface(
              icon: leadingIcon,
              tint: tint,
              hovered: hover,
            ),
          ),
        ),
      ),
    );
    if (widget.topLevel) {
      return Semantics(
        button: true,
        enabled: widget.onPressed != null,
        label: label,
        child: Tooltip(message: label, child: button),
      );
    }
    return Semantics(
      button: true,
      enabled: widget.onPressed != null,
      label: label,
      child: Tooltip(message: label, child: button),
    );
  }
}

class _CommandBarActionSurface extends StatelessWidget {
  const _CommandBarActionSurface({
    required this.icon,
    required this.tint,
    required this.hovered,
  });

  final Widget icon;
  final Color tint;
  final bool hovered;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: CamelliaMotion.hover,
      curve: CamelliaMotion.enter,
      width: _ToolbarTheme.buttonSize,
      height: _ToolbarTheme.buttonSize,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: hovered
            ? scheme.primaryContainer.withValues(alpha: 0.72)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(_ToolbarTheme.iconRadius),
      ),
      child: IconTheme.merge(
        data: IconThemeData(color: tint, size: 20),
        child: FittedBox(fit: BoxFit.contain, child: icon),
      ),
    );
  }
}

class _IconSubmenuButton extends StatefulWidget {
  final String tooltip;
  final Widget icon;
  final Color color;
  final Color hoverColor;
  final List<Widget> Function(_IconSubmenuButtonState state) menuChildrenGetter;
  final MenuStyle? menuStyle;
  final FFI? ffi;
  final bool inOverflow;

  _IconSubmenuButton({
    Key? key,
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.hoverColor,
    required this.menuChildrenGetter,
    this.ffi,
    this.menuStyle,
    this.inOverflow = false,
  }) : super(key: key);

  @override
  State<_IconSubmenuButton> createState() => _IconSubmenuButtonState();
}

class _IconSubmenuButtonState extends State<_IconSubmenuButton> {
  bool hover = false;
  final MenuController _menuController = MenuController();

  @override // discard @protected
  void setState(VoidCallback fn) {
    super.setState(fn);
  }

  @override
  Widget build(BuildContext context) {
    final tint = hover ? widget.hoverColor : widget.color;
    final label = translate(widget.tooltip);
    final leadingIcon = SizedBox.square(
      dimension: 20,
      child: IconTheme.merge(
        data: IconThemeData(color: tint, size: 20),
        child: FittedBox(fit: BoxFit.contain, child: widget.icon),
      ),
    );
    final menuChildren = widget
        .menuChildrenGetter(this)
        .map((e) => _buildPointerTrackWidget(e, widget.ffi))
        .toList();
    if (widget.inOverflow) {
      return SubmenuButton(
        leadingIcon: leadingIcon,
        menuStyle: widget.menuStyle ?? _ToolbarTheme.defaultMenuStyle(context),
        onHover: (value) => setState(() => hover = value),
        menuChildren: menuChildren,
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      );
    }
    return MenuAnchor(
      controller: _menuController,
      style: widget.menuStyle ?? _ToolbarTheme.defaultMenuStyle(context),
      menuChildren: menuChildren,
      builder: (context, controller, child) => _IconMenuButton(
        icon: widget.icon,
        tooltip: widget.tooltip,
        color: widget.color,
        hoverColor: widget.hoverColor,
        onPressed: controller.isOpen ? controller.close : controller.open,
      ),
    );
  }
}

class _SubmenuButton extends StatelessWidget {
  final List<Widget> menuChildren;
  final Widget? child;
  final FFI ffi;
  const _SubmenuButton({
    Key? key,
    required this.menuChildren,
    required this.child,
    required this.ffi,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SubmenuButton(
      key: key,
      child: child,
      menuChildren: menuChildren
          .map((e) => _buildPointerTrackWidget(e, ffi))
          .toList(),
      menuStyle: _ToolbarTheme.defaultMenuStyle(context),
    );
  }
}

class MenuButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget? trailingIcon;
  final Widget? child;
  final FFI? ffi;
  MenuButton({
    Key? key,
    this.onPressed,
    this.trailingIcon,
    required this.child,
    this.ffi,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MenuItemButton(
      key: key,
      onPressed: onPressed != null
          ? () {
              if (ffi != null) {
                _menuDismissCallback(ffi!);
              }
              onPressed?.call();
            }
          : null,
      trailingIcon: trailingIcon,
      child: child,
    );
  }
}

class CkbMenuButton extends StatelessWidget {
  final bool? value;
  final ValueChanged<bool?>? onChanged;
  final Widget? child;
  final FFI? ffi;
  const CkbMenuButton({
    Key? key,
    required this.value,
    required this.onChanged,
    required this.child,
    this.ffi,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return CheckboxMenuButton(
      key: key,
      value: value,
      child: child,
      onChanged: onChanged != null
          ? (bool? value) {
              if (ffi != null) {
                _menuDismissCallback(ffi!);
              }
              onChanged?.call(value);
            }
          : null,
    );
  }
}

class RdoMenuButton<T> extends StatelessWidget {
  final T value;
  final T? groupValue;
  final ValueChanged<T?>? onChanged;
  final Widget? child;
  final FFI? ffi;
  // When true, submenu will be dismissed on activate; when false, it stays open.
  final bool closeOnActivate;
  const RdoMenuButton({
    Key? key,
    required this.value,
    required this.groupValue,
    required this.child,
    this.ffi,
    this.onChanged,
    this.closeOnActivate = true,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return RadioMenuButton(
      value: value,
      groupValue: groupValue,
      child: child,
      closeOnActivate: closeOnActivate,
      onChanged: onChanged != null
          ? (T? value) {
              if (ffi != null && closeOnActivate) {
                _menuDismissCallback(ffi!);
              }
              onChanged?.call(value);
            }
          : null,
    );
  }
}

class _DraggableShowHide extends StatefulWidget {
  final String id;
  final FFI ffi;
  final SessionID sessionId;
  final RxDouble fraction;
  final Rx<_ToolbarEdge> edge;
  final Rxn<_ToolbarEdge> previewEdge;
  final Rxn<double> previewFraction;
  final Rxn<Size> toolbarSize;
  final bool isHorizontal;
  final void Function(_ToolbarEdge edge, double fraction) onPlacementChanged;
  final RxBool dragging;
  final ToolbarState toolbarState;
  final BorderRadius borderRadius;

  const _DraggableShowHide({
    Key? key,
    required this.id,
    required this.ffi,
    required this.sessionId,
    required this.fraction,
    required this.edge,
    required this.previewEdge,
    required this.previewFraction,
    required this.toolbarSize,
    required this.isHorizontal,
    required this.onPlacementChanged,
    required this.dragging,
    required this.toolbarState,
    required this.borderRadius,
  }) : super(key: key);

  @override
  State<_DraggableShowHide> createState() => _DraggableShowHideState();
}

class _DraggableShowHideState extends State<_DraggableShowHide> {
  static const double _left = 0;
  static const double _right = 1;
  static const double _controlExtent =
      RemoteCommandMenuMetrics.compactHandleExtent / 2;
  Offset? _lastPointerDown;
  Offset? _dragGrabOffset;
  double? _dragLongAxisGrabOffset;
  Size? _dragToolbarSize;

  RxBool get collapse => widget.toolbarState.collapse;

  // Bias the current preview so diagonal drags do not flicker between edges.
  static const double _switchHysteresisPx = 50.0;

  _ToolbarEdge _nearestToolbarEdge(Offset cursor, Size mediaSize) {
    double rawDist(_ToolbarEdge e) {
      switch (e) {
        case _ToolbarEdge.top:
          return cursor.dy;
        case _ToolbarEdge.bottom:
          return mediaSize.height - cursor.dy;
        case _ToolbarEdge.left:
          return cursor.dx;
        case _ToolbarEdge.right:
          return mediaSize.width - cursor.dx;
      }
    }

    final previewed = widget.previewEdge.value;
    var winner = widget.edge.value;
    var best = double.infinity;
    for (final e in _ToolbarEdge.values) {
      final biased = e == previewed
          ? rawDist(e) - _switchHysteresisPx
          : rawDist(e);
      if (biased < best) {
        best = biased;
        winner = e;
      }
    }
    return winner;
  }

  void _ensureDragGrabOffset(Offset cursor) {
    if (_dragGrabOffset != null) return;
    final mediaSize = MediaQueryData.fromView(View.of(context)).size;
    final toolbarSize = _toolbarSizeForEdge(
      widget.edge.value,
      widget.toolbarSize.value,
    );
    _dragToolbarSize = toolbarSize;
    final toolbarOffset = _toolbarOffsetForEdge(
      edge: widget.edge.value,
      fraction: widget.fraction.value,
      parentSize: mediaSize,
      toolbarSize: toolbarSize,
    );
    _dragGrabOffset = cursor - toolbarOffset;
    _dragLongAxisGrabOffset = _isHorizontalEdge(widget.edge.value)
        ? _dragGrabOffset?.dx
        : _dragGrabOffset?.dy;
  }

  double _dragGrabOffsetForEdge(_ToolbarEdge edge, Size toolbarSize) {
    final offset = _dragLongAxisGrabOffset ?? 0;
    final extent = _isHorizontalEdge(edge)
        ? toolbarSize.width
        : toolbarSize.height;
    return _clampToolbarFraction(offset, 0, extent);
  }

  void _updatePreview(Offset cursor) {
    _ensureDragGrabOffset(cursor);
    final mediaSize = MediaQueryData.fromView(View.of(context)).size;
    final winner = _nearestToolbarEdge(cursor, mediaSize);
    widget.previewEdge.value = winner;

    final toolbarSize = _toolbarSizeForEdge(winner, _dragToolbarSize);
    final grabOffset = _dragGrabOffsetForEdge(winner, toolbarSize);
    final double frac;
    if (winner == _ToolbarEdge.top || winner == _ToolbarEdge.bottom) {
      frac = _fractionForAlignedDrag(
        cursor: cursor.dx,
        grabOffset: grabOffset,
        parentExtent: mediaSize.width,
        toolbarExtent: toolbarSize.width,
        left: _left,
        right: _right,
      );
    } else {
      final fractionBounds = _fractionBoundsForEdge(winner, _left, _right);
      frac = _fractionForAlignedDrag(
        cursor: cursor.dy,
        grabOffset: grabOffset,
        parentExtent: mediaSize.height,
        toolbarExtent: toolbarSize.height,
        left: fractionBounds.left,
        right: fractionBounds.right,
      );
    }
    widget.previewFraction.value = frac;
  }

  void _resetDragTracking() {
    _lastPointerDown = null;
    _dragGrabOffset = null;
    _dragLongAxisGrabOffset = null;
    _dragToolbarSize = null;
  }

  void _commitPreview() {
    final newEdge = widget.previewEdge.value;
    final frac = widget.previewFraction.value;
    widget.previewEdge.value = null;
    widget.previewFraction.value = null;
    widget.dragging.value = false;
    _resetDragTracking();
    if (newEdge == null || frac == null) return;
    widget.edge.value = newEdge;
    widget.fraction.value = frac;
    widget.onPlacementChanged(newEdge, frac);
  }

  Widget _buildDraggable(BuildContext context) {
    final icon = Icon(
      widget.isHorizontal ? Icons.drag_indicator : Icons.drag_handle,
      size: 18,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Listener(
      onPointerDown: (event) => _lastPointerDown = event.position,
      child: Tooltip(
        message: translate('Move toolbar'),
        child: MouseRegion(
          cursor: SystemMouseCursors.move,
          child: Draggable(
            axis: null,
            feedback: Material(
              color: Theme.of(context).colorScheme.surface,
              elevation: 8,
              borderRadius: BorderRadius.circular(CamelliaRadius.control),
              child: SizedBox.square(
                dimension: _controlExtent,
                child: Center(child: icon),
              ),
            ),
            onDragStarted: () {
              final pointerDown = _lastPointerDown;
              if (pointerDown != null) {
                _ensureDragGrabOffset(pointerDown);
              }
              widget.dragging.value = true;
              widget.previewEdge.value = widget.edge.value;
              widget.previewFraction.value = widget.fraction.value;
            },
            onDragUpdate: (details) {
              _updatePreview(details.globalPosition);
            },
            onDragEnd: (_) => _commitPreview(),
            child: SizedBox.square(
              dimension: _controlExtent,
              child: Center(child: icon),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const double iconSize = 18;

    Widget buttonWrapper(
      VoidCallback? onPressed,
      IconData icon, {
      required String tooltip,
      Color hoverColor = _ToolbarTheme.blueColor,
    }) {
      return Tooltip(
        message: tooltip,
        child: TextButton(
          onPressed: onPressed,
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll(
              Size(_controlExtent, _controlExtent),
            ),
            maximumSize: const WidgetStatePropertyAll(
              Size(_controlExtent, _controlExtent),
            ),
            padding: const WidgetStatePropertyAll(EdgeInsets.all(7)),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(CamelliaRadius.control),
              ),
            ),
            foregroundColor: WidgetStatePropertyAll(
              Theme.of(context).colorScheme.onSurface,
            ),
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              return states.contains(WidgetState.hovered)
                  ? hoverColor.withValues(alpha: 0.14)
                  : Colors.transparent;
            }),
          ),
          child: Icon(icon, size: iconSize),
        ),
      );
    }

    final axis = widget.isHorizontal ? Axis.horizontal : Axis.vertical;
    final child = Flex(
      direction: axis,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildDraggable(context),
        Obx(
          () => collapse.isTrue
              ? _MinimizedMonitorSwitchButton(id: widget.id, ffi: widget.ffi)
              : const Offstage(),
        ),
        Obx(
          () => buttonWrapper(
            () => widget.toolbarState.switchCollapse(widget.sessionId),
            _toolbarCollapseIcon(widget.edge.value, collapse.isTrue),
            tooltip: translate(
              collapse.isFalse ? 'Hide Toolbar' : 'Show Toolbar',
            ),
          ),
        ),
        if (isWebDesktop)
          Obx(() {
            if (collapse.isFalse) {
              return Offstage();
            } else {
              return buttonWrapper(
                () => closeConnection(id: widget.id),
                Icons.close,
                tooltip: translate('Close'),
                hoverColor: _ToolbarTheme.redColor,
              );
            }
          }),
      ],
    );
    return Container(
      padding: EdgeInsets.zero,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.96),
        border: Border.all(color: _ToolbarTheme.borderColor(context), width: 1),
        borderRadius: widget.borderRadius,
      ),
      child: child,
    );
  }
}

class InputModeMenu {
  final String key;
  final String menu;

  InputModeMenu({required this.key, required this.menu});
}

_menuDismissCallback(FFI ffi) => ffi.inputModel.refreshMousePos();

Widget _buildPointerTrackWidget(Widget child, FFI? ffi) {
  return Listener(
    onPointerHover: (PointerHoverEvent e) => {
      if (ffi != null) {ffi.inputModel.lastMousePos = e.position},
    },
    child: MouseRegion(child: child),
  );
}

class EdgeThicknessControl extends StatelessWidget {
  final double value;
  final ValueChanged<double>? onChanged;
  final ColorScheme? colorScheme;

  const EdgeThicknessControl({
    Key? key,
    required this.value,
    this.onChanged,
    this.colorScheme,
  }) : super(key: key);

  static const double kMin = 20;
  static const double kMax = 150;

  @override
  Widget build(BuildContext context) {
    final colorScheme = this.colorScheme ?? Theme.of(context).colorScheme;

    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: colorScheme.primary,
        thumbColor: colorScheme.primary,
        overlayColor: colorScheme.primary.withValues(alpha: 0.1),
        showValueIndicator: ShowValueIndicator.never,
        thumbShape: _RectValueThumbShape(
          min: EdgeThicknessControl.kMin,
          max: EdgeThicknessControl.kMax,
          width: 52,
          height: 24,
          radius: 4,
          unit: 'px',
        ),
      ),
      child: Semantics(
        value: value.toInt().toString(),
        child: Slider(
          value: value,
          min: EdgeThicknessControl.kMin,
          max: EdgeThicknessControl.kMax,
          divisions: (EdgeThicknessControl.kMax - EdgeThicknessControl.kMin)
              .round(),
          semanticFormatterCallback: (double newValue) =>
              "${newValue.round()}px",
          onChanged: onChanged,
        ),
      ),
    );

    return slider;
  }
}

class _MinimizedMonitorSwitchButton extends StatelessWidget {
  final String id;
  final FFI ffi;

  const _MinimizedMonitorSwitchButton({
    Key? key,
    required this.id,
    required this.ffi,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    const double iconSize = 20;
    final cycle = _MonitorCycle(id, ffi);

    return Obx(() {
      final label = cycle.label;
      if (!mainGetLocalBoolOptionSync(kOptionAllowMonitorSwitchMainToolbar) ||
          !mainGetLocalBoolOptionSync(kOptionAllowMonitorSwitchMinToolbar)) {
        return const Offstage();
      }
      if (cycle.total < 2) return const Offstage();
      final privacyModeState = PrivacyModeState.find(id);
      if (privacyModeState.isNotEmpty &&
          !allowDisplaySwitchInPrivacyMode(
            ffi.ffiModel.pi,
            privacyModeState.value,
          )) {
        return const Offstage();
      }

      return SizedBox.square(
        dimension: 32,
        child: Tooltip(
          message: cycle.tooltip,
          child: TextButton(
            onPressed: cycle.next,
            style: ButtonStyle(
              minimumSize: const WidgetStatePropertyAll(Size(32, 32)),
              maximumSize: const WidgetStatePropertyAll(Size(32, 32)),
              padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.hovered)) {
                  return _ToolbarTheme.blueColor.withValues(alpha: 0.15);
                }
                return null;
              }),
            ),
            child: Stack(
              alignment: const Alignment(0, -0.125),
              children: [
                const Icon(
                  Icons.monitor_rounded,
                  size: iconSize,
                  color: _ToolbarTheme.blueColor,
                ),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 8,
                    height: 1,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}
