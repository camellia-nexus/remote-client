// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/models/input_model.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:get/get.dart';

class GestureIcons {
  static const String _family = 'GestureIcons';

  GestureIcons._();

  static const IconData iconMouse = IconData(0xe65c, fontFamily: _family);
  static const IconData iconTabletTouch = IconData(0xe9ce, fontFamily: _family);
  static const IconData iconGestureFDrag = IconData(
    0xe686,
    fontFamily: _family,
  );
  static const IconData iconMobileTouch = IconData(0xe9cd, fontFamily: _family);
  static const IconData iconGesturePress = IconData(
    0xe66c,
    fontFamily: _family,
  );
  static const IconData iconGestureTap = IconData(0xe66f, fontFamily: _family);
  static const IconData iconGesturePinch = IconData(
    0xe66a,
    fontFamily: _family,
  );
  static const IconData iconGesturePressHold = IconData(
    0xe66b,
    fontFamily: _family,
  );
  static const IconData iconGestureFDragUpDown_ = IconData(
    0xe685,
    fontFamily: _family,
  );
  static const IconData iconGestureFTap_ = IconData(
    0xe68e,
    fontFamily: _family,
  );
  static const IconData iconGestureFSwipeRight = IconData(
    0xe68f,
    fontFamily: _family,
  );
  static const IconData iconGestureFdoubleTap = IconData(
    0xe691,
    fontFamily: _family,
  );
  static const IconData iconGestureFThreeFingers = IconData(
    0xe687,
    fontFamily: _family,
  );
}

typedef OnTouchModeChange = void Function(bool);

class GestureHelp extends StatefulWidget {
  const GestureHelp({
    super.key,
    required this.touchMode,
    required this.onTouchModeChange,
    required this.virtualMouseMode,
    this.inputModel,
    this.onClose,
  });

  final bool touchMode;
  final OnTouchModeChange onTouchModeChange;
  final VirtualMouseMode virtualMouseMode;
  final InputModel? inputModel;
  final VoidCallback? onClose;

  @override
  State<StatefulWidget> createState() => _GestureHelpState();
}

class _GestureHelpState extends State<GestureHelp> {
  late bool _touchMode;

  VirtualMouseMode get _virtualMouseMode => widget.virtualMouseMode;

  @override
  void initState() {
    super.initState();
    _touchMode = widget.touchMode;
  }

