import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/setting_widgets.dart';
import 'package:camellia_remote_app/common/widgets/login.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:get/get.dart';

class WebClientSettingsPage extends StatefulWidget {
  const WebClientSettingsPage({super.key});

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

  void _openServerSettings() async {
    final serverConfig = await _loadServerConfig();
    if (!mounted) return;
    if (serverConfig == null) {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(translate('ID/Relay Server')),
          content: Text(translate('Failed to load server configuration')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(translate('Cancel')),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _openServerSettings();
              },
              child: Text(translate('Retry')),
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

              Widget buildField({
                required String label,
                required TextEditingController controller,
                required String error,
                String? hint,
              }) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: controller,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: hint,
                        errorText: error.isEmpty ? null : error,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ],
                );
              }

              return AlertDialog(
                title: Row(
                  children: [
                    Expanded(child: Text(translate('ID/Relay Server'))),
                    ...ServerConfigImportExportWidgets(controllers, errMsgs),
                  ],
                ),
                content: SizedBox(
                  width: 580,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        buildField(
                          label: translate('ID Server'),
                          controller: idCtrl,
                          error: idErr.value,
                          hint: 'host[:port]',
                        ),
                        const SizedBox(height: 10),
                        buildField(
                          label: translate('Relay Server'),
                          controller: relayCtrl,
                          error: relayErr.value,
                          hint: 'host[:port]',
                        ),
                        const SizedBox(height: 10),
                        buildField(
                          label: translate('API Server'),
                          controller: apiCtrl,
                          error: apiErr.value,
                          hint: 'https://api.example.com',
                        ),
                        const SizedBox(height: 10),
                        buildField(
                          label: 'Key',
                          controller: keyCtrl,
                          error: '',
                        ),
                        if (isInProgress) ...[
                          const SizedBox(height: 12),
                          const LinearProgressIndicator(),
                        ],
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: Text(translate('Cancel')),
                  ),
                  FilledButton(
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

  Widget _sectionCard(String title, List<Widget> children) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text(
              translate(title),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          ...children,
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final dropdownField = DropdownButtonFormField<String>(
          initialValue: value,
          items: items,
          isDense: true,
          isExpanded: true,
          onChanged: onChanged,
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
        );

        if (constraints.maxWidth < 420) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 24),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            translate(title),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (subtitle != null)
                            Text(
                              subtitle,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                dropdownField,
              ],
            ),
          );
        }

        return ListTile(
          leading: Icon(icon),
          title: Text(translate(title)),
          subtitle: subtitle == null ? null : Text(subtitle),
          trailing: SizedBox(width: 220, child: dropdownField),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
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

    return Scaffold(
      appBar: AppBar(title: Text(translate('Settings'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionCard('General', [
            if (_langsLoaded && _langs.isNotEmpty)
              _dropdownTile(
                icon: Icons.language,
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
                        if (v == null) {
                          return;
                        }
                        await bind.mainSetLocalOption(
                          key: kCommConfKeyLang,
                          value: v,
                        );
                        reloadCurrentWindow();
                      },
              )
            else if (_langsLoaded && _langsError != null)
              ListTile(
                leading: const Icon(Icons.language),
                title: Text(translate('Language')),
                subtitle: Text(
                  '${translate("Failed to load language list")}: $_langsError',
                  style: const TextStyle(color: Colors.red),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: translate('Retry'),
                  onPressed: _loadLanguages,
                ),
              ),
          ]),
          const SizedBox(height: 12),
          _sectionCard('Account', [
            Obx(() {
              final isLogin = gFFI.userModel.userName.value.isNotEmpty;
              return ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(isLogin ? translate('Logout') : translate('Login')),
                subtitle: isLogin
                    ? Text(gFFI.userModel.userName.value)
                    : Text(translate('Not logged in')),
                onTap: () async {
                  if (isLogin) {
                    await gFFI.userModel.logOut();
                  } else {
                    await loginDialog();
                  }
                  if (mounted) {
                    setState(() {});
                  }
                },
              );
            }),
          ]),
          const SizedBox(height: 12),
          _sectionCard('Network', [
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(translate('ID/Relay Server')),
              subtitle: Text(translate('Configure server endpoints and key')),
              onTap: _openServerSettings,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.web_asset_outlined),
              title: Text(translate('Use WebSocket')),
              subtitle: Text(
                'Web client transport is WS/WSS only (browser limitation).',
              ),
              trailing: Icon(
                allowWebSocket ? Icons.check_circle : Icons.info_outline,
                color: allowWebSocket ? Colors.green : Colors.orange,
              ),
            ),
            const Divider(height: 1),
            const ListTile(
              leading: Icon(Icons.lock_outline),
              title: Text('Direct IP access unavailable'),
              subtitle: Text(
                'Use a device ID with the authenticated ID/Relay route. Direct endpoints stay disabled until they support peer identity verification and end-to-end session encryption.',
              ),
            ),
          ]),
          const SizedBox(height: 12),
          _sectionCard('Display', [
            _dropdownTile(
              icon: Icons.desktop_windows_outlined,
              title: 'Default View Style',
              value: viewStyle,
              items: const [
                DropdownMenuItem(
                  value: kRemoteViewStyleOriginal,
                  child: Text('Scale original'),
                ),
                DropdownMenuItem(
                  value: kRemoteViewStyleAdaptive,
                  child: Text('Scale adaptive'),
                ),
              ],
              onChanged: isOptionFixed(kOptionViewStyle)
                  ? null
                  : (v) => _setUserDefaultOption(kOptionViewStyle, v ?? ''),
            ),
            const Divider(height: 1),
            _dropdownTile(
              icon: Icons.swap_vert_outlined,
              title: 'Default Scroll Style',
              value: scrollStyle,
              items: const [
                DropdownMenuItem(
                  value: kRemoteScrollStyleAuto,
                  child: Text('ScrollAuto'),
                ),
                DropdownMenuItem(
                  value: kRemoteScrollStyleBar,
                  child: Text('Scrollbar'),
                ),
              ],
              onChanged: isOptionFixed(kOptionScrollStyle)
                  ? null
                  : (v) => _setUserDefaultOption(kOptionScrollStyle, v ?? ''),
            ),
            const Divider(height: 1),
            _dropdownTile(
              icon: Icons.high_quality_outlined,
              title: 'Default Image Quality',
              value: imageQuality,
              items: const [
                DropdownMenuItem(
                  value: kRemoteImageQualityBest,
                  child: Text('Good image quality'),
                ),
                DropdownMenuItem(
                  value: kRemoteImageQualityBalanced,
                  child: Text('Balanced'),
                ),
                DropdownMenuItem(
                  value: kRemoteImageQualityLow,
                  child: Text('Optimize reaction time'),
                ),
                DropdownMenuItem(
                  value: kRemoteImageQualityCustom,
                  child: Text('Custom'),
                ),
              ],
              onChanged: isOptionFixed(kOptionImageQuality)
                  ? null
                  : (v) => _setUserDefaultOption(kOptionImageQuality, v ?? ''),
            ),
            if (imageQuality == kRemoteImageQualityCustom)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: customImageQualitySetting(),
              ),
            const Divider(height: 1),
            _dropdownTile(
              icon: Icons.video_settings_outlined,
              title: 'Default Codec',
              value: codecPreference,
              items: const [
                DropdownMenuItem(value: 'auto', child: Text('Auto')),
                DropdownMenuItem(value: 'vp8', child: Text('VP8')),
                DropdownMenuItem(value: 'vp9', child: Text('VP9')),
                DropdownMenuItem(value: 'av1', child: Text('AV1')),
                DropdownMenuItem(value: 'h264', child: Text('H264')),
                DropdownMenuItem(value: 'h265', child: Text('H265')),
              ],
              onChanged: isOptionFixed(kOptionCodecPreference)
                  ? null
                  : (v) =>
                        _setUserDefaultOption(kOptionCodecPreference, v ?? ''),
            ),
          ]),
          const SizedBox(height: 12),
          _sectionCard('Other Default Options', [
            ...otherDefaultSettings().map((item) {
              final key = item.$2;
              final value = bind.mainGetUserDefaultOption(key: key) == 'Y';
              return SwitchListTile(
                value: value,
                onChanged: isOptionFixed(key)
                    ? null
                    : (v) => _setUserDefaultBool(key, v),
                title: Text(_otherLabel(item.$1)),
              );
            }),
          ]),
          const SizedBox(height: 12),
          _sectionCard('About', [
            FutureBuilder<_AboutInfo>(
              future: _aboutFuture,
              builder: (context, snapshot) {
                final info = snapshot.data;
                final version = info?.version ?? '';
                final buildDate = info?.buildDate ?? '';
                final fingerprint = info?.fingerprint ?? '';
                final year = DateTime.now().year;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectionArea(
                        child: Text(
                          '${translate('Version')}: ${version.isEmpty ? '-' : version}',
                        ),
                      ),
                      const SizedBox(height: 6),
                      SelectionArea(
                        child: Text(
                          '${translate('Build Date')}: ${buildDate.isEmpty ? '-' : buildDate}',
                        ),
                      ),
                      const SizedBox(height: 6),
                      SelectionArea(
                        child: Text(
                          '${translate('Fingerprint')}: ${fingerprint.isEmpty ? '-' : fingerprint}',
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Copyright © $year Camellia Computing.',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ]),
        ],
      ),
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
