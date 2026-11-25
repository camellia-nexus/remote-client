import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common/shared_state.dart';
import 'package:camellia_remote_app/common/widgets/toolbar.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/mobile/widgets/floating_mouse.dart';
import 'package:camellia_remote_app/mobile/widgets/floating_mouse_widgets.dart';
import 'package:camellia_remote_app/mobile/widgets/gesture_help.dart';
import 'package:camellia_remote_app/models/chat_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../common/widgets/overlay.dart';
import '../../common/widgets/dialog.dart';
import '../../common/widgets/remote_input.dart';
import '../../models/input_model.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../../utils/image.dart';
import '../widgets/dialog.dart';
import '../widgets/custom_scale_widget.dart';

final initText = '1' * 1024;

// Workaround for Android (default input method, Microsoft SwiftKey keyboard) when using physical keyboard.
// When connecting a physical keyboard, `KeyEvent.physicalKey.usbHidUsage` are wrong is using Microsoft SwiftKey keyboard.
// https://github.com/flutter/flutter/issues/159384
// https://github.com/flutter/flutter/issues/159383
void _disableAndroidSoftKeyboard({bool? isKeyboardVisible}) {
  if (isAndroid) {
    if (isKeyboardVisible != true) {
      // `enable_soft_keyboard` will be set to `true` when clicking the keyboard icon, in `openKeyboard()`.
      gFFI.invokeMethod("enable_soft_keyboard", false);
    }
  }
}

class RemotePage extends StatefulWidget {
  const RemotePage({
    super.key,
    required this.id,
    this.password,
    this.isSharedPassword,
    this.forceRelay,
  });

  final String id;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> with WidgetsBindingObserver {
  late final int _generation;
  bool _teardownCalled = false;
  Timer? _timer;
  bool _showGestureHelp = false;
  bool _showVirtualKeys = false;
  bool _showFnNumbers = false;
  String _value = '';
  Orientation? _currentOrientation;
  Timer? _orientationTimer;
  final _uniqueKey = UniqueKey();
  Timer? _iosKeyboardWorkaroundTimer;

  final _blockableOverlayState = BlockableOverlayState();

  final keyboardVisibilityController = KeyboardVisibilityController();
  late final StreamSubscription<bool> keyboardSubscription;
  final FocusNode _mobileFocusNode = FocusNode();
  final FocusNode _physicalFocusNode = FocusNode();
  var _showEdit = false; // use soft keyboard
  var _dockCollapsed = false;

  Worker? _waylandKeyboardGateWorker;
  bool _waylandKeyboardGateInitialized = false;

  InputModel get inputModel => gFFI.inputModel;
  SessionID get sessionId => gFFI.sessionId;

  final TextEditingController _textController = TextEditingController(
    text: initText,
  );

  @override
  void initState() {
    super.initState();
    gFFI.mobileReset();
    _generation = gFFI.sessionGeneration;
    initSharedStates(widget.id, generation: _generation);
    gFFI.chatModel.voiceCallStatus.value = VoiceCallStatus.notStarted;
    gFFI.dialogManager.loadMobileActionsOverlayVisible();
    gFFI.ffiModel.updateEventListener(sessionId, widget.id);
    gFFI.start(
      widget.id,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      forceRelay: widget.forceRelay,
      skipMobileReset: true,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      gFFI.dialogManager.showLoading(
        translate('Connecting...'),
        onCancel: closeConnection,
      );
    });
    WakelockManager.enable(_uniqueKey);
    _physicalFocusNode.requestFocus();
    gFFI.inputModel.listenToMouse(true);
    gFFI.qualityMonitorModel.checkShowQualityMonitor(sessionId);
    keyboardSubscription = keyboardVisibilityController.onChange.listen(
      onSoftKeyboardChanged,
    );
    gFFI.chatModel.changeCurrentKey(
      MessageKey(widget.id, ChatModel.clientModeID),
    );
    _blockableOverlayState.applyFfi(gFFI);
    gFFI.imageModel.addCallbackOnFirstImage((String peerId) {
      gFFI.recordingModel.updateStatus(
        bind.sessionGetIsRecording(sessionId: gFFI.sessionId),
      );
      if (gFFI.recordingModel.start) {
        showToast(translate('Automatically record outgoing sessions'));
      }
      _disableAndroidSoftKeyboard(
        isKeyboardVisible: keyboardVisibilityController.isVisible,
      );
    });
    WidgetsBinding.instance.addObserver(this);

    inputModel.keyboardInputAllowed = true;

    // Wayland sessions may use clipboard-based text input on the controlled side.
    // Require explicit user confirmation before allowing soft-keyboard and
    // clipboard-assisted text input. Physical keyboard events are not gated here.
    _waylandKeyboardGateWorker = ever(gFFI.ffiModel.pi.isSet, (bool isSet) {
      if (isSet) {
        _initWaylandKeyboardGateIfNeeded();
      }
    });
    if (gFFI.ffiModel.pi.isSet.value) {
      _initWaylandKeyboardGateIfNeeded();
    }
  }

