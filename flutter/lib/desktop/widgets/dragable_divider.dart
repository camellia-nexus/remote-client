import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DraggableDivider extends StatefulWidget {
  final Axis axis;
  final double thickness;
  final Color color;
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
    this.thickness = 1.0,
    this.color = const Color.fromARGB(200, 177, 175, 175),
    this.onPointerMove,
    this.padding = const EdgeInsets.symmetric(horizontal: 1.0),
    this.onHover,
    this.onDragStart,
    this.onDragEnd,
    this.onEnter,
    this.onExit,
    this.hitTestBehavior = HitTestBehavior.translucent,
  });

  @override
  State<DraggableDivider> createState() => _DraggableDividerState();
}

class _DraggableDividerState extends State<DraggableDivider> {
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: widget.hitTestBehavior,
      onPointerDown: (event) {
        _isDragging = true;
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
          _isDragging = false;
          widget.onDragEnd?.call();
        }
      },
      onPointerCancel: (event) {
        if (_isDragging) {
          _isDragging = false;
          widget.onDragEnd?.call();
        }
      },
      onPointerHover: (event) => widget.onHover?.call(),
      child: MouseRegion(
        cursor: widget.axis == Axis.horizontal
            ? SystemMouseCursors.resizeUpDown
            : SystemMouseCursors.resizeLeftRight,
        onEnter: widget.onEnter,
        onExit: widget.onExit,
        child: Padding(
          padding: widget.padding,
          child: Container(
            decoration: BoxDecoration(color: widget.color),
            width: widget.axis == Axis.horizontal
                ? double.infinity
                : widget.thickness,
            height: widget.axis == Axis.horizontal
                ? widget.thickness
                : double.infinity,
          ),
        ),
      ),
    );
  }
}
