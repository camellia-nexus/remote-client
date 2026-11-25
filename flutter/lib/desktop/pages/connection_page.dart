// main window quick-connect hero & relay status pill

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common/widgets/server_settings_dialog.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../common/widgets/autocomplete.dart';
import '../../common/widgets/peer_tab_page.dart';
import '../../models/platform_model.dart';

enum _ConnectionMode { desktop, viewOnly, files, tunnel, camera, terminal }

Color _connectionModeTone(BuildContext context, _ConnectionMode mode) {
  return switch (mode) {
    _ConnectionMode.desktop => CamelliaColors.coral,
    _ConnectionMode.viewOnly => CamelliaColors.leaf,
    _ConnectionMode.files => CamelliaColors.azure,
    _ConnectionMode.tunnel => CamelliaColors.aqua,
    _ConnectionMode.camera => CamelliaColors.aqua,
    _ConnectionMode.terminal => CamelliaColors.orchid,
  };
}

/// Compact frosted status badge reporting relay / service readiness with
/// a clean popover menu for "Start service" and "Server settings".
class OnlineStatusWidget extends StatefulWidget {
  const OnlineStatusWidget({
    super.key,
    this.onSvcStatusChanged,
    this.compact = false,
  });

  final VoidCallback? onSvcStatusChanged;
  final bool compact;

  @override
  State<OnlineStatusWidget> createState() => _OnlineStatusWidgetState();
}

class _OnlineStatusWidgetState extends State<OnlineStatusWidget> {
  late final RxBool _svcStopped = Get.isRegistered<RxBool>(tag: 'stop-service')
      ? Get.find<RxBool>(tag: 'stop-service')
      : false.obs;
  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    _updateTimer = periodic_immediate(const Duration(seconds: 1), () async {
      await updateStatus();
    });
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  GlassBadgeTone _badgeTone() {
    if (_svcStopped.value) return GlassBadgeTone.warning;
    return switch (stateGlobal.svcStatus.value) {
      SvcStatus.ready => GlassBadgeTone.online,
      SvcStatus.connecting => GlassBadgeTone.connecting,
      SvcStatus.notReady => GlassBadgeTone.danger,
    };
  }

  String _connStatusText() {
    if (_svcStopped.value) {
      return translate('Service is not running');
    }
    return switch (stateGlobal.svcStatus.value) {
      SvcStatus.connecting => translate('connecting_status'),
      SvcStatus.notReady => translate('not_ready_status'),
      SvcStatus.ready => translate('Ready'),
    };
  }

