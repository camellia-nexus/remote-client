import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart' hide Dialog;
import '../../ui/camellia_design.dart';
import '../../ui/glass_components.dart';
import 'dragable_divider.dart';

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
  })  : _destination = initialDestination,
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

/// Unified desktop window shell providing Apple-style persistent navigation,
/// responsive sidebar/rail transitions, fluid workspace hosting, and resizable
/// pane splitting via [DraggableDivider].
class CamelliaDesktopShell extends StatefulWidget {
  const CamelliaDesktopShell({
    super.key,
    this.initialDestination = DesktopNavDestination.connect,
    this.currentDestination,
    this.onDestinationChanged,
    this.controller,
    this.connectBuilder,
    this.devicesBuilder,
    this.addressBookBuilder,
    this.settingsBuilder,
    this.statusWidget,
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
  final ValueChanged<DesktopNavDestination>? onDestinationChanged;
  final CamelliaDesktopShellController? controller;
  final WidgetBuilder? connectBuilder;
  final WidgetBuilder? devicesBuilder;
  final WidgetBuilder? addressBookBuilder;
  final WidgetBuilder? settingsBuilder;
  final Widget? statusWidget;
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

  static void switchTo(BuildContext context, DesktopNavDestination destination) {
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

  @override
  void dispose() {
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
    if (widget.controller != null) {
      widget.controller!.toggleCollapse();
    } else {
      setState(() => _userCollapsed = !(_userCollapsed ?? false));
    }
  }

  Future<void> openCommandPalette() async {
    await showCamelliaCommandPalette(
      context: context,
      onNavigate: setDestination,
      onToggleSidebar: toggleCollapse,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppVisual.tokens(context);
    final glass = CamelliaGlassTokens.of(context);

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            openCommandPalette,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            openCommandPalette,
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalWidth = constraints.maxWidth;
          final autoCollapsed = totalWidth < widget.collapseBreakpoint;
          final collapsed = widget.controller?.collapsed ??
              (_userCollapsed ?? autoCollapsed);
          final effectiveWidth =
              collapsed ? widget.railWidth : _sidebarWidth;

          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left Navigation Sidebar / Rail (Soft Frosted Glass Layer 1)
              RepaintBoundary(
                child: AnimatedContainer(
                  key: const ValueKey('desktop-nav-sidebar'),
                  duration: CamelliaMotion.resolve(
                    context,
                    CamelliaMotion.state,
                  ),
                  curve: CamelliaMotion.springSnappy,
                  width: effectiveWidth,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(color: glass.sidebarTint),
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
                            _buildCommandPaletteTrigger(
                              context,
                              renderCollapsed,
                            ),
                            const SizedBox(height: 6),
                            // Destination list
                            Expanded(
                              child: ListView(
                                padding: EdgeInsets.zero,
                                children: DesktopNavDestination.values.map((
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
              // Resizable Pane Splitting Divider
              if (!collapsed)
                DraggableDivider(
                  key: const ValueKey('desktop-nav-divider'),
                  axis: Axis.vertical,
                  thickness: 1.0,
                  color: glass.specularBottom,
                  onPointerMove: (delta) {
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
                  thickness: 1,
                  color: glass.specularBottom,
                ),
              // Primary Workspace View
              Expanded(
                child: Material(
                  key: const ValueKey('desktop-nav-content'),
                  color: tokens.page,
                  child: KeyedSubtree(
                    key: ValueKey(activeDestination),
                    child: _buildWorkspaceContent(context, activeDestination),
                  ),
                ),
              ),
            ],
          );
        },
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
        padding: const EdgeInsets.only(top: 8, bottom: 4),
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
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
      child: Row(
        children: [
          if (widget.leading != null)
            Flexible(child: widget.leading!)
          else ...[
            const Icon(
              Icons.shield_outlined,
              size: 20,
              color: CamelliaColors.indigo,
            ),
            const SizedBox(width: 8),
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
    final shortcutLabel = isMacOS ? '⌘K' : 'Ctrl+K';

    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Center(
          child: IconButton(
            key: const ValueKey('desktop-nav-command-palette'),
            icon: const Icon(Icons.search_rounded, size: 19),
            tooltip: '${translate('Search commands...')} ($shortcutLabel)',
            color: scheme.onSurfaceVariant,
            onPressed: openCommandPalette,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
      child: Material(
        color: AppVisual.inset(context).withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(CamelliaRadius.control),
        child: InkWell(
          key: const ValueKey('desktop-nav-command-palette'),
          borderRadius: BorderRadius.circular(CamelliaRadius.control),
          onTap: openCommandPalette,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                Icon(
                  Icons.search_rounded,
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
                    color: scheme.surface.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    shortcutLabel,
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
    );
  }

  Widget _buildSidebarFooter(BuildContext context, bool collapsed) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AppVisual.tokens(context);

    return ClipRect(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: collapsed ? 8 : 12,
          vertical: 8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.statusWidget != null)
              widget.statusWidget!
            else
              _DefaultStatusPill(
                collapsed: collapsed,
                tokens: tokens,
                scheme: scheme,
              ),
            if (widget.trailing != null) ...[
              const SizedBox(height: 6),
              widget.trailing!,
            ],
          ],
        ),
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: CamelliaColors.indigo),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isSelected = widget.isSelected;
    final isCollapsed = widget.isCollapsed;

    final Color backgroundColor;
    if (isSelected) {
      backgroundColor = CamelliaColors.indigo.withValues(alpha: 0.12);
    } else if (_hovered) {
      backgroundColor = scheme.onSurface.withValues(alpha: 0.05);
    } else {
      backgroundColor = Colors.transparent;
    }

    final Color foregroundColor = isSelected
        ? CamelliaColors.indigo
        : scheme.onSurfaceVariant;

    final iconData =
        isSelected ? widget.destination.selectedIcon : widget.destination.icon;

    if (isCollapsed) {
      return Padding(
        key: ValueKey('nav-rail-${widget.destination.name}'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Semantics(
          button: true,
          label: widget.destination.label,
          selected: isSelected,
          child: Tooltip(
            message: widget.destination.label,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onTap,
                child: AnimatedContainer(
                  duration: CamelliaMotion.hover,
                  curve: Curves.easeOutCubic,
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: backgroundColor,
                    borderRadius: BorderRadius.circular(CamelliaRadius.control),
                  ),
                  child: Icon(
                    iconData,
                    size: 22,
                    color: foregroundColor,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      key: ValueKey('nav-bar-${widget.destination.name}'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Semantics(
        button: true,
        label: widget.destination.label,
        selected: isSelected,
        child: Tooltip(
          message: widget.destination.label,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: CamelliaMotion.hover,
                curve: Curves.easeOutCubic,
                height: 40,
                clipBehavior: Clip.antiAlias,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: backgroundColor,
                  borderRadius: BorderRadius.circular(CamelliaRadius.control),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const NeverScrollableScrollPhysics(),
                  child: SizedBox(
                    width: 176,
                    child: Row(
                      children: [
                        Icon(
                          iconData,
                          size: 20,
                          color: foregroundColor,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            widget.destination.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: isSelected
                                  ? CamelliaColors.indigo
                                  : scheme.onSurface,
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
            ),
          ),
        ),
      ),
    );
  }
}

class _DefaultStatusPill extends StatelessWidget {
  const _DefaultStatusPill({
    required this.collapsed,
    required this.tokens,
    required this.scheme,
  });

  final bool collapsed;
  final AppDesignTokens tokens;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    if (collapsed) {
      return Tooltip(
        key: const ValueKey('status-pill-rail'),
        message: translate('Ready'),
        child: Center(
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: CamelliaColors.leaf,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: CamelliaColors.leaf.withValues(alpha: 0.4),
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      key: const ValueKey('status-pill-bar'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: tokens.surfaceContainer,
        borderRadius: BorderRadius.circular(CamelliaRadius.status),
        border: Border.all(color: tokens.border),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: SizedBox(
          width: 176,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: CamelliaColors.leaf,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: CamelliaColors.leaf.withValues(alpha: 0.4),
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
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
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
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onExecute;
}

/// Opens the frosted Liquid Glass `Cmd/Ctrl + K` global command palette.
Future<void> showCamelliaCommandPalette({
  required BuildContext context,
  required ValueChanged<DesktopNavDestination> onNavigate,
  required VoidCallback onToggleSidebar,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.36),
    builder: (dialogContext) => _CamelliaCommandPaletteDialog(
      onNavigate: onNavigate,
      onToggleSidebar: onToggleSidebar,
    ),
  );
}

class _CamelliaCommandPaletteDialog extends StatefulWidget {
  const _CamelliaCommandPaletteDialog({
    required this.onNavigate,
    required this.onToggleSidebar,
  });

  final ValueChanged<DesktopNavDestination> onNavigate;
  final VoidCallback onToggleSidebar;

  @override
  State<_CamelliaCommandPaletteDialog> createState() =>
      _CamelliaCommandPaletteDialogState();
}

class _CamelliaCommandPaletteDialogState
    extends State<_CamelliaCommandPaletteDialog> {
  final TextEditingController _queryController = TextEditingController();
  int _selectedIndex = 0;

  List<_CommandEntry> _buildEntries() {
    final entries = <_CommandEntry>[
      for (final dest in DesktopNavDestination.values)
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

    final query = _queryController.text.trim().toLowerCase();
    if (query.isEmpty) return entries;
    return entries
        .where(
          (e) =>
              e.title.toLowerCase().contains(query) ||
              e.subtitle.toLowerCase().contains(query),
        )
        .toList(growable: false);
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
          constraints: const BoxConstraints(maxWidth: 540, maxHeight: 440),
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
                      Icon(
                        Icons.search_rounded,
                        color: theme.colorScheme.primary,
                        size: 20,
                      ),
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
                          color: AppVisual.inset(context),
                          borderRadius: BorderRadius.circular(6),
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
                  color: theme.dividerColor.withValues(alpha: 0.5),
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
                            return Material(
                              color: active
                                  ? theme.colorScheme.primary.withValues(
                                      alpha: theme.brightness == Brightness.dark
                                          ? 0.22
                                          : 0.12,
                                    )
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
                                            ? theme.colorScheme.primary
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
                                              style: theme.textTheme.bodyMedium
                                                  ?.copyWith(
                                                    fontWeight: active
                                                        ? FontWeight.w600
                                                        : FontWeight.w500,
                                                  ),
                                            ),
                                            Text(
                                              entry.subtitle,
                                              style: theme.textTheme.bodySmall,
                                            ),
                                          ],
                                        ),
                                      ),
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
