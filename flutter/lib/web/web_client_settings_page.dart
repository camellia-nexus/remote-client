import 'dart:convert';

import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/login.dart';
import 'package:camellia_remote_app/common/widgets/server_settings_dialog.dart';
import 'package:camellia_remote_app/common/widgets/setting_widgets.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher_string.dart';

const String kWebPrefFullscreenOnConnect = 'web_fullscreen_on_connect';
const String kWebPrefPointerLock = 'web_pointer_lock';

class WebClientSettingsPage extends StatefulWidget {
  const WebClientSettingsPage({super.key, this.embedded = false});

  /// When true (e.g. hosted inside [showSettingsOverlay]), omits the outer
  /// [Scaffold] and [AppBar] so the page never renders a duplicated header.
  final bool embedded;

  @override
  State<WebClientSettingsPage> createState() => _WebClientSettingsPageState();
}

class _WebClientSettingsPageState extends State<WebClientSettingsPage> {
  late final Future<_AboutInfo> _aboutFuture;

  final List<({String key, String label})> _langs = [];
  bool _langsLoaded = false;
  String? _langsError;
  bool _fullscreenOnConnect = false;
  bool _pointerLockPreferred = false;

  @override
  void initState() {
    super.initState();
    _aboutFuture = _loadAboutInfo();
    _fullscreenOnConnect =
        bind.getLocalFlutterOption(k: kWebPrefFullscreenOnConnect) == 'Y';
    _pointerLockPreferred =
        bind.getLocalFlutterOption(k: kWebPrefPointerLock) == 'Y';
    _loadLanguages();
  }

