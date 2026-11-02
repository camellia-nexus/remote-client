import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common/shared_state.dart';
import 'package:camellia_remote_app/common/widgets/toolbar.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/mobile/widgets/floating_mouse.dart';
import 'package:camellia_remote_app/mobile/widgets/floating_mouse_widgets.dart';
import 'package:camellia_remote_app/mobile/widgets/gesture_help.dart';
import 'package:camellia_remote_app/models/chat_model.dart';
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';
import 'package:flutter_svg/svg.dart';
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
  Timer? _timer;
  bool _showGestureHelp = false;
  String _value = '';
  Orientation? _currentOrientation;
  final _uniqueKey = UniqueKey();
  Timer? _iosKeyboardWorkaroundTimer;

  final _blockableOverlayState = BlockableOverlayState();

  final keyboardVisibilityController = KeyboardVisibilityController();
  late final StreamSubscription<bool> keyboardSubscription;
  final FocusNode _mobileFocusNode = FocusNode();
  final FocusNode _physicalFocusNode = FocusNode();
  var _showEdit = false; // use soft keyboard

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
    initSharedStates(widget.id);
    gFFI.chatModel.voiceCallStatus.value = VoiceCallStatus.notStarted;
    gFFI.dialogManager.loadMobileActionsOverlayVisible();
    gFFI.ffiModel.updateEventListener(sessionId, widget.id);
    gFFI.start(
      widget.id,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      forceRelay: widget.forceRelay,
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

  @override
  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    // Close the session up-front. `gFFI.close()` below only calls `sessionClose`
    // after several awaits (canvas save, image update, the `enable_soft_keyboard`
    // platform call), so if the app is backgrounded while this page is disposing,
    // dispose can be suspended before reaching it and the connection is never torn
    // down. The reconnect then re-attaches to the leaked session and is stuck on
    // "Connecting...". Dispatching it here makes teardown happen synchronously on
    // pop; the `sessionClose` in `gFFI.close()` becomes a no-op once removed.
    unawaited(bind.sessionClose(sessionId: sessionId));
    // https://github.com/flutter/flutter/issues/64935
    super.dispose();
    gFFI.dialogManager.hideMobileActionsOverlay(store: false);
    gFFI.inputModel.listenToMouse(false);
    gFFI.imageModel.disposeImage();
    gFFI.cursorModel.disposeImages();
    await gFFI.invokeMethod("enable_soft_keyboard", true);
    _mobileFocusNode.dispose();
    _physicalFocusNode.dispose();
    clearWaylandKeyboardPromptSuppressedForConnection(sessionId.toString());
    _waylandKeyboardGateWorker?.dispose();
    inputModel.keyboardInputAllowed = true;
    await gFFI.close();
    _timer?.cancel();
    _iosKeyboardWorkaroundTimer?.cancel();
    gFFI.dialogManager.dismissAll();
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    WakelockManager.disable(_uniqueKey);
    await keyboardSubscription.cancel();
    removeSharedStates(widget.id);
    // `on_voice_call_closed` should be called when the connection is ended.
    // The inner logic of `on_voice_call_closed` will check if the voice call is active.
    // Only one client is considered here for now.
    gFFI.chatModel.onVoiceCallClosed("End connetion");
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    gFFI.ffiModel.onReconnectLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      trySyncClipboard();
    }
  }

  // For client side
  // When swithing from other app to this app, try to sync clipboard.
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

    // Ensure soft keyboard is not active before user confirms.
    _showEdit = false;
    gFFI.invokeMethod("enable_soft_keyboard", false);
    _mobileFocusNode.unfocus();
    _physicalFocusNode.requestFocus();
    setState(() {});
  }

  // to-do: It should be better to use transparent color instead of the bgColor.
  // But for now, the transparent color will cause the canvas to be white.
  // I'm sure that the white color is caused by the Overlay widget in BlockableOverlay.
  // But I don't know why and how to fix it.
  Widget emptyOverlay(Color bgColor) => BlockableOverlay(
    /// the Overlay key will be set with _blockableOverlayState in BlockableOverlay
    /// see override build() in [BlockableOverlay]
    state: _blockableOverlayState,
    underlying: Container(color: bgColor),
  );

  void onSoftKeyboardChanged(bool visible) {
    if (!visible) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      // [pi.version.isNotEmpty] -> check ready or not, avoid login without soft-keyboard
      if (gFFI.chatModel.chatWindowOverlayEntry == null &&
          gFFI.ffiModel.pi.version.isNotEmpty) {
        gFFI.invokeMethod("enable_soft_keyboard", false);
      }

      // Workaround for iOS: physical keyboard input fails after virtual keyboard is hidden
      // https://github.com/flutter/flutter/issues/39900
      // https://github.com/rustdesk/rustdesk/discussions/11843#discussioncomment-13499698 - Virtual keyboard issue
      if (isIOS) {
        _iosKeyboardWorkaroundTimer?.cancel();
        _iosKeyboardWorkaroundTimer = Timer(Duration(milliseconds: 100), () {
          if (!mounted) return;
          _physicalFocusNode.unfocus();
          _iosKeyboardWorkaroundTimer = Timer(Duration(milliseconds: 50), () {
            if (!mounted) return;
            _physicalFocusNode.requestFocus();
          });
        });
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
    // update for Scaffold
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

    // get common prefix of subNewValue and subOldValue
    var common = 0;
    for (
      ;
      common < subOldValue.length &&
          common < subNewValue.length &&
          subNewValue[common] == subOldValue[common];
      ++common
    ) {}

    // get newStr from subNewValue
    var newStr = "";
    if (subNewValue.length > common) {
      newStr = subNewValue.substring(common);
    }

    // Set the value to the old value and early return if is still composing. (1 && 2)
    // 1. The composing range is valid
    // 2. The new string is shorter than the composing range.
    if (_textController.value.isComposingRangeValid) {
      final composingLength =
          _textController.value.composing.end -
          _textController.value.composing.start;
      if (composingLength > newStr.length) {
        _value = oldValue;
        return;
      }
    }

    // Delete the different part in the old value.
    for (i = 0; i < subOldValue.length - common; ++i) {
      inputModel.inputKey('VK_BACK');
    }

    // Input the new string.
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
      // clipboard
      oldValue = '';
    }
    if (newValue.length == oldValue.length) {
      // ?
    } else if (newValue.length < oldValue.length) {
      final char = 'VK_BACK';
      inputModel.inputKey(char);
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
          // can not only input content[0], because when input ], [ are also auo insert, which cause ] never be input
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

  // handle mobile virtual keyboard
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
    // destroy first, so that our _value trick can work
    _value = initText;
    _textController.text = _value;
    setState(() => _showEdit = false);
    _timer?.cancel();
    _timer = Timer(kMobileDelaySoftKeyboard, () {
      // show now, and sleep a while to requestFocus to
      // make sure edit ready, so that keyboard won't show/hide/show/hide happen
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

    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) clientClose(sessionId, gFFI);
      },
      child: Scaffold(
        // workaround for https://github.com/rustdesk/rustdesk/issues/3131
        floatingActionButtonLocation: keyboardIsVisible
            ? FABLocation(FloatingActionButtonLocation.endFloat, 0, -35)
            : null,
        floatingActionButton: !showActionButton
            ? null
            : Tooltip(
                message: translate('Close'),
                child: FloatingActionButton.small(
                  foregroundColor: scheme.onSecondaryContainer,
                  backgroundColor: scheme.secondaryContainer,
                  child: const Icon(Icons.expand_more_rounded),
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
                      return Offstage();
                    }(),
              _bottomWidget(),
              gFFI.ffiModel.pi.isSet.isFalse
                  ? emptyOverlay(MyTheme.canvasColor)
                  : Offstage(),
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
                                    Timer(
                                      const Duration(milliseconds: 200),
                                      () {
                                        gFFI.dialogManager
                                            .resetMobileActionsOverlay(
                                              ffi: gFFI,
                                            );
                                        _currentOrientation = orientation;
                                        gFFI.canvasModel.updateViewStyle();
                                      },
                                    );
                                  }
                                  return Container(
                                    color: MyTheme.canvasColor,
                                    child: inputModel.isPhysicalMouse.value
                                        ? getBodyForMobile()
                                        : RawTouchGestureDetectorRegion(
                                            child: getBodyForMobile(),
                                            ffi: gFFI,
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
      // Disable RawKeyFocusScope before the connecting is established.
      // The "Delete" key on the soft keyboard may be grabbed when inputting the password dialog.
      child: gFFI.ffiModel.pi.isSet.isTrue
          ? RawKeyFocusScope(
              focusNode: _physicalFocusNode,
              inputModel: inputModel,
              child: child,
            )
          : child,
    );
  }

  Widget getBottomAppBar() {
    final ffiModel = Provider.of<FfiModel>(context);
    final canInput =
        !isWebDesktop && ffiModel.effectiveControlPolicy.canControlRemote;
    final actions = <Widget>[
      _RemoteDockButton(
        icon: Icons.close_rounded,
        label: translate('Close'),
        destructive: true,
        onPressed: () => clientClose(sessionId, gFFI),
      ),
      _RemoteDockButton(
        icon: Icons.display_settings_outlined,
        label: translate('Display'),
        onPressed: () {
          setState(() => _showEdit = false);
          showOptions(context, widget.id, gFFI.dialogManager);
        },
      ),
      if (canInput)
        _RemoteDockButton(
          icon: Icons.keyboard_alt_outlined,
          label: translate('Keyboard'),
          onPressed: openKeyboard,
        ),
      if (canInput)
        _RemoteDockButton(
          icon: ffiModel.isPeerAndroid
              ? Icons.smartphone_rounded
              : ffiModel.touchMode
              ? Icons.touch_app_outlined
              : Icons.mouse_outlined,
          label: translate(ffiModel.isPeerAndroid ? 'Actions' : 'Input'),
          onPressed: ffiModel.isPeerAndroid
              ? () => gFFI.dialogManager.toggleMobileActionsOverlay(ffi: gFFI)
              : () => setState(() => _showGestureHelp = true),
        ),
      if (!isWeb)
        FutureBuilder<dynamic>(
          future: gFFI.invokeMethod("get_value", "KEY_IS_SUPPORT_VOICE_CALL"),
          builder: (context, snapshot) {
            final supportsVoice = snapshot.data == true;
            return _RemoteDockButton(
              icon: Icons.forum_outlined,
              label: translate('Chat'),
              onPressed: () => isAndroid && supportsVoice
                  ? showChatOptions(widget.id)
                  : onPressedTextChat(widget.id),
            );
          },
        ),
      _RemoteDockButton(
        icon: Icons.more_horiz_rounded,
        label: translate('More'),
        onPressed: () {
          setState(() => _showEdit = false);
          showActions(widget.id);
        },
      ),
    ];
    return Material(
      elevation: 12,
      color: Theme.of(context).colorScheme.surface,
      shape: Border(
        top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: SizedBox(
              height: 64,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final action in actions) Expanded(child: action),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool get showCursorPaint =>
      !gFFI.ffiModel.isPeerAndroid &&
      !gFFI.canvasModel.cursorEmbedded &&
      !gFFI.inputModel.relativeMouseMode.value;

  Widget getBodyForMobile() {
    final keyboardIsVisible = keyboardVisibilityController.isVisible;
    return Container(
      color: MyTheme.canvasColor,
      child: Stack(
        children: () {
          final paints = [
            ImagePaint(ffiModel: gFFI.ffiModel),
            Positioned(
              top: 10,
              right: 10,
              child: QualityMonitor(gFFI.qualityMonitorModel),
            ),
            KeyHelpTools(
              keyboardIsVisible: keyboardIsVisible,
              showGestureHelp: _showGestureHelp,
            ),
            SizedBox(
              width: 0,
              height: 0,
              child: !_showEdit
                  ? Container()
                  : TextFormField(
                      textInputAction: TextInputAction.newline,
                      autocorrect: false,
                      // Flutter 3.16.9 Android.
                      // `enableSuggestions` causes secure keyboard to be shown.
                      // https://github.com/flutter/flutter/issues/139143
                      // https://github.com/flutter/flutter/issues/146540
                      // enableSuggestions: false,
                      autofocus: true,
                      focusNode: _mobileFocusNode,
                      maxLines: null,
                      controller: _textController,
                      // trick way to make backspace work always
                      keyboardType: TextInputType.multiline,
                      // `onChanged` may be called depending on the input method if this widget is wrapped in
                      // `Focus(onKeyEvent: ..., child: ...)`
                      // For `Backspace` button in the soft keyboard:
                      // en/fr input method:
                      //      1. The button will not trigger `onKeyEvent` if the text field is not empty.
                      //      2. The button will trigger `onKeyEvent` if the text field is empty.
                      // ko/zh/ja input method: the button will trigger `onKeyEvent`
                      //                     and the event will not popup if `KeyEventResult.handled` is returned.
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
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        Widget section(String title, List<TTextMenu> actions) {
          final visibleActions = actions.where((action) => !action.divider);
          if (visibleActions.isEmpty) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                child: Text(
                  title,
                  style: Theme.of(sheetContext).textTheme.labelLarge?.copyWith(
                    color: AppVisual.subduedText(sheetContext),
                  ),
                ),
              ),
              ...visibleActions.map(
                (action) => ListTile(
                  title: action.getChild(),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    action.onPressed?.call();
                  },
                ),
              ),
            ],
          );
        }

        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              section(translate('Device actions'), mobileActionMenus),
              section(translate('Session actions'), menus),
              const SizedBox(height: 12),
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

    TTextMenu makeTextMenu(
      String label,
      Widget icon,
      VoidCallback onPressed, {
      TextStyle? labelStyle,
    }) => TTextMenu(
      child: Text(translate(label), style: labelStyle),
      trailingIcon: Transform.scale(
        scale: (isDesktop || isWebDesktop) ? 0.8 : 1,
        child: IgnorePointer(child: IconButton(onPressed: null, icon: icon)),
      ),
      onPressed: onPressed,
    );

    final isInVoice = [
      VoiceCallStatus.waitingForResponse,
      VoiceCallStatus.connected,
    ].contains(gFFI.chatModel.voiceCallStatus.value);
    final menus = [
      makeTextMenu(
        'Text chat',
        Icon(Icons.message, color: MyTheme.accent),
        () => onPressedTextChat(widget.id),
      ),
      isInVoice
          ? makeTextMenu(
              'End voice call',
              SvgPicture.asset(
                'assets/call_wait.svg',
                colorFilter: ColorFilter.mode(
                  Colors.redAccent,
                  BlendMode.srcIn,
                ),
              ),
              onPressEndVoiceCall,
              labelStyle: TextStyle(color: Colors.redAccent),
            )
          : makeTextMenu(
              'Voice call',
              SvgPicture.asset(
                'assets/call_wait.svg',
                colorFilter: ColorFilter.mode(MyTheme.accent, BlendMode.srcIn),
              ),
              onPressVoiceCall,
            ),
    ];

    final menuItems = menus
        .asMap()
        .entries
        .map((e) => PopupMenuItem<int>(child: e.value.getChild(), value: e.key))
        .toList();
    if (!mounted) return;
    final size = MediaQuery.sizeOf(context);
    const x = 120.0;
    final y = size.height;
    final index = await showMenu(
      context: context,
      position: RelativeRect.fromLTRB(x, y, x, y),
      items: menuItems,
      elevation: 8,
    );
    if (index != null && index < menus.length) {
      menus[index].onPressed?.call();
    }
  }

  /// aka changeTouchMode
  BottomAppBar getGestureHelp() {
    return BottomAppBar(
      child: SingleChildScrollView(
        controller: ScrollController(),
        padding: EdgeInsets.symmetric(vertical: 10),
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
    );
  }

  // * Currently mobile does not enable map mode
  // void changePhysicalKeyboardInputMode() async {
  //   var current = await bind.sessionGetKeyboardMode(id: widget.id) ?? "legacy";
  //   gFFI.dialogManager.show((setState, close) {
  //     void setMode(String? v) async {
  //       await bind.sessionSetKeyboardMode(id: widget.id, value: v ?? "");
  //       setState(() => current = v ?? '');
  //       Future.delayed(Duration(milliseconds: 300), close);
  //     }
  //
  //     return CustomAlertDialog(
  //         title: Text(translate('Physical Keyboard Input Mode')),
  //         content: Column(mainAxisSize: MainAxisSize.min, children: [
  //           getRadio('Legacy mode', 'legacy', current, setMode),
  //           getRadio('Map mode', 'map', current, setMode),
  //         ]));
  //   }, clickMaskDismiss: true);
  // }
}

class _RemoteDockButton extends StatelessWidget {
  const _RemoteDockButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = destructive ? scheme.error : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 22, color: onPressed == null ? null : color),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: onPressed == null ? null : color,
                    fontWeight: FontWeight.w600,
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

class KeyHelpTools extends StatefulWidget {
  final bool keyboardIsVisible;
  final bool showGestureHelp;

  /// need to show by external request, etc [keyboardIsVisible] or [changeTouchMode]
  bool get requestShow => keyboardIsVisible || showGestureHelp;

  const KeyHelpTools({
    super.key,
    required this.keyboardIsVisible,
    required this.showGestureHelp,
  });

  @override
  State<KeyHelpTools> createState() => _KeyHelpToolsState();
}

class _KeyHelpToolsState extends State<KeyHelpTools> {
  var _more = true;
  var _fn = false;
  var _pin = false;
  final _keyboardVisibilityController = KeyboardVisibilityController();
  final _key = GlobalKey();

  InputModel get inputModel => gFFI.inputModel;

  Widget wrap(
    String text,
    void Function() onPressed, {
    bool? active,
    IconData? icon,
    String? tooltip,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final selected = active == true;
    final label = tooltip ?? text.trim();
    final foreground = selected
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;
    final button = TextButton(
      style: TextButton.styleFrom(
        foregroundColor: foreground,
        backgroundColor: selected
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        tapTargetSize: MaterialTapTargetSize.padded,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      onPressed: onPressed,
      child: icon != null
          ? Icon(icon, size: 20)
          : Text(
              translate(text.trim()),
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: label.isEmpty ? null : translate(label),
      child: label.isEmpty
          ? button
          : Tooltip(message: translate(label), child: button),
    );
  }

  void _updateRect() {
    final renderObject = _key.currentContext?.findRenderObject();
    if (renderObject == null) {
      return;
    }
    if (renderObject is RenderBox) {
      final size = renderObject.size;
      final pos = renderObject.localToGlobal(Offset.zero);
      gFFI.cursorModel.keyHelpToolsVisibilityChanged(
        Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height),
        widget.keyboardIsVisible,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasModifierOn =
        inputModel.ctrl ||
        inputModel.alt ||
        inputModel.shift ||
        inputModel.command;

    if (!_pin && !hasModifierOn && !widget.requestShow) {
      gFFI.cursorModel.keyHelpToolsVisibilityChanged(
        null,
        widget.keyboardIsVisible,
      );
      return Offstage();
    }
    final size = MediaQuery.of(context).size;

    final pi = gFFI.ffiModel.pi;
    final isMac = pi.platform == kPeerPlatformMacOS;
    final isWin = pi.platform == kPeerPlatformWindows;
    final isLinux = pi.platform == kPeerPlatformLinux;
    final modifiers = <Widget>[
      wrap('Ctrl ', () {
        setState(() => inputModel.ctrl = !inputModel.ctrl);
      }, active: inputModel.ctrl),
      wrap(' Alt ', () {
        setState(() => inputModel.alt = !inputModel.alt);
      }, active: inputModel.alt),
      wrap('Shift', () {
        setState(() => inputModel.shift = !inputModel.shift);
      }, active: inputModel.shift),
      wrap(isMac ? ' Cmd ' : ' Win ', () {
        setState(() => inputModel.command = !inputModel.command);
      }, active: inputModel.command),
    ];
    final keys = <Widget>[
      wrap(
        ' Fn ',
        () => setState(() {
          _fn = !_fn;
          if (_fn) {
            _more = false;
          }
        }),
        active: _fn,
      ),
      wrap(
        '',
        () => setState(() => _pin = !_pin),
        active: _pin,
        icon: Icons.push_pin,
        tooltip: 'Pin',
      ),
      wrap(
        ' ... ',
        () => setState(() {
          _more = !_more;
          if (_more) {
            _fn = false;
          }
        }),
        active: _more,
      ),
    ];
    final lineBreak = SizedBox(width: size.width, height: 0);
    final fn = <Widget>[lineBreak];
    for (var i = 1; i <= 12; ++i) {
      final name = 'F$i';
      fn.add(
        wrap(name, () {
          inputModel.inputKey('VK_$name');
        }),
      );
    }
    final more = <Widget>[
      lineBreak,
      wrap('Esc', () {
        inputModel.inputKey('VK_ESCAPE');
      }),
      wrap('Tab', () {
        inputModel.inputKey('VK_TAB');
      }),
      wrap('Home', () {
        inputModel.inputKey('VK_HOME');
      }),
      wrap('End', () {
        inputModel.inputKey('VK_END');
      }),
      wrap('Ins', () {
        inputModel.inputKey('VK_INSERT');
      }),
      wrap('Del', () {
        inputModel.inputKey('VK_DELETE');
      }),
      wrap('PgUp', () {
        inputModel.inputKey('VK_PRIOR');
      }),
      wrap('PgDn', () {
        inputModel.inputKey('VK_NEXT');
      }),
      // to-do: support PrtScr on Mac
      if (isWin || isLinux)
        wrap('PrtScr', () {
          inputModel.inputKey('VK_SNAPSHOT');
        }),
      if (isWin || isLinux)
        wrap('ScrollLock', () {
          inputModel.inputKey('VK_SCROLL');
        }),
      if (isWin || isLinux)
        wrap('Pause', () {
          inputModel.inputKey('VK_PAUSE');
        }),
      if (isWin || isLinux)
        // Maybe it's better to call it "Menu"
        // https://en.wikipedia.org/wiki/Menu_key
        wrap('Menu', () {
          inputModel.inputKey('Apps');
        }),
      wrap('Enter', () {
        inputModel.inputKey('VK_ENTER');
      }),
      lineBreak,
      wrap(
        '',
        () {
          inputModel.inputKey('VK_LEFT');
        },
        icon: Icons.keyboard_arrow_left,
        tooltip: 'Left',
      ),
      wrap(
        '',
        () {
          inputModel.inputKey('VK_UP');
        },
        icon: Icons.keyboard_arrow_up,
        tooltip: 'Up',
      ),
      wrap(
        '',
        () {
          inputModel.inputKey('VK_DOWN');
        },
        icon: Icons.keyboard_arrow_down,
        tooltip: 'Down',
      ),
      wrap(
        '',
        () {
          inputModel.inputKey('VK_RIGHT');
        },
        icon: Icons.keyboard_arrow_right,
        tooltip: 'Right',
      ),
      wrap(isMac ? 'Cmd+C' : 'Ctrl+C', () {
        sendPrompt(isMac, 'VK_C');
      }),
      wrap(isMac ? 'Cmd+V' : 'Ctrl+V', () {
        sendPrompt(isMac, 'VK_V');
      }),
      wrap(isMac ? 'Cmd+S' : 'Ctrl+S', () {
        sendPrompt(isMac, 'VK_S');
      }),
    ];
    final space = size.width > 320 ? 4.0 : 2.0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateRect();
    });
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: _key,
      elevation: 10,
      color: scheme.surface.withValues(alpha: 0.96),
      shape: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            10,
            _keyboardVisibilityController.isVisible ? 10 : 8,
            10,
            10,
          ),
          child: Wrap(
            spacing: space,
            runSpacing: space,
            children:
                <Widget>[lineBreak] +
                modifiers +
                keys +
                (_fn ? fn : []) +
                (_more ? more : []),
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
      return Offstage();
    }

    final minSize = 12.0;
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
  var displays = <Widget>[];
  final pi = gFFI.ffiModel.pi;
  final image = gFFI.ffiModel.getConnectionImageText();
  if (image != null) {
    displays.add(Padding(padding: const EdgeInsets.only(top: 8), child: image));
  }
  final privacyModeState = PrivacyModeState.find(id);
  if (pi.displays.length > 1 &&
      pi.currentDisplay != kAllDisplayValue &&
      (privacyModeState.isEmpty ||
          allowDisplaySwitchInPrivacyMode(pi, privacyModeState.value))) {
    final cur = pi.currentDisplay;
    final children = <Widget>[];
    for (var i = 0; i < pi.displays.length; ++i) {
      children.add(
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 56, minHeight: 44),
          child: ChoiceChip(
            selected: i == cur,
            avatar: const Icon(Icons.monitor_rounded, size: 18),
            label: Text('${i + 1}'),
            onSelected: i == cur
                ? null
                : (_) {
                    openMonitorInTheSameTab(i, gFFI, pi);
                    gFFI.dialogManager.dismissAll();
                  },
          ),
        ),
      );
    }
    displays.add(
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: children,
        ),
      ),
    );
  }

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

  await dialogManager.show(
    (setState, close, context) {
      final viewStyle =
          (viewStyleRadios.isNotEmpty ? viewStyleRadios[0].groupValue : '').obs;
      final imageQuality =
          (imageQualityRadios.isNotEmpty
                  ? imageQualityRadios[0].groupValue
                  : '')
              .obs;
      final codec =
          (codecRadios.isNotEmpty ? codecRadios[0].groupValue : '').obs;
      final rxCursorToggleValues = cursorToggles
          .map((e) => e.value.obs)
          .toList();
      final rxToggleValues = displayToggles.map((e) => e.value.obs).toList();
      final scheme = Theme.of(context).colorScheme;

      Widget section(String title, IconData icon, List<Widget> children) {
        if (children.isEmpty) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(icon, size: 20, color: scheme.primary),
                  const SizedBox(width: 10),
                  Text(
                    translate(title),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        );
      }

      Widget radioSection(
        String title,
        IconData icon,
        List<TRadioMenu<String>> entries,
        RxString selected, {
        Widget? footer,
      }) {
        if (entries.isEmpty) return const SizedBox.shrink();
        return Obx(
          () => section(title, icon, [
            RadioGroup<String>(
              groupValue: selected.value,
              onChanged: (value) {
                if (value == null) return;
                for (final entry in entries) {
                  if (entry.value == value) {
                    entry.onChanged?.call(value);
                    selected.value = value;
                    break;
                  }
                }
              },
              child: Column(
                children: [
                  for (final entry in entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: RadioListTile<String>(
                        value: entry.value,
                        enabled: entry.onChanged != null,
                        title: entry.child,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                        ),
                        minTileHeight: 52,
                        tileColor: scheme.surfaceContainer,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            ?footer,
          ]),
        );
      }

      Widget toggleTile(TToggleMenu entry, RxBool value, IconData icon) {
        return Obx(
          () => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: SwitchListTile(
              value: value.value,
              onChanged: entry.onChanged == null
                  ? null
                  : (next) {
                      entry.onChanged?.call(next);
                      value.value = next;
                    },
              secondary: Icon(icon, color: scheme.onSurfaceVariant),
              title: entry.child,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10),
              minTileHeight: 52,
              tileColor: scheme.surfaceContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        );
      }

      final popupDialogMenus = <Widget>[];
      final resolution = getResolutionMenu(gFFI, id);
      if (resolution != null) {
        popupDialogMenus.add(
          ListTile(
            leading: const Icon(Icons.aspect_ratio_rounded),
            title: resolution.child,
            trailing: const Icon(Icons.chevron_right_rounded),
            tileColor: scheme.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            onTap: () {
              close();
              resolution.onPressed?.call();
            },
          ),
        );
      }
      final virtualDisplayMenu = getVirtualDisplayMenu(gFFI, id);
      if (virtualDisplayMenu != null) {
        popupDialogMenus.add(
          Padding(
            padding: EdgeInsets.only(top: popupDialogMenus.isEmpty ? 0 : 6),
            child: ListTile(
              leading: const Icon(Icons.add_to_queue_rounded),
              title: virtualDisplayMenu.child,
              trailing: const Icon(Icons.chevron_right_rounded),
              tileColor: scheme.surfaceContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              onTap: () {
                close();
                virtualDisplayMenu.onPressed?.call();
              },
            ),
          ),
        );
      }

      final generalTiles = <Widget>[
        for (var i = 0; i < cursorToggles.length; i++)
          toggleTile(
            cursorToggles[i],
            rxCursorToggleValues[i],
            Icons.mouse_outlined,
          ),
        for (var i = 0; i < displayToggles.length; i++)
          toggleTile(
            displayToggles[i],
            rxToggleValues[i],
            Icons.display_settings_outlined,
          ),
        if (privacyModeList.length > 1)
          ListTile(
            leading: const Icon(Icons.visibility_off_outlined),
            title: Text(translate('Privacy mode')),
            trailing: const Icon(Icons.chevron_right_rounded),
            tileColor: scheme.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            onTap: () => setPrivacyModeDialog(
              dialogManager,
              privacyModeList,
              privacyModeState,
            ),
          ),
      ];

      return CustomAlertDialog(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                Icons.display_settings_rounded,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              translate('Display Settings'),
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        contentBoxConstraints: const BoxConstraints(maxWidth: 480),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (displays.isNotEmpty)
              section('Display', Icons.monitor_rounded, displays),
            radioSection(
              'View Mode',
              Icons.fit_screen_rounded,
              viewStyleRadios,
              viewStyle,
              footer: Obx(
                () => viewStyle.value == kRemoteViewStyleCustom
                    ? MobileCustomScaleControls(ffi: gFFI)
                    : const SizedBox.shrink(),
              ),
            ),
            radioSection(
              'Image Quality',
              Icons.high_quality_outlined,
              imageQualityRadios,
              imageQuality,
            ),
            radioSection(
              'Codec',
              Icons.video_settings_outlined,
              codecRadios,
              codec,
            ),
            if (popupDialogMenus.isNotEmpty)
              section('Display', Icons.aspect_ratio_rounded, popupDialogMenus),
            if (generalTiles.isNotEmpty)
              section('General', Icons.tune_rounded, generalTiles),
          ],
        ),
        actions: [
          SizedBox(
            width: 132,
            child: dialogButton(
              'OK',
              icon: const Icon(Icons.done_rounded),
              onPressed: close,
            ),
          ),
        ],
        onSubmit: close,
        onCancel: close,
      );
    },
    clickMaskDismiss: true,
    backDismiss: true,
  );
  _disableAndroidSoftKeyboard();
}

TTextMenu? getVirtualDisplayMenu(FFI ffi, String id) {
  if (!showVirtualDisplayMenu(ffi)) {
    return null;
  }
  return TTextMenu(
    child: Text(translate("Virtual display")),
    onPressed: () {
      ffi.dialogManager
          .show(
            (setState, close, context) {
              final children = getVirtualDisplayMenuChildren(ffi, id, close);
              return CustomAlertDialog(
                title: Text(translate('Virtual display')),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              );
            },
            clickMaskDismiss: true,
            backDismiss: true,
          )
          .then((value) {
            _disableAndroidSoftKeyboard();
          });
    },
  );
}

TTextMenu? getResolutionMenu(FFI ffi, String id) {
  final ffiModel = ffi.ffiModel;
  final pi = ffiModel.pi;
  final resolutions = pi.resolutions;
  final display = pi.tryGetDisplayIfNotAllDisplay(display: pi.currentDisplay);

  final visible =
      ffiModel.keyboard && (resolutions.length > 1) && display != null;
  if (!visible) return null;

  return TTextMenu(
    child: Text(translate("Resolution")),
    onPressed: () {
      ffi.dialogManager
          .show(
            (setState, close, context) {
              final children = resolutions
                  .map(
                    (e) => getRadio<String>(
                      Text('${e.width}x${e.height}'),
                      '${e.width}x${e.height}',
                      '${display.width}x${display.height}',
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
                title: Text(translate('Resolution')),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              );
            },
            clickMaskDismiss: true,
            backDismiss: true,
          )
          .then((value) {
            _disableAndroidSoftKeyboard();
          });
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