  Future<void> updateStatus() async {
    try {
      final raw = await bind.mainGetConnectStatus();
      if (raw.isEmpty) return;
      final status = jsonDecode(raw) as Map<String, dynamic>;
      final statusNum = status['status_num'] as int;
      final prevStatus = stateGlobal.svcStatus.value;
      if (statusNum == 0) {
        stateGlobal.svcStatus.value = SvcStatus.connecting;
      } else if (statusNum == 1) {
        stateGlobal.svcStatus.value = SvcStatus.ready;
      } else {
        stateGlobal.svcStatus.value = SvcStatus.notReady;
      }
      if (prevStatus != stateGlobal.svcStatus.value) {
        widget.onSvcStatusChanged?.call();
      }
      final videoCount = status['video_conn_count'];
      if (videoCount is int) {
        stateGlobal.videoConnCount.value = videoCount;
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppVisual.tokens(context);
    final glass = CamelliaGlassTokens.of(context);

    return Obx(() {
      final stopped = _svcStopped.value;
      final canConfigureServer = !bind.isDisableSettings();

      final badge = GlassBadge(
        label: _connStatusText(),
        tone: _badgeTone(),
        showDot: true,
        pulse: false,
        compact: widget.compact,
      );

      final menuButton = Theme(
        data: theme.copyWith(
          highlightColor: Colors.transparent,
          focusColor: Colors.transparent,
          splashColor: Colors.transparent,
          splashFactory: NoSplash.splashFactory,
        ),
        child: PopupMenuButton<String>(
          tooltip: translate('Status'),
          padding: EdgeInsets.zero,
          borderRadius: BorderRadius.circular(CamelliaRadius.pill),
          position: PopupMenuPosition.under,
          offset: const Offset(0, 6),
          color: tokens.surfaceElevated,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CamelliaRadius.surface),
            side: BorderSide(color: tokens.border, width: 0.85),
          ),
          onSelected: (action) async {
            switch (action) {
              case 'start':
                await start_service(true);
                await updateStatus();
              case 'server':
                showServerSettings(gFFI.dialogManager, setState);
              case 'refresh':
                await updateStatus();
            }
          },
          itemBuilder: (context) => [
            if (stopped)
              PopupMenuItem<String>(
                value: 'start',
                height: 38,
                child: Row(
                  children: [
                    Icon(
                      Icons.play_arrow_rounded,
                      size: 18,
                      color: glass.statusOnline,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      translate('Start service'),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            if (canConfigureServer)
              PopupMenuItem<String>(
                value: 'server',
                height: 38,
                child: Row(
                  children: [
                    Icon(
                      Icons.dns_rounded,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      translate('ID/Relay Server'),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            PopupMenuItem<String>(
              value: 'refresh',
              height: 38,
              child: Row(
                children: [
                  Icon(
                    CamelliaIcons.refresh,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Text(translate('Refresh'), style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ],
          child: badge,
        ),
      );

      if (stopped && !widget.compact) {
        return Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            menuButton,
            GlassButton(
              variant: GlassButtonVariant.secondary,
              minHeight: 32,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              icon: const Icon(Icons.play_arrow_rounded, size: 16),
              onPressed: () async {
                await start_service(true);
                await updateStatus();
              },
              child: Text(translate('Start service')),
            ),
          ],
        );
      }

      return menuButton;
    });
  }
}

/// Quick Connect Hero card for initiating remote sessions across modes.
class ConnectionPage extends StatefulWidget {
  const ConnectionPage({
    super.key,
    this.showDevices = true,
    this.showStatus = true,
  });

  final bool showDevices;

  /// Whether to show [OnlineStatusWidget] in the hero header.
  /// Set to `false` when hosted alongside [UnifiedIdentityCard] in the desktop
  /// hub so only a single status poller runs.
  final bool showStatus;

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage>
    with SingleTickerProviderStateMixin, WindowListener {
  final _idController = IDTextEditingController();

  final RxBool _idInputFocused = false.obs;
  final RxBool _hasInputError = false.obs;
  final RxBool _isConnecting = false.obs;
  final FocusNode _idFocusNode = FocusNode();
  final TextEditingController _idEditingController = TextEditingController();
  final GlassShakeController _shakeController = GlassShakeController();
  Timer? _errorResetTimer;
  Timer? _connectingResetTimer;

  _ConnectionMode _connectionMode = _ConnectionMode.desktop;
  bool isWindowMinimized = false;

  final AllPeersLoader _allPeersLoader = AllPeersLoader();

  // https://github.com/flutter/flutter/issues/157244
  Iterable<Peer> _autocompleteOpts = [];

  @override
  void initState() {
    super.initState();
    _allPeersLoader.init(setState);
    _idFocusNode.addListener(onFocusChanged);
    if (_idController.text.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final lastRemoteId = await bind.mainGetLastRemoteId();
        if (mounted && lastRemoteId != _idController.id) {
          setState(() {
            _idController.id = lastRemoteId;
          });
        }
      });
    }
    Get.put<TextEditingController>(_idEditingController);
    Get.put<IDTextEditingController>(_idController);
    _idController.addListener(_onIdChanged);
    _idEditingController.addListener(_onIdChanged);
    windowManager.addListener(this);
  }

  void _onIdChanged() {
    if (_hasInputError.value &&
        (_idController.id.trim().isNotEmpty ||
            _idEditingController.text.trim().isNotEmpty)) {
      _hasInputError.value = false;
      _errorResetTimer?.cancel();
    }
  }

  @override
  void dispose() {
    _errorResetTimer?.cancel();
    _connectingResetTimer?.cancel();
    _idController.removeListener(_onIdChanged);
    _idEditingController.removeListener(_onIdChanged);
    _idController.dispose();
    _shakeController.dispose();
    windowManager.removeListener(this);
    _allPeersLoader.clear();
    _idFocusNode.removeListener(onFocusChanged);
    _idFocusNode.dispose();
    _idEditingController.dispose();
    if (Get.isRegistered<IDTextEditingController>()) {
      Get.delete<IDTextEditingController>();
    }
    if (Get.isRegistered<TextEditingController>()) {
      Get.delete<TextEditingController>();
    }
    super.dispose();
  }

  @override
  void onWindowEvent(String eventName) {
    super.onWindowEvent(eventName);
    if (eventName == 'minimize') {
      isWindowMinimized = true;
    } else if (eventName == 'maximize' || eventName == 'restore') {
      if (isWindowMinimized && isWindows) {
        Get.forceAppUpdate();
      }
      isWindowMinimized = false;
    }
  }

  @override
  void onWindowEnterFullScreen() {
    stateGlobal.resizeEdgeSize.value = 0;
  }

  @override
  void onWindowLeaveFullScreen() {
    stateGlobal.resizeEdgeSize.value = stateGlobal.isMaximized.isTrue
        ? kMaximizeEdgeSize
        : windowResizeEdgeSize;
  }

  @override
  void onWindowClose() {
    super.onWindowClose();
    bind.mainOnMainWindowClose();
  }

  void onFocusChanged() {
    _idInputFocused.value = _idFocusNode.hasFocus;
    if (_idFocusNode.hasFocus) {
      if (_allPeersLoader.needLoad) {
        _allPeersLoader.getAllPeers();
      }

      final textLength = _idEditingController.value.text.length;
      _idEditingController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: textLength,
      );
    }
  }

  Future<void> _smartPasteId(
    TextEditingController fieldTextEditingController,
  ) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text?.trim();
    if (raw == null || raw.isEmpty || !mounted) return;

    // Extract a clean numeric ID when clipboard contains surrounding label text
    // (e.g., "ID: 123 456 789"), otherwise preserve trimmed alias/hostname.
    final numericMatch = RegExp(r'\d[\d\s\-]{4,}\d').firstMatch(raw);
    final extracted = numericMatch != null
        ? numericMatch.group(0)!.replaceAll(RegExp(r'[\s\-]'), '')
        : raw;

    setState(() {
      _idController.id = extracted;
      final formatted = _idController.text;
      fieldTextEditingController.value = TextEditingValue(
        text: formatted,
        selection: TextSelection.collapsed(offset: formatted.length),
      );
      _hasInputError.value = false;
    });
    HapticFeedback.selectionClick();
  }

  Future<void> onConnect({
    bool isFileTransfer = false,
    bool isViewCamera = false,
    bool isTerminal = false,
    bool isTcpTunneling = false,
    bool isViewOnly = false,
  }) async {
    final id = _idController.id;
    final cleanId = id.replaceAll(' ', '');
    if (cleanId.isEmpty) return;

    if (!isFileTransfer && !isViewCamera && !isTerminal && !isTcpTunneling) {
      try {
        if (isViewOnly) {
          await bind.mainSetPeerOption(
            id: cleanId,
            key: kOptionViewOnly,
            value: 'Y',
          );
        } else if (bind.mainGetPeerOptionSync(
              id: cleanId,
              key: kOptionViewOnly,
            ) ==
            'Y') {
          await bind.mainSetPeerOption(
            id: cleanId,
            key: kOptionViewOnly,
            value: 'N',
          );
        }
      } catch (_) {}
    }

    if (!mounted) return;
    await connect(
      context,
      id,
      isFileTransfer: isFileTransfer,
      isViewCamera: isViewCamera,
      isTerminal: isTerminal,
      isTcpTunneling: isTcpTunneling,
    );
  }

  Future<void> _connectSelectedMode() async {
    final rawId = _idController.id.trim();
    if (rawId.isEmpty) {
      _hasInputError.value = true;
      _shakeController.shake();
      _idFocusNode.requestFocus();
      return;
    }

    _hasInputError.value = false;
    _isConnecting.value = true;
    try {
      await onConnect(
        isViewOnly: _connectionMode == _ConnectionMode.viewOnly,
        isFileTransfer: _connectionMode == _ConnectionMode.files,
        isTcpTunneling: _connectionMode == _ConnectionMode.tunnel,
        isViewCamera: _connectionMode == _ConnectionMode.camera,
        isTerminal: _connectionMode == _ConnectionMode.terminal,
      );
    } catch (e) {
      debugPrint('Connection attempt failed: $e');
    } finally {
      if (mounted) {
        _connectingResetTimer?.cancel();
        _connectingResetTimer = null;
        _isConnecting.value = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        final split = widget.showDevices && constraints.maxWidth >= 860;
        final devices = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              translate('Devices'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Expanded(child: PeerTabPage()),
          ],
        );

        if (!widget.showDevices) {
          return _buildQuickConnectHero(context);
        }

        final padding = compact ? 14.0 : 20.0;
        return Padding(
          padding: EdgeInsets.fromLTRB(padding, padding, padding, 0),
          child: split
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 390,
                      child: constraints.maxHeight >= 580
                          ? Align(
                              alignment: Alignment.topCenter,
                              child: _buildQuickConnectHero(context),
                            )
                          : SingleChildScrollView(
                              child: _buildQuickConnectHero(context),
                            ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(child: devices),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildQuickConnectHero(context),
                    const SizedBox(height: 18),
                    Expanded(child: devices),
                  ],
                ),
        );
      },
    );
  }

  Widget _buildQuickConnectHero(BuildContext context) {
    final theme = Theme.of(context);
    final modeAccent = _connectionModeTone(context, _connectionMode);
    final showStatusBadge = widget.showStatus && !bind.isOutgoingOnly();

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 460;
        return CamelliaSection(
          title: translate('Connect'),
          description: translate('Choose a mode and enter a trusted device ID'),
          accent: modeAccent,
          trailing: showStatusBadge && !isNarrow
              ? const OnlineStatusWidget(compact: true)
              : null,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showStatusBadge && isNarrow) ...[
                const Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: OnlineStatusWidget(compact: true),
                ),
                const SizedBox(height: 10),
              ],
              _buildModeSelector(context, constraints.maxWidth),
              const SizedBox(height: 16),
              _buildHeroInputRow(context),
              const SizedBox(height: 14),
              _buildModeCaption(context, theme, modeAccent),
            ],
          ),
        );
      },
    );
  }

