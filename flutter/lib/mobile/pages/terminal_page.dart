import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/models/input_modifier_utils.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/models/terminal_model.dart';
import 'package:camellia_remote_app/mobile/terminal_keyboard_utils.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:xterm/xterm.dart';
import '../../desktop/pages/terminal_connection_manager.dart';
import '../../consts.dart';

const String _kMobileTerminalFontSizeKey = 'mobile-terminal-font-size';
const double _kTopSessionBarHeight = 44.0;

class TerminalPage extends StatefulWidget {
  const TerminalPage({
    super.key,
    required this.id,
    required this.password,
    required this.isSharedPassword,
    this.forceRelay,
    this.connToken,
    this.isTerminalRunAsAdmin = false,
  });

  final String id;
  final String? password;
  final bool? forceRelay;
  final bool? isSharedPassword;
  final String? connToken;
  final bool isTerminalRunAsAdmin;
  final terminalId = 0;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  late FFI _ffi;
  late TerminalModel _terminalModel;
  double? _cellHeight;
  double _sysKeyboardHeight = 0;
  Timer? _keyboardDebounce;
  final GlobalKey _keyboardKey = GlobalKey();
  double _keyboardHeight = 0;
  late bool _showTerminalExtraKeys;
  bool _ctrlLocked = false;
  bool _altLocked = false;
  bool _row3Expanded = false;
  bool _everTerminalOpened = false;
  bool _closingByTerminalExit = false;
  double _fontSize = 13.0;
  double _swipeStartX = 0;
  double _swipeCurrentX = 0;

  static const _webMonoFallback = <String>[
    'Consolas',
    'monospace',
    'Menlo',
    'Monaco',
    'Liberation Mono',
    'Courier New',
    'Noto Sans Mono CJK SC',
    'Noto Sans Mono CJK TC',
    'Noto Sans Mono CJK KR',
    'Noto Sans Mono CJK JP',
    'Noto Sans Mono CJK HK',
  ];

  SessionID get sessionId => _ffi.sessionId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    final savedFont = double.tryParse(
      bind.getLocalFlutterOption(k: _kMobileTerminalFontSizeKey),
    );
    if (savedFont != null) {
      _fontSize = savedFont.clamp(9.0, 22.0);
    }

    _ffi = TerminalConnectionManager.getConnection(
      peerId: widget.id,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      forceRelay: widget.forceRelay,
      connToken: widget.connToken,
      isTerminalRunAsAdmin: widget.isTerminalRunAsAdmin,
    );

    _terminalModel = TerminalModel(_ffi, widget.terminalId);
    _terminalModel.onResizeExternal = (w, h, pw, ph) {
      _cellHeight = ph * 1.0;
    };
    _terminalModel.addListener(_onTerminalStateChanged);

    _ffi.registerTerminalModel(widget.terminalId, _terminalModel);

    _terminalModel.onClosed = () {
      if (mounted) {
        closeConnection(id: widget.id);
      }
    };

    _showTerminalExtraKeys =
        !isWebDesktop &&
        mainGetLocalBoolOptionSync(kOptionEnableShowTerminalExtraKeys);
    _terminalModel.isCtrlLocked = () => _ctrlLocked;
    _terminalModel.clearCtrlLock = () {
      if (_ctrlLocked) setState(() => _ctrlLocked = false);
    };
    _terminalModel.isAltLocked = () => _altLocked;
    _terminalModel.clearAltLock = () {
      if (_altLocked) setState(() => _altLocked = false);
    };
    _row3Expanded =
        bind.mainGetLocalOption(key: kOptionShowTerminalCtrlKeys) == 'Y';

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ffi.dialogManager.showLoading(
        translate('Connecting...'),
        onCancel: closeConnection,
      );