  Future<void> teardown() async {
    if (_teardownCalled) return;
    _teardownCalled = true;
    final myGen = _generation;
    final mySessionId = sessionId;

    unawaited(bind.sessionClose(sessionId: mySessionId));
    gFFI.dialogManager.hideMobileActionsOverlay(store: false);
    gFFI.inputModel.listenToMouse(false);
    gFFI.imageModel.disposeImage();
    gFFI.cursorModel.disposeImages();
    await gFFI.invokeMethod("enable_soft_keyboard", true);
    inputModel.keyboardInputAllowed = true;

    await gFFI.close();
    if (gFFI.sessionGeneration != myGen) return;

    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    if (gFFI.sessionGeneration != myGen) return;

    WakelockManager.disable(_uniqueKey);
    removeSharedStates(widget.id, expectedGeneration: myGen);
    gFFI.chatModel.onVoiceCallClosed("End connetion");
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _waylandKeyboardGateWorker?.dispose();
    _mobileFocusNode.dispose();
    _physicalFocusNode.dispose();
    _textController.dispose();
    _timer?.cancel();
    _timer = null;
    _orientationTimer?.cancel();
    _orientationTimer = null;
    _iosKeyboardWorkaroundTimer?.cancel();
    _iosKeyboardWorkaroundTimer = null;
    keyboardSubscription.cancel();
    gFFI.dialogManager.dismissAll();
    clearWaylandKeyboardPromptSuppressedForConnection(sessionId.toString());

    if (!_teardownCalled) {
      unawaited(teardown());
    }

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    gFFI.ffiModel.onReconnectLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      trySyncClipboard();
    }
  }

  void trySyncClipboard() {
    gFFI.invokeMethod("try_sync_clipboard");
  }

  bool _shouldGateKeyboardForWayland() {
    if (!(isAndroid || isIOS)) return false;
    final pi = gFFI.ffiModel.pi;
    return pi.platform == kPeerPlatformLinux && pi.isWayland;
  }

  void _initWaylandKeyboardGateIfNeeded() {
    if (!mounted) return;
    if (_waylandKeyboardGateInitialized) return;
    if (!_shouldGateKeyboardForWayland()) return;

    _waylandKeyboardGateInitialized = true;

    final allowWaylandKeyboard = mainGetPeerBoolOptionSync(
      widget.id,
      kPeerOptionAllowWaylandKeyboard,
    );
    if (!shouldShowWaylandKeyboardPrompt(
      connectionId: sessionId.toString(),
      isWaylandPeer: _shouldGateKeyboardForWayland(),
      allowWaylandKeyboardRemembered: allowWaylandKeyboard,
    )) {
      inputModel.keyboardInputAllowed = true;
      return;
    }

    inputModel.keyboardInputAllowed = false;

    _showEdit = false;
    gFFI.invokeMethod("enable_soft_keyboard", false);
    _mobileFocusNode.unfocus();
    _physicalFocusNode.requestFocus();
    setState(() {});
  }

  Widget emptyOverlay(Color bgColor) => BlockableOverlay(
    state: _blockableOverlayState,
    underlying: Container(color: bgColor),
  );

  void onSoftKeyboardChanged(bool visible) {
    if (!visible) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      if (gFFI.chatModel.chatWindowOverlayEntry == null &&
          gFFI.ffiModel.pi.version.isNotEmpty) {
        gFFI.invokeMethod("enable_soft_keyboard", false);
      }

      if (isIOS) {
        _iosKeyboardWorkaroundTimer?.cancel();
        _iosKeyboardWorkaroundTimer = Timer(
          const Duration(milliseconds: 100),
          () {
            if (!mounted) return;
            _physicalFocusNode.unfocus();
            _iosKeyboardWorkaroundTimer = Timer(
              const Duration(milliseconds: 50),
              () {
                if (!mounted) return;
                _physicalFocusNode.requestFocus();
              },
            );
          },
        );
      }
    } else {
      _iosKeyboardWorkaroundTimer?.cancel();
      _iosKeyboardWorkaroundTimer = null;
      _timer?.cancel();
      _timer = Timer(kMobileDelaySoftKeyboardFocus, () {
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
        _mobileFocusNode.requestFocus();
      });
    }
    setState(() {});
  }

  void _handleIOSSoftKeyboardInput(String newValue) {
    var oldValue = _value;
    _value = newValue;
    var i = newValue.length - 1;
    for (; i >= 0 && newValue[i] != '1'; --i) {}
    var j = oldValue.length - 1;
    for (; j >= 0 && oldValue[j] != '1'; --j) {}
    if (i < j) j = i;
    var subNewValue = newValue.substring(j + 1);
    var subOldValue = oldValue.substring(j + 1);

    var common = 0;
    for (
      ;
      common < subOldValue.length &&
          common < subNewValue.length &&
          subNewValue[common] == subOldValue[common];
      ++common
    ) {}

    var newStr = "";
    if (subNewValue.length > common) {
      newStr = subNewValue.substring(common);
    }

    if (_textController.value.isComposingRangeValid) {
      final composingLength =
          _textController.value.composing.end -
          _textController.value.composing.start;
      if (composingLength > newStr.length) {
        _value = oldValue;
        return;
      }
    }

    for (i = 0; i < subOldValue.length - common; ++i) {
      inputModel.inputKey('VK_BACK');
    }

    if (newStr.length > 1) {
      bind.sessionInputString(sessionId: sessionId, value: newStr);
    } else {
      inputChar(newStr);
    }
  }

  void _handleNonIOSSoftKeyboardInput(String newValue) {
    var oldValue = _value;
    _value = newValue;
    if (oldValue.isNotEmpty &&
        newValue.isNotEmpty &&
        oldValue[0] == '1' &&
        newValue[0] != '1') {
      oldValue = '';
    }
    if (newValue.length == oldValue.length) {
      // no-op
    } else if (newValue.length < oldValue.length) {
      inputModel.inputKey('VK_BACK');
    } else {
      final content = newValue.substring(oldValue.length);
      if (content.length > 1) {
        if (oldValue != '' &&
            content.length == 2 &&
            (content == '""' ||
                content == '()' ||
                content == '[]' ||
                content == '<>' ||
                content == "{}" ||
                content == '”“' ||
                content == '《》' ||
                content == '（）' ||
                content == '【】')) {
          bind.sessionInputString(sessionId: sessionId, value: content);
          _openKeyboardUnlocked();
          return;
        }
        bind.sessionInputString(sessionId: sessionId, value: content);
      } else {
        inputChar(content);
      }
    }
  }

  void handleSoftKeyboardInput(String newValue) {
    if (!gFFI.ffiModel.effectiveControlPolicy.canControlRemote) {
      return;
    }
    if (!inputModel.keyboardInputAllowed) {
      return;
    }
    if (isIOS) {
      _handleIOSSoftKeyboardInput(newValue);
    } else {
      _handleNonIOSSoftKeyboardInput(newValue);
    }
  }

  void inputChar(String char) {
    if (!gFFI.ffiModel.effectiveControlPolicy.canControlRemote) {
      return;
    }
    if (!inputModel.keyboardInputAllowed) {
      return;
    }
    if (char == '\n') {
      char = 'VK_RETURN';
    } else if (char == ' ') {
      char = 'VK_SPACE';
    }
    inputModel.inputKey(char);
  }

  void openKeyboard() {
    if (!gFFI.ffiModel.effectiveControlPolicy.canControlRemote) {
      return;
    }
    final allowWaylandKeyboard = mainGetPeerBoolOptionSync(
      widget.id,
      kPeerOptionAllowWaylandKeyboard,
    );
    if (shouldShowWaylandKeyboardPrompt(
      connectionId: sessionId.toString(),
      isWaylandPeer: _shouldGateKeyboardForWayland(),
      allowWaylandKeyboardRemembered: allowWaylandKeyboard,
    )) {
      inputModel.keyboardInputAllowed = false;
      showWaylandKeyboardInputWarningDialog(
        id: widget.id,
        connectionId: sessionId.toString(),
        ffi: gFFI,
        onEnable: () async {
          _openKeyboardUnlocked();
        },
      );
      return;
    }
    _openKeyboardUnlocked();
  }

  void _openKeyboardUnlocked() {
    inputModel.keyboardInputAllowed = true;
    gFFI.invokeMethod("enable_soft_keyboard", true);
    _value = initText;
    _textController.text = _value;
    setState(() => _showEdit = false);
    _timer?.cancel();
    _timer = Timer(kMobileDelaySoftKeyboard, () {
      setState(() => _showEdit = true);
      _timer?.cancel();
      _timer = Timer(kMobileDelaySoftKeyboardFocus, () {
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
        _mobileFocusNode.requestFocus();
      });
    });
  }

  Widget _bottomWidget() => _showGestureHelp
      ? getGestureHelp()
      : (gFFI.ffiModel.pi.displays.isNotEmpty
            ? getBottomAppBar()
            : const SizedBox.shrink());

  @override
  Widget build(BuildContext context) {
    final keyboardIsVisible =
        keyboardVisibilityController.isVisible && _showEdit;
    final showActionButton = keyboardIsVisible || _showGestureHelp;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) clientClose(sessionId, gFFI);
      },
      child: Scaffold(
        floatingActionButtonLocation: keyboardIsVisible
            ? FABLocation(FloatingActionButtonLocation.endFloat, 0, -35)
            : null,
        floatingActionButton: !showActionButton
            ? null
            : GlassIconButton(
                icon: Icons.keyboard_arrow_down_rounded,
                tooltip: translate('Close'),
                size: 40,
                iconSize: 22,
                onPressed: () {
                  setState(() {
                    if (keyboardIsVisible) {
                      _showEdit = false;
                      gFFI.invokeMethod("enable_soft_keyboard", false);
                      _mobileFocusNode.unfocus();
                      _physicalFocusNode.requestFocus();
                    } else if (_showGestureHelp) {
                      _showGestureHelp = false;
                    }
                  });
                },
              ),
        bottomNavigationBar: Obx(
          () => Stack(
            alignment: Alignment.bottomCenter,
            children: [
              gFFI.ffiModel.pi.isSet.isTrue &&
                      gFFI.ffiModel.waitForFirstImage.isTrue
                  ? emptyOverlay(MyTheme.canvasColor)
                  : () {
                      gFFI.ffiModel.tryShowAndroidActionsOverlay();
                      return const Offstage();
                    }(),
              _bottomWidget(),
              gFFI.ffiModel.pi.isSet.isFalse
                  ? emptyOverlay(MyTheme.canvasColor)
                  : const Offstage(),
            ],
          ),
        ),
        body: Obx(
          () => getRawPointerAndKeyBody(
            Overlay(
              initialEntries: [
                OverlayEntry(
                  builder: (context) {
                    return Container(
                      color: kColorCanvas,
                      child: isWebDesktop
                          ? getBodyForDesktopWithListener()
                          : SafeArea(
                              child: OrientationBuilder(
                                builder: (ctx, orientation) {
                                  if (_currentOrientation != orientation) {
                                    _currentOrientation = orientation;
                                    _orientationTimer?.cancel();
                                    _orientationTimer = Timer(
                                      const Duration(milliseconds: 200),
                                      () {
                                        if (!mounted) return;
                                        gFFI.dialogManager
                                            .resetMobileActionsOverlay(
                                              ffi: gFFI,
                                            );
                                        gFFI.canvasModel.updateViewStyle();
                                      },
                                    );
                                  }
                                  return Container(
                                    color: MyTheme.canvasColor,
                                    child: inputModel.isPhysicalMouse.value
                                        ? getBodyForMobile()
                                        : RawTouchGestureDetectorRegion(
                                            ffi: gFFI,
                                            child: getBodyForMobile(),
                                          ),
                                  );
                                },
                              ),
                            ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget getRawPointerAndKeyBody(Widget child) {
    final ffiModel = Provider.of<FfiModel>(context);
    return RawPointerMouseRegion(
      cursor: ffiModel.effectiveControlPolicy.canControlRemote
          ? SystemMouseCursors.none
          : MouseCursor.defer,
      inputModel: inputModel,
      child: gFFI.ffiModel.pi.isSet.isTrue
          ? RawKeyFocusScope(
              focusNode: _physicalFocusNode,
              inputModel: inputModel,
              child: child,
            )
          : child,
    );
  }

  Widget _buildVirtualKeyBar() {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);
    final accent = dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    final isMac = gFFI.ffiModel.pi.platform == kPeerPlatformMacOS;

    Widget keyCap({
      required String label,
      IconData? icon,
      bool active = false,
      required VoidCallback onTap,
    }) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: AnimatedContainer(
            duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
            constraints: const BoxConstraints(minHeight: 32, minWidth: 38),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active
                  ? accent.withValues(alpha: dark ? 0.26 : 0.16)
                  : tokens.surfaceContainer.withValues(
                      alpha: dark ? 0.78 : 0.88,
                    ),
              borderRadius: BorderRadius.circular(CamelliaRadius.control),
              border: Border.all(
                color: active
                    ? accent.withValues(alpha: 0.75)
                    : tokens.border.withValues(alpha: 0.85),
                width: 0.85,
              ),
            ),
            child: icon != null
                ? Icon(
                    icon,
                    size: 16,
                    color: active ? accent : theme.colorScheme.onSurface,
                  )
                : Text(
                    label,
                    style: CamelliaTypography.tabular(
                      theme.textTheme.labelMedium?.copyWith(
                        color: active ? accent : theme.colorScheme.onSurface,
                        fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                      ),
                    ),
                  ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: GlassSurface(
            layer: CamelliaGlassLayer.modal,
            borderRadius: BorderRadius.circular(CamelliaRadius.surface),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  keyCap(
                    label: 'Esc',
                    onTap: () => inputModel.inputKey('Escape'),
                  ),
                  keyCap(
                    label: 'Tab',
                    onTap: () => inputModel.inputKey('Tab'),
                  ),
                  keyCap(
                    label: 'Ctrl',
                    active: inputModel.ctrl,
                    onTap: () =>
                        setState(() => inputModel.ctrl = !inputModel.ctrl),
                  ),
                  keyCap(
                    label: 'Alt',
                    active: inputModel.alt,
                    onTap: () =>
                        setState(() => inputModel.alt = !inputModel.alt),
                  ),
                  keyCap(
                    label: isMac ? 'Cmd' : 'Win',
                    active: inputModel.command,
                    onTap: () => setState(
                      () => inputModel.command = !inputModel.command,
                    ),
                  ),
                  keyCap(
                    label: 'Shift',
                    active: inputModel.shift,
                    onTap: () =>
                        setState(() => inputModel.shift = !inputModel.shift),
                  ),
                  keyCap(
                    label: 'F1–12',
                    active: _showFnNumbers,
                    onTap: () =>
                        setState(() => _showFnNumbers = !_showFnNumbers),
                  ),
                  if (_showFnNumbers) ...[
                    for (var i = 1; i <= 12; i++)
                      keyCap(
                        label: 'F$i',
                        onTap: () => inputModel.inputKey('VK_F$i'),
                      ),
                  ] else ...[
                    keyCap(
                      label: 'Left',
                      icon: Icons.keyboard_arrow_left_rounded,
                      onTap: () => inputModel.inputKey('LeftArrow'),
                    ),
                    keyCap(
                      label: 'Up',
                      icon: Icons.keyboard_arrow_up_rounded,
                      onTap: () => inputModel.inputKey('UpArrow'),
                    ),
                    keyCap(
                      label: 'Down',
                      icon: Icons.keyboard_arrow_down_rounded,
                      onTap: () => inputModel.inputKey('DownArrow'),
                    ),
                    keyCap(
                      label: 'Right',
                      icon: Icons.keyboard_arrow_right_rounded,
                      onTap: () => inputModel.inputKey('RightArrow'),
                    ),
                    keyCap(
                      label: 'Home',
                      onTap: () => inputModel.inputKey('VK_HOME'),
                    ),
                    keyCap(
                      label: 'End',
                      onTap: () => inputModel.inputKey('VK_END'),
                    ),
                    keyCap(
                      label: 'PgUp',
                      onTap: () => inputModel.inputKey('VK_PRIOR'),
                    ),
                    keyCap(
                      label: 'PgDn',
                      onTap: () => inputModel.inputKey('VK_NEXT'),
                    ),
                    keyCap(
                      label: 'Del',
                      onTap: () => inputModel.inputKey('Delete'),
                    ),
                    keyCap(
                      label: 'CAD',
                      onTap: () => bind.sessionCtrlAltDel(sessionId: sessionId),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget getBottomAppBar() {
    final ffiModel = Provider.of<FfiModel>(context);
    final canInput =
        !isWebDesktop && ffiModel.effectiveControlPolicy.canControlRemote;
    final actions = <Widget>[
      _RemoteDockButton(
        icon: CamelliaIcons.close,
        label: translate('Close'),
        destructive: true,
        onPressed: () {
          HapticFeedback.mediumImpact();
          clientClose(sessionId, gFFI);
        },
      ),
      _RemoteDockButton(
        icon: CamelliaIcons.display,
        label: translate('Display'),
        onPressed: () {
          HapticFeedback.selectionClick();
          setState(() => _showEdit = false);
          showOptions(context, widget.id, gFFI.dialogManager);
        },
      ),
      if (canInput)
        _RemoteDockButton(
          icon: CamelliaIcons.keyboard,
          label: translate('Keyboard'),
          onPressed: () {
            HapticFeedback.selectionClick();
            openKeyboard();
          },
        ),
      if (canInput)
        _RemoteDockButton(
          icon: _showVirtualKeys
              ? Icons.keyboard_hide_rounded
              : Icons.keyboard_command_key_rounded,
          label: 'Fn',
          active: _showVirtualKeys,
          onPressed: () {
            HapticFeedback.selectionClick();
            setState(() => _showVirtualKeys = !_showVirtualKeys);
          },
        ),
      if (canInput)
        _RemoteDockButton(
          icon: ffiModel.isPeerAndroid
              ? Icons.smartphone_rounded
              : ffiModel.touchMode
              ? CamelliaIcons.touch
              : CamelliaIcons.mouse,
          label: translate(
            ffiModel.isPeerAndroid
                ? 'Actions'
                : (ffiModel.touchMode ? 'Touch' : 'Mouse'),
          ),
          active: !ffiModel.isPeerAndroid && ffiModel.touchMode,
          onPressed: () {
            HapticFeedback.selectionClick();
            if (ffiModel.isPeerAndroid) {
              gFFI.dialogManager.toggleMobileActionsOverlay(ffi: gFFI);
            } else {
              ffiModel.toggleTouchMode();
              final enabled = ffiModel.touchMode;
              bind.sessionPeerOption(
                sessionId: sessionId,
                name: kOptionTouchMode,
                value: enabled ? 'Y' : 'N',
              );
              showToast(translate(enabled ? 'Touch mode' : 'Mouse mode'));
            }
          },
        ),
      if (!isWeb)
        FutureBuilder<dynamic>(
          future: gFFI.invokeMethod("get_value", "KEY_IS_SUPPORT_VOICE_CALL"),
          builder: (context, snapshot) {
            final supportsVoice = snapshot.data == true;
            return Obx(() {
              final isInVoice = [
                VoiceCallStatus.waitingForResponse,
                VoiceCallStatus.connected,
              ].contains(gFFI.chatModel.voiceCallStatus.value);
              return _RemoteDockButton(
                icon: isInVoice ? CamelliaIcons.voiceCall : CamelliaIcons.chat,
                label: translate('Chat'),
                active: isInVoice,
                onPressed: () {
                  HapticFeedback.selectionClick();
                  if ((isAndroid && supportsVoice) || isInVoice) {
                    showChatOptions(widget.id);
                  } else {
                    onPressedTextChat(widget.id);
                  }
                },
              );
            });
          },
        ),
      _RemoteDockButton(
        icon: CamelliaIcons.more,
        label: translate('More'),
        onPressed: () {
          HapticFeedback.selectionClick();
          setState(() => _showEdit = false);
          showActions(widget.id);
        },
      ),
    ];

    if (_dockCollapsed) {
      return SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 6),
        child: Center(
          heightFactor: 1,
          child: Opacity(
            opacity: 0.84,
            child: GlassSurface(
              layer: CamelliaGlassLayer.modal,
              borderRadius: BorderRadius.circular(CamelliaRadius.pill),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _dockCollapsed = false);
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.keyboard_arrow_up_rounded,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      translate('Controls'),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canInput && _showVirtualKeys) _buildVirtualKeyBar(),
          GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() {
                _dockCollapsed = true;
                _showVirtualKeys = false;
              });
            },
            child: Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(CamelliaRadius.pill),
                ),
              ),
            ),
          ),
          Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: GlassSurface(
                layer: CamelliaGlassLayer.modal,
                elevated: true,
                borderRadius: BorderRadius.circular(CamelliaRadius.sheet),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 54),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      for (final action in actions) Expanded(child: action),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool get showCursorPaint =>
      !gFFI.ffiModel.isPeerAndroid &&
      !gFFI.canvasModel.cursorEmbedded &&
      !gFFI.inputModel.relativeMouseMode.value;

  Widget getBodyForMobile() {
    final topInset = MediaQuery.paddingOf(context).top;
    return Container(
      color: MyTheme.canvasColor,
      child: Stack(
        children: () {
          final paints = [
            ImagePaint(ffiModel: gFFI.ffiModel),
            Positioned(
              top: topInset + 8,
              right: 10,
              child: QualityMonitor(gFFI.qualityMonitorModel),
            ),
            SizedBox(
              width: 0,
              height: 0,
              child: !_showEdit
                  ? const SizedBox.shrink()
                  : TextFormField(
                      textInputAction: TextInputAction.newline,
                      autocorrect: false,
                      autofocus: true,
                      focusNode: _mobileFocusNode,
                      maxLines: null,
                      controller: _textController,
                      keyboardType: TextInputType.multiline,
                      onChanged: handleSoftKeyboardInput,
                    ).workaroundFreezeLinuxMint(),
            ),
          ];
          if (showCursorPaint) {
            paints.add(CursorPaint(widget.id));
          }
          if (gFFI.ffiModel.touchMode) {
            paints.add(FloatingMouse(ffi: gFFI));
          } else {
            paints.add(FloatingMouseWidgets(ffi: gFFI));
          }
          return paints;
        }(),
      ),
    );
  }

  Widget getBodyForDesktopWithListener() {
    final ffiModel = Provider.of<FfiModel>(context);
    var paints = <Widget>[ImagePaint(ffiModel: ffiModel)];
    if (showCursorPaint) {
      final cursor = bind.sessionGetToggleOptionSync(
        sessionId: sessionId,
        arg: 'show-remote-cursor',
      );
      if (ffiModel.keyboard || cursor) {
        paints.add(CursorPaint(widget.id));
      }
    }
    return Container(
      color: MyTheme.canvasColor,
      child: Stack(children: paints),
    );
  }

  List<TTextMenu> _getMobileActionMenus() {
    if (gFFI.ffiModel.pi.platform != kPeerPlatformAndroid ||
        !gFFI.ffiModel.keyboard) {
      return [];
    }
    final enabled = versionCmp(gFFI.ffiModel.pi.version, '1.2.7') >= 0;
    if (!enabled) return [];
    return [
      TTextMenu(
        child: Text(translate('Back')),
        onPressed: () => gFFI.inputModel.onMobileBack(),
      ),
      TTextMenu(
        child: Text(translate('Home')),
        onPressed: () => gFFI.inputModel.onMobileHome(),
      ),
      TTextMenu(
        child: Text(translate('Apps')),
        onPressed: () => gFFI.inputModel.onMobileApps(),
      ),
      TTextMenu(
        child: Text(translate('Volume up')),
        onPressed: () => gFFI.inputModel.onMobileVolumeUp(),
      ),
      TTextMenu(
        child: Text(translate('Volume down')),
        onPressed: () => gFFI.inputModel.onMobileVolumeDown(),
      ),
      TTextMenu(
        child: Text(translate('Power')),
        onPressed: () => gFFI.inputModel.onMobilePower(),
      ),
    ];
  }

  void showActions(String id) async {
    final mobileActionMenus = _getMobileActionMenus();
    final menus = toolbarControls(context, id, gFFI);
    await showGlassBottomSheet<void>(
      context: context,
      title: translate('Session actions'),
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final dark = theme.brightness == Brightness.dark;
        final tokens =
            theme.extension<AppDesignTokens>() ?? MyTheme.tokens(sheetContext);

        Widget section(String title, List<TTextMenu> actions) {
          final visibleActions = actions
              .where((action) => !action.divider)
              .toList(growable: false);
          if (visibleActions.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 6),
                  child: Text(
                    title,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: tokens.muted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.surfaceContainer.withValues(
                      alpha: dark ? 0.65 : 0.80,
                    ),
                    borderRadius: BorderRadius.circular(CamelliaRadius.surface),
                    border: Border.all(
                      color: tokens.border.withValues(alpha: 0.85),
                      width: 0.85,
                    ),
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < visibleActions.length; i++) ...[
                        if (i > 0)
                          Divider(
                            height: 1,
                            thickness: 0.85,
                            indent: 14,
                            endIndent: 14,
                            color: tokens.border.withValues(alpha: 0.55),
                          ),
                        ListTile(
                          dense: true,
                          minTileHeight: 46,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                          ),
                          title: visibleActions[i].getChild(),
                          trailing: Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: tokens.muted,
                          ),
                          onTap: () {
                            HapticFeedback.selectionClick();
                            Navigator.of(sheetContext).pop();
                            visibleActions[i].onPressed?.call();
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.74,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              if (!gFFI.ffiModel.isPeerAndroid)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: tokens.surfaceContainer.withValues(
                        alpha: dark ? 0.65 : 0.80,
                      ),
                      borderRadius: BorderRadius.circular(
                        CamelliaRadius.surface,
                      ),
                      border: Border.all(
                        color: tokens.border.withValues(alpha: 0.85),
                        width: 0.85,
                      ),
                    ),
                    child: ListTile(
                      dense: true,
                      minTileHeight: 48,
                      leading: Icon(
                        CamelliaIcons.touch,
                        size: 19,
                        color: dark
                            ? theme.colorScheme.secondary
                            : theme.colorScheme.primary,
                      ),
                      title: Text(
                        translate('Gesture Help'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: tokens.muted,
                      ),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Navigator.of(sheetContext).pop();
                        setState(() => _showGestureHelp = true);
                      },
                    ),
                  ),
                ),
              section(translate('Device actions'), mobileActionMenus),
              section(translate('Session actions'), menus),
              const SizedBox(height: 14),
            ],
          ),
        );
      },
    );
  }

  void onPressedTextChat(String id) {
    gFFI.chatModel.changeCurrentKey(MessageKey(id, ChatModel.clientModeID));
    gFFI.chatModel.toggleChatOverlay();
  }

  Future<void> showChatOptions(String id) async {
    void onPressVoiceCall() =>
        bind.sessionRequestVoiceCall(sessionId: sessionId);
    void onPressEndVoiceCall() =>
        bind.sessionCloseVoiceCall(sessionId: sessionId);

    final supportsVoice =
        isAndroid &&
        (await gFFI.invokeMethod("get_value", "KEY_IS_SUPPORT_VOICE_CALL") ==
            true);
    if (!mounted) return;

    final isInVoice = [
      VoiceCallStatus.waitingForResponse,
      VoiceCallStatus.connected,
    ].contains(gFFI.chatModel.voiceCallStatus.value);

    await showGlassBottomSheet<void>(
      context: context,
      title: translate('Chat'),
      builder: (sheetCtx) {
        final theme = Theme.of(sheetCtx);
        final glass = CamelliaGlassTokens.of(sheetCtx);
        final accent = theme.brightness == Brightness.dark
            ? theme.colorScheme.secondary
            : theme.colorScheme.primary;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(CamelliaIcons.chat, color: accent),
                title: Text(translate('Text chat')),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  onPressedTextChat(widget.id);
                },
              ),
              if (isInVoice)
                ListTile(
                  leading: Icon(
                    CamelliaIcons.endCall,
                    color: glass.statusAlert,
                  ),
                  title: Text(
                    translate('End voice call'),
                    style: TextStyle(
                      color: glass.statusAlert,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    onPressEndVoiceCall();
                  },
                )
              else if (isAndroid && supportsVoice)
                ListTile(
                  leading: Icon(CamelliaIcons.voiceCall, color: accent),
                  title: Text(translate('Voice call')),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    onPressVoiceCall();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Widget getGestureHelp() {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      child: GlassSurface(
        layer: CamelliaGlassLayer.modal,
        elevated: true,
        borderRadius: BorderRadius.circular(CamelliaRadius.sheet),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: SingleChildScrollView(
          child: GestureHelp(
            touchMode: gFFI.ffiModel.touchMode,
            onTouchModeChange: (t) {
              gFFI.ffiModel.toggleTouchMode();
              final v = gFFI.ffiModel.touchMode ? 'Y' : 'N';
              bind.mainSetLocalOption(key: kOptionTouchMode, value: v);
            },
            virtualMouseMode: gFFI.ffiModel.virtualMouseMode,
            inputModel: gFFI.inputModel,
          ),
        ),
      ),
    );
  }
}

class _RemoteDockButton extends StatelessWidget {
  const _RemoteDockButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.destructive = false,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool destructive;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final accent = dark ? scheme.secondary : scheme.primary;
    final color = destructive
        ? scheme.error
        : active
        ? accent
        : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: active,
      label: label,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
            decoration: BoxDecoration(
              color: active
                  ? accent.withValues(alpha: dark ? 0.20 : 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 20, color: onPressed == null ? null : color),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: onPressed == null ? null : color,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w600,
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

class ImagePaint extends StatelessWidget {
  final FfiModel ffiModel;
  const ImagePaint({super.key, required this.ffiModel});

  @override
  Widget build(BuildContext context) {
    final m = Provider.of<ImageModel>(context);
    final c = Provider.of<CanvasModel>(context);
    var s = c.scale;
    if (ffiModel.isPeerLinux) {
      final displays = ffiModel.pi.getCurDisplays();
      if (displays.isNotEmpty) {
        s = s / displays[0].scale;
      }
    }
    final adjust = c.getAdjustY();
    return CustomPaint(
      painter: ImagePainter(
        image: m.image,
        x: c.x / s,
        y: (c.y + adjust) / s,
        scale: s,
      ),
    );
  }
}

class CursorPaint extends StatelessWidget {
  final String id;
  const CursorPaint(this.id, {super.key});

  @override
  Widget build(BuildContext context) {
    final m = Provider.of<CursorModel>(context);
    final c = Provider.of<CanvasModel>(context);
    final ffiModel = Provider.of<FfiModel>(context);
    final s = c.scale;
    double hotx = m.hotx;
    double hoty = m.hoty;
    var image = m.image;
    if (image == null) {
      if (preDefaultCursor.image != null) {
        image = preDefaultCursor.image;
        hotx = preDefaultCursor.image!.width / 2;
        hoty = preDefaultCursor.image!.height / 2;
      }
    }
    if (preForbiddenCursor.image != null &&
        !ffiModel.viewOnly &&
        !ffiModel.keyboard &&
        !ShowRemoteCursorState.find(id).value) {
      image = preForbiddenCursor.image;
      hotx = preForbiddenCursor.image!.width / 2;
      hoty = preForbiddenCursor.image!.height / 2;
    }
    if (image == null) {
      return const Offstage();
    }

    const minSize = 12.0;
    double mins =
        minSize / (image.width > image.height ? image.width : image.height);
    double factor = 1.0;
    if (s < mins) {
      factor = s / mins;
    }
    final s2 = s < mins ? mins : s;
    final adjust = c.getAdjustY();
    return CustomPaint(
      painter: ImagePainter(
        image: image,
        x: (m.x - hotx) * factor + c.x / s2,
        y: (m.y - hoty) * factor + (c.y + adjust) / s2,
        scale: s2,
      ),
    );
  }
}

void showOptions(
  BuildContext context,
  String id,
  OverlayDialogManager dialogManager,
) async {
  final pi = gFFI.ffiModel.pi;
  final connectionSummary = gFFI.ffiModel.getConnectionImageText();
  final privacyModeState = PrivacyModeState.find(id);
  final canSwitchDisplay =
      pi.displays.length > 1 &&
      pi.currentDisplay != kAllDisplayValue &&
      (privacyModeState.isEmpty ||
          allowDisplaySwitchInPrivacyMode(pi, privacyModeState.value));

  final viewStyleRadios = await toolbarViewStyle(context, id, gFFI);
  if (!context.mounted) return;
  final imageQualityRadios = await toolbarImageQuality(context, id, gFFI);
  if (!context.mounted) return;
  final codecRadios = await toolbarCodec(context, id, gFFI);
  if (!context.mounted) return;
  final cursorToggles = await toolbarCursor(context, id, gFFI);
  if (!context.mounted) return;
  final displayToggles = await toolbarDisplayToggle(context, id, gFFI);
  if (!context.mounted) return;

  List<TToggleMenu> privacyModeList = [];
  if ((gFFI.ffiModel.pi.features.privacyMode && gFFI.ffiModel.keyboard) ||
      privacyModeState.isNotEmpty) {
    privacyModeList = toolbarPrivacyMode(privacyModeState, context, id, gFFI);
    if (privacyModeList.length == 1) {
      displayToggles.add(privacyModeList[0]);
    }
  }

  final viewStyle =
      (viewStyleRadios.isNotEmpty ? viewStyleRadios[0].groupValue : '').obs;
  final imageQuality =
      (imageQualityRadios.isNotEmpty ? imageQualityRadios[0].groupValue : '')
          .obs;
  final codec = (codecRadios.isNotEmpty ? codecRadios[0].groupValue : '').obs;
  final rxCursorToggleValues = cursorToggles.map((e) => e.value.obs).toList();
  final rxToggleValues = displayToggles.map((e) => e.value.obs).toList();

  await showGlassBottomSheet<void>(
    context: context,
    title: translate('Display Settings'),
    builder: (sheetCtx) {
      final theme = Theme.of(sheetCtx);
      final dark = theme.brightness == Brightness.dark;
      final tokens =
          theme.extension<AppDesignTokens>() ?? MyTheme.tokens(sheetCtx);
      final accent = dark
          ? theme.colorScheme.secondary
          : theme.colorScheme.primary;

      Widget sectionFrame({
        required String title,
        required IconData icon,
        required List<Widget> children,
      }) {
        if (children.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.surfaceContainer.withValues(
                alpha: dark ? 0.65 : 0.80,
              ),
              borderRadius: BorderRadius.circular(CamelliaRadius.surface),
              border: Border.all(
                color: tokens.border.withValues(alpha: 0.85),
                width: 0.85,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: 17, color: accent),
                      const SizedBox(width: 8),
                      Text(
                        translate(title),
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ...children,
                ],
              ),
            ),
          ),
        );
      }

      Widget radioGroupSection(
        String title,
        IconData icon,
        List<TRadioMenu<String>> entries,
        RxString selected, {
        Widget? footer,
      }) {
        if (entries.isEmpty) return const SizedBox.shrink();
        return Obx(
          () => sectionFrame(
            title: title,
            icon: icon,
            children: [
              Column(
                children: [
                  for (final entry in entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(
                          CamelliaRadius.control,
                        ),
                        onTap: entry.onChanged == null
                            ? null
                            : () {
                                HapticFeedback.selectionClick();
                                entry.onChanged?.call(entry.value);
                                selected.value = entry.value;
                              },
                        child: AnimatedContainer(
                          duration: CamelliaMotion.resolve(
                            sheetCtx,
                            CamelliaMotion.hover,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 9,
                          ),
                          decoration: BoxDecoration(
                            color: selected.value == entry.value
                                ? accent.withValues(alpha: dark ? 0.18 : 0.10)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(
                              CamelliaRadius.control,
                            ),
                            border: Border.all(
                              color: selected.value == entry.value
                                  ? accent.withValues(alpha: 0.55)
                                  : Colors.transparent,
                              width: 0.85,
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: DefaultTextStyle.merge(
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: selected.value == entry.value
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                  child: entry.child,
                                ),
                              ),
                              Icon(
                                CamelliaIcons.check,
                                size: 17,
                                color: selected.value == entry.value
                                    ? accent
                                    : Colors.transparent,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              ?footer,
            ],
          ),
        );
      }

      Widget toggleRow(TToggleMenu entry, RxBool value, IconData icon) {
        return Obx(
          () => SwitchListTile.adaptive(
            dense: true,
            value: value.value,
            onChanged: entry.onChanged == null
                ? null
                : (next) {
                    HapticFeedback.selectionClick();
                    entry.onChanged?.call(next);
                    value.value = next;
                  },
            secondary: Icon(icon, size: 18, color: tokens.muted),
            title: DefaultTextStyle.merge(
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
              child: entry.child,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          ),
        );
      }

      final displayHeaderWidgets = <Widget>[
        if (connectionSummary != null)
          Padding(
            padding: EdgeInsets.only(bottom: canSwitchDisplay ? 10 : 0),
            child: connectionSummary,
          ),
        if (canSwitchDisplay)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < pi.displays.length; i++)
                GestureDetector(
                  onTap: () {
                    if (i == pi.currentDisplay) return;
                    HapticFeedback.selectionClick();
                    Navigator.of(sheetCtx).pop();
                    openMonitorInTheSameTab(i, gFFI, pi);
                  },
                  child: AnimatedContainer(
                    duration: CamelliaMotion.resolve(
                      sheetCtx,
                      CamelliaMotion.feedback,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: i == pi.currentDisplay
                          ? accent.withValues(alpha: dark ? 0.22 : 0.14)
                          : tokens.surface,
                      borderRadius: BorderRadius.circular(
                        CamelliaRadius.control,
                      ),
                      border: Border.all(
                        color: i == pi.currentDisplay
                            ? accent.withValues(alpha: 0.65)
                            : tokens.border.withValues(alpha: 0.85),
                        width: 0.85,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          CamelliaIcons.screen,
                          size: 15,
                          color: i == pi.currentDisplay ? accent : tokens.muted,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${i + 1}',
                          style: CamelliaTypography.tabular(
                            theme.textTheme.labelMedium?.copyWith(
                              color: i == pi.currentDisplay
                                  ? accent
                                  : theme.colorScheme.onSurface,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
      ];

      final subSheetRows = <Widget>[];
      final resolution = getResolutionMenu(gFFI, id, parentContext: context);
      if (resolution != null) {
        subSheetRows.add(
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: Icon(
              Icons.aspect_ratio_rounded,
              size: 18,
              color: tokens.muted,
            ),
            title: resolution.child,
            trailing: Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: tokens.muted,
            ),
            onTap: () {
              Navigator.of(sheetCtx).pop();
              resolution.onPressed?.call();
            },
          ),
        );
      }
      final virtualDisplay = getVirtualDisplayMenu(
        gFFI,
        id,
        parentContext: context,
      );
      if (virtualDisplay != null) {
        subSheetRows.add(
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: Icon(
              Icons.add_to_queue_rounded,
              size: 18,
              color: tokens.muted,
            ),
            title: virtualDisplay.child,
            trailing: Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: tokens.muted,
            ),
            onTap: () {
              Navigator.of(sheetCtx).pop();
              virtualDisplay.onPressed?.call();
            },
          ),
        );
      }

      final generalRows = <Widget>[
        for (var i = 0; i < cursorToggles.length; i++)
          toggleRow(
            cursorToggles[i],
            rxCursorToggleValues[i],
            CamelliaIcons.mouse,
          ),
        for (var i = 0; i < displayToggles.length; i++)
          toggleRow(
            displayToggles[i],
            rxToggleValues[i],
            CamelliaIcons.display,
          ),
        if (privacyModeList.length > 1)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: Icon(
              CamelliaIcons.privacy,
              size: 18,
              color: tokens.muted,
            ),
            title: Text(translate('Privacy mode')),
            trailing: Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: tokens.muted,
            ),
            onTap: () {
              Navigator.of(sheetCtx).pop();
              setPrivacyModeDialog(
                dialogManager,
                privacyModeList,
                privacyModeState,
                sheetContext: context,
              );
            },
          ),
      ];

      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.78,
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
          shrinkWrap: true,
          children: [
            if (displayHeaderWidgets.isNotEmpty)
              sectionFrame(
                title: 'Display',
                icon: CamelliaIcons.screen,
                children: displayHeaderWidgets,
              ),
            radioGroupSection(
              'View Mode',
              Icons.fit_screen_rounded,
              viewStyleRadios,
              viewStyle,
              footer: Obx(
                () => viewStyle.value == kRemoteViewStyleCustom
                    ? Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: MobileCustomScaleControls(ffi: gFFI),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
            radioGroupSection(
              'Image Quality',
              Icons.high_quality_outlined,
              imageQualityRadios,
              imageQuality,
            ),
            radioGroupSection(
              'Codec',
              Icons.video_settings_outlined,
              codecRadios,
              codec,
            ),
            if (subSheetRows.isNotEmpty)
              sectionFrame(
                title: 'Display',
                icon: Icons.aspect_ratio_rounded,
                children: subSheetRows,
              ),
            if (generalRows.isNotEmpty)
              sectionFrame(
                title: 'General',
                icon: CamelliaIcons.settings,
                children: generalRows,
              ),
          ],
        ),
      );
    },
  );
  _disableAndroidSoftKeyboard();
}

TTextMenu? getVirtualDisplayMenu(
  FFI ffi,
  String id, {
  BuildContext? parentContext,
}) {
  if (!showVirtualDisplayMenu(ffi)) {
    return null;
  }
  return TTextMenu(
    child: Text(translate("Virtual display")),
    onPressed: () async {
      if (parentContext != null && parentContext.mounted) {
        await showGlassBottomSheet<void>(
          context: parentContext,
          title: translate('Virtual display'),
          builder: (sheetCtx) {
            final children = getVirtualDisplayMenuChildren(
              ffi,
              id,
              () => Navigator.of(sheetCtx).pop(),
            );
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
            );
          },
        );
        _disableAndroidSoftKeyboard();
        return;
      }
      ffi.dialogManager
          .show(
            (setState, close, context) {
              final children = getVirtualDisplayMenuChildren(ffi, id, close);
              return CustomAlertDialog(
                title: ModernDialogHeader(
                  icon: Icons.add_to_queue_rounded,
                  title: translate('Virtual display'),
                  onClose: close,
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              );
            },
            clickMaskDismiss: true,
            backDismiss: true,
          )
          .then((_) => _disableAndroidSoftKeyboard());
    },
  );
}

TTextMenu? getResolutionMenu(
  FFI ffi,
  String id, {
  BuildContext? parentContext,
}) {
  final ffiModel = ffi.ffiModel;
  final pi = ffiModel.pi;
  final resolutions = pi.resolutions;
  final display = pi.tryGetDisplayIfNotAllDisplay(display: pi.currentDisplay);

  final visible =
      ffiModel.keyboard && (resolutions.length > 1) && display != null;
  if (!visible) return null;

  return TTextMenu(
    child: Text(translate("Resolution")),
    onPressed: () async {
      final currentKey = '${display.width}x${display.height}';
      if (parentContext != null && parentContext.mounted) {
        await showGlassBottomSheet<void>(
          context: parentContext,
          title: translate('Resolution'),
          builder: (sheetCtx) {
            final theme = Theme.of(sheetCtx);
            final dark = theme.brightness == Brightness.dark;
            final accent = dark
                ? theme.colorScheme.secondary
                : theme.colorScheme.primary;
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.62,
              ),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
                shrinkWrap: true,
                children: [
                  for (final r in resolutions)
                    Builder(
                      builder: (ctx) {
                        final val = '${r.width}x${r.height}';
                        final selected = val == currentKey;
                        return ListTile(
                          dense: true,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              CamelliaRadius.control,
                            ),
                          ),
                          title: Text(
                            '${r.width} × ${r.height}',
                            style: CamelliaTypography.tabular(
                              theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: selected ? accent : null,
                              ),
                            ),
                          ),
                          trailing: Icon(
                            CamelliaIcons.check,
                            size: 18,
                            color: selected ? accent : Colors.transparent,
                          ),
                          onTap: () {
                            HapticFeedback.selectionClick();
                            Navigator.of(sheetCtx).pop();
                            bind.sessionChangeResolution(
                              sessionId: ffi.sessionId,
                              display: pi.currentDisplay,
                              width: r.width,
                              height: r.height,
                            );
                          },
                        );
                      },
                    ),
                ],
              ),
            );
          },
        );
        _disableAndroidSoftKeyboard();
        return;
      }

      ffi.dialogManager
          .show(
            (setState, close, context) {
              final children = resolutions
                  .map(
                    (e) => getRadio<String>(
                      Text(
                        '${e.width} × ${e.height}',
                        style: CamelliaTypography.tabular(
                          Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      '${e.width}x${e.height}',
                      currentKey,
                      (value) {
                        close();
                        bind.sessionChangeResolution(
                          sessionId: ffi.sessionId,
                          display: pi.currentDisplay,
                          width: e.width,
                          height: e.height,
                        );
                      },
                    ),
                  )
                  .toList();
              return CustomAlertDialog(
                title: ModernDialogHeader(
                  icon: Icons.aspect_ratio_rounded,
                  title: translate('Resolution'),
                  onClose: close,
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              );
            },
            clickMaskDismiss: true,
            backDismiss: true,
          )
          .then((_) => _disableAndroidSoftKeyboard());
    },
  );
}

void sendPrompt(bool isMac, String key) {
  final old = isMac ? gFFI.inputModel.command : gFFI.inputModel.ctrl;
  if (isMac) {
    gFFI.inputModel.command = true;
  } else {
    gFFI.inputModel.ctrl = true;
  }
  gFFI.inputModel.inputKey(key);
  if (isMac) {
    gFFI.inputModel.command = old;
  } else {
    gFFI.inputModel.ctrl = old;
  }
}

class FABLocation extends FloatingActionButtonLocation {
  FloatingActionButtonLocation location;
  double offsetX;
  double offsetY;
  FABLocation(this.location, this.offsetX, this.offsetY);

  @override
  Offset getOffset(ScaffoldPrelayoutGeometry scaffoldGeometry) {
    final offset = location.getOffset(scaffoldGeometry);
    return Offset(offset.dx + offsetX, offset.dy + offsetY);
  }
}