  Widget _buildModeSelector(BuildContext context, double availableWidth) {
    final showText = availableWidth >= 520;
    final allSegments = <GlassSegmentItem>[
      GlassSegmentItem(
        value: _ConnectionMode.desktop,
        icon: Icons.desktop_windows_outlined,
        label: showText ? translate('Desktop') : null,
        tooltip: translate('Control Remote Desktop'),
      ),
      GlassSegmentItem(
        value: _ConnectionMode.viewOnly,
        icon: Icons.visibility_outlined,
        label: showText ? translate('View') : null,
        tooltip: translate('View Mode'),
      ),
      GlassSegmentItem(
        value: _ConnectionMode.files,
        icon: Icons.folder_copy_outlined,
        label: showText ? translate('Files') : null,
        tooltip: translate('Transfer file'),
      ),
      if (isDesktop)
        GlassSegmentItem(
          value: _ConnectionMode.tunnel,
          icon: CamelliaIcons.tunnel,
          label: showText ? translate('Tunnel') : null,
          tooltip: translate('TCP tunneling'),
        ),
      GlassSegmentItem(
        value: _ConnectionMode.camera,
        icon: Icons.videocam_outlined,
        label: showText ? translate('Camera') : null,
        tooltip: translate('View camera'),
      ),
      GlassSegmentItem(
        value: _ConnectionMode.terminal,
        icon: Icons.terminal_rounded,
        label: showText ? translate('Terminal') : null,
        tooltip: translate('Terminal'),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: CamelliaSpace.xxs),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: GlassSegmentedControl(
          compact: true,
          expand: false,
          items: allSegments,
          selected: _connectionMode,
          onChanged: (mode) => setState(() => _connectionMode = mode as _ConnectionMode),
        ),
      ),
    );
  }

  Widget _buildHeroInputRow(BuildContext context) {
    return GlassShakeBox(
      controller: _shakeController,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stackCta = constraints.maxWidth < 380;
          final compactCta = constraints.maxWidth < 500;
          final optionsWidth =
              (constraints.maxWidth - (stackCta ? 0.0 : (compactCta ? 96.0 : 148.0)))
                  .clamp(220.0, 620.0)
                  .toDouble();

          final inputWidget = _buildAutocomplete(context, optionsWidth);
          final ctaButton = Obx(
            () => GlassButton(
              variant: GlassButtonVariant.primary,
              loading: _isConnecting.value,
              expand: stackCta,
              minHeight: 48,
              padding: EdgeInsets.symmetric(
                horizontal: compactCta && !stackCta ? 16 : 22,
                vertical: 12,
              ),
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              onPressed: _connectSelectedMode,
              child: Text(translate('Connect')),
            ),
          );

          if (stackCta) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                inputWidget,
                const SizedBox(height: CamelliaSpace.sm),
                ctaButton,
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: inputWidget),
              const SizedBox(width: CamelliaSpace.sm),
              ctaButton,
            ],
          );
        },
      ),
    );
  }

  Widget _buildModeCaption(
    BuildContext context,
    ThemeData theme,
    Color modeAccent,
  ) {
    final tokens = AppVisual.tokens(context);
    final description = switch (_connectionMode) {
      _ConnectionMode.desktop => translate('Control Remote Desktop'),
      _ConnectionMode.viewOnly => translate('View Mode'),
      _ConnectionMode.files => translate('Transfer file'),
      _ConnectionMode.tunnel => translate('TCP tunneling'),
      _ConnectionMode.camera => translate('View camera'),
      _ConnectionMode.terminal => translate('Terminal'),
    };
    return Row(
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: modeAccent,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: tokens.surfaceContainer.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: tokens.border, width: 0.85),
          ),
          child: Text(
            '↵',
            style: CamelliaTypography.tabular(
              theme.textTheme.labelSmall?.copyWith(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAutocomplete(BuildContext context, double optionsWidth) {
    return RawAutocomplete<Peer>(
      optionsBuilder: (TextEditingValue textEditingValue) {
        if (textEditingValue.text == '') {
          _autocompleteOpts = const Iterable<Peer>.empty();
        } else if (_allPeersLoader.peers.isEmpty &&
            !_allPeersLoader.isPeersLoaded) {
          final emptyPeer = Peer(
            id: '',
            username: '',
            hostname: '',
            alias: '',
            platform: '',
            tags: [],
            hash: '',
            password: '',
            forceAlwaysRelay: false,
            rdpPort: '',
            rdpUsername: '',
            loginName: '',
            device_group_name: '',
            note: '',
          );
          _autocompleteOpts = [emptyPeer];
        } else {
          final textWithoutSpaces = textEditingValue.text.replaceAll(' ', '');
          if (int.tryParse(textWithoutSpaces) != null) {
            textEditingValue = TextEditingValue(
              text: textWithoutSpaces,
              selection: textEditingValue.selection,
            );
          }
          final textToFind = textEditingValue.text.toLowerCase();
          _autocompleteOpts = _allPeersLoader.peers
              .where(
                (peer) =>
                    peer.id.toLowerCase().contains(textToFind) ||
                    peer.username.toLowerCase().contains(textToFind) ||
                    peer.hostname.toLowerCase().contains(textToFind) ||
                    peer.alias.toLowerCase().contains(textToFind),
              )
              .toList();
          _allPeersLoader.queryOnlines(_autocompleteOpts);
        }
        return _autocompleteOpts;
      },
      focusNode: _idFocusNode,
      textEditingController: _idEditingController,
      fieldViewBuilder:
          (
            BuildContext context,
            TextEditingController fieldTextEditingController,
            FocusNode fieldFocusNode,
            VoidCallback onFieldSubmitted,
          ) {
            updateTextAndPreserveSelection(
              fieldTextEditingController,
              _idController.text,
            );
            final theme = Theme.of(context);
            final glass = CamelliaGlassTokens.of(context);
            return ValueListenableBuilder<TextEditingValue>(
              valueListenable: fieldTextEditingController,
              builder: (context, textValue, _) {
                return Obx(
                  () => GlassInput(
                    controller: fieldTextEditingController,
                    focusNode: fieldFocusNode,
                    enabled: !_isConnecting.value,
                    minHeight: 48,
                    tabularNums: true,
                    prefixIcon: Icons.dialpad_rounded,
                    hintText: _idInputFocused.value
                        ? null
                        : translate('Enter Remote ID'),
                    errorText: _hasInputError.value
                        ? translate('Enter Remote ID')
                        : null,
                    showClearButton: true,
                    showPasteButton: false,
                    keyboardType: TextInputType.visiblePassword,
                    inputFormatters: [IDTextInputFormatter()],
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontSize: 20,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.7,
                    ),
                    trailing: textValue.text.isEmpty
                        ? Tooltip(
                            message: translate('Paste'),
                            child: Material(
                              type: MaterialType.transparency,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(
                                  CamelliaRadius.pill,
                                ),
                                hoverColor: glass.hoverOverlay,
                                highlightColor: Colors.transparent,
                                splashColor: Colors.transparent,
                                splashFactory: NoSplash.splashFactory,
                                focusColor: Colors.transparent,
                                onTap: () =>
                                    _smartPasteId(fieldTextEditingController),
                                child: Padding(
                                  padding: const EdgeInsets.all(6),
                                  child: Icon(
                                    CamelliaIcons.paste,
                                    size: 17,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          )
                        : null,
                    onClear: () {
                      _idEditingController.clear();
                      _idController.id = '';
                      _hasInputError.value = false;
                    },
                    onChanged: (v) {
                      _idController.id = v;
                      if (_hasInputError.value && v.trim().isNotEmpty) {
                        _hasInputError.value = false;
                      }
                    },
                    onSubmitted: (_) => _connectSelectedMode(),
                  ).workaroundFreezeLinuxMint(),
                );
              },
            );
          },
      onSelected: (option) {
        setState(() {
          _idController.id = option.id;
          _hasInputError.value = false;
          FocusScope.of(context).unfocus();
        });
      },
      optionsViewBuilder:
          (
            BuildContext context,
            AutocompleteOnSelected<Peer> onSelected,
            Iterable<Peer> options,
          ) {
            options = _autocompleteOpts;
            double maxHeight = options.length * 52.0;
            if (options.length == 1) {
              maxHeight = 58;
            } else if (options.length == 3) {
              maxHeight = 156;
            } else if (options.length == 4) {
              maxHeight = 208;
            }
            maxHeight = maxHeight.clamp(0, 240);

            return Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: GlassSurface(
                  layer: CamelliaGlassLayer.modal,
                  elevated: true,
                  borderRadius: BorderRadius.circular(CamelliaRadius.surface),
                  child: Material(
                    type: MaterialType.transparency,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: maxHeight,
                        maxWidth: optionsWidth.clamp(260, 620).toDouble(),
                      ),
                      child:
                          _allPeersLoader.peers.isEmpty &&
                              !_allPeersLoader.isPeersLoaded
                          ? const SizedBox(
                              height: 80,
                              child: Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 4,
                              ),
                              child: ListView(
                                padding: EdgeInsets.zero,
                                children: options
                                    .map(
                                      (peer) => AutocompletePeerTile(
                                        onSelect: () => onSelected(peer),
                                        peer: peer,
                                      ),
                                    )
                                    .toList(),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            );
          },
    );
  }
}