      if (mounted && _showTerminalExtraKeys) {
        setState(_updateKeyboardHeight);
      }
    });
    _ffi.ffiModel.updateEventListener(_ffi.sessionId, widget.id);
  }

  @override
  void dispose() {
    _terminalModel.removeListener(_onTerminalStateChanged);
    _ffi.unregisterTerminalModel(widget.terminalId);
    _terminalModel.dispose();
    _keyboardDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
    TerminalConnectionManager.releaseConnection(
      widget.id,
      isTerminalRunAsAdmin: widget.isTerminalRunAsAdmin,
    );
  }

  void _adjustFontSize(double delta) {
    final next = (_fontSize + delta).clamp(9.0, 22.0);
    if (next == _fontSize) return;
    HapticFeedback.selectionClick();
    setState(() {
      _fontSize = next;
    });
    bind.setLocalFlutterOption(
      k: _kMobileTerminalFontSizeKey,
      v: next.toStringAsFixed(0),
    );
  }

  void _onTerminalStateChanged() {
    final opened = _terminalModel.terminalOpened;
    if (opened) {
      _everTerminalOpened = true;
    }
    if (isWebDesktop &&
        _everTerminalOpened &&
        !opened &&
        !_closingByTerminalExit) {
      _closingByTerminalExit = true;
      Future.microtask(() {
        if (!mounted) return;
        closeConnection(id: widget.id);
      });
      return;
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();

    _keyboardDebounce?.cancel();
    _keyboardDebounce = Timer(const Duration(milliseconds: 20), () {
      if (!mounted) return;
      final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
      if (bottomInset != _sysKeyboardHeight) {
        setState(() {
          _sysKeyboardHeight = bottomInset;
        });
      }
    });
  }

  void _updateKeyboardHeight() {
    if (_keyboardKey.currentContext != null) {
      final renderBox =
          _keyboardKey.currentContext!.findRenderObject() as RenderBox?;
      if (renderBox != null && renderBox.hasSize) {
        _keyboardHeight = renderBox.size.height;
      }
    }
  }

  EdgeInsets _calculatePadding(double heightPx, double bottomSafe) {
    final bottomReserve =
        _sysKeyboardHeight +
        (_showTerminalExtraKeys ? _keyboardHeight + 8 : bottomSafe);
    if (_cellHeight == null || _cellHeight! <= 0) {
      return EdgeInsets.fromLTRB(6.0, 4.0, 6.0, bottomReserve + 4.0);
    }
    final realHeight = max(0.0, heightPx - bottomReserve);
    final rows = (realHeight / _cellHeight!).floor();
    final extraSpace = realHeight - rows * _cellHeight!;
    final topBottom = max(0.0, extraSpace / 2.0);
    return EdgeInsets.only(
      left: 6.0,
      right: 6.0,
      top: topBottom,
      bottom: topBottom + bottomReserve,
    );
  }

  Future<void> _pasteClipboardText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || !mounted) return;

    await _terminalModel.pasteText(text);
    if (mounted) {
      _terminalModel.terminalController.clearSelection();
    }
  }

  KeyEventResult _handleTerminalKeyEvent(FocusNode _, KeyEvent event) {
    final hardwareKeyboard = HardwareKeyboard.instance;
    final shouldPaste = shouldHandleTerminalPasteShortcut(
      logicalKey: event.logicalKey,
      isKeyDown: event is KeyDownEvent,
      isKeyRepeat: event is KeyRepeatEvent,
      controlPressed: hardwareKeyboard.isControlPressed,
      metaPressed: hardwareKeyboard.isMetaPressed,
      altPressed: hardwareKeyboard.isAltPressed,
      shiftPressed: hardwareKeyboard.isShiftPressed,
      modifierLockActive: _ctrlLocked || _altLocked,
    );
    if (!shouldPaste) return KeyEventResult.ignored;

    unawaited(_pasteClipboardText());
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        clientClose(sessionId, _ffi);
      },
      child: buildBody(),
    );
  }

  Widget _buildTopSessionBar(BuildContext context, double topSafe) {
    final glass = CamelliaGlassTokens.of(context);
    final connected = _terminalModel.terminalOpened;
    final dotColor = connected ? glass.statusOnline : glass.statusConnecting;

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withValues(alpha: 0.14),
            width: 0.85,
          ),
        ),
      ),
      child: GlassSurface(
        layer: CamelliaGlassLayer.modal,
        tintColor: const Color(0xE60A0F1A),
        borderRadius: BorderRadius.zero,
        showShadow: false,
        strokeWidth: 0,
        padding: EdgeInsets.only(
          top: topSafe,
          left: 12,
          right: 8,
        ),
        child: SizedBox(
          height: _kTopSessionBarHeight,
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: dotColor.withValues(alpha: 0.45),
                      blurRadius: 5,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                CamelliaIcons.terminal,
                size: 16,
                color: CamelliaColors.aqua,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        widget.id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CamelliaTypography.tabular(
                          const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ),
                    if (widget.isTerminalRunAsAdmin) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: CamelliaColors.sun.withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: CamelliaColors.sun.withValues(alpha: 0.55),
                            width: 0.75,
                          ),
                        ),
                        child: Text(
                          translate('Admin'),
                          style: const TextStyle(
                            color: Color(0xFFFCD34D),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Font size − / + controls
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.16),
                    width: 0.85,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _TopBarSmallButton(
                      icon: Icons.remove_rounded,
                      tooltip: translate('Decrease font size'),
                      onTap: _fontSize > 9.0
                          ? () => _adjustFontSize(-1.0)
                          : null,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        '${_fontSize.round()}',
                        style: CamelliaTypography.tabular(
                          const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    _TopBarSmallButton(
                      icon: Icons.add_rounded,
                      tooltip: translate('Increase font size'),
                      onTap: _fontSize < 22.0
                          ? () => _adjustFontSize(1.0)
                          : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              if (!isWebDesktop)
                _TopBarSmallButton(
                  icon: _showTerminalExtraKeys
                      ? Icons.keyboard_hide_rounded
                      : CamelliaIcons.keyboard,
                  tooltip: translate('Show terminal extra keys'),
                  active: _showTerminalExtraKeys,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _showTerminalExtraKeys = !_showTerminalExtraKeys;
                      if (!_showTerminalExtraKeys) {
                        _keyboardHeight = 0;
                      }
                    });
                    if (_showTerminalExtraKeys) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          setState(_updateKeyboardHeight);
                        }
                      });
                    }
                  },
                ),
              const SizedBox(width: 4),
              // Explicit Close / Disconnect × button on BOTH Android & iOS & Web
              Tooltip(
                message: translate('Close'),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    clientClose(sessionId, _ffi);
                  },
                  child: Container(
                    width: 32,
                    height: 30,
                    decoration: BoxDecoration(
                      color: CamelliaColors.statusAlertLight.withValues(
                        alpha: 0.22,
                      ),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: CamelliaColors.statusAlertLight.withValues(
                          alpha: 0.50,
                        ),
                        width: 0.85,
                      ),
                    ),
                    child: const Icon(
                      CamelliaIcons.close,
                      size: 16,
                      color: Color(0xFFFDA4AF),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildBody() {
    final topSafe = MediaQuery.paddingOf(context).top;
    final bottomSafe = MediaQuery.paddingOf(context).bottom;
    final liveBottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final effectiveSysKeyboardHeight = max(_sysKeyboardHeight, liveBottomInset);

    final scaffold = Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFF070B12),
      body: Stack(
        children: [
          Positioned.fill(
            top: topSafe + _kTopSessionBarHeight,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return TerminalView(
                  _terminalModel.terminal,
                  controller: _terminalModel.terminalController,
                  autofocus: true,
                  theme: TerminalThemes.whiteOnBlack,
                  textStyle: _getTerminalStyle(),
                  backgroundOpacity: 1.0,
                  deleteDetection: isIOS,
                  onKeyEvent: _handleTerminalKeyEvent,
                  padding: _calculatePadding(constraints.maxHeight, bottomSafe),
                  onSecondaryTapDown: (details, offset) async {
                    final selection =
                        _terminalModel.terminalController.selection;
                    if (selection != null) {
                      final text = _terminalModel.terminal.buffer.getText(
                        selection,
                      );
                      _terminalModel.terminalController.clearSelection();
                      await Clipboard.setData(ClipboardData(text: text));
                    } else {
                      await _pasteClipboardText();
                    }
                  },
                );
              },
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildTopSessionBar(context, topSafe),
          ),
          if (_showTerminalExtraKeys)
            _buildFloatingKeyboard(
              effectiveSysKeyboardHeight > 0
                  ? effectiveSysKeyboardHeight + 6
                  : bottomSafe + 6,
            ),
        ],
      ),
    );

    if (isIOS) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final screenWidth = constraints.maxWidth;
          final edgeThreshold = (screenWidth * 0.1).clamp(20.0, 80.0);
          final swipeThreshold = (screenWidth * 0.25).clamp(80.0, 300.0);

          return RawGestureDetector(
            behavior: HitTestBehavior.translucent,
            gestures: <Type, GestureRecognizerFactory>{
              HorizontalDragGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    HorizontalDragGestureRecognizer
                  >(
                    () => HorizontalDragGestureRecognizer(
                      debugOwner: this,
                      supportedDevices: kTouchBasedDeviceKinds,
                    ),
                    (HorizontalDragGestureRecognizer instance) {
                      instance
                        ..onDown = (details) {
                          _swipeStartX = details.localPosition.dx;
                          _swipeCurrentX = details.localPosition.dx;
                        }
                        ..onUpdate = (details) {
                          _swipeCurrentX = details.localPosition.dx;
                        }
                        ..onEnd = (details) {
                          if (_swipeStartX < edgeThreshold &&
                              (_swipeCurrentX - _swipeStartX) >
                                  swipeThreshold) {
                            clientClose(sessionId, _ffi);
                          }
                          _swipeStartX = 0;
                          _swipeCurrentX = 0;
                        }
                        ..onCancel = () {
                          _swipeStartX = 0;
                          _swipeCurrentX = 0;
                        };
                    },
                  ),
            },
            child: scaffold,
          );
        },
      );
    }

    return scaffold;
  }

  Widget _buildFloatingKeyboard(double bottomOffset) {
    return AnimatedPositioned(
      duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
      curve: CamelliaMotion.standard,
      left: 8,
      right: 8,
      bottom: bottomOffset,
      child: Center(
        heightFactor: 1.0,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: GlassSurface(
            key: _keyboardKey,
            layer: CamelliaGlassLayer.modal,
            elevated: true,
            tintColor: const Color(0xE00D1422),
            borderRadius: BorderRadius.circular(CamelliaRadius.surface),
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
            child: LayoutBuilder(
              builder: (context, constraints) {
                const slots = 7;
                final maxRowWidth = constraints.maxWidth;
                final keyWidth = min(
                  terminalKeyboardKeyWidth,
                  max(
                    34.0,
                    (maxRowWidth - (slots - 1) * terminalKeyboardKeySpacing) /
                        slots,
                  ),
                );

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: _buildKeyboardKeyButtons(
                        terminalKeyboardRow1Keys,
                        keyWidth,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ..._buildKeyboardKeyButtons(
                          terminalKeyboardRow2Keys,
                          keyWidth,
                        ),
                        const SizedBox(width: terminalKeyboardKeySpacing),
                        _buildCollapseButton(keyWidth),
                      ],
                    ),
                    if (_row3Expanded) ...[
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ..._buildKeyboardKeyButtons(
                            terminalKeyboardRow3Keys,
                            keyWidth,
                          ),
                          for (
                            var i = 0;
                            i < terminalKeyboardRow3TrailingPlaceholderCount;
                            i++
                          ) ...[
                            const SizedBox(width: terminalKeyboardKeySpacing),
                            SizedBox(width: keyWidth),
                          ],
                        ],
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  void _toggleRow3Expanded() {
    final willExpand = !_row3Expanded;
    final shouldClearModifiers = shouldClearTerminalModifiersWhenRow3Collapses(
      wasExpanded: _row3Expanded,
      willExpand: willExpand,
      ctrlLocked: _ctrlLocked,
      altLocked: _altLocked,
    );
    setState(() {
      _row3Expanded = willExpand;
      if (shouldClearModifiers) {
        _ctrlLocked = false;
        _altLocked = false;
      }
    });
    mainSetLocalBoolOption(kOptionShowTerminalCtrlKeys, willExpand);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_showTerminalExtraKeys) return;
      setState(_updateKeyboardHeight);
    });
  }

  Widget _buildCollapseButton(double keyWidth) {
    return Semantics(
      label: translate('Show terminal extra keys'),
      toggled: _row3Expanded,
      button: true,
      child: _TerminalKeyCap(
        width: keyWidth,
        active: _row3Expanded,
        onTap: () {
          HapticFeedback.selectionClick();
          _toggleRow3Expanded();
        },
        child: Icon(
          _row3Expanded
              ? Icons.keyboard_arrow_up_rounded
              : Icons.keyboard_arrow_down_rounded,
          size: 17,
          color: _row3Expanded
              ? CamelliaColors.aqua
              : Colors.white.withValues(alpha: 0.85),
        ),
      ),
    );
  }

  List<Widget> _buildKeyboardKeyButtons(List<String> labels, double keyWidth) {
    return [
      for (var i = 0; i < labels.length; i++) ...[
        _buildKeyButton(labels[i], keyWidth),
        if (i < labels.length - 1)
          const SizedBox(width: terminalKeyboardKeySpacing),
      ],
    ];
  }

  Widget _buildModifierToggleButton({
    required String text,
    required String semanticsLabel,
    required bool isLocked,
    required double keyWidth,
    required VoidCallback onPressed,
  }) {
    return Semantics(
      label: semanticsLabel,
      toggled: isLocked,
      button: true,
      child: _TerminalKeyCap(
        width: keyWidth,
        active: isLocked,
        onTap: () {
          HapticFeedback.selectionClick();
          onPressed();
        },
        child: Text(
          text,
          style: CamelliaTypography.tabular(
            TextStyle(
              fontSize: 11.5,
              fontWeight: isLocked ? FontWeight.w700 : FontWeight.w600,
              color: isLocked
                  ? CamelliaColors.aqua
                  : Colors.white.withValues(alpha: 0.90),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKeyButton(String label, double keyWidth) {
    if (label == 'Ctrl') {
      return _buildModifierToggleButton(
        text: 'Ctrl',
        semanticsLabel: 'Ctrl',
        isLocked: _ctrlLocked,
        keyWidth: keyWidth,
        onPressed: () => setState(() => _ctrlLocked = !_ctrlLocked),
      );
    }
    if (label == 'Alt') {
      return _buildModifierToggleButton(
        text: 'Alt',
        semanticsLabel: 'Alt',
        isLocked: _altLocked,
        keyWidth: keyWidth,
        onPressed: () => setState(() => _altLocked = !_altLocked),
      );
    }

    return _TerminalKeyCap(
      width: keyWidth,
      onTap: () {
        HapticFeedback.selectionClick();
        _sendKeyToTerminal(label);
      },
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: CamelliaTypography.tabular(
          TextStyle(
            fontSize: label.length > 4 ? 10.5 : 11.5,
            fontWeight: FontWeight.w600,
            color: Colors.white.withValues(alpha: 0.90),
          ),
        ),
      ),
    );
  }

  void _sendKeyToTerminal(String key) {
    String send;
    switch (key) {
      case 'Esc':
        send = '\x1B';
        break;
      case 'Tab':
        send = '\t';
        break;
      case 'Ctrl+C':
        send = '\x03';
        break;
      case '↑':
        send = '\x1B[A';
        break;
      case '↓':
        send = '\x1B[B';
        break;
      case '→':
        send = '\x1B[C';
        break;
      case '←':
        send = '\x1B[D';
        break;
      case 'Home':
        send = '\x1B[H';
        break;
      case 'End':
        send = '\x1B[F';
        break;
      case 'PgUp':
        send = '\x1B[5~';
        break;
      case 'PgDn':
        send = '\x1B[6~';
        break;
      default:
        send = key;
        break;
    }

    _terminalModel.sendVirtualKey(send);
  }

  TerminalStyle _getTerminalStyle() {
    return TerminalStyle(
      fontFamily: isWeb ? 'Consolas' : 'monospace',
      fontFamilyFallback: _webMonoFallback,
      fontSize: _fontSize,
      height: 1.18,
    );
  }

  @override
  bool get wantKeepAlive => true;
}

class _TopBarSmallButton extends StatelessWidget {
  const _TopBarSmallButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = !enabled
        ? Colors.white.withValues(alpha: 0.30)
        : active
        ? CamelliaColors.aqua
        : Colors.white.withValues(alpha: 0.86);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(icon, size: 15, color: fg),
        ),
      ),
    );
  }
}

class _TerminalKeyCap extends StatefulWidget {
  const _TerminalKeyCap({
    required this.width,
    required this.onTap,
    required this.child,
    this.active = false,
  });

  final double width;
  final VoidCallback onTap;
  final Widget child;
  final bool active;

  @override
  State<_TerminalKeyCap> createState() => _TerminalKeyCapState();
}

class _TerminalKeyCapState extends State<_TerminalKeyCap> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.active
        ? CamelliaColors.aqua.withValues(alpha: 0.22)
        : _pressed
        ? Colors.white.withValues(alpha: 0.20)
        : Colors.white.withValues(alpha: 0.08);
    final border = widget.active
        ? CamelliaColors.aqua.withValues(alpha: 0.65)
        : Colors.white.withValues(alpha: 0.18);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 110),
        width: widget.width,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border, width: 0.85),
        ),
        child: widget.child,
      ),
    );
  }
}
