import 'dart:async';
import 'package:debounce_throttle/debounce_throttle.dart';
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../models/chat_model.dart';
import '../../models/model.dart';
import 'chat_page.dart';

class DraggableChatWindow extends StatelessWidget {
  const DraggableChatWindow({
    Key? key,
    this.position = Offset.zero,
    required this.width,
    required this.height,
    required this.chatModel,
  }) : super(key: key);

  final Offset position;
  final double width;
  final double height;
  final ChatModel chatModel;

  @override
  Widget build(BuildContext context) {
    if (draggablePositions.chatWindow.isInvalid()) {
      draggablePositions.chatWindow.update(position);
    }
    return isIOS
        ? IOSDraggable(
            position: draggablePositions.chatWindow,
            chatModel: chatModel,
            width: width,
            height: height,
            builder: (context) {
              return Column(
                children: [
                  _buildChatHeader(context, isMobileHeader: true),
                  Expanded(child: ChatPage(chatModel: chatModel)),
                ],
              );
            },
          )
        : Draggable(
            checkKeyboard: true,
            checkScreenSize: true,
            position: draggablePositions.chatWindow,
            width: width,
            height: height,
            chatModel: chatModel,
            builder: (context, onPanUpdate) {
              return GlassSurface(
                layer: CamelliaGlassLayer.modal,
                elevated: true,
                strokeWidth: 0.85,
                borderRadius: BorderRadius.circular(CamelliaRadius.surface),
                padding: EdgeInsets.zero,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(CamelliaRadius.surface),
                  child: Scaffold(
                    backgroundColor: Colors.transparent,
                    resizeToAvoidBottomInset: false,
                    body: Column(
                      children: [
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanUpdate: onPanUpdate,
                          child: _buildChatHeader(
                            context,
                            isMobileHeader: !(isDesktop || isWebDesktop),
                          ),
                        ),
                        Expanded(child: ChatPage(chatModel: chatModel)),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
  }

  Widget _buildChatHeader(
    BuildContext context, {
    required bool isMobileHeader,
  }) {
    final theme = Theme.of(context);
    final tokens =
        theme.extension<AppDesignTokens>() ?? AppVisual.tokens(context);
    final accent = theme.brightness == Brightness.dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    return Container(
      height: 42,
      padding: const EdgeInsets.fromLTRB(14, 0, 6, 0),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: tokens.border, width: 0.85),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Obx(
              () => AnimatedOpacity(
                duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
                opacity: chatModel.isWindowFocus.value ? 1.0 : 0.65,
                child: Row(
                  children: [
                    Icon(CamelliaIcons.chat, size: 17, color: accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        translate("Chat"),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (isMobileHeader)
            GlassIconButton(
              icon: Icons.keyboard_arrow_down_rounded,
              size: 30,
              iconSize: 18,
              tooltip: translate('Minimize'),
              onPressed: chatModel.hideChatWindowOverlay,
            ),
          GlassIconButton(
            icon: CamelliaIcons.close,
            size: 30,
            iconSize: 16,
            tooltip: translate('Close'),
            onPressed: () {
              chatModel.hideChatWindowOverlay();
              if (isMobileHeader) {
                chatModel.hideChatIconOverlay();
              }
            },
          ),
        ],
      ),
    );
  }
}

class CustomAppBar extends StatelessWidget implements PreferredSizeWidget {
  final GestureDragUpdateCallback onPanUpdate;
  final Widget appBar;

  const CustomAppBar({
    Key? key,
    required this.onPanUpdate,
    required this.appBar,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(onPanUpdate: onPanUpdate, child: appBar);
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}

/// floating buttons of back/home/recent actions for android
class DraggableMobileActions extends StatelessWidget {
  DraggableMobileActions({
    this.onBackPressed,
    this.onRecentPressed,
    this.onHomePressed,
    this.onHidePressed,
    required this.position,
    required this.width,
    required this.height,
    required this.scale,
  });

  final double scale;
  final DraggableKeyPosition position;
  final double width;
  final double height;
  final VoidCallback? onBackPressed;
  final VoidCallback? onHomePressed;
  final VoidCallback? onRecentPressed;
  final VoidCallback? onHidePressed;

  @override
  Widget build(BuildContext context) {
    final tokens =
        Theme.of(context).extension<AppDesignTokens>() ??
        AppVisual.tokens(context);
    final btnSize = (32 * scale).clamp(28.0, 48.0);
    final icoSize = (18 * scale).clamp(15.0, 26.0);
    return Draggable(
      position: position,
      width: scale * width,
      height: scale * height,
      builder: (_, onPanUpdate) {
        return GestureDetector(
          onPanUpdate: onPanUpdate,
          child: GlassSurface(
            layer: CamelliaGlassLayer.modal,
            elevated: true,
            strokeWidth: 0.85,
            borderRadius: BorderRadius.circular(CamelliaRadius.pill),
            padding: EdgeInsets.symmetric(horizontal: 6 * scale),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                GlassIconButton(
                  icon: CamelliaIcons.arrowBack,
                  size: btnSize,
                  iconSize: icoSize,
                  tooltip: translate('Back'),
                  onPressed: onBackPressed,
                ),
                GlassIconButton(
                  icon: CamelliaIcons.home,
                  size: btnSize,
                  iconSize: icoSize,
                  tooltip: translate('Home'),
                  onPressed: onHomePressed,
                ),
                GlassIconButton(
                  icon: CamelliaIcons.more,
                  size: btnSize,
                  iconSize: icoSize,
                  tooltip: translate('More'),
                  onPressed: onRecentPressed,
                ),
                Container(
                  width: 1,
                  height: (20 * scale).clamp(14.0, 26.0),
                  color: tokens.border,
                ),
                GlassIconButton(
                  icon: Icons.keyboard_arrow_down_rounded,
                  size: btnSize,
                  iconSize: icoSize,
                  tooltip: translate('Hide'),
                  onPressed: onHidePressed,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class DraggableKeyPosition {
  final String key;
  Offset _pos;
  late Debouncer<int> _debouncerStore;
  DraggableKeyPosition(this.key)
    : _pos = DraggablePositions.kInvalidDraggablePosition;

  get pos => _pos;

  _loadPosition(String k) {
    final value = bind.getLocalFlutterOption(k: k);
    if (value.isNotEmpty) {
      final parts = value.split(',');
      if (parts.length == 2) {
        return Offset(double.parse(parts[0]), double.parse(parts[1]));
      }
    }
    return DraggablePositions.kInvalidDraggablePosition;
  }

  load() {
    _pos = _loadPosition(key);
    _debouncerStore = Debouncer<int>(
      const Duration(milliseconds: 500),
      onChanged: (v) => _store(),
      initialValue: 0,
    );
  }

  update(Offset pos) {
    _pos = pos;
    _triggerStore();
  }

  // Adjust position to keep it in the screen
  // Only used for desktop and web desktop
  tryAdjust(double w, double h, double scale) {
    final size = MediaQuery.sizeOf(Get.context!);
    w = w * scale;
    h = h * scale;
    double x = _pos.dx;
    double y = _pos.dy;
    if (x + w > size.width) {
      x = size.width - w;
    }
    final tabBarHeight = isDesktop ? 40.0 : 0.0;
    if (y + h > (size.height - tabBarHeight)) {
      y = size.height - tabBarHeight - h;
    }
    if (x < 0) {
      x = 0;
    }
    if (y < 0) {
      y = 0;
    }
    if (x != _pos.dx || y != _pos.dy) {
      update(Offset(x, y));
    }
  }

  isInvalid() {
    return _pos == DraggablePositions.kInvalidDraggablePosition;
  }

  _triggerStore() => _debouncerStore.value = _debouncerStore.value + 1;
  _store() {
    bind.setLocalFlutterOption(k: key, v: '${_pos.dx},${_pos.dy}');
  }
}

class DraggablePositions {
  static const kChatWindow = 'draggablePositionChat';
  static const kMobileActions = 'draggablePositionMobile';
  static const kIOSDraggable = 'draggablePositionIOS';

  static const kInvalidDraggablePosition = Offset(-999999, -999999);
  final chatWindow = DraggableKeyPosition(kChatWindow);
  final mobileActions = DraggableKeyPosition(kMobileActions);
  final iOSDraggable = DraggableKeyPosition(kIOSDraggable);

  load() {
    chatWindow.load();
    mobileActions.load();
    iOSDraggable.load();
  }
}

DraggablePositions draggablePositions = DraggablePositions();

class Draggable extends StatefulWidget {
  Draggable({
    Key? key,
    this.checkKeyboard = false,
    this.checkScreenSize = false,
    required this.position,
    required this.width,
    required this.height,
    this.chatModel,
    required this.builder,
  }) : super(key: key);

  final bool checkKeyboard;
  final bool checkScreenSize;
  final DraggableKeyPosition position;
  final double width;
  final double height;
  final ChatModel? chatModel;
  final Widget Function(BuildContext, GestureDragUpdateCallback) builder;

  @override
  State<StatefulWidget> createState() => _DraggableState(chatModel);
}

class _DraggableState extends State<Draggable> {
  late ChatModel? _chatModel;
  bool _keyboardVisible = false;
  double _saveHeight = 0;
  double _lastBottomHeight = 0;

  _DraggableState(ChatModel? chatModel) {
    _chatModel = chatModel;
  }

  get position => widget.position.pos;

  void onPanUpdate(DragUpdateDetails d) {
    final offset = d.delta;
    final size = MediaQuery.sizeOf(context);
    double x = 0;
    double y = 0;

    if (position.dx + offset.dx + widget.width > size.width) {
      x = size.width - widget.width;
    } else if (position.dx + offset.dx < 0) {
      x = 0;
    } else {
      x = position.dx + offset.dx;
    }

    if (position.dy + offset.dy + widget.height > size.height) {
      y = size.height - widget.height;
    } else if (position.dy + offset.dy < 0) {
      y = 0;
    } else {
      y = position.dy + offset.dy;
    }
    setState(() {
      widget.position.update(Offset(x, y));
    });
    _chatModel?.setChatWindowPosition(position);
  }

  checkScreenSize() {
    // Ensure the draggable always stays within current screen bounds
    widget.position.tryAdjust(widget.width, widget.height, 1);
  }

  checkKeyboard() {
    final bottomHeight = MediaQuery.viewInsetsOf(context).bottom;
    final currentVisible = bottomHeight != 0;

    // save
    if (!_keyboardVisible && currentVisible) {
      _saveHeight = position.dy;
    }

    // reset
    if (_lastBottomHeight > 0 && bottomHeight == 0) {
      setState(() {
        widget.position.update(Offset(position.dx, _saveHeight));
      });
    }

    // onKeyboardVisible
    if (_keyboardVisible && currentVisible) {
      final sumHeight = bottomHeight + widget.height;
      final contextHeight = MediaQuery.sizeOf(context).height;
      if (sumHeight + position.dy > contextHeight) {
        final y = contextHeight - sumHeight;
        setState(() {
          widget.position.update(Offset(position.dx, y));
        });
      }
    }

    _keyboardVisible = currentVisible;
    _lastBottomHeight = bottomHeight;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.checkKeyboard) {
      checkKeyboard();
    }
    if (widget.checkScreenSize) {
      checkScreenSize();
    }
    return Stack(
      children: [
        Positioned(
          top: position.dy,
          left: position.dx,
          width: widget.width,
          height: widget.height,
          child: widget.builder(context, onPanUpdate),
        ),
      ],
    );
  }
}

class IOSDraggable extends StatefulWidget {
  const IOSDraggable({
    Key? key,
    this.chatModel,
    required this.position,
    required this.width,
    required this.height,
    required this.builder,
  }) : super(key: key);

  final DraggableKeyPosition position;
  final ChatModel? chatModel;
  final double width;
  final double height;
  final Widget Function(BuildContext) builder;

  @override
  IOSDraggableState createState() =>
      IOSDraggableState(chatModel, width, height);
}

class IOSDraggableState extends State<IOSDraggable> {
  late ChatModel? _chatModel;
  late double _width;
  late double _height;
  bool _keyboardVisible = false;
  double _saveHeight = 0;
  double _lastBottomHeight = 0;

  IOSDraggableState(ChatModel? chatModel, double w, double h) {
    _chatModel = chatModel;
    _width = w;
    _height = h;
  }

  DraggableKeyPosition get position => widget.position;

  checkKeyboard() {
    final bottomHeight = MediaQuery.viewInsetsOf(context).bottom;
    final currentVisible = bottomHeight != 0;

    // save
    if (!_keyboardVisible && currentVisible) {
      _saveHeight = position.pos.dy;
    }

    // reset
    if (_lastBottomHeight > 0 && bottomHeight == 0) {
      setState(() {
        position.update(Offset(position.pos.dx, _saveHeight));
      });
    }

    // onKeyboardVisible
    if (_keyboardVisible && currentVisible) {
      final sumHeight = bottomHeight + _height;
      final contextHeight = MediaQuery.sizeOf(context).height;
      if (sumHeight + position.pos.dy > contextHeight) {
        final y = contextHeight - sumHeight;
        setState(() {
          position.update(Offset(position.pos.dx, y));
        });
      }
    }

    _keyboardVisible = currentVisible;
    _lastBottomHeight = bottomHeight;
  }

  @override
  void initState() {
    super.initState();
    position.tryAdjust(_width, _height, 1);
  }

  @override
  Widget build(BuildContext context) {
    checkKeyboard();
    return Stack(
      children: [
        Positioned(
          left: position.pos.dx,
          top: position.pos.dy,
          child: GestureDetector(
            onPanUpdate: (details) {
              setState(() {
                position.update(position.pos + details.delta);
              });
              _chatModel?.setChatWindowPosition(position.pos);
            },
            child: SizedBox(
              width: _width,
              height: _height,
              child: GlassSurface(
                layer: CamelliaGlassLayer.modal,
                elevated: true,
                strokeWidth: 0.85,
                borderRadius: BorderRadius.circular(CamelliaRadius.surface),
                padding: EdgeInsets.zero,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(CamelliaRadius.surface),
                  child: Material(
                    type: MaterialType.transparency,
                    child: widget.builder(context),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class QualityMonitor extends StatelessWidget {
  final QualityMonitorModel qualityMonitorModel;
  const QualityMonitor(this.qualityMonitorModel, {super.key});

  Widget _row(BuildContext context, IconData icon, String info, String? value) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 15, color: scheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            translate(info),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          value?.trim().isNotEmpty == true ? value! : '—',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: CamelliaTypography.tabular(
            Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider.value(
    value: qualityMonitorModel,
    child: Consumer<QualityMonitorModel>(
      builder: (context, quality, child) {
        final delay = quality.data.delay == null
            ? '—'
            : (quality.data.fps ?? '')
                  .replaceAll(' ', '')
                  .replaceAll('0', '')
                  .isEmpty
            ? '0 ms'
            : '${quality.data.delay} ms';
        final bitrate = quality.data.targetBitrate == null
            ? '—'
            : '${quality.data.targetBitrate} kbps';
        final delayMs = int.tryParse(quality.data.delay?.trim() ?? '');
        final signalColor = CamelliaIcons.signalColor(context, delayMs);
        return AnimatedSwitcher(
          duration: CamelliaMotion.resolve(context, CamelliaMotion.feedback),
          child: !quality.show
              ? const SizedBox.shrink()
              : IgnorePointer(
                  key: const ValueKey('quality-monitor'),
                  child: GlassSurface(
                    layer: CamelliaGlassLayer.modal,
                    elevated: true,
                    borderRadius: BorderRadius.circular(CamelliaRadius.surface),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: 210,
                        maxWidth: 252,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                CamelliaStatusDot(
                                  color: signalColor,
                                  size: 8,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    translate('Connection quality'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                ),
                                Icon(
                                  CamelliaIcons.signalIcon(delayMs),
                                  size: 16,
                                  color: signalColor,
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            _row(
                              context,
                              Icons.network_check_rounded,
                              'Speed',
                              quality.data.speed,
                            ),
                            const SizedBox(height: 8),
                            _row(
                              context,
                              Icons.movie_filter_outlined,
                              'FPS',
                              quality.data.fps,
                            ),
                            const SizedBox(height: 8),
                            _row(context, Icons.speed_rounded, 'Delay', delay),
                            const SizedBox(height: 8),
                            _row(
                              context,
                              Icons.tune_rounded,
                              'Target Bitrate',
                              bitrate,
                            ),
                            const SizedBox(height: 8),
                            _row(
                              context,
                              Icons.memory_rounded,
                              'Codec',
                              quality.data.codecFormat,
                            ),
                            const SizedBox(height: 8),
                            _row(
                              context,
                              Icons.palette_outlined,
                              'Chroma',
                              quality.data.chroma,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        );
      },
    ),
  );
}

class BlockableOverlayState extends OverlayKeyState {
  final _middleBlocked = false.obs;

  VoidCallback? onMiddleBlockedClick; // to-do use listener

  RxBool get middleBlocked => _middleBlocked;

  StreamSubscription<bool> addMiddleBlockedListener(void Function(bool) cb) {
    return _middleBlocked.listen(cb);
  }

  void setMiddleBlocked(bool blocked) {
    if (blocked != _middleBlocked.value) {
      _middleBlocked.value = blocked;
    }
  }

  void applyFfi(FFI ffi) {
    ffi.dialogManager.setOverlayState(this);
    ffi.chatModel.setOverlayState(this);
    // make remote page penetrable automatically, effective for chat over remote
    onMiddleBlockedClick = () {
      setMiddleBlocked(false);
    };
  }
}

class BlockableOverlay extends StatelessWidget {
  final Widget underlying;
  final List<OverlayEntry>? upperLayer;

  final BlockableOverlayState state;

  BlockableOverlay({
    required this.underlying,
    required this.state,
    this.upperLayer,
  });

  @override
  Widget build(BuildContext context) {
    final initialEntries = [
      OverlayEntry(builder: (_) => underlying),

      /// middle layer
      OverlayEntry(
        builder: (context) => Obx(
          () => Listener(
            onPointerDown: (_) {
              state.onMiddleBlockedClick?.call();
            },
            child: Container(
              color: state.middleBlocked.value ? Colors.transparent : null,
            ),
          ),
        ),
      ),
    ];

    if (upperLayer != null) {
      initialEntries.addAll(upperLayer!);
    }

    /// set key
    return Overlay(key: state.key, initialEntries: initialEntries);
  }
}
