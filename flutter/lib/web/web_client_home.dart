import 'dart:async';
import 'dart:convert';

import 'package:auto_size_text_field/auto_size_text_field.dart';
import 'package:camellia_remote_app/common/formatter/id_formatter.dart';
import 'package:camellia_remote_app/common/widgets/autocomplete.dart';
import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/common/widgets/peer_tab_page.dart';
import 'package:camellia_remote_app/common/widgets/settings_overlay.dart';
import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:camellia_remote_app/web/web_client_settings_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:web/web.dart' as web;

import '../common.dart';
import '../models/model.dart';
import '../models/platform_model.dart';

enum _WebConnectMode { desktop, fileTransfer, terminal, camera }

class WebClientHomePage extends StatefulWidget {
  const WebClientHomePage({super.key});

  @override
  State<WebClientHomePage> createState() => _WebClientHomePageState();
}

class _WebClientHomePageState extends State<WebClientHomePage> {
  final IDTextEditingController _idController = IDTextEditingController();
  final FocusNode _idFocusNode = FocusNode();
  final TextEditingController _idEditingController = TextEditingController();
  final AllPeersLoader _allPeersLoader = AllPeersLoader();
  final GlassShakeController _shakeController = GlassShakeController();

  StreamSubscription? _uniLinksSubscription;
  Iterable<Peer> _autocompleteOpts = [];
  _WebConnectMode _mode = _WebConnectMode.desktop;
  bool _idEmpty = true;
  bool _isFieldFocused = false;
  bool _copiedMyId = false;
  bool _fullscreenPreferred = false;
  bool _pointerLockPreferred = false;
  bool _clipboardChecked = false;
  Timer? _statusTimer;
  Timer? _copyResetTimer;
  String _myId = '';