  Future<void> _loadLanguages() async {
    try {
      _langsError = null;
      final langsJson = await bind.mainGetLangs();
      final parsed = jsonDecode(langsJson) as List<dynamic>;
      _langs.clear();
      _langs.add((key: defaultOptionLang, label: translate('Default')));
      for (final row in parsed) {
        if (row is List && row.length >= 2) {
          final key = row[0].toString();
          final label = row[1].toString();
          _langs.add((key: key, label: label));
        }
      }
      _langsLoaded = true;
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      _langsError = e.toString();
      _langsLoaded = true;
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<_AboutInfo> _loadAboutInfo() async {
    final version = await bind.mainGetVersion();
    final buildDate = await bind.mainGetBuildDate();
    final fingerprint = await bind.mainGetFingerprint();
    return _AboutInfo(
      version: version,
      buildDate: buildDate,
      fingerprint: fingerprint,
    );
  }

  Future<void> _setUserDefaultOption(String key, String value) async {
    await bind.mainSetUserDefaultOption(key: key, value: value);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _setUserDefaultBool(String key, bool value) async {
    final offValue = key == kOptionEnableFileCopyPaste ? 'N' : defaultOptionNo;
    await bind.mainSetUserDefaultOption(
      key: key,
      value: value ? 'Y' : offValue,
    );
    if (mounted) {
      setState(() {});
    }
  }

  void _openServerSettings() {
    showServerSettings(gFFI.dialogManager, (cb) {
      if (mounted) {
        setState(cb);
      }
    });
  }

  String _otherLabel(String raw) {
    if (raw == 'show_monitors_tip') {
      return translate('Show monitors toolbar');
    }
    if (raw == 'swap-left-right-mouse') {
      return translate('Swap left and right mouse buttons');
    }
    return translate(raw);
  }

  Widget _sectionCard({
    required IconData icon,
    required String title,
    String? subtitle,
    required List<Widget> children,
  }) {
    final theme = Theme.of(context);
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);
    final accent = theme.brightness == Brightness.dark
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    return GlassCard(
      title: translate(title),
      subtitle: subtitle == null ? null : translate(subtitle),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(CamelliaRadius.control),
        ),
        child: Icon(icon, size: 17, color: accent),
      ),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 0.85,
                color: tokens.border.withValues(alpha: 0.65),
              ),
            children[i],
          ],
        ],
      ),
    );
  }

  Widget _dropdownTile({
    required IconData icon,
    required String title,
    required String value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?>? onChanged,
    String? subtitle,
  }) {
    final theme = Theme.of(context);
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final dropdownField = DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surfaceContainer.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(CamelliaRadius.control),
            border: Border.all(
              color: tokens.border.withValues(alpha: 0.85),
              width: 0.85,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: value,
                items: items,
                isExpanded: true,
                isDense: true,
                dropdownColor: theme.colorScheme.surfaceContainerHigh,
                icon: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: tokens.muted,
                ),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
                onChanged: onChanged,
              ),
            ),
          ),
        );

        final headerRow = Row(
          children: [
            Icon(icon, size: 19, color: tokens.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    translate(title),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: tokens.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );

        if (constraints.maxWidth < 460) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                headerRow,
                const SizedBox(height: 8),
                SizedBox(height: 38, child: dropdownField),
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Expanded(child: headerRow),
              const SizedBox(width: 14),
              SizedBox(width: 210, height: 38, child: dropdownField),
            ],
          ),
        );
      },
    );
  }

  Widget _buildThemeRow(BuildContext context) {
    final theme = Theme.of(context);
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);

    return ValueListenableBuilder<CamelliaThemePreference>(
      valueListenable: MyTheme.themeNotifier,
      builder: (context, pref, _) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 480;
              final switcher = GlassSegmentedControl<CamelliaThemePreference>(
                compact: compact,
                expand: compact,
                selected: pref,
                items: [
                  GlassSegmentItem(
                    value: CamelliaThemePreference.system,
                    icon: Icons.brightness_auto_rounded,
                    label: compact ? null : translate('Follow System'),
                    tooltip: translate('Follow System'),
                  ),
                  GlassSegmentItem(
                    value: CamelliaThemePreference.light,
                    icon: Icons.light_mode_rounded,
                    label: compact ? null : translate('Light'),
                    tooltip: translate('Light'),
                  ),
                  GlassSegmentItem(
                    value: CamelliaThemePreference.dark,
                    icon: Icons.dark_mode_rounded,
                    label: compact ? null : translate('Dark'),
                    tooltip: translate('Dark'),
                  ),
                  GlassSegmentItem(
                    value: CamelliaThemePreference.midnight,
                    icon: Icons.nights_stay_rounded,
                    label: compact ? null : translate('OLED Midnight'),
                    tooltip: translate('OLED Midnight'),
                  ),
                ],
                onChanged: (next) async {
                  await MyTheme.changeThemePreference(next);
                  if (mounted) {
                    setState(() {});
                  }
                },
              );

              final labelCol = Row(
                children: [
                  Icon(Icons.brightness_6_rounded, size: 19, color: tokens.muted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          translate('Theme'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          translate(
                            'Switch between Light, Dark, OLED Midnight, or System appearance.',
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: tokens.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );

              if (constraints.maxWidth < 620) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [labelCol, const SizedBox(height: 10), switcher],
                );
              }
              return Row(
                children: [
                  Expanded(child: labelCol),
                  const SizedBox(width: 14),
                  switcher,
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildThemeStyleRow(BuildContext context) {
    final theme = Theme.of(context);
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);

    return ValueListenableBuilder<CamelliaThemeStyle>(
      valueListenable: MyTheme.themeStyleNotifier,
      builder: (context, style, _) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 480;
              final switcher = GlassSegmentedControl<CamelliaThemeStyle>(
                compact: compact,
                expand: compact,
                selected: style,
                items: [
                  GlassSegmentItem(
                    value: CamelliaThemeStyle.auroraFrost,
                    icon: Icons.auto_awesome_rounded,
                    label: compact ? null : translate('Aurora Frost'),
                    tooltip: translate('Aurora Frost'),
                  ),
                  GlassSegmentItem(
                    value: CamelliaThemeStyle.obsidianCyber,
                    icon: Icons.bolt_rounded,
                    label: compact ? null : translate('Obsidian Cyber'),
                    tooltip: translate('Obsidian Cyber'),
                  ),
                  GlassSegmentItem(
                    value: CamelliaThemeStyle.nordicTitanium,
                    icon: Icons.layers_rounded,
                    label: compact ? null : translate('Nordic Titanium'),
                    tooltip: translate('Nordic Titanium'),
                  ),
                ],
                onChanged: (next) async {
                  await MyTheme.changeThemeStyle(next);
                  if (mounted) {
                    setState(() {});
                  }
                },
              );

              final labelCol = Row(
                children: [
                  Icon(Icons.palette_outlined, size: 19, color: tokens.muted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          translate('Theme Style'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          translate('Modern Liquid Glass'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: tokens.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );

              if (constraints.maxWidth < 620) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [labelCol, const SizedBox(height: 10), switcher],
                );
              }
              return Row(
                children: [
                  Expanded(child: labelCol),
                  const SizedBox(width: 14),
                  switcher,
                ],
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens =
        theme.extension<AppDesignTokens>() ?? MyTheme.tokens(context);
    final glass = CamelliaGlassTokens.of(context);
    final allowWebSocket = mainGetBoolOptionSync(kOptionAllowWebSocket);

    final viewStyleRaw = bind.mainGetUserDefaultOption(key: kOptionViewStyle);
    final viewStyle =
        const {
          kRemoteViewStyleOriginal,
          kRemoteViewStyleAdaptive,
        }.contains(viewStyleRaw)
        ? viewStyleRaw
        : kRemoteViewStyleOriginal;
    final scrollStyleRaw = bind.mainGetUserDefaultOption(
      key: kOptionScrollStyle,
    );
    final scrollStyle =
        const {
          kRemoteScrollStyleAuto,
          kRemoteScrollStyleBar,
        }.contains(scrollStyleRaw)
        ? scrollStyleRaw
        : kRemoteScrollStyleAuto;
    final imageQualityRaw = bind.mainGetUserDefaultOption(
      key: kOptionImageQuality,
    );
    final imageQuality =
        const {
          kRemoteImageQualityBest,
          kRemoteImageQualityBalanced,
          kRemoteImageQualityLow,
          kRemoteImageQualityCustom,
        }.contains(imageQualityRaw)
        ? imageQualityRaw
        : kRemoteImageQualityBalanced;
    final codecPreferenceRaw = bind.mainGetUserDefaultOption(
      key: kOptionCodecPreference,
    );
    final codecPreference =
        const {
          'auto',
          'vp8',
          'vp9',
          'av1',
          'h264',
          'h265',
        }.contains(codecPreferenceRaw)
        ? codecPreferenceRaw
        : 'auto';

    var currentLang = bind.mainGetLocalOption(key: kCommConfKeyLang);
    final langKeys = _langs.map((e) => e.key).toSet();
    if (!langKeys.contains(currentLang)) {
      currentLang = defaultOptionLang;
    }

    final listContent = ListView(
      padding: EdgeInsets.all(widget.embedded ? 16 : 20),
      children: [
        _sectionCard(
          icon: CamelliaIcons.settings,
          title: 'General',
          subtitle: 'Appearance and display language',
          children: [
            _buildThemeRow(context),
            _buildThemeStyleRow(context),
            if (_langsLoaded && _langs.isNotEmpty)
              _dropdownTile(
                icon: Icons.language_rounded,
                title: 'Language',
                value: currentLang,
                items: _langs
                    .map(
                      (e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.label)),
                    )
                    .toList(),
                onChanged: isOptionFixed(kCommConfKeyLang)
                    ? null
                    : (v) async {
                        if (v == null) return;
                        await bind.mainSetLocalOption(
                          key: kCommConfKeyLang,
                          value: v,
                        );
                        reloadCurrentWindow();
                      },
              )
            else if (_langsLoaded && _langsError != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.language_rounded, color: glass.statusAlert),
                title: Text(translate('Language')),
                subtitle: Text(
                  '${translate("Failed to load language list")}: $_langsError',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: glass.statusAlert,
                  ),
                ),
                trailing: GlassIconButton(
                  icon: CamelliaIcons.refresh,
                  size: 34,
                  iconSize: 17,
                  tooltip: translate('Retry'),
                  onPressed: _loadLanguages,
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        _sectionCard(
          icon: Icons.person_outline_rounded,
          title: 'Account',
          subtitle: 'Sync address book and trusted sessions',
          children: [
            Obx(() {
              final isLogin = gFFI.userModel.userName.value.isNotEmpty;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.account_circle_outlined,
                      size: 22,
                      color: tokens.muted,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isLogin
                                ? gFFI.userModel.displayNameOrUserName
                                : translate('Not logged in'),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            isLogin
                                ? translate('Signed in to Camellia account')
                                : translate(
                                    'Sign in to sync devices and address book',
                                  ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: tokens.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    GlassButton(
                      variant: isLogin
                          ? GlassButtonVariant.secondary
                          : GlassButtonVariant.primary,
                      minHeight: 36,
                      onPressed: () async {
                        if (isLogin) {
                          logOutConfirmDialog();
                        } else {
                          await loginDialog();
                        }
                        if (mounted) {
                          setState(() {});
                        }
                      },
                      child: Text(
                        isLogin ? translate('Logout') : translate('Login'),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
        const SizedBox(height: 14),
        _sectionCard(
          icon: CamelliaIcons.tunnel,
          title: 'Network',
          subtitle: 'Relay routing and browser transport status',
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.dns_outlined, color: tokens.muted),
              title: Text(
                translate('ID/Relay Server'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                translate('Configure server endpoints and key'),
                style: theme.textTheme.bodySmall?.copyWith(color: tokens.muted),
              ),
              trailing: GlassButton(
                variant: GlassButtonVariant.secondary,
                minHeight: 34,
                onPressed: _openServerSettings,
                child: Text(translate('Configure')),
              ),
              onTap: _openServerSettings,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.web_asset_outlined, color: tokens.muted),
              title: Text(
                translate('Use WebSocket'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                translate(
                  'Web client transport is WS/WSS only (browser limitation).',
                ),
                style: theme.textTheme.bodySmall?.copyWith(color: tokens.muted),
              ),
              trailing: GlassBadge(
                label: allowWebSocket
                    ? translate('Active')
                    : translate('Required'),
                tone: allowWebSocket
                    ? GlassBadgeTone.online
                    : GlassBadgeTone.warning,
                showDot: true,
                compact: true,
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(CamelliaIcons.lock, color: tokens.muted),
              title: Text(
                translate('Direct IP access unavailable'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                translate(
                  'Use a device ID with the authenticated ID/Relay route. Direct endpoints stay disabled until they support peer identity verification and end-to-end session encryption.',
                ),
                style: theme.textTheme.bodySmall?.copyWith(color: tokens.muted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _sectionCard(
          icon: Icons.web_rounded,
          title: 'Browser Session Controls',
          subtitle: 'Session ergonomics and input behavior',
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _fullscreenOnConnect,
              onChanged: (v) async {
                setState(() => _fullscreenOnConnect = v);
                await bind.setLocalFlutterOption(
                  k: kWebPrefFullscreenOnConnect,
                  v: v ? 'Y' : 'N',
                );
              },
              secondary: Icon(Icons.fullscreen_rounded, color: tokens.muted),
              title: Text(
                translate('Fullscreen Mode'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                translate(
                  'Maximizes remote canvas and reduces browser chrome. Press Esc to exit.',
                ),
                style: theme.textTheme.bodySmall?.copyWith(color: tokens.muted),
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _pointerLockPreferred,
              onChanged: (v) async {
                setState(() => _pointerLockPreferred = v);
                await bind.setLocalFlutterOption(
                  k: kWebPrefPointerLock,
                  v: v ? 'Y' : 'N',
                );
              },
              secondary: Icon(CamelliaIcons.mouse, color: tokens.muted),
              title: Text(
                translate('Pointer Lock (Relative Mouse)'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                translate(
                  'Captures cursor for 3D apps and precision navigation. Press Esc to release pointer.',
                ),
                style: theme.textTheme.bodySmall?.copyWith(color: tokens.muted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _sectionCard(
          icon: CamelliaIcons.display,
          title: 'Display',
          subtitle: 'Default scaling, video quality, and codec preferences',
          children: [
            _dropdownTile(
              icon: Icons.fit_screen_rounded,
              title: 'Default View Style',
              value: viewStyle,
              items: [
                DropdownMenuItem(
                  value: kRemoteViewStyleOriginal,
                  child: Text(translate('Scale original')),
                ),
                DropdownMenuItem(
                  value: kRemoteViewStyleAdaptive,
                  child: Text(translate('Scale adaptive')),
                ),
              ],
              onChanged: isOptionFixed(kOptionViewStyle)
                  ? null
                  : (v) => _setUserDefaultOption(kOptionViewStyle, v ?? ''),
            ),
            _dropdownTile(
              icon: Icons.swap_vert_outlined,
              title: 'Default Scroll Style',
              value: scrollStyle,
              items: [
                DropdownMenuItem(
                  value: kRemoteScrollStyleAuto,
                  child: Text(translate('ScrollAuto')),
                ),
                DropdownMenuItem(
                  value: kRemoteScrollStyleBar,
                  child: Text(translate('Scrollbar')),
                ),
              ],
              onChanged: isOptionFixed(kOptionScrollStyle)
                  ? null
                  : (v) => _setUserDefaultOption(kOptionScrollStyle, v ?? ''),
            ),
            _dropdownTile(
              icon: Icons.high_quality_outlined,
              title: 'Default Image Quality',
              value: imageQuality,
              items: [
                DropdownMenuItem(
                  value: kRemoteImageQualityBest,
                  child: Text(translate('Good image quality')),
                ),
                DropdownMenuItem(
                  value: kRemoteImageQualityBalanced,
                  child: Text(translate('Balanced')),
                ),
                DropdownMenuItem(
                  value: kRemoteImageQualityLow,
                  child: Text(translate('Optimize reaction time')),
                ),
                DropdownMenuItem(
                  value: kRemoteImageQualityCustom,
                  child: Text(translate('Custom')),
                ),
              ],
              onChanged: isOptionFixed(kOptionImageQuality)
                  ? null
                  : (v) => _setUserDefaultOption(kOptionImageQuality, v ?? ''),
            ),
            if (imageQuality == kRemoteImageQualityCustom)
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 10),
                child: customImageQualitySetting(),
              ),
            _dropdownTile(
              icon: Icons.video_settings_outlined,
              title: 'Default Codec',
              value: codecPreference,
              items: [
                DropdownMenuItem(value: 'auto', child: Text(translate('Auto'))),
                const DropdownMenuItem(value: 'vp8', child: Text('VP8')),
                const DropdownMenuItem(value: 'vp9', child: Text('VP9')),
                const DropdownMenuItem(value: 'av1', child: Text('AV1')),
                const DropdownMenuItem(value: 'h264', child: Text('H264')),
                const DropdownMenuItem(value: 'h265', child: Text('H265')),
              ],
              onChanged: isOptionFixed(kOptionCodecPreference)
                  ? null
                  : (v) =>
                        _setUserDefaultOption(kOptionCodecPreference, v ?? ''),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _sectionCard(
          icon: Icons.checklist_rounded,
          title: 'Other Default Options',
          subtitle: 'Session ergonomics and input behavior',
          children: [
            ...otherDefaultSettings().map((item) {
              final key = item.$2;
              final value = bind.mainGetUserDefaultOption(key: key) == 'Y';
              return SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: value,
                onChanged: isOptionFixed(key)
                    ? null
                    : (v) => _setUserDefaultBool(key, v),
                title: Text(
                  _otherLabel(item.$1),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              );
            }),
          ],
        ),
        const SizedBox(height: 14),
        _sectionCard(
          icon: CamelliaIcons.shield,
          title: 'About',
          subtitle: 'Version, privacy, and licenses',
          children: [
            FutureBuilder<_AboutInfo>(
              future: _aboutFuture,
              builder: (context, snapshot) {
                final info = snapshot.data;
                final version = info?.version ?? '';
                final buildDate = info?.buildDate ?? '';
                final fingerprint = info?.fingerprint ?? '';
                final monoStyle = CamelliaTypography.tabular(
                  theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                );
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectionArea(
                        child: Text(
                          '${translate('Version')}: ${version.isEmpty ? '—' : version}',
                          style: monoStyle,
                        ),
                      ),
                      const SizedBox(height: 6),
                      SelectionArea(
                        child: Text(
                          '${translate('Build Date')}: ${buildDate.isEmpty ? '—' : buildDate}',
                          style: monoStyle,
                        ),
                      ),
                      const SizedBox(height: 6),
                      SelectionArea(
                        child: Text(
                          '${translate('Fingerprint')}: ${fingerprint.isEmpty ? '—' : fingerprint}',
                          style: monoStyle,
                        ),
                      ),
                      const SizedBox(height: 10),
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => launchUrlString(
                          'https://github.com/camellia-nexus/remote-client',
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'github.com/camellia-nexus/remote-client',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: theme.colorScheme.primary,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.open_in_new_rounded,
                                size: 14,
                                color: theme.colorScheme.primary,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );

    if (widget.embedded) {
      return Material(type: MaterialType.transparency, child: listContent);
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(translate('Settings')),
      ),
      body: CamelliaBackdrop(child: SafeArea(child: listContent)),
    );
  }
}

class _AboutInfo {
  const _AboutInfo({
    required this.version,
    required this.buildDate,
    required this.fingerprint,
  });

  final String version;
  final String buildDate;
  final String fingerprint;
}
