import 'dart:async';
import 'dart:ui' as ui;

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common/shared_state.dart';
import 'package:camellia_remote_app/common/widgets/toolbar.dart';
import 'package:camellia_remote_app/consts.dart';
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
import '../widgets/custom_scale_widget.dart';

final initText = '1' * 1024;

void _disableAndroidSoftKeyboard({bool? isKeyboardVisible}) {
  if (isAndroid) {
    if (isKeyboardVisible != true) {
      gFFI.invokeMethod("enable_soft_keyboard", false);
    }
  }
}

class ViewCameraPage extends StatefulWidget {
  const ViewCameraPage({
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
  State<ViewCameraPage> createState() => _ViewCameraPageState();
}

class _ViewCameraPageState extends State<ViewCameraPage>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _showBar = !isWebDesktop;
  bool _showGestureHelp = false;
  Orientation? _currentOrientation;
  Timer? _orientationTimer;
  double _viewInsetsBottom = 0;
  final _uniqueKey = UniqueKey();
  late final int _generation;
  bool _teardownCalled = false;
  Timer? _timerDidChangeMetrics;

  final _blockableOverlayState = BlockableOverlayState();

  final keyboardVisibilityController = KeyboardVisibilityController();
  final FocusNode _mobileFocusNode = FocusNode();
  final FocusNode _physicalFocusNode = FocusNode();
  var _showEdit = false;

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
      isViewCamera: true,
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
    _mobileFocusNode.dispose();
    _physicalFocusNode.dispose();
    _textController.dispose();
    _timer?.cancel();
    _timer = null;
    _orientationTimer?.cancel();
    _orientationTimer = null;
    _timerDidChangeMetrics?.cancel();
    _timerDidChangeMetrics = null;
    gFFI.dialogManager.dismissAll();

    if (!_teardownCalled) {
      unawaited(teardown());
    }

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {}

  @override
  void didChangeMetrics() {
    if (gFFI.cursorModel.lastKeyboardIsVisible &&
        gFFI.canvasModel.isMobileCanvasChanged) {
      return;
    }

    final newBottom =
        MediaQueryData.fromView(ui.PlatformDispatcher.instance.views.first)
            .viewInsets
            .bottom;
    _timerDidChangeMetrics?.cancel();
    _timerDidChangeMetrics = Timer(const Duration(milliseconds: 100), () async {
      if (newBottom != _viewInsetsBottom) {
        gFFI.canvasModel.mobileFocusCanvasCursor();
        _viewInsetsBottom = newBottom;
      }
    });
  }

  Widget emptyOverlay(Color bgColor) => BlockableOverlay(
    state: _blockableOverlayState,
    underlying: Container(color: bgColor),
  );

  Widget _bottomWidget() {
    if (_showGestureHelp) {
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
    return gFFI.ffiModel.pi.displays.isNotEmpty
        ? getBottomAppBar()
        : const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final keyboardIsVisible =
        keyboardVisibilityController.isVisible && _showEdit;
    final showDismissButton = keyboardIsVisible || _showGestureHelp;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        clientClose(sessionId, gFFI);
      },
      child: Scaffold(
        floatingActionButtonLocation: keyboardIsVisible
            ? FABLocation(FloatingActionButtonLocation.endFloat, 0, -35)
            : null,
        floatingActionButton: !showDismissButton
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
                      child: SafeArea(
                        child: OrientationBuilder(
                          builder: (ctx, orientation) {
                            if (_currentOrientation != orientation) {
                              _currentOrientation = orientation;
                              _orientationTimer?.cancel();
                              _orientationTimer = Timer(
                                const Duration(milliseconds: 200),
                                () {
                                  if (!mounted) return;
                                  gFFI.dialogManager.resetMobileActionsOverlay(
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
                                      isCamera: true,
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
    return CameraRawPointerMouseRegion(
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

  void _showCameraSwitcherSheet() {
    final pi = gFFI.ffiModel.pi;
    if (pi.displays.length <= 1) return;
    showGlassBottomSheet<void>(
      context: context,
      title: translate('Switch Camera'),
      builder: (sheetCtx) {
        final theme = Theme.of(sheetCtx);
        final dark = theme.brightness == Brightness.dark;
        final accent = dark
            ? theme.colorScheme.secondary
            : theme.colorScheme.primary;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < pi.displays.length; i++)
                ListTile(
                  dense: true,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(CamelliaRadius.control),
                  ),
                  leading: Icon(
                    CamelliaIcons.camera,
                    size: 19,
                    color: i == pi.currentDisplay
                        ? accent
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(
                    '${translate('View camera')} ${i + 1}',
                    style: CamelliaTypography.tabular(
                      theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: i == pi.currentDisplay
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: i == pi.currentDisplay ? accent : null,
                      ),
                    ),
                  ),
                  trailing: Icon(
                    CamelliaIcons.check,
                    size: 18,
                    color: i == pi.currentDisplay ? accent : Colors.transparent,
                  ),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    Navigator.of(sheetCtx).pop();
                    if (i != pi.currentDisplay) {
                      openMonitorInTheSameTab(i, gFFI, pi);
                    }
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Widget getBottomAppBar() {
    final theme = Theme.of(context);
    final pi = gFFI.ffiModel.pi;
    final hasMultipleCameras =
        pi.displays.length > 1 && pi.currentDisplay != kAllDisplayValue;

    if (!_showBar) {
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
                  setState(() => _showBar = true);
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      CamelliaIcons.camera,
                      size: 15,
                      color: theme.colorScheme.onSurface,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      translate('Controls'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.keyboard_arrow_up_rounded,
                      size: 17,
                      color: theme.colorScheme.onSurface,
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
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Obx(
            () => gFFI.ffiModel.waitForFirstImage.isTrue
                ? const SizedBox.shrink()
                : GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _showBar = false);
                    },
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.28,
                          ),
                          borderRadius: BorderRadius.circular(
                            CamelliaRadius.pill,
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: GlassSurface(
                layer: CamelliaGlassLayer.modal,
                elevated: true,
                borderRadius: BorderRadius.circular(CamelliaRadius.sheet),
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hasMultipleCameras) ...[
                      _CameraDockButton(
                        icon: Icons.cameraswitch_rounded,
                        label: '${pi.currentDisplay + 1}/${pi.displays.length}',
                        tabularLabel: true,
                        onPressed: _showCameraSwitcherSheet,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: _CameraDockButton(
                        icon: CamelliaIcons.display,
                        label: translate('Display'),
                        onPressed: () {
                          HapticFeedback.selectionClick();
                          setState(() => _showEdit = false);
                          showOptions(context, widget.id, gFFI.dialogManager);
                        },
                      ),
                    ),
                    if (!isWeb)
                      Expanded(
                        child: futureBuilder(
                          future: gFFI.invokeMethod(
                            "get_value",
                            "KEY_IS_SUPPORT_VOICE_CALL",
                          ),
                          hasData: (isSupportVoiceCall) => Obx(() {
                            final isInVoice = [
                              VoiceCallStatus.waitingForResponse,
                              VoiceCallStatus.connected,
                            ].contains(gFFI.chatModel.voiceCallStatus.value);
                            return _CameraDockButton(
                              icon: isInVoice
                                  ? CamelliaIcons.voiceCall
                                  : ((isAndroid && isSupportVoiceCall) ||
                                        isInVoice)
                                  ? CamelliaIcons.chat
                                  : Icons.message_rounded,
                              label: translate('Chat'),
                              active: isInVoice,
                              onPressed: () {
                                HapticFeedback.selectionClick();
                                if ((isAndroid && isSupportVoiceCall) ||
                                    isInVoice) {
                                  showChatOptions(widget.id);
                                } else {
                                  onPressedTextChat(widget.id);
                                }
                              },
                            );
                          }),
                        ),
                      ),
                    Expanded(
                      child: _CameraDockButton(
                        icon: CamelliaIcons.more,
                        label: translate('More'),
                        onPressed: () {
                          HapticFeedback.selectionClick();
                          setState(() => _showEdit = false);
                          showActions(widget.id);
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    GlassButton(
                      variant: GlassButtonVariant.danger,
                      minHeight: 40,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      borderRadius: BorderRadius.circular(CamelliaRadius.pill),
                      icon: const Icon(CamelliaIcons.close, size: 17),
                      onPressed: () {
                        HapticFeedback.mediumImpact();
                        clientClose(sessionId, gFFI);
                      },
                      child: Text(translate('Disconnect')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget getBodyForMobile() {
    final topInset = MediaQuery.paddingOf(context).top;
    return Container(
      color: MyTheme.canvasColor,
      child: Stack(
        children: () {
          final paints = [
            const ImagePaint(),
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
                      onChanged: null,
                    ).workaroundFreezeLinuxMint(),
            ),
          ];
          return paints;
        }(),
      ),
    );
  }

  Widget getBodyForDesktopWithListener() {
    var paints = <Widget>[const ImagePaint()];
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
      builder: (sheetCtx) {
        final theme = Theme.of(sheetCtx);
        final dark = theme.brightness == Brightness.dark;
        final tokens =
            theme.extension<AppDesignTokens>() ?? MyTheme.tokens(sheetCtx);

        Widget section(String title, List<TTextMenu> actions) {
          final visible = actions
              .where((a) => !a.divider)
              .toList(growable: false);
          if (visible.isEmpty) return const SizedBox.shrink();
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
                      for (var i = 0; i < visible.length; i++) ...[
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
                          title: visible[i].getChild(),
                          trailing: Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: tokens.muted,
                          ),
                          onTap: () {
                            HapticFeedback.selectionClick();
                            Navigator.of(sheetCtx).pop();
                            visible[i].onPressed?.call();
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
            maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.72,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
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
                      Navigator.of(sheetCtx).pop();
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

    final supportsVoiceCall =
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
              else if (isAndroid && supportsVoiceCall)
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
}

class _CameraDockButton extends StatelessWidget {
  const _CameraDockButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.active = false,
    this.tabularLabel = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool active;
  final bool tabularLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    final color = active ? accent : theme.colorScheme.onSurfaceVariant;
    final baseStyle = theme.textTheme.labelSmall?.copyWith(
      color: color,
      fontWeight: active ? FontWeight.w700 : FontWeight.w600,
    );

    return Semantics(
      button: true,
      selected: active,
      label: label,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          decoration: BoxDecoration(
            color: active
                ? accent.withValues(alpha: dark ? 0.20 : 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 19, color: color),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: tabularLabel
                    ? CamelliaTypography.tabular(baseStyle)
                    : baseStyle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ImagePaint extends StatelessWidget {
  const ImagePaint({super.key});

  @override
  Widget build(BuildContext context) {
    final m = Provider.of<ImageModel>(context);
    final c = Provider.of<CanvasModel>(context);
    var s = c.scale;
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

void showOptions(
  BuildContext context,
  String id,
  OverlayDialogManager dialogManager,
) async {
  final pi = gFFI.ffiModel.pi;
  final connectionSummary = gFFI.ffiModel.getConnectionImageText();
  final hasMultipleCameras =
      pi.displays.length > 1 && pi.currentDisplay != kAllDisplayValue;

  final viewStyleRadios = await toolbarViewStyle(context, id, gFFI);
  if (!context.mounted) return;
  final imageQualityRadios = await toolbarImageQuality(context, id, gFFI);
  if (!context.mounted) return;
  final codecRadios = await toolbarCodec(context, id, gFFI);
  if (!context.mounted) return;
  final displayToggles = await toolbarDisplayToggle(context, id, gFFI);
  if (!context.mounted) return;

  final viewStyle =
      (viewStyleRadios.isNotEmpty ? viewStyleRadios[0].groupValue : '').obs;
  final imageQuality =
      (imageQualityRadios.isNotEmpty ? imageQualityRadios[0].groupValue : '')
          .obs;
  final codec = (codecRadios.isNotEmpty ? codecRadios[0].groupValue : '').obs;
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

      final cameraWidgets = <Widget>[
        if (connectionSummary != null)
          Padding(
            padding: EdgeInsets.only(bottom: hasMultipleCameras ? 10 : 0),
            child: connectionSummary,
          ),
        if (hasMultipleCameras)
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
                          CamelliaIcons.camera,
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

      final toggleWidgets = <Widget>[
        for (var i = 0; i < displayToggles.length; i++)
          Obx(
            () => SwitchListTile.adaptive(
              dense: true,
              value: rxToggleValues[i].value,
              onChanged: displayToggles[i].onChanged == null
                  ? null
                  : (next) {
                      HapticFeedback.selectionClick();
                      displayToggles[i].onChanged?.call(next);
                      rxToggleValues[i].value = next;
                    },
              secondary: Icon(
                CamelliaIcons.display,
                size: 18,
                color: tokens.muted,
              ),
              title: DefaultTextStyle.merge(
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
                child: displayToggles[i].child,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            ),
          ),
      ];

      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.76,
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
          shrinkWrap: true,
          children: [
            if (cameraWidgets.isNotEmpty)
              sectionFrame(
                title: 'View camera',
                icon: CamelliaIcons.camera,
                children: cameraWidgets,
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
            if (toggleWidgets.isNotEmpty)
              sectionFrame(
                title: 'General',
                icon: CamelliaIcons.settings,
                children: toggleWidgets,
              ),
          ],
        ),
      );
    },
  );
  _disableAndroidSoftKeyboard();
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
