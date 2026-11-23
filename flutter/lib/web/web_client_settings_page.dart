import 'dart:convert';

import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/common/widgets/login.dart';
import 'package:camellia_remote_app/common/widgets/setting_widgets.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

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

  @override
  void initState() {
    super.initState();
    _aboutFuture = _loadAboutInfo();
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

  Future<ServerConfig?> _loadServerConfig() async {
    try {
      final rawOptions = await bind.mainGetOptions();
      final options = jsonDecode(rawOptions);
      if (options is! Map<String, dynamic>) {
        return null;
      }
      return ServerConfig.fromOptions(options);
    } catch (_) {
      return null;
    }
  }

  Future<void> _openServerSettings() async {
    final serverConfig = await _loadServerConfig();
    if (!mounted) return;
    if (serverConfig == null) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => CustomAlertDialog(
          title: ModernDialogHeader.warning(
            title: translate('ID/Relay Server'),
            subtitle: translate('Failed to load server configuration'),
          ),
          content: Text(
            translate(
              'Please verify your browser network connection and retry loading endpoint settings.',
            ),
            style: Theme.of(ctx).textTheme.bodyMedium,
          ),
          actions: [
            dialogButton(
              'Cancel',
              onPressed: () => Navigator.of(ctx).pop(),
              isOutline: true,
            ),
            dialogButton(
              'Retry',
              onPressed: () {
                Navigator.of(ctx).pop();
                _openServerSettings();
              },
            ),
          ],
        ),
      );
      return;
    }

    final idCtrl = TextEditingController(text: serverConfig.idServer);
    final relayCtrl = TextEditingController(text: serverConfig.relayServer);
    final apiCtrl = TextEditingController(text: serverConfig.apiServer);
    final keyCtrl = TextEditingController(text: serverConfig.key);

    final idErr = ''.obs;
    final relayErr = ''.obs;
    final apiErr = ''.obs;
    final controllers = [idCtrl, relayCtrl, apiCtrl, keyCtrl];
    final errMsgs = [idErr, relayErr, apiErr];
    var isInProgress = false;

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              Future<void> submit() async {
                setDialogState(() {
                  isInProgress = true;
                });
                final ok = await setServerConfig(
                  null,
                  errMsgs,
                  ServerConfig(
                    idServer: idCtrl.text.trim(),
                    relayServer: relayCtrl.text.trim(),
                    apiServer: apiCtrl.text.trim(),
                    key: keyCtrl.text.trim(),
                  ),
                );
                if (!dialogContext.mounted) {
                  return;
                }
                setDialogState(() {
                  isInProgress = false;
                });
                if (ok) {
                  Navigator.of(dialogContext).pop();
                  showToast(translate('Successful'));
                  if (mounted) {
                    setState(() {});
                  }
                } else {
                  setDialogState(() {});
                  showToast(translate('Failed'));
                }
              }

              return CustomAlertDialog(
                title: Row(
                  children: [
                    Expanded(
                      child: ModernDialogHeader(
                        icon: Icons.dns_rounded,
                        title: translate('ID/Relay Server'),
                        subtitle: translate(
                          'Configure server endpoints and key',
                        ),
                      ),
                    ),
                    ...ServerConfigImportExportWidgets(controllers, errMsgs),
                  ],
                ),
                content: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 540),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GlassInput(
                          labelText: translate('ID Server'),
                          controller: idCtrl,
                          errorText: idErr.value.isEmpty ? null : idErr.value,
                          hintText: 'host[:port]',
                          tabularNums: true,
                        ),
                        const SizedBox(height: 12),
                        GlassInput(
                          labelText: translate('Relay Server'),
                          controller: relayCtrl,
                          errorText: relayErr.value.isEmpty
                              ? null
                              : relayErr.value,
                          hintText: 'host[:port]',
                          tabularNums: true,
                        ),
                        const SizedBox(height: 12),
                        GlassInput(
                          labelText: translate('API Server'),
                          controller: apiCtrl,
                          errorText: apiErr.value.isEmpty ? null : apiErr.value,
                          hintText: 'https://api.example.com',
                        ),
                        const SizedBox(height: 12),
                        GlassInput(
                          labelText: translate('Key'),
                          controller: keyCtrl,
                          tabularNums: true,
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  GlassButton(
                    variant: GlassButtonVariant.secondary,
                    onPressed: isInProgress
                        ? null
                        : () => Navigator.of(dialogContext).pop(),
                    child: Text(translate('Cancel')),
                  ),
                  GlassButton(
                    variant: GlassButtonVariant.primary,
                    loading: isInProgress,
                    onPressed: isInProgress ? null : submit,
                    child: Text(translate('OK')),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      for (final c in controllers) {
        c.dispose();
      }
    }
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
    final glass = CamelliaGlassTokens.of(context);
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
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 0.8,
                color: glass.specularBottom.withValues(alpha: 0.55),
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
    final glass = CamelliaGlassTokens.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final dropdownField = GlassSurface(
          layer: CamelliaGlassLayer.floating,
          showShadow: false,
          enableBlur: false,
          borderRadius: BorderRadius.circular(CamelliaRadius.control),
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
                color: theme.colorScheme.onSurfaceVariant,
              ),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
              onChanged: onChanged,
            ),
          ),
        );

        final headerRow = Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
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
                        color: theme.colorScheme.onSurfaceVariant,
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
              SizedBox(
                width: 210,
                height: 38,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(CamelliaRadius.control),
                    border: Border.all(color: glass.specularBottom, width: 0.6),
                  ),
                  child: dropdownField,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildThemeRow(BuildContext context) {
    final theme = Theme.of(context);
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
                  Icon(
                    Icons.palette_outlined,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
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
                            color: theme.colorScheme.onSurfaceVariant,
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
          icon: Icons.tune_rounded,
          title: 'General',
          subtitle: 'Appearance and display language',
          children: [
            _buildThemeRow(context),
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
                  size: 36,
                  iconSize: 18,
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
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isLogin
                                ? gFFI.userModel.userName.value
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
                                    'Sign in to access your synced devices',
                                  ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
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
                      minHeight: 38,
                      onPressed: () async {
                        if (isLogin) {
                          await gFFI.userModel.logOut();
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
          icon: Icons.hub_outlined,
          title: 'Network',
          subtitle: 'Relay routing and browser transport status',
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.dns_outlined,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              title: Text(
                translate('ID/Relay Server'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                translate('Configure server endpoints and key'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
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
              leading: Icon(
                Icons.web_asset_outlined,
                color: theme.colorScheme.onSurfaceVariant,
              ),
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
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
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
              leading: Icon(
                CamelliaIcons.lock,
                color: theme.colorScheme.onSurfaceVariant,
              ),
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
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
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
              icon: Icons.desktop_windows_outlined,
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
          title: translate('About'),
          children: [
            FutureBuilder<_AboutInfo>(
              future: _aboutFuture,
              builder: (context, snapshot) {
                final info = snapshot.data;
                final version = info?.version ?? '';
                final buildDate = info?.buildDate ?? '';
                final fingerprint = info?.fingerprint ?? '';
                final year = DateTime.now().year;
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
                          '${translate('Version')}: ${version.isEmpty ? '-' : version}',
                          style: monoStyle,
                        ),
                      ),
                      const SizedBox(height: 6),
                      SelectionArea(
                        child: Text(
                          '${translate('Build Date')}: ${buildDate.isEmpty ? '-' : buildDate}',
                          style: monoStyle,
                        ),
                      ),
                      const SizedBox(height: 6),
                      SelectionArea(
                        child: Text(
                          '${translate('Fingerprint')}: ${fingerprint.isEmpty ? '-' : fingerprint}',
                          style: monoStyle,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Copyright © $year Camellia Computing.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
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
