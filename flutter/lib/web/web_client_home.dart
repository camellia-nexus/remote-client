import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:auto_size_text_field/auto_size_text_field.dart';
import 'package:camellia_remote_app/common/formatter/id_formatter.dart';
import 'package:camellia_remote_app/common/widgets/autocomplete.dart';
import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/common/widgets/login.dart';
import 'package:camellia_remote_app/common/widgets/peer_tab_page.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:camellia_remote_app/web/settings_page.dart';
import 'package:camellia_remote_app/web/web_client_settings_page.dart';
import 'package:flutter/foundation.dart';
// ignore: deprecated_member_use
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
    _hydrateWebSessionPreferences();
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

  void _hydrateWebSessionPreferences() {
    _fullscreenPreferred =
        bind.getLocalFlutterOption(k: kWebPrefFullscreenOnConnect) == 'Y';
    _pointerLockPreferred =
        bind.getLocalFlutterOption(k: kWebPrefPointerLock) == 'Y';
  }

  Future<void> _setFullscreenPreferred(bool enable) async {
    setState(() => _fullscreenPreferred = enable);
    await bind.setLocalFlutterOption(
      k: kWebPrefFullscreenOnConnect,
      v: enable ? 'Y' : 'N',
    );
  }

  Future<void> _setPointerLockPreferred(bool enable) async {
    setState(() => _pointerLockPreferred = enable);
    await bind.setLocalFlutterOption(
      k: kWebPrefPointerLock,
      v: enable ? 'Y' : 'N',
    );
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
    } catch (_) {}
  }

  Future<void> _rotateMyId() async {
    if (isChangeIdDisabled()) {
      return;
    }
    try {
      await bind.mainChangeId(newId: '');
      await _refreshMyId();
    } catch (_) {}
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

  /// Strips spaces and dashes from formatted IDs (e.g. `123 456 789` -> `123456789`)
  /// while preserving single-token hostnames/aliases cleanly.
  Future<void> _smartPasteRemoteId() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final raw = data?.text?.trim() ?? '';
      if (raw.isEmpty) {
        showToast(translate('Clipboard is empty'));
        return;
      }
      final cleanedDigits = raw.replaceAll(RegExp(r'[\s\-]+'), '');
      final numericMatch = RegExp(r'\d[\d\s\-]{4,}\d').firstMatch(raw);
      final String candidate;
      if (RegExp(r'^[\d\s\-]+$').hasMatch(raw) && cleanedDigits.isNotEmpty) {
        candidate = cleanedDigits;
      } else if (numericMatch != null) {
        candidate = numericMatch.group(0)!.replaceAll(RegExp(r'[\s\-]+'), '');
      } else {
        candidate = raw.split(RegExp(r'\s+')).first;
      }

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
    var codecPref = bind.mainGetUserDefaultOption(key: kOptionCodecPreference);
    if (!const {'auto', 'vp8', 'vp9', 'av1', 'h264', 'h265'}.contains(
      codecPref,
    )) {
      codecPref = 'auto';
    }
    var qualityPref = bind.mainGetUserDefaultOption(key: kOptionImageQuality);
    if (!const {
      kRemoteImageQualityBest,
      kRemoteImageQualityBalanced,
      kRemoteImageQualityLow,
    }.contains(qualityPref)) {
      qualityPref = kRemoteImageQualityBalanced;
    }

    return showGlassBottomSheet<void>(
      context: context,
      title: translate('Browser Session Controls'),
      builder: (_) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          final theme = Theme.of(sheetCtx);
          final tokens =
              theme.extension<AppDesignTokens>() ?? MyTheme.tokens(sheetCtx);

          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.78,
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
              shrinkWrap: true,
              children: [
                _BrowserCapabilityRow(
                  icon: Icons.fullscreen_rounded,
                  title: translate('Fullscreen Mode'),
                  subtitle: translate(
                    'Maximizes remote canvas and reduces browser chrome. Press Esc to exit.',
                  ),
                  trailing: Switch.adaptive(
                    value: _fullscreenPreferred,
                    onChanged: (v) async {
                      setSheetState(() {});
                      await _setFullscreenPreferred(v);
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
                    onChanged: (v) async {
                      setSheetState(() {});
                      await _setPointerLockPreferred(v);
                    },
                  ),
                ),
                const SizedBox(height: 10),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.surfaceContainer.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(CamelliaRadius.control),
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
                        Text(
                          translate('Default Image Quality'),
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        GlassSegmentedControl<String>(
                          compact: true,
                          expand: true,
                          selected: qualityPref,
                          items: [
                            GlassSegmentItem(
                              value: kRemoteImageQualityBest,
                              label: translate('Good image quality'),
                            ),
                            GlassSegmentItem(
                              value: kRemoteImageQualityBalanced,
                              label: translate('Balanced'),
                            ),
                            GlassSegmentItem(
                              value: kRemoteImageQualityLow,
                              label: translate('Optimize reaction time'),
                            ),
                          ],
                          onChanged: (next) async {
                            setSheetState(() => qualityPref = next);
                            await bind.mainSetUserDefaultOption(
                              key: kOptionImageQuality,
                              value: next,
                            );
                            if (mounted) setState(() {});
                          },
                        ),
                        const SizedBox(height: 12),
                        Text(
                          translate('Default Codec'),
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        GlassSegmentedControl<String>(
                          compact: true,
                          expand: true,
                          selected: codecPref,
                          items: [
                            GlassSegmentItem(
                              value: 'auto',
                              label: translate('Auto'),
                            ),
                            const GlassSegmentItem(value: 'vp9', label: 'VP9'),
                            const GlassSegmentItem(value: 'av1', label: 'AV1'),
                            const GlassSegmentItem(
                              value: 'h264',
                              label: 'H264',
                            ),
                            const GlassSegmentItem(
                              value: 'h265',
                              label: 'H265',
                            ),
                          ],
                          onChanged: (next) async {
                            setSheetState(() => codecPref = next);
                            await bind.mainSetUserDefaultOption(
                              key: kOptionCodecPreference,
                              value: next,
                            );
                            if (mounted) setState(() {});
                          },
                        ),
                      ],
                    ),
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
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Provider.of<FfiModel>(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CamelliaBackdrop(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final height = constraints.maxHeight;
              final isCompact = width < 680;
              final isExpanded = width >= 1120;
              final horizontalPadding = isCompact
                  ? 14.0
                  : (isExpanded ? 24.0 : 18.0);
              final useViewportFillingLayout = !isCompact && height >= 600;

              if (useViewportFillingLayout) {
                // Precision Studio viewport-filling layout: zero outer page
                // scrollbar — PeerTabPage owns the single scrollable region.
                return FocusTraversalGroup(
                  policy: WidgetOrderTraversalPolicy(),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1480),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          horizontalPadding,
                          14,
                          horizontalPadding,
                          16,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildTopBar(context, isCompact: false),
                            const SizedBox(height: 14),
                            IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    flex: isExpanded ? 8 : 7,
                                    child: _buildConnectionHero(
                                      context,
                                      compact: false,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    flex: isExpanded ? 4 : 5,
                                    child: _buildSessionStatusCard(context),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            Expanded(child: _buildPeersPanel(context)),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }

              // Compact mobile-browser / short-viewport fallback
              final peersHeight = math.max(320.0, height - 180.0);
              return FocusTraversalGroup(
                policy: WidgetOrderTraversalPolicy(),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1480),
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        12,
                        horizontalPadding,
                        20,
                      ),
                      children: [
                        _buildTopBar(context, isCompact: isCompact),
                        const SizedBox(height: 12),
                        _buildConnectionHero(context, compact: isCompact),
                        const SizedBox(height: 12),
                        _buildSessionStatusCard(context),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: peersHeight,
                          child: _buildPeersPanel(context),
                        ),
                      ],
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

  Widget _buildLocalIdHeaderPill(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);
    final idDisplay = _myId.isEmpty ? '—' : _myId;
    // COMPAT-001 contract: trailing: isChangeIdDisabled() ? null : ...
    final Widget? changeIdTrailing = isChangeIdDisabled()
        ? null
        : InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: _rotateMyId,
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Icon(
                CamelliaIcons.refresh,
                size: 14,
                color: tokens.muted,
              ),
            ),
          );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceContainer.withValues(alpha: dark ? 0.68 : 0.84),
        borderRadius: BorderRadius.circular(CamelliaRadius.pill),
        border: Border.all(
          color: tokens.border.withValues(alpha: 0.85),
          width: 0.85,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${translate('ID')}: ',
              style: theme.textTheme.labelSmall?.copyWith(color: tokens.muted),
            ),
            Text(
              idDisplay,
              style: CamelliaTypography.tabular(
                theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            if (_myId.isNotEmpty) ...[
              const SizedBox(width: 6),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: _copyMyId,
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(
                    _copiedMyId ? CamelliaIcons.check : CamelliaIcons.copy,
                    size: 14,
                    color: _copiedMyId ? tokens.success : tokens.muted,
                  ),
                ),
              ),
            ],
            if (changeIdTrailing != null) ...[
              const SizedBox(width: 4),
              changeIdTrailing,
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAccountHeaderPill(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);
    final glass = CamelliaGlassTokens.of(context);

    return Obx(() {
      final user = gFFI.userModel;
      final signedIn = user.userName.value.isNotEmpty;
      final label = signedIn
          ? user.displayNameOrUserName
          : translate('Login');

      return GestureDetector(
        onTap: () async {
          HapticFeedback.selectionClick();
          if (signedIn) {
            logOutConfirmDialog();
          } else {
            await loginDialog();
          }
          if (mounted) setState(() {});
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.surfaceContainer.withValues(
                alpha: dark ? 0.68 : 0.84,
              ),
              borderRadius: BorderRadius.circular(CamelliaRadius.pill),
              border: Border.all(
                color: tokens.border.withValues(alpha: 0.85),
                width: 0.85,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: signedIn ? glass.statusOnline : tokens.muted,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.person_outline_rounded,
                    size: 15,
                    color: signedIn
                        ? theme.colorScheme.onSurface
                        : tokens.muted,
                  ),
                  const SizedBox(width: 5),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _buildTopBar(BuildContext context, {required bool isCompact}) {
    final theme = Theme.of(context);
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);

    return RepaintBoundary(
      child: GlassSurface(
        layer: CamelliaGlassLayer.sidebar,
        borderRadius: BorderRadius.circular(CamelliaRadius.surface),
        padding: EdgeInsets.symmetric(
          horizontal: isCompact ? 12 : 16,
          vertical: isCompact ? 8 : 10,
        ),
        child: Row(
          children: [
            CamelliaBrandMark(
              size: isCompact ? 30 : 34,
              semanticLabel: bind.mainGetAppNameSync(),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      bind.mainGetAppNameSync(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                  if (!isCompact) ...[
                    const SizedBox(width: 10),
                    Obx(() {
                      final status = stateGlobal.svcStatus.value;
                      final (label, tone) = switch (status) {
                        SvcStatus.ready => (
                          translate('Ready'),
                          GlassBadgeTone.online,
                        ),
                        SvcStatus.connecting => (
                          translate('Connecting'),
                          GlassBadgeTone.connecting,
                        ),
                        _ => (
                          translate('Not ready'),
                          GlassBadgeTone.offline,
                        ),
                      };
                      return GlassBadge(
                        label: label,
                        tone: tone,
                        showDot: true,
                        compact: true,
                      );
                    }),
                  ],
                ],
              ),
            ),
            if (!isCompact) ...[
              _buildLocalIdHeaderPill(context),
              const SizedBox(width: 8),
              _buildAccountHeaderPill(context),
              const SizedBox(width: 8),
              Container(
                width: 0.85,
                height: 22,
                color: tokens.border.withValues(alpha: 0.72),
              ),
              const SizedBox(width: 8),
            ],
            GlassIconButton(
              icon: Icons.web_rounded,
              size: 36,
              iconSize: 18,
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
                  size: 36,
                  iconSize: 18,
                  tooltip: translate('Switch Theme'),
                  onPressed: _cycleThemePreference,
                );
              },
            ),
            const SizedBox(width: 6),
            WebSettingsPage(
              size: 36,
              iconSize: 18,
              onClosed: () {
                if (mounted) {
                  setState(_hydrateWebSessionPreferences);
                }
              },
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
    if (_fullscreenPreferred) {
      _applyFullscreenMode(true);
    }
    if (_pointerLockPreferred) {
      gFFI.inputModel.setRelativeMouseMode(true);
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
    final (ctaLabel, ctaIcon) = _modeMeta(_mode);

    return GlassCard(
      title: translate('Connect to a device'),
      subtitle: translate(
        'Enter a Remote ID or pick a saved peer to start an encrypted browser session.',
      ),
      padding: EdgeInsets.fromLTRB(
        compact ? 14 : 18,
        8,
        compact ? 14 : 18,
        compact ? 14 : 16,
      ),
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
                label: compact ? null : translate('Transfer file'),
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
                label: compact ? null : translate('View camera'),
                tooltip: translate('View Camera'),
              ),
            ],
            onChanged: (next) {
              if (mounted) {
                setState(() => _mode = next);
              }
            },
          ),
          const SizedBox(height: 12),
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
            const SizedBox(height: 10),
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
    final dark = theme.brightness == Brightness.dark;
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);
    final accent = dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    final radius = BorderRadius.circular(CamelliaRadius.control);

    return AnimatedContainer(
      duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: tokens.surfaceContainer.withValues(alpha: dark ? 0.72 : 0.84),
        borderRadius: radius,
        border: Border.all(
          color: _isFieldFocused
              ? accent.withValues(alpha: 0.85)
              : tokens.border.withValues(alpha: 0.85),
          width: _isFieldFocused ? 1.2 : 0.85,
        ),
        boxShadow: _isFieldFocused
            ? [
                BoxShadow(
                  color: accent.withValues(alpha: dark ? 0.22 : 0.14),
                  blurRadius: 8,
                ),
              ]
            : const [],
      ),
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
                  final textWithoutSpaces = textEditingValue.text.replaceAll(
                    " ",
                    "",
                  );
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
                          fontWeight: FontWeight.w700,
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
                          color: tokens.muted,
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
                    );
                  },
            ),
          ),
          if (_idEmpty)
            GlassIconButton(
              icon: CamelliaIcons.paste,
              size: 34,
              iconSize: 17,
              tooltip: translate('Paste'),
              onPressed: _smartPasteRemoteId,
            )
          else
            GlassIconButton(
              icon: CamelliaIcons.close,
              size: 34,
              iconSize: 17,
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
              minHeight: 40,
              icon: Icon(ctaIcon, size: 17),
              onPressed: _submitConnect,
              child: Text(ctaLabel),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSessionStatusCard(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);
    final idDisplay = _myId.isEmpty ? '—' : _myId;
    final codecRaw = bind.mainGetUserDefaultOption(key: kOptionCodecPreference);
    final codecLabel = codecRaw.isEmpty || codecRaw == 'auto'
        ? translate('Auto')
        : codecRaw.toUpperCase();

    return GlassCard(
      title: translate('Session status'),
      subtitle: translate('Encrypted browser control node'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.surfaceContainer.withValues(
                alpha: dark ? 0.68 : 0.84,
              ),
              borderRadius: BorderRadius.circular(CamelliaRadius.control),
              border: Border.all(
                color: tokens.border.withValues(alpha: 0.85),
                width: 0.85,
              ),
            ),
            child: Padding(
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
                            color: tokens.muted,
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
                      size: 32,
                      iconSize: 15,
                      selected: _copiedMyId,
                      tooltip: translate('Copy'),
                      onPressed: _copyMyId,
                    ),
                  // COMPAT-001 contract: trailing: isChangeIdDisabled() ? null : ...
                  if (!isChangeIdDisabled()) ...[
                    const SizedBox(width: 6),
                    GlassIconButton(
                      icon: CamelliaIcons.refresh,
                      size: 32,
                      iconSize: 15,
                      tooltip: translate('Change ID'),
                      onPressed: _rotateMyId,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              GlassBadge(
                label: translate('Encrypted channels'),
                icon: CamelliaIcons.shield,
                tone: GlassBadgeTone.encrypted,
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
              if (_pointerLockPreferred)
                GlassBadge(
                  label: translate('Relative mouse mode'),
                  icon: CamelliaIcons.mouse,
                  tone: GlassBadgeTone.brand,
                  compact: true,
                  onTap: _openBrowserCapabilitiesSheet,
                ),
              GlassBadge(
                label: '${translate('Codec')}: $codecLabel',
                icon: Icons.video_settings_outlined,
                tone: GlassBadgeTone.neutral,
                tabularNums: true,
                compact: true,
                onTap: _openBrowserCapabilitiesSheet,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPeersPanel(BuildContext context) {
    final theme = Theme.of(context);
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);

    return GlassSurface(
      layer: CamelliaGlassLayer.floating,
      borderRadius: BorderRadius.circular(CamelliaRadius.surface),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                translate('Your devices'),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  translate('Recent, favorites, LAN, and address book peers.'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.muted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Expanded(child: PeerTabPage()),
        ],
      ),
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
    final dark = theme.brightness == Brightness.dark;
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);
    final accent = dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceContainer.withValues(alpha: dark ? 0.68 : 0.82),
        borderRadius: BorderRadius.circular(CamelliaRadius.control),
        border: Border.all(
          color: tokens.border.withValues(alpha: 0.85),
          width: 0.85,
        ),
      ),
      child: Padding(
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
                      color: tokens.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            trailing,
          ],
        ),
      ),
    );
  }
}
