// These floating mouse widgets simulate physical mouse buttons, scroll wheel,
// and precision joystick when connecting from mobile to desktop in mouse mode.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/remote_input.dart';
import 'package:camellia_remote_app/models/input_model.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';

const double _kSpaceToHorizontalEdge = 20;
const double _wheelWidth = 46;
const double _wheelHeight = 152;
const double _kSpaceToVerticalEdge = 16;
const double _kSpaceBetweenLeftRightButtons = 36;
const double _kLeftRightButtonWidth = 56;
const double _kLeftRightButtonHeight = 40;
const double _kBorderWidth = 0.85;
const int _kInputTimerIntervalMillis = 100;

class FloatingMouseWidgets extends StatefulWidget {
  final FFI ffi;
  const FloatingMouseWidgets({
    super.key,
    required this.ffi,
  });

  @override
  State<FloatingMouseWidgets> createState() => _FloatingMouseWidgetsState();
}

class _FloatingMouseWidgetsState extends State<FloatingMouseWidgets> {
  InputModel get _inputModel => widget.ffi.inputModel;
  CursorModel get _cursorModel => widget.ffi.cursorModel;
  late final VirtualMouseMode _virtualMouseMode;

  @override
  void initState() {
    super.initState();
    _virtualMouseMode = widget.ffi.ffiModel.virtualMouseMode;
    _virtualMouseMode.addListener(_onVirtualMouseModeChanged);
    _cursorModel.blockEvents = false;
    isSpecialHoldDragActive = false;
  }

  void _onVirtualMouseModeChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _virtualMouseMode.removeListener(_onVirtualMouseModeChanged);
    super.dispose();
    _cursorModel.blockEvents = false;
    isSpecialHoldDragActive = false;
  }

  @override
  Widget build(BuildContext context) {
    final virtualMouseMode = _virtualMouseMode;
    if (!virtualMouseMode.showVirtualMouse) {
      return const Offstage();
    }
    return Stack(
      children: [
        FloatingWheel(
          inputModel: _inputModel,
          cursorModel: _cursorModel,
        ),
        if (virtualMouseMode.showVirtualJoystick)
          VirtualJoystick(
            cursorModel: _cursorModel,
            inputModel: _inputModel,
          ),
        FloatingLeftRightButton(
          isLeft: true,
          inputModel: _inputModel,
          cursorModel: _cursorModel,
        ),
        FloatingLeftRightButton(
          isLeft: false,
          inputModel: _inputModel,
          cursorModel: _cursorModel,
        ),
      ],
    );
  }
}

class FloatingWheel extends StatefulWidget {
  final InputModel inputModel;
  final CursorModel cursorModel;
  const FloatingWheel({
    super.key,
    required this.inputModel,
    required this.cursorModel,
  });

  @override
  State<FloatingWheel> createState() => _FloatingWheelState();
}

class _FloatingWheelState extends State<FloatingWheel> {
  Offset _position = Offset.zero;
  bool _isInitialized = false;
  Rect? _lastBlockedRect;

  bool _isUpDown = false;
  bool _isMidDown = false;
  bool _isDownDown = false;

  Orientation? _previousOrientation;

  Timer? _scrollTimer;

