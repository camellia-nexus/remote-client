import 'package:flutter/material.dart';

import '../../ui/camellia_design.dart';

class MenuButton extends StatefulWidget {
  final GestureTapCallback? onPressed;
  final Color color;
  final Color hoverColor;
  final Color? splashColor;
  final Widget child;
  final String? tooltip;
  final EdgeInsetsGeometry padding;
  final bool enableFeedback;
  const MenuButton({
    super.key,
    required this.onPressed,
    required this.color,
    required this.hoverColor,
    required this.child,
    this.splashColor,
    this.tooltip = "",
    this.padding = const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
    this.enableFeedback = true,
  });

  @override
  State<MenuButton> createState() => _MenuButtonState();
}

class _MenuButtonState extends State<MenuButton> {
  bool _isHover = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(CamelliaRadius.control);
    final button = Material(
      type: MaterialType.transparency,
      child: AnimatedContainer(
        duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
        curve: CamelliaMotion.standard,
        decoration: BoxDecoration(
          borderRadius: radius,
          color: _isHover ? widget.hoverColor : widget.color,
        ),
        child: InkWell(
          hoverColor: widget.hoverColor,
          highlightColor: Colors.transparent,
          splashColor: widget.splashColor ?? Colors.transparent,
          splashFactory: NoSplash.splashFactory,
          onHover: (val) {
            if (mounted && _isHover != val) {
              setState(() => _isHover = val);
            }
          },
          borderRadius: radius,
          enableFeedback: widget.enableFeedback,
          onTap: widget.onPressed,
          child: widget.child,
        ),
      ),
    );

    final tip = widget.tooltip;
    return Padding(
      padding: widget.padding,
      child: (tip != null && tip.isNotEmpty)
          ? Tooltip(
              waitDuration: const Duration(milliseconds: 350),
              message: tip,
              child: button,
            )
          : button,
    );
  }
}
