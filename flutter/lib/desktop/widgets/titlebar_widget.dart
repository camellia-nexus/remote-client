import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import '../../ui/camellia_design.dart';

const double kDesktopTitleBarHeight = 40;

final class DesktopTitleBarLabels {
  const DesktopTitleBarLabels({
    this.minimize = 'Minimize',
    this.maximize = 'Maximize',
    this.restore = 'Restore',
    this.close = 'Close',
  });

  final String minimize;
  final String maximize;
  final String restore;
  final String close;
}

abstract interface class DesktopWindowController {
  Future<void> startDragging();
  Future<void> showSystemMenu();
  Future<bool> isMaximized();
  Future<void> maximize();
  Future<void> unmaximize();
  Future<void> minimize();
  Future<void> close();
}

final class WindowManagerDesktopWindowController
    implements DesktopWindowController {
  const WindowManagerDesktopWindowController();

  @override
  Future<void> startDragging() => windowManager.startDragging();

  @override
  Future<void> showSystemMenu() => windowManager.popUpWindowMenu();

  @override
  Future<bool> isMaximized() => windowManager.isMaximized();

  @override
  Future<void> maximize() => windowManager.maximize();

  @override
  Future<void> unmaximize() => windowManager.unmaximize();

  @override
  Future<void> minimize() => windowManager.minimize();

  @override
  Future<void> close() => windowManager.close();
}

/// Platform-aware custom chrome for the primary desktop window.
///
/// macOS keeps its native traffic-light controls. Windows and Linux render
/// caption controls here while retaining native move, resize, and system-menu
/// behavior through [windowManager].
class DesktopTitleBar extends StatefulWidget {
  const DesktopTitleBar({
    super.key,
    this.appName,
    this.controller = const WindowManagerDesktopWindowController(),
    this.showCaptionButtons,
    this.labels = const DesktopTitleBarLabels(),
  });

  final String? appName;
  final DesktopWindowController controller;
  final bool? showCaptionButtons;
  final DesktopTitleBarLabels labels;

  @override
  State<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

class _DesktopTitleBarState extends State<DesktopTitleBar> with WindowListener {
  bool _isMaximized = false;
  bool _isFocused = true;

  bool get _usesWindowManager =>
      widget.controller is WindowManagerDesktopWindowController;

  bool get _showCaptionButtons => widget.showCaptionButtons ?? !isMacOS;

  @override
  void initState() {
    super.initState();
    if (_usesWindowManager) {
      windowManager.addListener(this);
    }
    _refreshMaximized();
  }

  @override
  void didUpdateWidget(covariant DesktopTitleBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final usedWindowManager =
        oldWidget.controller is WindowManagerDesktopWindowController;
    if (usedWindowManager != _usesWindowManager) {
      if (usedWindowManager) windowManager.removeListener(this);
      if (_usesWindowManager) windowManager.addListener(this);
    }
    if (oldWidget.controller != widget.controller) _refreshMaximized();
  }

  @override
  void dispose() {
    if (_usesWindowManager) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  Future<void> _refreshMaximized() async {
    final value = await widget.controller.isMaximized();
    if (mounted && value != _isMaximized) {
      setState(() => _isMaximized = value);
    }
  }

  Future<void> _toggleMaximized() async {
    if (await widget.controller.isMaximized()) {
      await widget.controller.unmaximize();
      if (mounted) setState(() => _isMaximized = false);
    } else {
      await widget.controller.maximize();
      if (mounted) setState(() => _isMaximized = true);
    }
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _isMaximized = false);
  }

  @override
  void onWindowFocus() {
    if (mounted) setState(() => _isFocused = true);
  }

  @override
  void onWindowBlur() {
    if (mounted) setState(() => _isFocused = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = _isFocused
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.72);
    final title = widget.appName ?? bind.mainGetAppNameSync();
    return Material(
      color: theme.colorScheme.surface,
      child: SizedBox(
        height: kDesktopTitleBarHeight,
        child: Row(
          children: [
            if (isMacOS) const SizedBox(width: 78),
            _WindowMenuIcon(
              controller: widget.controller,
              foreground: foreground,
              appName: title,
            ),
            Expanded(
              child: GestureDetector(
                key: const ValueKey('desktop-title-drag-region'),
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) => widget.controller.startDragging(),
                onDoubleTap: _toggleMaximized,
                onSecondaryTapDown: (_) => widget.controller.showSystemMenu(),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            if (_showCaptionButtons) ...[
              _CaptionButton(
                tooltip: widget.labels.minimize,
                icon: Icons.remove_rounded,
                iconSize: 16,
                foreground: foreground,
                onPressed: widget.controller.minimize,
              ),
              _CaptionButton(
                tooltip: _isMaximized
                    ? widget.labels.restore
                    : widget.labels.maximize,
                icon: _isMaximized
                    ? Icons.filter_none_rounded
                    : Icons.crop_square_rounded,
                iconSize: _isMaximized ? 12 : 14,
                foreground: foreground,
                onPressed: _toggleMaximized,
              ),
              _CaptionButton(
                tooltip: widget.labels.close,
                icon: Icons.close_rounded,
                iconSize: 16,
                foreground: foreground,
                destructive: true,
                onPressed: widget.controller.close,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WindowMenuIcon extends StatelessWidget {
  const _WindowMenuIcon({
    required this.controller,
    required this.foreground,
    required this.appName,
  });

  final DesktopWindowController controller;
  final Color foreground;
  final String appName;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: appName,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: controller.showSystemMenu,
        onDoubleTap: controller.close,
        onSecondaryTapDown: (_) => controller.showSystemMenu(),
        child: SizedBox(
          width: 40,
          height: kDesktopTitleBarHeight,
          child: Center(
            child: Opacity(opacity: foreground.a, child: loadIcon(18)),
          ),
        ),
      ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.tooltip,
    required this.icon,
    required this.foreground,
    required this.onPressed,
    this.destructive = false,
    this.iconSize = 14,
  });

  final String tooltip;
  final IconData icon;
  final Color foreground;
  final Future<void> Function() onPressed;
  final bool destructive;
  final double iconSize;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDestructive = widget.destructive;
    final Color backgroundColor;
    if (_pressed) {
      backgroundColor = isDestructive
          ? const Color(0xFFB02619)
          : scheme.onSurface.withValues(alpha: 0.14);
    } else if (_hovered) {
      backgroundColor = isDestructive
          ? const Color(0xFFC42B1C)
          : scheme.onSurface.withValues(alpha: 0.08);
    } else {
      backgroundColor = Colors.transparent;
    }

    final Color foregroundColor = (_hovered || _pressed) && isDestructive
        ? Colors.white
        : widget.foreground;

    return Semantics(
      button: true,
      label: widget.tooltip,
      child: Tooltip(
        message: widget.tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() {
            _hovered = false;
            _pressed = false;
          }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: widget.onPressed,
            child: AnimatedContainer(
              duration: CamelliaMotion.hover,
              curve: Curves.easeOutCubic,
              width: 46,
              height: kDesktopTitleBarHeight,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(CamelliaRadius.control / 2),
              ),
              child: Icon(
                widget.icon,
                size: widget.iconSize,
                color: foregroundColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