  InputModel get _inputModel => widget.inputModel;
  CursorModel get _cursorModel => widget.cursorModel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resetPosition();
    });
  }

  void _resetPosition() {
    final size = MediaQuery.sizeOf(context);
    setState(() {
      _position = Offset(
        size.width - _wheelWidth - _kSpaceToHorizontalEdge,
        (size.height - _wheelHeight) / 2,
      );
      _isInitialized = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateBlockedRect();
    });
  }

  void _updateBlockedRect() {
    if (_lastBlockedRect != null) {
      _cursorModel.removeBlockedRect(_lastBlockedRect!);
    }
    final newRect = Rect.fromLTWH(
      _position.dx,
      _position.dy,
      _wheelWidth,
      _wheelHeight,
    );
    _cursorModel.addBlockedRect(newRect);
    _lastBlockedRect = newRect;
  }

  @override
  void dispose() {
    _scrollTimer?.cancel();
    if (_lastBlockedRect != null) {
      _cursorModel.removeBlockedRect(_lastBlockedRect!);
    }
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final currentOrientation = MediaQuery.orientationOf(context);
    if (_previousOrientation != null &&
        _previousOrientation != currentOrientation) {
      _resetPosition();
    }
    _previousOrientation = currentOrientation;
  }

  Widget _buildUpDownButton({
    required void Function(PointerDownEvent) onPointerDown,
    required void Function(PointerUpEvent) onPointerUp,
    required void Function(PointerCancelEvent) onPointerCancel,
    required bool pressed,
    required BorderRadiusGeometry borderRadius,
    required IconData iconData,
    required Color baseFill,
    required Color activeFill,
    required Color borderColor,
    required Color accentColor,
  }) {
    return Listener(
      onPointerDown: onPointerDown,
      onPointerUp: onPointerUp,
      onPointerCancel: onPointerCancel,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: _wheelWidth,
        height: 51,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: pressed ? activeFill : baseFill,
          border: Border.all(
            color: pressed ? accentColor : borderColor,
            width: _kBorderWidth,
          ),
          borderRadius: borderRadius,
        ),
        child: Icon(
          iconData,
          color: Colors.white.withValues(alpha: pressed ? 1.0 : 0.86),
          size: 26,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Positioned(child: Offstage());
    }
    return Positioned(
      left: _position.dx,
      top: _position.dy,
      child: _buildWidget(context),
    );
  }

  Widget _buildWidget(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.brightness == Brightness.dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    final baseFill = CamelliaColors.darkSurface.withValues(alpha: 0.66);
    final activeFill = accent.withValues(alpha: 0.56);
    final borderColor = Colors.white.withValues(alpha: 0.28);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_wheelWidth * 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: SizedBox(
        width: _wheelWidth,
        height: _wheelHeight,
        child: Column(
          children: [
            _buildUpDownButton(
              onPointerDown: (_) {
                setState(() => _isUpDown = true);
                _startScrollTimer(1);
              },
              onPointerUp: (_) {
                setState(() => _isUpDown = false);
                _stopScrollTimer();
              },
              onPointerCancel: (_) {
                setState(() => _isUpDown = false);
                _stopScrollTimer();
              },
              pressed: _isUpDown,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(_wheelWidth * 0.5),
              ),
              iconData: Icons.keyboard_arrow_up_rounded,
              baseFill: baseFill,
              activeFill: activeFill,
              borderColor: borderColor,
              accentColor: accent,
            ),
            Listener(
              onPointerDown: (_) {
                setState(() => _isMidDown = true);
                _inputModel.tapDown(MouseButtons.wheel);
              },
              onPointerUp: (_) {
                setState(() => _isMidDown = false);
                _inputModel.tapUp(MouseButtons.wheel);
              },
              onPointerCancel: (_) {
                setState(() => _isMidDown = false);
                _inputModel.tapUp(MouseButtons.wheel);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: _wheelWidth,
                height: 50,
                decoration: BoxDecoration(
                  color: _isMidDown ? activeFill : baseFill,
                  border: Border.symmetric(
                    vertical: BorderSide(
                      color: _isMidDown ? accent : borderColor,
                      width: _kBorderWidth,
                    ),
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 14,
                        height: 2,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Container(
                        width: 20,
                        height: 2,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.90),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Container(
                        width: 14,
                        height: 2,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _buildUpDownButton(
              onPointerDown: (_) {
                setState(() => _isDownDown = true);
                _startScrollTimer(-1);
              },
              onPointerUp: (_) {
                setState(() => _isDownDown = false);
                _stopScrollTimer();
              },
              onPointerCancel: (_) {
                setState(() => _isDownDown = false);
                _stopScrollTimer();
              },
              pressed: _isDownDown,
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(_wheelWidth * 0.5),
              ),
              iconData: Icons.keyboard_arrow_down_rounded,
              baseFill: baseFill,
              activeFill: activeFill,
              borderColor: borderColor,
              accentColor: accent,
            ),
          ],
        ),
      ),
    );
  }

  void _startScrollTimer(int direction) {
    _scrollTimer?.cancel();
    _inputModel.scroll(direction);
    _scrollTimer = Timer.periodic(
      const Duration(milliseconds: _kInputTimerIntervalMillis),
      (timer) {
        _inputModel.scroll(direction);
      },
    );
  }

  void _stopScrollTimer() {
    _scrollTimer?.cancel();
    _scrollTimer = null;
  }
}

class FloatingLeftRightButton extends StatefulWidget {
  final bool isLeft;
  final InputModel inputModel;
  final CursorModel cursorModel;
  const FloatingLeftRightButton({
    super.key,
    required this.isLeft,
    required this.inputModel,
    required this.cursorModel,
  });

  @override
  State<FloatingLeftRightButton> createState() =>
      _FloatingLeftRightButtonState();
}

class _FloatingLeftRightButtonState extends State<FloatingLeftRightButton> {
  Offset _position = Offset.zero;
  bool _isInitialized = false;
  bool _isDown = false;
  Rect? _lastBlockedRect;

  Orientation? _previousOrientation;
  Offset _preSavedPos = Offset.zero;

  Timer? _tapDownTimer;
  final Duration _pressTimeout = const Duration(milliseconds: 200);
  bool _isDragging = false;

  bool get _isLeft => widget.isLeft;
  InputModel get _inputModel => widget.inputModel;
  CursorModel get _cursorModel => widget.cursorModel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final currentOrientation = MediaQuery.orientationOf(context);
      _previousOrientation = currentOrientation;
      _resetPosition(currentOrientation);
    });
  }

  @override
  void dispose() {
    if (_lastBlockedRect != null) {
      _cursorModel.removeBlockedRect(_lastBlockedRect!);
    }
    _tapDownTimer?.cancel();
    _trySavePosition();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final currentOrientation = MediaQuery.orientationOf(context);
    if (_previousOrientation == null ||
        _previousOrientation != currentOrientation) {
      _resetPosition(currentOrientation);
    }
    _previousOrientation = currentOrientation;
  }

  double _getOffsetX(double w) {
    if (_isLeft) {
      return (w - _kLeftRightButtonWidth * 2 - _kSpaceBetweenLeftRightButtons) *
          0.5;
    } else {
      return (w + _kSpaceBetweenLeftRightButtons) * 0.5;
    }
  }

  String _getPositionKey(Orientation ori) {
    final strLeftRight = _isLeft ? 'l' : 'r';
    final strOri = ori == Orientation.landscape ? 'l' : 'p';
    return '$strLeftRight$strOri-mouse-btn-pos';
  }

  static Offset? _loadPositionFromString(String s) {
    if (s.isEmpty) {
      return null;
    }
    try {
      final m = jsonDecode(s);
      return Offset(m['x'], m['y']);
    } catch (e) {
      debugPrintStack(label: 'Failed to load position "$s" $e');
      return null;
    }
  }

  void _trySavePosition() {
    if (_previousOrientation == null) return;
    if (((_position - _preSavedPos)).distanceSquared < 0.1) return;
    final pos = jsonEncode({'x': _position.dx, 'y': _position.dy});
    bind.setLocalFlutterOption(
      k: _getPositionKey(_previousOrientation!),
      v: pos,
    );
    _preSavedPos = _position;
  }

  void _restorePosition(Orientation ori) {
    final ps = bind.getLocalFlutterOption(k: _getPositionKey(ori));
    final pos = _loadPositionFromString(ps);
    if (pos == null) {
      final size = MediaQuery.sizeOf(context);
      _position = Offset(
        _getOffsetX(size.width),
        size.height - _kSpaceToVerticalEdge - _kLeftRightButtonHeight,
      );
    } else {
      _position = pos;
      _preSavedPos = pos;
    }
  }

  void _resetPosition(Orientation ori) {
    setState(() {
      _restorePosition(ori);
      _isInitialized = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateBlockedRect();
    });
  }

  void _updateBlockedRect() {
    if (_lastBlockedRect != null) {
      _cursorModel.removeBlockedRect(_lastBlockedRect!);
    }
    final newRect = Rect.fromLTWH(
      _position.dx,
      _position.dy,
      _kLeftRightButtonWidth,
      _kLeftRightButtonHeight,
    );
    _cursorModel.addBlockedRect(newRect);
    _lastBlockedRect = newRect;
  }

  void _onMoveUpdateDelta(Offset delta) {
    final context = this.context;
    final size = MediaQuery.sizeOf(context);
    Offset newPosition = _position + delta;
    double minX = _kSpaceToHorizontalEdge;
    double minY = _kSpaceToVerticalEdge;
    double maxX =
        size.width - _kLeftRightButtonWidth - _kSpaceToHorizontalEdge;
    double maxY =
        size.height - _kLeftRightButtonHeight - _kSpaceToVerticalEdge;
    newPosition = Offset(
      newPosition.dx.clamp(minX, maxX),
      newPosition.dy.clamp(minY, maxY),
    );
    final isPositionChanged = !(isDoubleEqual(newPosition.dx, _position.dx) &&
        isDoubleEqual(newPosition.dy, _position.dy));
    setState(() {
      _position = newPosition;
    });
    if (isPositionChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateBlockedRect();
      });
    }
  }

  void _onBodyPointerMoveUpdate(PointerMoveEvent event) {
    _cursorModel.blockEvents = true;
    _isDragging = true;
    _tapDownTimer?.cancel();
    _tapDownTimer = null;
    _onMoveUpdateDelta(event.delta);
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Positioned(child: Offstage());
    }
    final theme = Theme.of(context);
    final accent = theme.brightness == Brightness.dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    final baseFill = CamelliaColors.darkSurface.withValues(alpha: 0.66);
    final activeFill = accent.withValues(alpha: 0.56);
    final borderColor = Colors.white.withValues(alpha: 0.28);

    return Positioned(
      left: _position.dx,
      top: _position.dy,
      child: Listener(
        onPointerMove: _onBodyPointerMoveUpdate,
        onPointerDown: (event) async {
          _isDragging = false;
          setState(() {
            _isDown = true;
          });
          _tapDownTimer?.cancel();
          _tapDownTimer = Timer(_pressTimeout, () {
            isSpecialHoldDragActive = true;
            () async {
              await _cursorModel.syncCursorPosition();
              await _inputModel.tapDown(
                _isLeft ? MouseButtons.left : MouseButtons.right,
              );
            }();
            _tapDownTimer = null;
          });
        },
        onPointerUp: (event) {
          _cursorModel.blockEvents = false;
          setState(() {
            _isDown = false;
          });
          if (_tapDownTimer != null) {
            _tapDownTimer!.cancel();
            _tapDownTimer = null;
            _inputModel
                .tapDown(_isLeft ? MouseButtons.left : MouseButtons.right)
                .then(
                  (_) => Future.delayed(const Duration(milliseconds: 50), () {
                    _inputModel.tapUp(
                      _isLeft ? MouseButtons.left : MouseButtons.right,
                    );
                  }),
                );
          } else {
            if (isSpecialHoldDragActive) {
              _inputModel.tapUp(
                _isLeft ? MouseButtons.left : MouseButtons.right,
              );
            }
          }

          if (_isDragging) {
            _trySavePosition();
          }
          isSpecialHoldDragActive = false;
        },
        onPointerCancel: (event) {
          _cursorModel.blockEvents = false;
          setState(() {
            _isDown = false;
          });
          _tapDownTimer?.cancel();
          _tapDownTimer = null;
          if (isSpecialHoldDragActive) {
            _inputModel.tapUp(_isLeft ? MouseButtons.left : MouseButtons.right);
          }
          isSpecialHoldDragActive = false;
          if (_isDragging) {
            _trySavePosition();
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: _kLeftRightButtonWidth,
          height: _kLeftRightButtonHeight,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _isDown ? activeFill : baseFill,
            border: Border.all(
              color: _isDown ? accent : borderColor,
              width: _kBorderWidth,
            ),
            borderRadius: _isLeft
                ? const BorderRadius.horizontal(
                    left: Radius.circular(_kLeftRightButtonHeight * 0.5),
                    right: Radius.circular(10),
                  )
                : const BorderRadius.horizontal(
                    left: Radius.circular(10),
                    right: Radius.circular(_kLeftRightButtonHeight * 0.5),
                  ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.24),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: CustomPaint(
            size: const Size(20, 24),
            painter: _MouseButtonIconPainter(
              isLeft: _isLeft,
              strokeColor: Colors.white.withValues(alpha: 0.86),
              activeColor: _isDown ? Colors.white : accent,
            ),
          ),
        ),
      ),
    );
  }
}