  @override
  void initState() {
    super.initState();
    stateGlobal.isInMainPage = true;
    if (!isWeb) {
      _uniLinksSubscription = listenUniLinks();
    }
    _allPeersLoader.init(setState);
    _idController.addListener(_onIdControllerChanged);
    _idFocusNode.addListener(_onFocusChanged);

    if (_idController.text.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final lastRemoteId = await bind.mainGetLastRemoteId();
        if (!mounted) return;
        if (lastRemoteId != _idController.id) {
          setState(() {
            _idController.id = lastRemoteId;
          });
        }
      });
    }

    Get.put<IDTextEditingController>(_idController);
    Get.put<TextEditingController>(_idEditingController);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleUnilink(context);
    });
    _syncClientStatus();
    _refreshMyId();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _syncClientStatus();
    });
  }

  void _onIdControllerChanged() {
    final empty = _idController.text.isEmpty;
    if (empty != _idEmpty && mounted) {
      setState(() {
        _idEmpty = empty;
      });
    }
  }

  @override
  void dispose() {
    _uniLinksSubscription?.cancel();
    _copyResetTimer?.cancel();
    _idController.removeListener(_onIdControllerChanged);
    _idController.dispose();
    _idFocusNode.removeListener(_onFocusChanged);
    _idFocusNode.dispose();
    _idEditingController.dispose();
    _shakeController.dispose();
    _statusTimer?.cancel();
    _allPeersLoader.clear();
    if (Get.isRegistered<IDTextEditingController>()) {
      Get.delete<IDTextEditingController>();
    }
    if (Get.isRegistered<TextEditingController>()) {
      Get.delete<TextEditingController>();
    }
    super.dispose();
  }

  Future<void> _syncClientStatus() async {
    try {
      final rawStatus = await bind.mainGetConnectStatus();
      final status = jsonDecode(rawStatus) as Map<String, dynamic>;
      final statusNum = (status['status_num'] as num?)?.toInt() ?? -1;
      if (statusNum == 1) {
        stateGlobal.svcStatus.value = SvcStatus.ready;
      } else if (statusNum == 0) {
        stateGlobal.svcStatus.value = SvcStatus.connecting;
      } else {
        stateGlobal.svcStatus.value = SvcStatus.notReady;
      }
    } catch (_) {
      stateGlobal.svcStatus.value = SvcStatus.notReady;
    }

    if (_myId.isEmpty) {
      _refreshMyId();
    }
  }

  Future<void> _refreshMyId() async {
    try {
      final id = await bind.mainGetMyId();
      if (mounted && id.isNotEmpty && id != _myId) {
        setState(() {
          _myId = id;
        });
      }
    } catch (_) {
      // Ignore ID refresh failures; keep last known value.
    }
  }

  Future<void> _rotateMyId() async {
    if (isChangeIdDisabled()) {
      return;
    }
    try {
      await bind.mainChangeId(newId: '');
      await _refreshMyId();
    } catch (_) {
      // Ignore rotation errors for now.
    }
  }

  Future<void> _copyMyId() async {
    if (_myId.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _myId));
    HapticFeedback.lightImpact();
    _copyResetTimer?.cancel();
    if (mounted) {
      setState(() => _copiedMyId = true);
    }
    showToast(translate('Copied'));
    _copyResetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _copiedMyId = false);
      }
    });
  }

  Future<void> _smartPasteRemoteId() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final raw = data?.text?.trim() ?? '';
      if (raw.isEmpty) {
        showToast(translate('Clipboard is empty'));
        return;
      }
      final candidate = raw.split(RegExp(r'\s+')).first;
      if (!mounted) return;
      setState(() {
        _idController.id = candidate;
        _clipboardChecked = true;
      });
      HapticFeedback.selectionClick();
    } catch (_) {
      showToast(
        translate('Allow browser clipboard access to enable smart paste'),
      );
    }
  }

  Future<void> _cycleThemePreference() async {
    const order = [
      CamelliaThemePreference.system,
      CamelliaThemePreference.light,
      CamelliaThemePreference.dark,
      CamelliaThemePreference.midnight,
    ];
    final current = MyTheme.themeNotifier.value;
    final next = order[(order.indexOf(current) + 1) % order.length];
    await MyTheme.changeThemePreference(next);
    final label = switch (next) {
      CamelliaThemePreference.system => translate('Follow System'),
      CamelliaThemePreference.light => translate('Light'),
      CamelliaThemePreference.dark => translate('Dark'),
      CamelliaThemePreference.midnight => translate('OLED Midnight'),
    };
    showToast(label);
  }

  IconData _themeIcon(CamelliaThemePreference pref) {
    return switch (pref) {
      CamelliaThemePreference.system => Icons.brightness_auto_rounded,
      CamelliaThemePreference.light => Icons.light_mode_rounded,
      CamelliaThemePreference.dark => Icons.dark_mode_rounded,
      CamelliaThemePreference.midnight => Icons.nights_stay_rounded,
    };
  }

  Future<void> _openSettings() {
    return showSettingsOverlay<void>(
      context: context,
      title: translate('Settings'),
      builder: (_) => const WebClientSettingsPage(embedded: true),
    );
  }

  void _applyFullscreenMode(bool enable) {
    if (!kIsWeb) return;
    try {
      if (enable) {
        web.document.documentElement?.requestFullscreen();
      } else {
        if (web.document.fullscreenElement != null) {
          web.document.exitFullscreen();
        }
      }
    } catch (_) {}
  }

  Future<void> _openBrowserCapabilitiesSheet() {
    return showGlassBottomSheet<void>(
      context: context,
      title: translate('Browser Session Controls'),
      builder: (_) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          final theme = Theme.of(sheetCtx);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BrowserCapabilityRow(
                icon: Icons.fullscreen_rounded,
                title: translate('Fullscreen Mode'),
                subtitle: translate(
                  'Maximizes remote canvas and reduces browser chrome. Press Esc to exit.',
                ),
                trailing: Switch.adaptive(
                  value: _fullscreenPreferred,
                  onChanged: (v) {
                    setSheetState(() => _fullscreenPreferred = v);
                    setState(() => _fullscreenPreferred = v);
                    _applyFullscreenMode(v);
                    showToast(
                      v
                          ? translate('Fullscreen enabled for sessions')
                          : translate('Windowed session mode'),
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
              _BrowserCapabilityRow(
                icon: CamelliaIcons.mouse,
                title: translate('Pointer Lock (Relative Mouse)'),
                subtitle: translate(
                  'Captures cursor for 3D apps and precision navigation. Press Esc to release pointer.',
                ),
                trailing: Switch.adaptive(
                  value: _pointerLockPreferred,
                  onChanged: (v) {
                    setSheetState(() => _pointerLockPreferred = v);
                    setState(() => _pointerLockPreferred = v);
                  },
                ),
              ),
              const SizedBox(height: 10),
              _BrowserCapabilityRow(
                icon: CamelliaIcons.keyboard,
                title: translate('System Shortcut Interception'),
                subtitle: translate(
                  'Browser-reserved shortcuts (Ctrl+W, Ctrl+T, Alt+Tab) require Fullscreen or installed PWA window mode to forward reliably.',
                ),
                trailing: GlassBadge(
                  label: translate('PWA / Fullscreen'),
                  tone: GlassBadgeTone.brand,
                  compact: true,
                ),
              ),
              const SizedBox(height: 10),
              _BrowserCapabilityRow(
                icon: CamelliaIcons.clipboard,
                title: translate('Web Clipboard Permission'),
                subtitle: translate(
                  'Verify browser permission for seamless remote copy & paste synchronization.',
                ),
                trailing: GlassButton(
                  variant: GlassButtonVariant.secondary,
                  minHeight: 34,
                  onPressed: () async {
                    try {
                      await Clipboard.getData(Clipboard.kTextPlain);
                      setSheetState(() => _clipboardChecked = true);
                      setState(() => _clipboardChecked = true);
                      showToast(translate('Clipboard permission ready'));
                    } catch (_) {
                      showToast(
                        translate(
                          'Please grant clipboard permission in browser site settings',
                        ),
                      );
                    }
                  },
                  child: Text(
                    _clipboardChecked
                        ? translate('Verified')
                        : translate('Verify'),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                translate(
                  'GPU compositing layers are isolated so frosted glass controls never drop video frame rate.',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Provider.of<FfiModel>(context);
    final viewport = MediaQuery.sizeOf(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CamelliaBackdrop(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final isCompact = width < 640;
              final isExpanded = width >= 1080;
              final horizontalPadding = isCompact
                  ? 14.0
                  : (isExpanded ? 28.0 : 20.0);

              final peersMinHeight = (viewport.height - 460).clamp(
                320.0,
                640.0,
              );

              return FocusTraversalGroup(
                policy: WidgetOrderTraversalPolicy(),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1440),
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        isCompact ? 12 : 18,
                        horizontalPadding,
                        24,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildTopBar(context, isCompact: isCompact),
                          SizedBox(height: isCompact ? 14 : 20),
                          if (isCompact) ...[
                            _buildConnectionHero(context, compact: true),
                            const SizedBox(height: 14),
                            _buildSessionStatusCard(context),
                          ] else
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: isExpanded ? 7 : 6,
                                  child: _buildConnectionHero(
                                    context,
                                    compact: false,
                                  ),
                                ),
                                const SizedBox(width: 18),
                                Expanded(
                                  flex: isExpanded ? 4 : 5,
                                  child: _buildSessionStatusCard(context),
                                ),
                              ],
                            ),
                          SizedBox(height: isCompact ? 14 : 20),
                          _buildPeersPanel(context, peersMinHeight),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, {required bool isCompact}) {
    final theme = Theme.of(context);
    return RepaintBoundary(
      child: GlassSurface(
        layer: CamelliaGlassLayer.sidebar,
        borderRadius: BorderRadius.circular(CamelliaRadius.surface),
        padding: EdgeInsets.symmetric(
          horizontal: isCompact ? 12 : 18,
          vertical: isCompact ? 10 : 12,
        ),
        child: Row(
          children: [
            CamelliaAnimatedBrandMark(
              size: isCompact ? 34 : 38,
              semanticLabel: bind.mainGetAppNameSync(),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    bind.mainGetAppNameSync(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                  if (!isCompact)
                    Text(
                      translate(
                        'Connect and manage trusted devices in your browser',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (!isCompact) ...[
              const SizedBox(width: 10),
              Obx(() {
                final status = stateGlobal.svcStatus.value;
                final (label, tone, pulse) = switch (status) {
                  SvcStatus.ready => (
                    translate('Ready'),
                    GlassBadgeTone.online,
                    false,
                  ),
                  SvcStatus.connecting => (
                    translate('Connecting'),
                    GlassBadgeTone.connecting,
                    true,
                  ),
                  _ => (translate('Not ready'), GlassBadgeTone.offline, false),
                };
                return GlassBadge(
                  label: label,
                  tone: tone,
                  showDot: true,
                  pulse: pulse,
                );
              }),
            ],
            const SizedBox(width: 8),
            GlassIconButton(
              icon: Icons.web_rounded,
              tooltip: translate('Browser Session Controls'),
              selected: _fullscreenPreferred || _pointerLockPreferred,
              onPressed: _openBrowserCapabilitiesSheet,
            ),
            const SizedBox(width: 6),
            ValueListenableBuilder<CamelliaThemePreference>(
              valueListenable: MyTheme.themeNotifier,
              builder: (context, pref, _) {
                return GlassIconButton(
                  icon: _themeIcon(pref),
                  tooltip: translate('Switch Theme'),
                  onPressed: _cycleThemePreference,
                );
              },
            ),
            const SizedBox(width: 6),
            GlassIconButton(
              icon: CamelliaIcons.settings,
              tooltip: translate('Settings'),
              onPressed: _openSettings,
            ),
          ],
        ),
      ),
    );
  }

  void _onFocusChanged() {
    final focused = _idFocusNode.hasFocus;
    if (focused != _isFieldFocused && mounted) {
      setState(() {
        _isFieldFocused = focused;
      });
    }
    _idEmpty = _idEditingController.text.isEmpty;
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

  void _submitConnect() {
    final id = _idController.id.trim();
    if (id.isEmpty) {
      _shakeController.shake();
      showToast(translate('Please enter a Remote ID'));
      return;
    }
    connect(
      context,
      id,
      isFileTransfer: _mode == _WebConnectMode.fileTransfer,
      isViewCamera: _mode == _WebConnectMode.camera,
      isTerminal: _mode == _WebConnectMode.terminal,
    );
  }

  void _handleUnilink(BuildContext context) {
    if (!mounted || webInitialLink.isEmpty) {
      return;
    }
    final link = webInitialLink;
    webInitialLink = '';
    final splitter = ["/#/", "/#", "#/", "#"];
    var fakelink = '';
    for (final s in splitter) {
      if (link.contains(s)) {
        final list = link.split(s);
        if (list.length < 2 || list[1].isEmpty) {
          return;
        }
        list.removeAt(0);
        fakelink = "${bind.mainUriPrefixSync()}${list.join(s)}";
        break;
      }
    }
    if (fakelink.isEmpty) {
      return;
    }
    final uri = Uri.tryParse(fakelink);
    if (uri == null) {
      return;
    }
    final args = urlLinkToCmdArgs(uri);
    if (args == null || args.isEmpty) {
      return;
    }
    bool isFileTransfer = false;
    bool isViewCamera = false;
    bool isTerminal = false;
    bool isTerminalRunAsAdmin = false;
    String? id;
    String? password;
    for (int i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--connect':
        case '--play':
          if (i + 1 < args.length) {
            id = args[i + 1];
            i++;
          }
          break;
        case '--file-transfer':
          isFileTransfer = true;
          if (i + 1 < args.length) {
            id = args[i + 1];
            i++;
          }
          break;
        case '--view-camera':
          isViewCamera = true;
          if (i + 1 < args.length) {
            id = args[i + 1];
            i++;
          }
          break;
        case '--terminal':
          isTerminal = true;
          if (i + 1 < args.length) {
            id = args[i + 1];
            i++;
          }
          break;
        case '--terminal-admin':
          isTerminal = true;
          isTerminalRunAsAdmin = true;
          if (i + 1 < args.length) {
            id = args[i + 1];
            i++;
          }
          break;
        case '--password':
          if (i + 1 < args.length) {
            password = args[i + 1];
            i++;
          }
          break;
        default:
          break;
      }
    }
    if (id != null && mounted) {
      connect(
        context,
        id,
        isFileTransfer: isFileTransfer,
        isViewCamera: isViewCamera,
        isTerminal: isTerminal,
        password: password,
        isTerminalRunAsAdmin: isTerminalRunAsAdmin,
      );
    }
  }

  (String label, IconData icon) _modeMeta(_WebConnectMode mode) {
    return switch (mode) {
      _WebConnectMode.desktop => (
        translate('Remote Control'),
        CamelliaIcons.display,
      ),
      _WebConnectMode.fileTransfer => (
        translate('File Transfer'),
        CamelliaIcons.transfer,
      ),
      _WebConnectMode.terminal => (
        translate('Terminal'),
        CamelliaIcons.terminal,
      ),
      _WebConnectMode.camera => (
        translate('View Camera'),
        CamelliaIcons.camera,
      ),
    };
  }

  Widget _buildConnectionHero(BuildContext context, {required bool compact}) {
    final theme = Theme.of(context);
    final (ctaLabel, ctaIcon) = _modeMeta(_mode);
    final accent = theme.brightness == Brightness.dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;

    return GlassCard(
      title: translate('Connect to a device'),
      subtitle: translate(
        'Enter a Remote ID or pick a saved peer to start an encrypted browser session.',
      ),
      accent: accent,
      padding: EdgeInsets.all(compact ? 14 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassSegmentedControl<_WebConnectMode>(
            compact: compact,
            expand: true,
            selected: _mode,
            items: [
              GlassSegmentItem(
                value: _WebConnectMode.desktop,
                icon: CamelliaIcons.display,
                label: compact ? null : translate('Control'),
                tooltip: translate('Remote Control'),
              ),
              GlassSegmentItem(
                value: _WebConnectMode.fileTransfer,
                icon: CamelliaIcons.transfer,
                label: compact ? null : translate('Files'),
                tooltip: translate('File Transfer'),
              ),
              GlassSegmentItem(
                value: _WebConnectMode.terminal,
                icon: CamelliaIcons.terminal,
                label: compact ? null : translate('Terminal'),
                tooltip: translate('Terminal'),
              ),
              GlassSegmentItem(
                value: _WebConnectMode.camera,
                icon: CamelliaIcons.camera,
                label: compact ? null : translate('Camera'),
                tooltip: translate('View Camera'),
              ),
            ],
            onChanged: (next) {
              if (mounted) {
                setState(() => _mode = next);
              }
            },
          ),
          const SizedBox(height: 14),
          GlassShakeBox(
            controller: _shakeController,
            child: _buildRemoteIdField(
              context,
              compact: compact,
              ctaLabel: ctaLabel,
              ctaIcon: ctaIcon,
            ),
          ),
          if (compact) ...[
            const SizedBox(height: 12),
            GlassButton(
              variant: GlassButtonVariant.primary,
              expand: true,
              icon: Icon(ctaIcon, size: 18),
              onPressed: _submitConnect,
              child: Text(ctaLabel),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRemoteIdField(
    BuildContext context, {
    required bool compact,
    required String ctaLabel,
    required IconData ctaIcon,
  }) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final accent = theme.brightness == Brightness.dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    final radius = BorderRadius.circular(CamelliaRadius.control);

    return AnimatedContainer(
      duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: glass.floatingTint,
        borderRadius: radius,
        boxShadow: _isFieldFocused
            ? [
                BoxShadow(
                  color: glass.focusGlow.withValues(alpha: 0.30),
                  blurRadius: 8,
                  spreadRadius: 0.5,
                ),
              ]
            : const [],
      ),
      child: CustomPaint(
        foregroundPainter: SpecularEdgePainter(
          borderRadius: radius,
          topColor: _isFieldFocused ? accent : glass.specularTop,
          bottomColor: _isFieldFocused
              ? accent.withValues(alpha: 0.55)
              : glass.specularBottom,
          strokeWidth: _isFieldFocused ? 1.25 : 0.9,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            children: [
              Expanded(
                child: RawAutocomplete<Peer>(
                  optionsBuilder: (TextEditingValue textEditingValue) {
                    if (textEditingValue.text == '') {
                      _autocompleteOpts = const Iterable<Peer>.empty();
                    } else if (_allPeersLoader.peers.isEmpty &&
                        !_allPeersLoader.isPeersLoaded) {
                      _autocompleteOpts = [
                        Peer(
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
                        ),
                      ];
                    } else {
                      final textWithoutSpaces = textEditingValue.text
                          .replaceAll(" ", "");
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
                                peer.username.toLowerCase().contains(
                                  textToFind,
                                ) ||
                                peer.hostname.toLowerCase().contains(
                                  textToFind,
                                ) ||
                                peer.alias.toLowerCase().contains(textToFind),
                          )
                          .toList();
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
                        return AutoSizeTextField(
                          controller: fieldTextEditingController,
                          focusNode: fieldFocusNode,
                          minFontSize: 16,
                          autocorrect: false,
                          enableSuggestions: false,
                          keyboardType: TextInputType.visiblePassword,
                          onChanged: (String text) {
                            _idController.id = text;
                          },
                          style: CamelliaTypography.tabular(
                            theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          decoration: InputDecoration(
                            labelText: translate('Remote ID'),
                            hintText: '000 000 000',
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            labelStyle: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          inputFormatters: [IDTextInputFormatter()],
                          onSubmitted: (_) => _submitConnect(),
                        );
                      },
                  onSelected: (option) {
                    setState(() {
                      _idController.id = option.id;
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
                        double maxHeight = options.length * 50.0;
                        if (options.length == 1) {
                          maxHeight = 56;
                        } else if (options.length == 3) {
                          maxHeight = 152;
                        } else if (options.length == 4) {
                          maxHeight = 198;
                        }
                        maxHeight = maxHeight.clamp(0, 224);
                        return Align(
                          alignment: Alignment.topLeft,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: GlassSurface(
                              layer: CamelliaGlassLayer.modal,
                              elevated: true,
                              borderRadius: BorderRadius.circular(
                                CamelliaRadius.surface,
                              ),
                              child: Material(
                                type: MaterialType.transparency,
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxHeight: maxHeight,
                                    maxWidth: 380,
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
                                      : ListView(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 4,
                                          ),
                                          children: options
                                              .map(
                                                (peer) => AutocompletePeerTile(
                                                  onSelect: () =>
                                                      onSelected(peer),
                                                  peer: peer,
                                                ),
                                              )
                                              .toList(),
                                        ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                ),
              ),
              if (_idEmpty)
                GlassIconButton(
                  icon: CamelliaIcons.paste,
                  size: 36,
                  iconSize: 18,
                  tooltip: translate('Paste'),
                  onPressed: _smartPasteRemoteId,
                )
              else
                GlassIconButton(
                  icon: CamelliaIcons.close,
                  size: 36,
                  iconSize: 18,
                  tooltip: translate('Clear'),
                  onPressed: () {
                    setState(() {
                      _idController.clear();
                    });
                  },
                ),
              if (!compact) ...[
                const SizedBox(width: 8),
                GlassButton(
                  variant: GlassButtonVariant.primary,
                  minHeight: 42,
                  icon: Icon(ctaIcon, size: 18),
                  onPressed: _submitConnect,
                  child: Text(ctaLabel),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSessionStatusCard(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final idDisplay = _myId.isEmpty ? '—' : _myId;

    return GlassCard(
      title: translate('Session status'),
      subtitle: translate('Encrypted browser control node'),
      accent: glass.statusEncrypted,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassSurface(
            layer: CamelliaGlassLayer.floating,
            showShadow: false,
            enableBlur: false,
            borderRadius: BorderRadius.circular(CamelliaRadius.control),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        translate('Your ID'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: muted,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        idDisplay,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CamelliaTypography.tabular(
                          theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_myId.isNotEmpty)
                  GlassIconButton(
                    icon: _copiedMyId
                        ? CamelliaIcons.check
                        : CamelliaIcons.copy,
                    size: 34,
                    iconSize: 16,
                    selected: _copiedMyId,
                    tooltip: translate('Copy'),
                    onPressed: _copyMyId,
                  ),
                  // COMPAT-001 contract: trailing: isChangeIdDisabled() ? null : ...
                if (!isChangeIdDisabled()) ...[
                  const SizedBox(width: 6),
                  GlassIconButton(
                    icon: CamelliaIcons.refresh,
                    size: 34,
                    iconSize: 16,
                    tooltip: translate('Change ID'),
                    onPressed: _rotateMyId,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              GlassBadge(
                label: translate('Encrypted channels'),
                icon: CamelliaIcons.shield,
                tone: GlassBadgeTone.encrypted,
                compact: true,
              ),
              GlassBadge(
                label: translate('Control-only'),
                icon: CamelliaIcons.lock,
                tone: GlassBadgeTone.neutral,
                compact: true,
              ),
              GlassBadge(
                label: _fullscreenPreferred
                    ? translate('Fullscreen Ready')
                    : translate('Browser Controls'),
                icon: Icons.fullscreen_rounded,
                tone: _fullscreenPreferred
                    ? GlassBadgeTone.brand
                    : GlassBadgeTone.neutral,
                compact: true,
                onTap: _openBrowserCapabilitiesSheet,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPeersPanel(BuildContext context, double minHeight) {
    return GlassCard(
      title: translate('Your devices'),
      subtitle: translate('Recent, favorites, LAN, and address book peers.'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: SizedBox(height: minHeight, child: PeerTabPage()),
    );
  }
}

class _BrowserCapabilityRow extends StatelessWidget {
  const _BrowserCapabilityRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.brightness == Brightness.dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    return GlassSurface(
      layer: CamelliaGlassLayer.floating,
      showShadow: false,
      enableBlur: false,
      borderRadius: BorderRadius.circular(CamelliaRadius.control),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          trailing,
        ],
      ),
    );
  }
}
