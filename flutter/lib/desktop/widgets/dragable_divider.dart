import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart' show AppVisual;
import '../../ui/camellia_design.dart';

class DraggableDivider extends StatefulWidget {
  final Axis axis;
  final double thickness;
  final Color? color;
  final Color? activeColor;
  final Function(double)? onPointerMove;
  final VoidCallback? onHover;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;
  final PointerEnterEventListener? onEnter;
  final PointerExitEventListener? onExit;
  final EdgeInsets padding;
  final HitTestBehavior hitTestBehavior;

  const DraggableDivider({
    super.key,
    this.axis = Axis.horizontal,
    this.thickness = 0.85,
    this.color,
    this.activeColor,
    this.onPointerMove,
    this.padding = const EdgeInsets.symmetric(horizontal: 3.5),
    this.onHover,
    this.onDragStart,
    this.onDragEnd,
    this.onEnter,
    this.onExit,
    this.hitTestBehavior = HitTestBehavior.opaque,
  });

  @override
  State<DraggableDivider> createState() => _DraggableDividerState();
}

class _DraggableDividerState extends State<DraggableDivider> {
  bool _isDragging = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = AppVisual.tokens(context);
    final active = _isDragging || _isHovered;
    final baseColor = widget.color ?? tokens.border;
    final highlightColor =
        widget.activeColor ??
        tokens.focusRing.withValues(alpha: _isDragging ? 0.92 : 0.72);
    final lineThickness = active ? 2.0 : widget.thickness;

    final effectivePadding = widget.axis == Axis.vertical
        ? EdgeInsets.symmetric(
            horizontal: widget.padding.horizontal < 7.0
                ? (8.0 - widget.thickness).clamp(0.0, 8.0) / 2.0
                : widget.padding.horizontal / 2.0,
          )
        : EdgeInsets.symmetric(
            vertical: widget.padding.vertical < 7.0
                ? (8.0 - widget.thickness).clamp(0.0, 8.0) / 2.0
                : widget.padding.vertical / 2.0,
          );

    return Listener(
      behavior: widget.hitTestBehavior,
      onPointerDown: (event) {
        if (!_isDragging && mounted) {
          setState(() => _isDragging = true);
        }
        widget.onDragStart?.call();
      },
      onPointerMove: (event) {
        final dl = widget.axis == Axis.horizontal
            ? event.localDelta.dy
            : event.localDelta.dx;
        widget.onPointerMove?.call(dl);
      },
      onPointerUp: (event) {
        if (_isDragging) {
          if (mounted) setState(() => _isDragging = false);
          widget.onDragEnd?.call();
        }
      },
      onPointerCancel: (event) {
        if (_isDragging) {
          if (mounted) setState(() => _isDragging = false);
          widget.onDragEnd?.call();
        }
      },
      onPointerHover: (event) => widget.onHover?.call(),
      child: MouseRegion(
        cursor: widget.axis == Axis.horizontal
            ? SystemMouseCursors.resizeUpDown
            : SystemMouseCursors.resizeLeftRight,
        onEnter: (event) {
          if (mounted) setState(() => _isHovered = true);
          widget.onEnter?.call(event);
        },
        onExit: (event) {
          if (mounted) setState(() => _isHovered = false);
          widget.onExit?.call(event);
        },
        child: SizedBox(
          width: widget.axis == Axis.vertical
              ? effectivePadding.horizontal + widget.thickness
              : double.infinity,
          height: widget.axis == Axis.horizontal
              ? effectivePadding.vertical + widget.thickness
              : double.infinity,
          child: Center(
            child: AnimatedContainer(
              duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
              curve: CamelliaMotion.standard,
              width: widget.axis == Axis.horizontal
                  ? double.infinity
                  : lineThickness,
              height: widget.axis == Axis.horizontal
                  ? lineThickness
                  : double.infinity,
              decoration: BoxDecoration(
                color: active ? highlightColor : baseColor,
                borderRadius: active ? BorderRadius.circular(1.0) : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