class _MouseButtonIconPainter extends CustomPainter {
  const _MouseButtonIconPainter({
    required this.isLeft,
    required this.strokeColor,
    required this.activeColor,
  });

  final bool isLeft;
  final Color strokeColor;
  final Color activeColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final body = RRect.fromRectAndRadius(
      rect.deflate(1.2),
      Radius.circular(size.width * 0.44),
    );
    final stroke = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final activeFill = Paint()
      ..color = activeColor.withValues(alpha: 0.88)
      ..style = PaintingStyle.fill;

    canvas.save();
    canvas.clipRRect(body);
    final halfRect = isLeft
        ? Rect.fromLTWH(0, 0, size.width * 0.5, size.height * 0.48)
        : Rect.fromLTWH(
            size.width * 0.5,
            0,
            size.width * 0.5,
            size.height * 0.48,
          );
    canvas.drawRect(halfRect, activeFill);
    canvas.restore();

    canvas.drawRRect(body, stroke);
    canvas.drawLine(
      Offset(size.width * 0.5, 1.4),
      Offset(size.width * 0.5, size.height * 0.48),
      stroke,
    );
    canvas.drawLine(
      Offset(1.4, size.height * 0.48),
      Offset(size.width - 1.4, size.height * 0.48),
      stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _MouseButtonIconPainter oldDelegate) =>
      oldDelegate.isLeft != isLeft ||
      oldDelegate.strokeColor != strokeColor ||
      oldDelegate.activeColor != activeColor;
}

