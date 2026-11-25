import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart' hide Dialog;
import '../../common/formatter/id_formatter.dart';
import '../../common/widgets/brand_shell.dart';
import '../../models/peer_model.dart';
import '../../models/state_model.dart';
import '../../ui/camellia_design.dart';
import '../../ui/glass_components.dart';
import 'dragable_divider.dart';

/// Theme-aware active brand accent guaranteeing WCAG AA+ contrast across
/// Light, Dark, and OLED Midnight across all three Camellia theme styles.
Color _shellActiveAccent(BuildContext context) {
  final theme = Theme.of(context);
  final glass = CamelliaGlassTokens.of(context);
  final style = glass.themeStyle != CamelliaThemeStyle.auroraFrost
      ? glass.themeStyle
      : MyTheme.themeStyleNotifier.value;
  if (style == CamelliaThemeStyle.auroraFrost) {
    return theme.brightness == Brightness.dark
        ? CamelliaColors.indigoDark
        : CamelliaColors.indigo;
  }
  return theme.colorScheme.primary;
}

/// Navigation destinations available in the Camellia Remote desktop shell.
enum DesktopNavDestination {
  connect,
  devices,
  addressBook,
  settings;

  String get label {
    switch (this) {
      case DesktopNavDestination.connect:
        return translate('Connect');
      case DesktopNavDestination.devices:
        return translate('Devices');
      case DesktopNavDestination.addressBook:
        return translate('Address Book');
      case DesktopNavDestination.settings:
        return translate('Settings');
    }
  }

  IconData get icon {
    switch (this) {
      case DesktopNavDestination.connect:
        return Icons.sensors_outlined;
      case DesktopNavDestination.devices:
        return Icons.devices_outlined;
      case DesktopNavDestination.addressBook:
        return Icons.contact_mail_outlined;
      case DesktopNavDestination.settings:
        return Icons.settings_outlined;
    }
  }

  IconData get selectedIcon {
    switch (this) {
      case DesktopNavDestination.connect:
        return Icons.sensors_rounded;
      case DesktopNavDestination.devices:
        return Icons.devices_rounded;
      case DesktopNavDestination.addressBook:
        return Icons.contact_mail_rounded;
      case DesktopNavDestination.settings:
        return Icons.settings_rounded;
    }
  }
}

/// Optional controller to programmatically manage [CamelliaDesktopShell] state.
class CamelliaDesktopShellController extends ChangeNotifier {
  CamelliaDesktopShellController({
    DesktopNavDestination initialDestination = DesktopNavDestination.connect,
    bool? initialCollapsed,
  }) : _destination = initialDestination,
       _collapsed = initialCollapsed;

  DesktopNavDestination _destination;
  DesktopNavDestination get destination => _destination;

  set destination(DesktopNavDestination value) {
    if (_destination != value) {
      _destination = value;
      notifyListeners();
    }
  }

  bool? _collapsed;
  bool? get collapsed => _collapsed;

  void toggleCollapse() {
    _collapsed = !(_collapsed ?? false);
    notifyListeners();
  }

  void setCollapsed(bool value) {
    if (_collapsed != value) {
      _collapsed = value;
      notifyListeners();
    }
  }
}

/// Unified desktop window shell providing Apple Liquid Glass persistent
/// navigation, ambient backdrop refraction across sidebar and workspace,
/// responsive sidebar/rail transitions, live `Cmd/Ctrl + K` command & peer
/// palette, and resizable pane splitting via [DraggableDivider].
class CamelliaDesktopShell extends StatefulWidget {
  const CamelliaDesktopShell({
    super.key,
    this.initialDestination = DesktopNavDestination.connect,
    this.currentDestination,
    this.destinations,
    this.onDestinationChanged,
    this.controller,
    this.connectBuilder,
    this.devicesBuilder,
    this.addressBookBuilder,
    this.settingsBuilder,
    this.topBar,
    this.statusWidget,
    this.warningWidget,
    this.leading,
    this.trailing,
    this.sidebarHeader,
    this.collapseBreakpoint = 840.0,
    this.defaultSidebarWidth = 220.0,
    this.minSidebarWidth = 180.0,
    this.maxSidebarWidth = 320.0,
    this.railWidth = 64.0,
  });

  final DesktopNavDestination initialDestination;
  final DesktopNavDestination? currentDestination;
  final List<DesktopNavDestination>? destinations;
  final ValueChanged<DesktopNavDestination>? onDestinationChanged;
  final CamelliaDesktopShellController? controller;
  final WidgetBuilder? connectBuilder;
  final WidgetBuilder? devicesBuilder;
  final WidgetBuilder? addressBookBuilder;
  final WidgetBuilder? settingsBuilder;

  /// Optional minimalist title drag strip rendered above the sidebar + content
  /// inside the unified root [CamelliaBackdrop].
  final Widget? topBar;

  final Widget? statusWidget;
  final Widget? warningWidget;
  final Widget? leading;
  final Widget? trailing;
  final Widget? sidebarHeader;
  final double collapseBreakpoint;
  final double defaultSidebarWidth;
  final double minSidebarWidth;
  final double maxSidebarWidth;
  final double railWidth;

