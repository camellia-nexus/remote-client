import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class AnimatedRotationWidget extends StatefulWidget {
  final VoidCallback onPressed;
  final ValueChanged<bool>? onHover;
  final Widget child;
  final RxBool? spinning;
  const AnimatedRotationWidget(
      {super.key,
      required this.onPressed,
      required this.child,
      this.spinning,
      this.onHover});

  @override
  State<AnimatedRotationWidget> createState() => AnimatedRotationWidgetState();
}

class AnimatedRotationWidgetState extends State<AnimatedRotationWidget> {
  double turns = 0.0;
  StreamSubscription<bool>? _spinSub;

  @override
  void initState() {
    super.initState();
    _subscribeSpin();
  }

  void _subscribeSpin() {
    _spinSub?.cancel();
    _spinSub = widget.spinning?.listen((v) {
      if (v && mounted) {
        setState(() {
          turns += 1;
        });
      }
    });
  }

  @override
  void didUpdateWidget(covariant AnimatedRotationWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spinning != widget.spinning) {
      _subscribeSpin();
    }
  }

  @override
  void dispose() {
    _spinSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedRotation(
        turns: turns,
        duration: const Duration(milliseconds: 200),
        onEnd: () {
          if (widget.spinning?.value == true && mounted) {
            setState(() => turns += 1.0);
          }
        },
        child: InkWell(
            onTap: () {
              if (mounted) setState(() => turns += 1.0);
              widget.onPressed();
            },
            onHover: widget.onHover,
            child: widget.child));
  }
}