class VirtualJoystick extends StatefulWidget {
  final CursorModel cursorModel;
  final InputModel inputModel;

  const VirtualJoystick({
    super.key,
    required this.cursorModel,
    required this.inputModel,
  });

  @override
  State<VirtualJoystick> createState() => _VirtualJoystickState();
}

class _VirtualJoystickState extends State<VirtualJoystick> {
  Offset _position = Offset.zero;
  bool _isInitialized = false;
  Offset _offset = Offset.zero;
  final double _joystickRadius = 48.0;
  final double _thumbRadius = 18.0;
  final double _moveStep = 3.0;
  final double _speed = 1.0;

  static const double _kRelativeMouseScale = 3.0;

  Timer? _dragStartTimer;
  Timer? _continuousMoveTimer;
  Size? _lastScreenSize;
  bool _isPressed = false;

  bool get _useRelativeMouse => widget.inputModel.relativeMouseMode.value;

  @override
  void initState() {
    super.initState();
    widget.cursorModel.blockEvents = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _lastScreenSize = MediaQuery.sizeOf(context);
      _resetPosition();
    });
  }

  @override
  void dispose() {
    _stopSendEventTimer();
    widget.cursorModel.blockEvents = false;
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final currentScreenSize = MediaQuery.sizeOf(context);
    if (_lastScreenSize != null && _lastScreenSize != currentScreenSize) {
      _resetPosition();
    }
    _lastScreenSize = currentScreenSize;
  }

  void _resetPosition() {
    final size = MediaQuery.sizeOf(context);
    setState(() {
      _position = Offset(
        _kSpaceToHorizontalEdge + _joystickRadius,
        size.height * 0.5 + _joystickRadius * 1.4,
      );
      _isInitialized = true;
    });
  }

  Offset _offsetToPanDelta(Offset offset) {
    return Offset(
      offset.dx / _joystickRadius,
      offset.dy / _joystickRadius,
    );
  }

  void _sendMovement(Offset delta) {
    if (_useRelativeMouse) {
      widget.inputModel.sendMobileRelativeMouseMove(
        delta.dx * _kRelativeMouseScale,
        delta.dy * _kRelativeMouseScale,
      );
    } else {
      widget.cursorModel.updatePan(delta, Offset.zero, false);
    }
  }

  void _stopSendEventTimer() {
    _dragStartTimer?.cancel();
    _continuousMoveTimer?.cancel();
    _dragStartTimer = null;
    _continuousMoveTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Positioned(child: Offstage());
    }
    final theme = Theme.of(context);
    final accent = theme.brightness == Brightness.dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;

    return Positioned(
      left: _position.dx - _joystickRadius,
      top: _position.dy - _joystickRadius,
      child: GestureDetector(
        onPanStart: (details) {
          setState(() {
            _isPressed = true;
          });
          widget.cursorModel.blockEvents = true;
          _updateOffset(details.localPosition);

          final initialDelta = _offsetToPanDelta(_offset);
          if (initialDelta.distance > 0) {
            _sendMovement(initialDelta);
          }

          _dragStartTimer?.cancel();
          _dragStartTimer = Timer(const Duration(milliseconds: 120), () {
            _continuousMoveTimer?.cancel();
            _continuousMoveTimer = periodic_immediate(
              const Duration(milliseconds: 20),
              () async {
                if (_offset != Offset.zero) {
                  _sendMovement(
                    _offsetToPanDelta(_offset) * _moveStep * _speed,
                  );
                }
              },
            );
          });
        },
        onPanUpdate: (details) {
          _updateOffset(details.localPosition);
        },
        onPanEnd: (details) {
          setState(() {
            _offset = Offset.zero;
            _isPressed = false;
          });
          widget.cursorModel.blockEvents = false;
          _stopSendEventTimer();
        },
        child: CustomPaint(
          size: Size(_joystickRadius * 2, _joystickRadius * 2),
          painter: _JoystickPainter(
            offset: _offset,
            joystickRadius: _joystickRadius,
            thumbRadius: _thumbRadius,
            isPressed: _isPressed,
            accentColor: accent,
          ),
        ),
      ),
    );
  }

  void _updateOffset(Offset localPosition) {
    final center = Offset(_joystickRadius, _joystickRadius);
    final offset = localPosition - center;
    final distance = offset.distance;

    if (distance <= _joystickRadius) {
      setState(() {
        _offset = offset;
      });
    } else {
      final clampedOffset = offset / distance * _joystickRadius;
      setState(() {
        _offset = clampedOffset;
      });
    }
  }
}