  static CamelliaDesktopShellState? of(BuildContext context) {
    return context.findAncestorStateOfType<CamelliaDesktopShellState>();
  }

  static void switchTo(
    BuildContext context,
    DesktopNavDestination destination,
  ) {
    of(context)?.setDestination(destination);
  }

  @override
  State<CamelliaDesktopShell> createState() => CamelliaDesktopShellState();
}

class CamelliaDesktopShellState extends State<CamelliaDesktopShell> {
  late DesktopNavDestination _activeDestination;
  bool? _userCollapsed;
  late double _sidebarWidth;

  DesktopNavDestination get activeDestination =>
      widget.currentDestination ??
      widget.controller?.destination ??
      _activeDestination;

  bool get isExplicitlyCollapsed =>
      widget.controller?.collapsed ?? _userCollapsed ?? false;

  @override
  void initState() {
    super.initState();
    _activeDestination =
        widget.currentDestination ??
        widget.controller?.destination ??
        widget.initialDestination;
    _sidebarWidth = widget.defaultSidebarWidth;
    widget.controller?.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant CamelliaDesktopShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_handleControllerChanged);
      widget.controller?.addListener(_handleControllerChanged);
    }
    if (widget.currentDestination != null &&
        widget.currentDestination != _activeDestination) {
      _activeDestination = widget.currentDestination!;
    }
  }

  Timer? _hoverEnterTimer;
  Timer? _hoverExitTimer;
  bool _hoverExpanded = false;
  bool _isDragging = false;
  bool _isDividerHovered = false;

  void _handleSidebarMouseEnter(PointerEnterEvent event) {
    _hoverExitTimer?.cancel();
    _hoverEnterTimer?.cancel();
    if (_isDragging) return;
    _hoverEnterTimer = Timer(const Duration(milliseconds: 100), () {
      if (mounted && !_hoverExpanded && !_isDragging) {
        setState(() => _hoverExpanded = true);
      }
    });
  }

  void _handleSidebarMouseExit(PointerExitEvent event) {
    _hoverEnterTimer?.cancel();
    _hoverExitTimer?.cancel();
    if (_isDragging || _isDividerHovered) return;
    _hoverExitTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted && _hoverExpanded && !_isDragging && !_isDividerHovered) {
        setState(() => _hoverExpanded = false);
      }
    });
  }

  void _onDividerDragStart() {
    _hoverEnterTimer?.cancel();
    _hoverExitTimer?.cancel();
    _isDragging = true;
  }

  void _onDividerDragEnd() {
    _isDragging = false;
    if (!_isDividerHovered) {
      _hoverExitTimer?.cancel();
      _hoverExitTimer = Timer(const Duration(milliseconds: 200), () {
        if (mounted && _hoverExpanded && !_isDragging && !_isDividerHovered) {
          setState(() => _hoverExpanded = false);
        }
      });
    }
  }

  void _onDividerEnter(PointerEnterEvent event) {
    _hoverEnterTimer?.cancel();
    _hoverExitTimer?.cancel();
    _isDividerHovered = true;
  }

  void _onDividerExit(PointerExitEvent event) {
    _isDividerHovered = false;
    if (!_isDragging && _hoverExpanded) {
      _hoverExitTimer?.cancel();
      _hoverExitTimer = Timer(const Duration(milliseconds: 220), () {
        if (mounted && _hoverExpanded && !_isDragging && !_isDividerHovered) {
          setState(() => _hoverExpanded = false);
        }
      });
    }
  }

  @override
  void dispose() {
    _hoverEnterTimer?.cancel();
    _hoverExitTimer?.cancel();
    widget.controller?.removeListener(_handleControllerChanged);
    super.dispose();
  }

  void _handleControllerChanged() {
    if (mounted) setState(() {});
  }

  void setDestination(DesktopNavDestination destination) {
    if (activeDestination != destination) {
      setState(() => _activeDestination = destination);
      if (widget.controller != null) {
        widget.controller!.destination = destination;
      }
      widget.onDestinationChanged?.call(destination);
    }
  }

  void toggleCollapse() {
    _hoverEnterTimer?.cancel();
    _hoverExitTimer?.cancel();
    _hoverExpanded = false;
    if (widget.controller != null) {
      widget.controller!.toggleCollapse();
    } else {
      final isCurrentlyCollapsed = widget.controller?.collapsed ??
          (_userCollapsed ??
              (MediaQuery.sizeOf(context).width < widget.collapseBreakpoint));
      setState(() => _userCollapsed = !isCurrentlyCollapsed);
    }
  }

  List<DesktopNavDestination> _commandPaletteDestinations() {
    return <DesktopNavDestination>[
      DesktopNavDestination.connect,
      if (widget.devicesBuilder != null) DesktopNavDestination.devices,
      if (widget.addressBookBuilder != null) DesktopNavDestination.addressBook,
      DesktopNavDestination.settings,
    ];
  }

  Future<void> openCommandPalette() async {
    await showCamelliaCommandPalette(
      context: context,
      onNavigate: setDestination,
      onToggleSidebar: toggleCollapse,
      availableDestinations: _commandPaletteDestinations(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppVisual.tokens(context);
    final glass = CamelliaGlassTokens.of(context);

    final shellBody = LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final autoCollapsed = totalWidth < widget.collapseBreakpoint;
        final baseCollapsed =
            widget.controller?.collapsed ?? (_userCollapsed ?? autoCollapsed);
        final collapsed = baseCollapsed && !_hoverExpanded;
        final effectiveWidth = collapsed ? widget.railWidth : _sidebarWidth;

        final visibleDestinations = widget.destinations ??
            ((widget.devicesBuilder != null ||
                    widget.addressBookBuilder != null)
                ? DesktopNavDestination.values
                : const [
                    DesktopNavDestination.connect,
                    DesktopNavDestination.settings,
                  ]);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left Navigation Sidebar / Rail & Divider (Hysteresis & Drag Resilience)
            MouseRegion(
              onEnter: _handleSidebarMouseEnter,
              onExit: _handleSidebarMouseExit,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  RepaintBoundary(
                    child: AnimatedContainer(
                      key: const ValueKey('desktop-nav-sidebar'),
                      duration: CamelliaMotion.resolve(context, CamelliaMotion.state),
                      curve: CamelliaMotion.springSnappy,
                      width: effectiveWidth,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: glass.sidebarTint,
                        border: Border(
                          top: BorderSide(color: glass.specularTop, width: 0.6),
                        ),
                      ),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(
                          sigmaX: glass.sidebarBlur,
                          sigmaY: glass.sidebarBlur,
                        ),
                        child: LayoutBuilder(
                          builder: (context, sidebarConstraints) {
                            final renderCollapsed =
                                collapsed || sidebarConstraints.maxWidth < 156;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _buildSidebarHeader(context, renderCollapsed),
                                _buildCommandPaletteTrigger(context, renderCollapsed),
                                const SizedBox(height: 8),
                                // Destination list
                                Expanded(
                                  child: ListView(
                                    padding: const EdgeInsets.symmetric(vertical: 2),
                                    children: visibleDestinations.map((
                                      dest,
                                    ) {
                                      return _DesktopNavItem(
                                        key: ValueKey('desktop-nav-${dest.name}'),
                                        destination: dest,
                                        isSelected: dest == activeDestination,
                                        isCollapsed: renderCollapsed,
                                        onTap: () => setDestination(dest),
                                      );
                                    }).toList(),
                                  ),
                                ),
                                // Bottom status pill / footer
                                _buildSidebarFooter(context, renderCollapsed),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  // Resizable Pane Splitting Divider (8px interactive hit zone)
                  if (!collapsed)
                    DraggableDivider(
                      key: const ValueKey('desktop-nav-divider'),
                      axis: Axis.vertical,
                      thickness: 0.85,
                      padding: const EdgeInsets.symmetric(horizontal: 3.575),
                      color: tokens.border,
                      activeColor: _shellActiveAccent(context).withValues(alpha: 0.82),
                      onDragStart: _onDividerDragStart,
                      onDragEnd: _onDividerDragEnd,
                      onEnter: _onDividerEnter,
                      onExit: _onDividerExit,
                      onHover: () => _hoverExitTimer?.cancel(),
                      onPointerMove: (delta) {
                        _hoverExitTimer?.cancel();
                        setState(() {
                          _sidebarWidth = (_sidebarWidth + delta).clamp(
                            widget.minSidebarWidth,
                            widget.maxSidebarWidth,
                          );
                        });
                      },
                    )
                  else
                    VerticalDivider(
                      key: const ValueKey('desktop-nav-divider'),
                      width: 1,
                      thickness: 0.85,
                      color: tokens.border,
                    ),
                ],
              ),
            ),
            // Primary Workspace View (transparent so root CamelliaBackdrop
            // refracts smoothly through both sidebar and floating glass cards)
            Expanded(
              child: RepaintBoundary(
                child: Material(
                  key: const ValueKey('desktop-nav-content'),
                  type: MaterialType.transparency,
                  child: KeyedSubtree(
                    key: ValueKey(activeDestination),
                    child: _buildWorkspaceContent(context, activeDestination),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    return CamelliaBackdrop(
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyK, control: true):
              openCommandPalette,
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
              openCommandPalette,
        },
        child: widget.topBar != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  widget.topBar!,
                  Expanded(child: shellBody),
                ],
              )
            : shellBody,
      ),
    );
  }

  Widget _buildSidebarHeader(BuildContext context, bool collapsed) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (widget.sidebarHeader != null) {
      return widget.sidebarHeader!;
    }

    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Center(
          child: IconButton(
            key: const ValueKey('desktop-nav-collapse-toggle'),
            icon: const Icon(Icons.view_sidebar_rounded, size: 20),
            tooltip: translate('Expand navigation'),
            color: scheme.onSurfaceVariant,
            onPressed: toggleCollapse,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
      child: Row(
        children: [
          if (widget.leading != null)
            Flexible(child: widget.leading!)
          else ...[
            const CamelliaBrandMark(size: 24, withPlate: true),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                'Camellia Remote',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ],
          IconButton(
            key: const ValueKey('desktop-nav-collapse-toggle'),
            icon: const Icon(Icons.view_sidebar_outlined, size: 18),
            tooltip: translate('Collapse navigation'),
            color: scheme.onSurfaceVariant,
            onPressed: toggleCollapse,
          ),
        ],
      ),
    );
  }

  Widget _buildCommandPaletteTrigger(BuildContext context, bool collapsed) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final glass = CamelliaGlassTokens.of(context);
    final shortcutLabel = isMacOS ? '⌘K' : 'Ctrl+K';

    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Center(
          child: IconButton(
            key: const ValueKey('desktop-nav-command-palette'),
            icon: const Icon(CamelliaIcons.search, size: 19),
            tooltip: '${translate('Search commands...')} ($shortcutLabel)',
            color: scheme.onSurfaceVariant,
            onPressed: openCommandPalette,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      child: _CommandPaletteTriggerPill(
        key: const ValueKey('desktop-nav-command-palette'),
        shortcutLabel: shortcutLabel,
        glass: glass,
        onTap: openCommandPalette,
      ),
    );
  }

  Widget _buildSidebarFooter(BuildContext context, bool collapsed) {
    final glass = CamelliaGlassTokens.of(context);

    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CollapsedStatusIndicator(glass: glass),
            if (widget.warningWidget != null) ...[
              const SizedBox(height: 6),
              widget.warningWidget!,
            ],
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: widget.statusWidget != null
                    ? widget.statusWidget!
                    : const _DefaultStatusPill(),
              ),
              if (widget.warningWidget != null) ...[
                const SizedBox(width: 6),
                widget.warningWidget!,
              ],
            ],
          ),
          if (widget.trailing != null) ...[
            const SizedBox(height: 6),
            widget.trailing!,
          ],
        ],
      ),
    );
  }

  Widget _buildWorkspaceContent(
    BuildContext context,
    DesktopNavDestination destination,
  ) {
    switch (destination) {
      case DesktopNavDestination.connect:
        return widget.connectBuilder?.call(context) ??
            _buildPlaceholder(
              context,
              destination.label,
              destination.icon,
              translate('Quick Connect and identity access workspace'),
            );
      case DesktopNavDestination.devices:
        return widget.devicesBuilder?.call(context) ??
            _buildPlaceholder(
              context,
              destination.label,
              destination.icon,
              translate('Device directory and peer manager workspace'),
            );
      case DesktopNavDestination.addressBook:
        return widget.addressBookBuilder?.call(context) ??
            _buildPlaceholder(
              context,
              destination.label,
              destination.icon,
              translate('Address book contacts and group directory'),
            );
      case DesktopNavDestination.settings:
        return widget.settingsBuilder?.call(context) ??
            _buildPlaceholder(
              context,
              destination.label,
              destination.icon,
              translate('In-shell preferences and configuration'),
            );
    }
  }

  Widget _buildPlaceholder(
    BuildContext context,
    String title,
    IconData icon,
    String description,
  ) {
    final theme = Theme.of(context);
    final accent = _shellActiveAccent(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: accent),
          const SizedBox(height: 12),
          Text(
            title,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _CommandPaletteTriggerPill extends StatefulWidget {
  const _CommandPaletteTriggerPill({
    super.key,
    required this.shortcutLabel,
    required this.glass,
    required this.onTap,
  });

  final String shortcutLabel;
  final CamelliaGlassTokens glass;
  final VoidCallback onTap;

  @override
  State<_CommandPaletteTriggerPill> createState() =>
      _CommandPaletteTriggerPillState();
}

class _CommandPaletteTriggerPillState
    extends State<_CommandPaletteTriggerPill> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final glass = widget.glass;
    final radius = BorderRadius.circular(CamelliaRadius.control);
    final reduceMotion = CamelliaMotion.reduceMotion(context);

    final bg = _hovered
        ? Color.alphaBlend(glass.hoverOverlay, glass.floatingTint)
        : glass.floatingTint.withValues(alpha: 0.72);

    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) {
        if (mounted) setState(() => _hovered = v);
      },
      onShowFocusHighlight: (v) {
        if (mounted) setState(() => _focused = v);
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () {
          HapticFeedback.selectionClick();
          widget.onTap();
        },
        child: AnimatedScale(
          scale: reduceMotion ? 1.0 : (_pressed ? 0.97 : 1.0),
          duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
          curve: CamelliaMotion.springSnappy,
          child: AnimatedContainer(
            duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
            curve: CamelliaMotion.standard,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: radius,
              boxShadow: (_focused &&
                      FocusManager.instance.highlightMode ==
                          FocusHighlightMode.traditional)
                  ? [
                      BoxShadow(
                        color: glass.focusGlow.withValues(alpha: 0.30),
                        blurRadius: 8,
                        spreadRadius: 0.5,
                      ),
                    ]
                  : const [],
            ),
            child: CustomPaint(
              foregroundPainter: SpecularEdgePainter(
                borderRadius: radius,
                topColor: glass.specularTop,
                bottomColor: glass.specularBottom,
                strokeWidth: 0.85,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                child: Row(
                  children: [
                    Icon(
                      CamelliaIcons.search,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        translate('Search'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainer.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(
                          color: glass.specularBottom,
                          width: 0.6,
                        ),
                      ),
                      child: Text(
                        widget.shortcutLabel,
                        style: CamelliaTypography.tabular(
                          theme.textTheme.labelSmall?.copyWith(fontSize: 10),
                        ),
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
}

class _DesktopNavItem extends StatefulWidget {
  const _DesktopNavItem({
    super.key,
    required this.destination,
    required this.isSelected,
    required this.isCollapsed,
    required this.onTap,
  });

  final DesktopNavDestination destination;
  final bool isSelected;
  final bool isCollapsed;
  final VoidCallback onTap;

  @override
  State<_DesktopNavItem> createState() => _DesktopNavItemState();
}

class _DesktopNavItemState extends State<_DesktopNavItem> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  void _handleActivate() {
    HapticFeedback.selectionClick();
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final glass = CamelliaGlassTokens.of(context);
    final dark = theme.brightness == Brightness.dark;
    final themeStyle = glass.themeStyle != CamelliaThemeStyle.auroraFrost
        ? glass.themeStyle
        : MyTheme.themeStyleNotifier.value;
    final accent = _shellActiveAccent(context);
    final isSelected = widget.isSelected;
    final isCollapsed = widget.isCollapsed;
    final reduceMotion = CamelliaMotion.reduceMotion(context);
    final radius = BorderRadius.circular(CamelliaRadius.control);

    final Color backgroundColor;
    if (isSelected) {
      if (themeStyle == CamelliaThemeStyle.auroraFrost) {
        backgroundColor = dark
            ? CamelliaColors.indigoDark.withValues(alpha: 0.20)
            : CamelliaColors.indigo.withValues(alpha: 0.12);
      } else {
        backgroundColor = scheme.primary.withValues(alpha: 0.14);
      }
    } else if (_hovered) {
      backgroundColor = glass.hoverOverlay;
    } else {
      backgroundColor = Colors.transparent;
    }

    final Color foregroundColor = isSelected
        ? accent
        : (_hovered ? scheme.onSurface : scheme.onSurfaceVariant);

    final iconData = isSelected
        ? widget.destination.selectedIcon
        : widget.destination.icon;

    final List<BoxShadow> shadows = [
      if (_focused &&
          FocusManager.instance.highlightMode ==
              FocusHighlightMode.traditional)
        BoxShadow(
          color: glass.focusGlow.withValues(alpha: 0.30),
          blurRadius: 8,
          spreadRadius: 0.5,
        ),
    ];

    Widget wrapInteractive({required Key itemKey, required Widget child}) {
      return Padding(
        key: itemKey,
        padding: EdgeInsets.symmetric(
          horizontal: 10,
          vertical: isCollapsed ? 4 : 3,
        ),
        child: Semantics(
          button: true,
          label: widget.destination.label,
          selected: isSelected,
          child: Tooltip(
            message: widget.destination.label,
            child: FocusableActionDetector(
              mouseCursor: SystemMouseCursors.click,
              onShowHoverHighlight: (v) {
                if (mounted) {
                  setState(() {
                    _hovered = v;
                    if (!v) _pressed = false;
                  });
                }
              },
              onShowFocusHighlight: (v) {
                if (mounted) setState(() => _focused = v);
              },
              actions: <Type, Action<Intent>>{
                ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) {
                    _handleActivate();
                    return null;
                  },
                ),
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) => setState(() => _pressed = true),
                onTapUp: (_) => setState(() => _pressed = false),
                onTapCancel: () => setState(() => _pressed = false),
                onTap: _handleActivate,
                child: AnimatedScale(
                  scale: reduceMotion ? 1.0 : (_pressed ? 0.97 : 1.0),
                  duration: CamelliaMotion.resolve(
                    context,
                    CamelliaMotion.feedback,
                  ),
                  curve: CamelliaMotion.springSnappy,
                  child: child,
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (isCollapsed) {
      return wrapInteractive(
        itemKey: ValueKey('nav-rail-${widget.destination.name}'),
        child: AnimatedContainer(
          duration: CamelliaMotion.resolve(context, CamelliaMotion.state),
          curve: CamelliaMotion.springSnappy,
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: radius,
            boxShadow: shadows,
          ),
          child: CustomPaint(
            foregroundPainter: isSelected || _hovered
                ? SpecularEdgePainter(
                    borderRadius: radius,
                    topColor: isSelected
                        ? accent.withValues(alpha: dark ? 0.42 : 0.28)
                        : glass.specularTop,
                    bottomColor: isSelected
                        ? accent.withValues(alpha: dark ? 0.18 : 0.12)
                        : glass.specularBottom,
                    strokeWidth: 0.85,
                  )
                : null,
            child: Icon(iconData, size: 21, color: foregroundColor),
          ),
        ),
      );
    }

    return wrapInteractive(
      itemKey: ValueKey('nav-bar-${widget.destination.name}'),
      child: AnimatedContainer(
        duration: CamelliaMotion.resolve(context, CamelliaMotion.state),
        curve: CamelliaMotion.springSnappy,
        height: 40,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: radius,
          boxShadow: shadows,
        ),
        child: CustomPaint(
          foregroundPainter: isSelected || _hovered
              ? SpecularEdgePainter(
                  borderRadius: radius,
                  topColor: isSelected
                      ? accent.withValues(alpha: dark ? 0.42 : 0.28)
                      : glass.specularTop,
                  bottomColor: isSelected
                      ? accent.withValues(alpha: dark ? 0.18 : 0.12)
                      : glass.specularBottom,
                  strokeWidth: 0.85,
                )
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(iconData, size: 19, color: foregroundColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.destination.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isSelected ? accent : scheme.onSurface,
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CollapsedStatusIndicator extends StatelessWidget {
  const _CollapsedStatusIndicator({required this.glass});

  final CamelliaGlassTokens glass;

  @override
  Widget build(BuildContext context) {
    final statusColor = _resolveStatusDotColor(glass);
    final statusLabel = _resolveStatusLabel();

    return Tooltip(
      key: const ValueKey('status-pill-rail'),
      message: statusLabel,
      child: Center(
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: statusColor,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: statusColor.withValues(alpha: 0.45),
                blurRadius: 6,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _resolveStatusDotColor(CamelliaGlassTokens glass) {
    try {
      return switch (stateGlobal.svcStatus.value) {
        SvcStatus.ready => glass.statusOnline,
        SvcStatus.connecting => glass.statusConnecting,
        SvcStatus.notReady => glass.statusAlert,
      };
    } catch (_) {
      return glass.statusAlert;
    }
  }

  String _resolveStatusLabel() {
    try {
      return switch (stateGlobal.svcStatus.value) {
        SvcStatus.ready => translate('Ready'),
        SvcStatus.connecting => translate('connecting_status'),
        SvcStatus.notReady => translate('not_ready_status'),
      };
    } catch (_) {
      return translate('not_ready_status');
    }
  }
}

class _DefaultStatusPill extends StatelessWidget {
  const _DefaultStatusPill();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final radius = BorderRadius.circular(CamelliaRadius.status);

    return DecoratedBox(
      key: const ValueKey('status-pill-bar'),
      decoration: BoxDecoration(
        color: glass.floatingTint.withValues(alpha: 0.78),
        borderRadius: radius,
      ),
      child: CustomPaint(
        foregroundPainter: SpecularEdgePainter(
          borderRadius: radius,
          topColor: glass.specularTop,
          bottomColor: glass.specularBottom,
          strokeWidth: 0.8,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: glass.statusOnline,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: glass.statusOnline.withValues(alpha: 0.42),
                      blurRadius: 6,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  translate('Ready'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommandEntry {
  const _CommandEntry({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onExecute,
    this.searchBlob = '',
    this.badgeText,
    this.onlineState,
    this.isTabularTitle = false,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onExecute;
  final String searchBlob;
  final String? badgeText;
  final bool? onlineState;
  final bool isTabularTitle;
}

/// Opens the frosted Liquid Glass `Cmd/Ctrl + K` global command & peer palette.
Future<void> showCamelliaCommandPalette({
  required BuildContext context,
  required ValueChanged<DesktopNavDestination> onNavigate,
  required VoidCallback onToggleSidebar,
  List<DesktopNavDestination> availableDestinations =
      DesktopNavDestination.values,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.36),
    builder: (dialogContext) => _CamelliaCommandPaletteDialog(
      hostContext: context,
      onNavigate: onNavigate,
      onToggleSidebar: onToggleSidebar,
      availableDestinations: availableDestinations,
    ),
  );
}

class _CamelliaCommandPaletteDialog extends StatefulWidget {
  const _CamelliaCommandPaletteDialog({
    required this.hostContext,
    required this.onNavigate,
    required this.onToggleSidebar,
    required this.availableDestinations,
  });

  final BuildContext hostContext;
  final ValueChanged<DesktopNavDestination> onNavigate;
  final VoidCallback onToggleSidebar;
  final List<DesktopNavDestination> availableDestinations;

  @override
  State<_CamelliaCommandPaletteDialog> createState() =>
      _CamelliaCommandPaletteDialogState();
}

class _CamelliaCommandPaletteDialogState
    extends State<_CamelliaCommandPaletteDialog> {
  final TextEditingController _queryController = TextEditingController();
  int _selectedIndex = 0;
  late final List<Peer> _cachedPeers;

  @override
  void initState() {
    super.initState();
    _cachedPeers = _collectAllPeers();
  }

  /// Safely collects deduplicated saved/recent/favorite/LAN peers.
  /// Wrapped in individual try/catch guards so pure widget tests without
  /// initialized FFI models never fail.
  List<Peer> _collectAllPeers() {
    final map = <String, Peer>{};

    void addAllSafe(Iterable<Peer> Function() getter) {
      try {
        for (final peer in getter()) {
          if (peer.id.isEmpty) continue;
          final existing = map[peer.id];
          if (existing == null) {
            map[peer.id] = peer;
          } else if (peer.online && !existing.online) {
            map[peer.id] = peer;
          }
        }
      } catch (_) {}
    }

    addAllSafe(() => gFFI.recentPeersModel.peers);
    addAllSafe(() => gFFI.favoritePeersModel.peers);
    addAllSafe(() => gFFI.lanPeersModel.peers);
    addAllSafe(() => gFFI.abModel.peersModel.peers);
    addAllSafe(() => gFFI.groupModel.peersModel.peers);

    return map.values.toList(growable: false);
  }

  /// Returns a positive score when [query] fuzzy-matches [candidate], or `0`
  /// when there is no match. Substring matches outrank subsequence matches.
  int _fuzzyScore(String query, String candidate) {
    if (query.isEmpty) return 1;
    final q = query.toLowerCase();
    final c = candidate.toLowerCase();
    if (c.isEmpty) return 0;
    if (c == q) return 100;
    if (c.startsWith(q)) return 85;
    final subIndex = c.indexOf(q);
    if (subIndex >= 0) return 70 - subIndex.clamp(0, 30);

    // Ordered character subsequence fuzzy match
    var qi = 0;
    var consecutive = 0;
    var bonus = 0;
    for (var ci = 0; ci < c.length && qi < q.length; ci++) {
      if (c.codeUnitAt(ci) == q.codeUnitAt(qi)) {
        qi++;
        consecutive++;
        bonus += consecutive * 2;
      } else {
        consecutive = 0;
      }
    }
    if (qi == q.length) {
      return (20 + bonus).clamp(20, 60);
    }
    return 0;
  }

  _CommandEntry _peerEntry(Peer peer) {
    final displayTitle = peer.alias.isNotEmpty
        ? peer.alias
        : (peer.hostname.isNotEmpty ? peer.hostname : formatID(peer.id));
    final hostDetail = [
      if (peer.username.isNotEmpty) peer.username,
      if (peer.hostname.isNotEmpty && peer.hostname != displayTitle)
        peer.hostname,
    ].join('@');
    final formattedId = formatID(peer.id);
    final subtitle = hostDetail.isNotEmpty
        ? '$formattedId · $hostDetail'
        : formattedId;

    return _CommandEntry(
      title: displayTitle,
      subtitle: subtitle,
      icon: CamelliaIcons.platformIcon(peer.platform),
      searchBlob: '${peer.id} ${peer.alias} ${peer.hostname} ${peer.username}',
      badgeText: peer.online ? translate('Online') : translate('Offline'),
      onlineState: peer.online,
      isTabularTitle: peer.alias.isEmpty && peer.hostname.isEmpty,
      onExecute: () {
        if (widget.hostContext.mounted) {
          connect(widget.hostContext, peer.id);
        }
      },
    );
  }

  List<_CommandEntry> _buildEntries() {
    final staticCommands = <_CommandEntry>[
      for (final dest in widget.availableDestinations)
        _CommandEntry(
          title: dest.label,
          subtitle: translate('Switch workspace'),
          icon: dest.selectedIcon,
          onExecute: () => widget.onNavigate(dest),
        ),
      _CommandEntry(
        title: translate('Toggle sidebar'),
        subtitle: translate('Expand or collapse navigation'),
        icon: Icons.view_sidebar_rounded,
        onExecute: widget.onToggleSidebar,
      ),
      _CommandEntry(
        title: '${translate('Theme')}: ${translate('Light')}',
        subtitle: translate('Switch appearance'),
        icon: Icons.light_mode_rounded,
        onExecute: () =>
            MyTheme.changeThemePreference(CamelliaThemePreference.light),
      ),
      _CommandEntry(
        title: '${translate('Theme')}: ${translate('Dark')}',
        subtitle: translate('Switch appearance'),
        icon: Icons.dark_mode_rounded,
        onExecute: () =>
            MyTheme.changeThemePreference(CamelliaThemePreference.dark),
      ),
      _CommandEntry(
        title: '${translate('Theme')}: ${translate('OLED Midnight')}',
        subtitle: translate('Switch appearance'),
        icon: Icons.contrast_rounded,
        onExecute: () =>
            MyTheme.changeThemePreference(CamelliaThemePreference.midnight),
      ),
      _CommandEntry(
        title: '${translate('Theme')}: ${translate('Follow System')}',
        subtitle: translate('Switch appearance'),
        icon: Icons.brightness_auto_rounded,
        onExecute: () =>
            MyTheme.changeThemePreference(CamelliaThemePreference.system),
      ),
    ];

    final rawQuery = _queryController.text.trim();
    if (rawQuery.isEmpty) {
      return <_CommandEntry>[
        ...staticCommands,
        for (final peer in _cachedPeers.take(8)) _peerEntry(peer),
      ];
    }

    final results = <_CommandEntry>[];

    // Top dynamic action when user types a numeric remote ID (>= 6 digits)
    final strippedId = rawQuery.replaceAll(RegExp(r'[\s\-]'), '');
    if (strippedId.length >= 6 && RegExp(r'^\d+$').hasMatch(strippedId)) {
      results.add(
        _CommandEntry(
          title: '${translate('Connect')} · ${formatID(strippedId)}',
          subtitle: translate('Control Remote Desktop'),
          icon: Icons.bolt_rounded,
          badgeText: translate('Connect'),
          isTabularTitle: true,
          onExecute: () {
            if (widget.hostContext.mounted) {
              connect(widget.hostContext, strippedId);
            }
          },
        ),
      );
    }

    // Score and rank matching peers
    final normalizedQuery = strippedId.isNotEmpty &&
            RegExp(r'^\d+$').hasMatch(strippedId)
        ? strippedId
        : rawQuery;
    final scoredPeers = <(int, _CommandEntry)>[];
    for (final peer in _cachedPeers) {
      final entry = _peerEntry(peer);
      final best = [
        _fuzzyScore(normalizedQuery, peer.id),
        _fuzzyScore(rawQuery, peer.alias),
        _fuzzyScore(rawQuery, peer.hostname),
        _fuzzyScore(rawQuery, peer.username),
      ].reduce((a, b) => a > b ? a : b);
      if (best > 0) {
        scoredPeers.add((best + (peer.online ? 5 : 0), entry));
      }
    }
    scoredPeers.sort((a, b) => b.$1.compareTo(a.$1));
    results.addAll(scoredPeers.map((pair) => pair.$2));

    // Score and rank matching commands
    final scoredCommands = <(int, _CommandEntry)>[];
    for (final cmd in staticCommands) {
      final titleScore = _fuzzyScore(rawQuery, cmd.title);
      final subScore = _fuzzyScore(rawQuery, cmd.subtitle);
      final best = titleScore > subScore ? titleScore : subScore;
      if (best > 0) {
        scoredCommands.add((best, cmd));
      }
    }
    scoredCommands.sort((a, b) => b.$1.compareTo(a.$1));
    results.addAll(scoredCommands.map((pair) => pair.$2));

    return results;
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  void _runEntry(_CommandEntry entry) {
    Navigator.of(context).pop();
    entry.onExecute();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final accent = _shellActiveAccent(context);
    final dark = theme.brightness == Brightness.dark;
    final entries = _buildEntries();
    final safeIndex = entries.isEmpty
        ? 0
        : _selectedIndex.clamp(0, entries.length - 1);

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowDown): () {
          if (entries.isNotEmpty) {
            setState(() {
              _selectedIndex = (safeIndex + 1) % entries.length;
            });
          }
        },
        const SingleActivator(LogicalKeyboardKey.arrowUp): () {
          if (entries.isNotEmpty) {
            setState(() {
              _selectedIndex = (safeIndex - 1 + entries.length) % entries.length;
            });
          }
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          Navigator.of(context).pop();
        },
      },
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 460),
          child: GlassSurface(
            layer: CamelliaGlassLayer.modal,
            elevated: true,
            borderRadius: BorderRadius.circular(CamelliaRadius.sheet),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: Row(
                    children: [
                      Icon(CamelliaIcons.search, color: accent, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('command-palette-input'),
                          controller: _queryController,
                          autofocus: true,
                          onChanged: (_) => setState(() => _selectedIndex = 0),
                          onSubmitted: (_) {
                            if (entries.isNotEmpty) {
                              _runEntry(entries[safeIndex]);
                            }
                          },
                          decoration: InputDecoration(
                            hintText: translate('Search commands...'),
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: glass.specularBottom,
                            width: 0.7,
                          ),
                        ),
                        child: Text(
                          'ESC',
                          style: CamelliaTypography.tabular(
                            theme.textTheme.labelSmall,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  color: glass.specularBottom.withValues(alpha: 0.75),
                ),
                Flexible(
                  child: entries.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(28),
                          child: Center(
                            child: Text(
                              translate('No matching commands'),
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                          itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            final active = index == safeIndex;
                            final titleStyle = theme.textTheme.bodyMedium
                                ?.copyWith(
                                  fontWeight: active
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                );
                            return Material(
                              color: active
                                  ? accent.withValues(alpha: dark ? 0.22 : 0.12)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(
                                CamelliaRadius.control,
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(
                                  CamelliaRadius.control,
                                ),
                                onHover: (hovered) {
                                  if (hovered && _selectedIndex != index) {
                                    setState(() => _selectedIndex = index);
                                  }
                                },
                                onTap: () => _runEntry(entry),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        entry.icon,
                                        size: 19,
                                        color: active
                                            ? accent
                                            : theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              entry.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: entry.isTabularTitle
                                                  ? CamelliaTypography.tabular(
                                                      titleStyle,
                                                    )
                                                  : titleStyle,
                                            ),
                                            Text(
                                              entry.subtitle,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: CamelliaTypography.tabular(
                                                theme.textTheme.bodySmall,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (entry.onlineState != null) ...[
                                        const SizedBox(width: 8),
                                        GlassBadge(
                                          label: entry.badgeText ?? '',
                                          tone: entry.onlineState!
                                              ? GlassBadgeTone.online
                                              : GlassBadgeTone.offline,
                                          showDot: true,
                                          compact: true,
                                        ),
                                      ] else if (entry.badgeText != null) ...[
                                        const SizedBox(width: 8),
                                        GlassBadge(
                                          label: entry.badgeText!,
                                          tone: GlassBadgeTone.brand,
                                          compact: true,
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