  @override
  void didUpdateWidget(covariant GestureHelp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.touchMode != widget.touchMode) {
      _touchMode = widget.touchMode;
    }
  }

  void _exitRelativeMouseModeIf(bool condition) {
    if (condition) {
      widget.inputModel?.setRelativeMouseMode(false);
    }
  }

  Widget _buildToggleRow({
    required BuildContext context,
    required IconData icon,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);
    final accent = dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceContainer.withValues(alpha: dark ? 0.65 : 0.80),
        borderRadius: BorderRadius.circular(CamelliaRadius.control),
        border: Border.all(
          color: tokens.border.withValues(alpha: 0.85),
          width: 0.85,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 18, color: value ? accent : tokens.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Switch.adaptive(
              value: value,
              onChanged: (next) {
                HapticFeedback.selectionClick();
                onChanged(next);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);
    final size = MediaQuery.sizeOf(context);
    final columns = size.width >= 560 ? 3 : 2;
    const horizontalPad = 14.0;
    const spacing = 8.0;
    final availableWidth = (size.width - horizontalPad * 2 - 20).clamp(
      240.0,
      720.0,
    );
    final cardWidth =
        (availableWidth - spacing * (columns - 1)) / columns;

    final gestureCards = _touchMode
        ? <(IconData, String, String)>[
            (
              Icons.touch_app_rounded,
              translate("One-Finger Tap"),
              translate("Left Mouse"),
            ),
            (
              Icons.pan_tool_alt_rounded,
              translate("One-Long Tap"),
              translate("Right Mouse"),
            ),
            (
              Icons.swipe_rounded,
              translate("One-Finger Move"),
              translate("Mouse Drag"),
            ),
            (
              Icons.unfold_more_rounded,
              translate("Three-Finger vertically"),
              translate("Mouse Wheel"),
            ),
            (
              Icons.open_with_rounded,
              translate("Two-Finger Move"),
              translate("Canvas Move"),
            ),
            (
              Icons.pinch_rounded,
              translate("Pinch to Zoom"),
              translate("Canvas Zoom"),
            ),
          ]
        : <(IconData, String, String)>[
            (
              Icons.touch_app_rounded,
              translate("One-Finger Tap"),
              translate("Left Mouse"),
            ),
            (
              Icons.pan_tool_alt_rounded,
              translate("One-Long Tap"),
              translate("Right Mouse"),
            ),
            (
              Icons.ads_click_rounded,
              translate("Double Tap & Move"),
              translate("Mouse Drag"),
            ),
            (
              Icons.unfold_more_rounded,
              translate("Three-Finger vertically"),
              translate("Mouse Wheel"),
            ),
            (
              Icons.open_with_rounded,
              translate("Two-Finger Move"),
              translate("Canvas Move"),
            ),
            (
              Icons.pinch_rounded,
              translate("Pinch to Zoom"),
              translate("Canvas Zoom"),
            ),
          ];

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: horizontalPad,
        vertical: 8,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  _touchMode ? CamelliaIcons.touch : CamelliaIcons.mouse,
                  size: 18,
                  color: dark
                      ? theme.colorScheme.secondary
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    translate('Gesture Help'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (widget.onClose != null)
                  GlassIconButton(
                    icon: CamelliaIcons.close,
                    tooltip: translate('Close'),
                    size: 32,
                    iconSize: 16,
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      widget.onClose?.call();
                    },
                  ),
              ],
            ),
            const SizedBox(height: 10),
            GlassSegmentedControl<bool>(
              expand: true,
              selected: _touchMode,
              items: [
                GlassSegmentItem<bool>(
                  value: false,
                  icon: CamelliaIcons.mouse,
                  label: translate("Mouse mode"),
                ),
                GlassSegmentItem<bool>(
                  value: true,
                  icon: CamelliaIcons.touch,
                  label: translate("Touch mode"),
                ),
              ],
              onChanged: (nextTouchMode) {
                if (_touchMode == nextTouchMode) return;
                setState(() {
                  _touchMode = nextTouchMode;
                  widget.onTouchModeChange(_touchMode);
                  _exitRelativeMouseModeIf(_touchMode);
                });
              },
            ),
            const SizedBox(height: 10),
            _buildToggleRow(
              context: context,
              icon: CamelliaIcons.mouse,
              label: translate('Show virtual mouse'),
              value: _virtualMouseMode.showVirtualMouse,
              onChanged: (_) async {
                await _virtualMouseMode.toggleVirtualMouse();
                _exitRelativeMouseModeIf(!_virtualMouseMode.showVirtualMouse);
                if (mounted) setState(() {});
              },
            ),
            if (_touchMode && _virtualMouseMode.showVirtualMouse) ...[
              const SizedBox(height: 8),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: tokens.surfaceContainer.withValues(
                    alpha: dark ? 0.65 : 0.80,
                  ),
                  borderRadius: BorderRadius.circular(CamelliaRadius.control),
                  border: Border.all(
                    color: tokens.border.withValues(alpha: 0.85),
                    width: 0.85,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              translate('Virtual mouse size'),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            '${_virtualMouseMode.virtualMouseScale.toStringAsFixed(1)}×',
                            style: CamelliaTypography.tabular(
                              theme.textTheme.labelMedium?.copyWith(
                                color: tokens.muted,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          Text(
                            translate('Small'),
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 12,
                              color: tokens.muted,
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              value: _virtualMouseMode.virtualMouseScale,
                              min: 0.8,
                              max: 1.8,
                              divisions: 10,
                              onChanged: (value) {
                                _virtualMouseMode.setVirtualMouseScale(value);
                                setState(() {});
                              },
                            ),
                          ),
                          Text(
                            translate('Large'),
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 12,
                              color: tokens.muted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (!_touchMode && _virtualMouseMode.showVirtualMouse) ...[
              const SizedBox(height: 8),
              _buildToggleRow(
                context: context,
                icon: Icons.gamepad_rounded,
                label: translate("Show virtual joystick"),
                value: _virtualMouseMode.showVirtualJoystick,
                onChanged: (_) async {
                  await _virtualMouseMode.toggleVirtualJoystick();
                  _exitRelativeMouseModeIf(
                    !_virtualMouseMode.showVirtualJoystick,
                  );
                  if (mounted) setState(() {});
                },
              ),
            ],
            if (!_touchMode &&
                _virtualMouseMode.showVirtualMouse &&
                _virtualMouseMode.showVirtualJoystick &&
                widget.inputModel != null) ...[
              const SizedBox(height: 8),
              Obx(
                () => _buildToggleRow(
                  context: context,
                  icon: Icons.my_location_rounded,
                  label: translate('Relative mouse mode'),
                  value: widget.inputModel!.relativeMouseMode.value,
                  onChanged: (value) {
                    widget.inputModel!.setRelativeMouseMode(value);
                  },
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final item in gestureCards)
                  GestureInfo(cardWidth, item.$1, item.$2, item.$3),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class GestureInfo extends StatelessWidget {
  const GestureInfo(
    this.width,
    this.icon,
    this.fromText,
    this.toText, {
    super.key,
  });

  final String fromText;
  final String toText;
  final IconData icon;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);
    final accent = dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;

    return SizedBox(
      width: width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfaceContainer.withValues(alpha: dark ? 0.56 : 0.72),
          borderRadius: BorderRadius.circular(CamelliaRadius.control),
          border: Border.all(
            color: tokens.border.withValues(alpha: 0.85),
            width: 0.85,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: dark ? 0.18 : 0.10),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 17, color: accent),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      toText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      fromText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: tokens.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