class _JoystickPainter extends CustomPainter {
  const _JoystickPainter({
    required this.offset,
    required this.joystickRadius,
    required this.thumbRadius,
    required this.isPressed,
    required this.accentColor,
  });

  final Offset offset;
  final double joystickRadius;
  final double thumbRadius;
  final bool isPressed;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final basePaint = Paint()
      ..color = CamelliaColors.darkSurface.withValues(alpha: 0.62)
      ..style = PaintingStyle.fill;
    final ringPaint = Paint()
      ..color = isPressed
          ? accentColor.withValues(alpha: 0.85)
          : Colors.white.withValues(alpha: 0.28)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9;
    final innerGuidePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    canvas.drawCircle(center, joystickRadius, basePaint);
    canvas.drawCircle(center, joystickRadius, ringPaint);
    canvas.drawCircle(center, joystickRadius * 0.52, innerGuidePaint);

    // Subtle cardinal ticks
    for (var i = 0; i < 4; i++) {
      final angle = i * (pi / 2);
      final p1 = center + Offset(cos(angle), sin(angle)) * (joystickRadius - 7);
      final p2 = center + Offset(cos(angle), sin(angle)) * (joystickRadius - 2);
      canvas.drawLine(p1, p2, innerGuidePaint);
    }

    final thumbCenter = center + offset;
    final thumbFill = Paint()
      ..color = isPressed
          ? accentColor.withValues(alpha: 0.92)
          : Colors.white.withValues(alpha: 0.88)
      ..style = PaintingStyle.fill;
    final thumbBorder = Paint()
      ..color = Colors.white.withValues(alpha: 0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;

    canvas.drawCircle(thumbCenter, thumbRadius, thumbFill);
    canvas.drawCircle(thumbCenter, thumbRadius, thumbBorder);
  }

  @override
  bool shouldRepaint(covariant _JoystickPainter oldDelegate) {
    return oldDelegate.offset != offset ||
        oldDelegate.isPressed != isPressed ||
        oldDelegate.accentColor != accentColor;
  }
}
