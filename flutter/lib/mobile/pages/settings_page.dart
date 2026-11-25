import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/widgets/setting_widgets.dart';
import 'package:camellia_remote_app/common/widgets/settings_components.dart';
import 'package:camellia_remote_app/common/widgets/socks5_proxy_dialog.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../common.dart';
import '../../common/widgets/dialog.dart';
import '../../common/widgets/login.dart';
import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../widgets/deploy_dialog.dart';
import 'package:camellia_remote_app/common/widgets/server_settings_dialog.dart';
import 'home_page.dart';
import 'scan_page.dart';

class SettingsPage extends StatefulWidget implements PageShape {
  const SettingsPage({super.key});

  @override
  String get title => translate("Settings");

  @override
  Icon get icon => const Icon(CamelliaIcons.settings);

  @override
  List<Widget> get appBarActions =>
      bind.isDisableSettings() ? const [] : const [ScanButton()];

  @override
  State<SettingsPage> createState() => _SettingsState();
}

const url = 'https://github.com/camellia-nexus/remote-client';
const _privacyUrl =
    'https://github.com/camellia-nexus/remote-client/blob/main/docs/privacy.md';

SettingsThemeData _camelliaSettingsTheme(
  BuildContext context,
  Brightness brightness,
) {
  final dark = brightness == Brightness.dark;
  final midnight =
      dark && MyTheme.getThemePreference() == CamelliaThemePreference.midnight;
  final style = MyTheme.getThemeStyle();
  final tokens = AppDesignTokens.resolve(
    style,
    brightness,
    oledMidnight: midnight,
  );
  final glass = CamelliaGlassTokens.of(context);
  final accent = switch (style) {
    CamelliaThemeStyle.obsidianCyber =>
      dark ? const Color(0xFF34D399) : const Color(0xFF059669),
    CamelliaThemeStyle.nordicTitanium =>
      dark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
    CamelliaThemeStyle.auroraFrost =>
      dark ? CamelliaColors.orchid : CamelliaColors.indigo,
  };
  final text = midnight
      ? CamelliaColors.midnightText
      : dark
      ? CamelliaColors.darkText
      : CamelliaColors.lightText;

  return SettingsThemeData(
    settingsListBackground: Colors.transparent,
    settingsSectionBackground: glass.floatingTint,
    dividerColor: tokens.border.withValues(alpha: 0.65),
    tileHighlightColor: accent.withValues(alpha: dark ? 0.16 : 0.08),
    titleTextColor: accent,
    leadingIconsColor: accent,
    trailingTextColor: tokens.muted,
    tileDescriptionTextColor: tokens.muted,
    settingsTileTextColor: text,
    inactiveTitleColor: tokens.muted.withValues(alpha: 0.62),
    inactiveSubtitleColor: tokens.muted.withValues(alpha: 0.52),
    inactiveSwitchColor: tokens.muted.withValues(alpha: 0.34),
    titleTextStyle: const TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.2,
    ),
    tileTextStyle: const TextStyle(
      fontSize: 14.5,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
  );
}

enum KeepScreenOn { never, duringControlled, serviceOn }

String _keepScreenOnToOption(KeepScreenOn value) {
  switch (value) {
    case KeepScreenOn.never:
      return 'never';
    case KeepScreenOn.duringControlled:
      return 'during-controlled';
    case KeepScreenOn.serviceOn:
      return 'service-on';
  }
}

KeepScreenOn optionToKeepScreenOn(String value) {
  switch (value) {
    case 'never':
      return KeepScreenOn.never;
    case 'service-on':
      return KeepScreenOn.serviceOn;
    default:
      return KeepScreenOn.duringControlled;
  }
}

class _SettingsState extends State<SettingsPage> with WidgetsBindingObserver {
  final _hasIgnoreBattery = false;
  var _ignoreBatteryOpt = false;
  var _enableStartOnBoot = false;
  var _showTerminalExtraKeys = false;
  var _floatingWindowDisabled = false;
  var _keepScreenOn = KeepScreenOn.duringControlled;
  var _enableAbr = false;
  var _denyLANDiscovery = false;
  var _onlyWhiteList = false;
  var _enableDirectIPAccess = false;
  var _enableRecordSession = false;
  var _enableHardwareCodec = false;
  var _allowWebSocket = false;
  var _autoRecordIncomingSession = false;
  var _autoRecordOutgoingSession = false;
  var _allowAutoDisconnect = false;
  var _localIP = "";
  var _directAccessPort = "";
  var _fingerprint = "";
  var _buildDate = "";
  var _autoDisconnectTimeout = "";
  var _hideServer = false;
  var _hideProxy = false;
  var _hideNetwork = false;
  var _hideWebSocket = false;
  var _enableTrustedDevices = false;
  var _enableUdpPunch = false;
  var _disableUdp = false;
  var _enableIpv6Punch = false;
  var _isUsingPublicServer = false;
  var _allowAskForNoteAtEndOfConnection = false;
  var _preventSleepWhileConnected = true;
  var _uploadRecordingsToServer = false;

  _SettingsState() {
    _enableAbr = option2bool(
      kOptionEnableAbr,
      bind.mainGetOptionSync(key: kOptionEnableAbr),
    );
    _denyLANDiscovery = !option2bool(
      kOptionEnableLanDiscovery,
      bind.mainGetOptionSync(key: kOptionEnableLanDiscovery),
    );
    _onlyWhiteList = whitelistNotEmpty();
    _enableDirectIPAccess = option2bool(
      kOptionEnableDirectServer,
      bind.mainGetOptionSync(key: kOptionEnableDirectServer),
    );
    _enableRecordSession = option2bool(
      kOptionEnableRecordSession,
      bind.mainGetOptionSync(key: kOptionEnableRecordSession),
    );
    _enableHardwareCodec = option2bool(
      kOptionEnableHwcodec,
      bind.mainGetOptionSync(key: kOptionEnableHwcodec),
    );
    _allowWebSocket = mainGetBoolOptionSync(kOptionAllowWebSocket);
    _disableUdp = bind.mainGetOptionSync(key: kOptionDisableUdp) == 'Y';
    _autoRecordIncomingSession = option2bool(
      kOptionAllowAutoRecordIncoming,
      bind.mainGetOptionSync(key: kOptionAllowAutoRecordIncoming),
    );
    _autoRecordOutgoingSession = option2bool(
      kOptionAllowAutoRecordOutgoing,
      bind.mainGetLocalOption(key: kOptionAllowAutoRecordOutgoing),
    );
    _uploadRecordingsToServer = option2bool(
      kOptionUploadRecordingsToServer,
      bind.mainGetOptionSync(key: kOptionUploadRecordingsToServer),
    );
    _localIP = bind.mainGetOptionSync(key: 'local-ip-addr');
    _directAccessPort = bind.mainGetOptionSync(key: kOptionDirectAccessPort);
    _allowAutoDisconnect = option2bool(
      kOptionAllowAutoDisconnect,
      bind.mainGetOptionSync(key: kOptionAllowAutoDisconnect),
    );
    _autoDisconnectTimeout = bind.mainGetOptionSync(
      key: kOptionAutoDisconnectTimeout,
    );
    _hideServer =
        bind.mainGetBuildinOption(key: kOptionHideServerSetting) == 'Y';
    _hideProxy = bind.mainGetBuildinOption(key: kOptionHideProxySetting) == 'Y';
    _hideNetwork =
        bind.mainGetBuildinOption(key: kOptionHideNetworkSetting) == 'Y';
    _hideWebSocket =
        bind.mainGetBuildinOption(key: kOptionHideWebSocketSetting) == 'Y' ||
        isWeb;
    _enableTrustedDevices = mainGetBoolOptionSync(kOptionEnableTrustedDevices);
    _enableUdpPunch = mainGetLocalBoolOptionSync(kOptionEnableUdpPunch);
    _enableIpv6Punch = mainGetLocalBoolOptionSync(kOptionEnableIpv6Punch);
    _allowAskForNoteAtEndOfConnection = mainGetLocalBoolOptionSync(
      kOptionAllowAskForNoteAtEndOfConnection,
    );
    _preventSleepWhileConnected = mainGetLocalBoolOptionSync(
      kOptionKeepAwakeDuringOutgoingSessions,
    );
    _showTerminalExtraKeys = mainGetLocalBoolOptionSync(
      kOptionEnableShowTerminalExtraKeys,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      var update = false;

      if (_hasIgnoreBattery) {
        final res = await checkAndUpdateIgnoreBatteryStatus();
        if (!mounted) return;
        if (res) {
          update = true;
        }
      }

      final startOnBoot = await checkAndUpdateStartOnBoot();
      if (!mounted) return;
      if (startOnBoot) {
        update = true;
      }

      var enableStartOnBoot = await gFFI.invokeMethod(
        AndroidChannel.kGetStartOnBootOpt,
      );
      if (!mounted) return;
      if (enableStartOnBoot) {
        final canStart = await canStartOnBoot();
        if (!mounted) return;
        if (!canStart) {
          enableStartOnBoot = false;
          gFFI.invokeMethod(AndroidChannel.kSetStartOnBootOpt, false);
        }
      }

      if (enableStartOnBoot != _enableStartOnBoot) {
        update = true;
        _enableStartOnBoot = enableStartOnBoot;
      }

      final alertWindowCheck = await AndroidPermissionManager.check(
        kSystemAlertWindow,
      );
      if (!mounted) return;
      var floatingWindowDisabled =
          bind.mainGetLocalOption(key: kOptionDisableFloatingWindow) == "Y" ||
          !alertWindowCheck;
      if (floatingWindowDisabled != _floatingWindowDisabled) {
        update = true;
        _floatingWindowDisabled = floatingWindowDisabled;
      }

      final keepScreenOn = _floatingWindowDisabled
          ? KeepScreenOn.never
          : optionToKeepScreenOn(
              bind.mainGetLocalOption(key: kOptionKeepScreenOn),
            );
      if (keepScreenOn != _keepScreenOn) {
        update = true;
        _keepScreenOn = keepScreenOn;
      }

      final fingerprint = await bind.mainGetFingerprint();
      if (!mounted) return;
      if (_fingerprint != fingerprint) {
        update = true;
        _fingerprint = fingerprint;
      }

      final buildDate = await bind.mainGetBuildDate();
      if (!mounted) return;
      if (_buildDate != buildDate) {
        update = true;
        _buildDate = buildDate;
      }

      final isUsingPublicServer = await bind.mainIsUsingPublicServer();
      if (!mounted) return;
      if (_isUsingPublicServer != isUsingPublicServer) {
        update = true;
        _isUsingPublicServer = isUsingPublicServer;
      }

      if (update && mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      () async {
        final ibs = await checkAndUpdateIgnoreBatteryStatus();
        final sob = await checkAndUpdateStartOnBoot();
        if (!mounted) return;
        if (ibs || sob) {
          setState(() {});
        }
      }();
    }
  }

  Future<bool> checkAndUpdateIgnoreBatteryStatus() async {
    final res = await AndroidPermissionManager.check(
      kRequestIgnoreBatteryOptimizations,
    );
    if (_ignoreBatteryOpt != res) {
      _ignoreBatteryOpt = res;
      return true;
    } else {
      return false;
    }
  }

  Future<bool> checkAndUpdateStartOnBoot() async {
    if (!await canStartOnBoot() && _enableStartOnBoot) {
      _enableStartOnBoot = false;
      debugPrint(
        "checkAndUpdateStartOnBoot and set _enableStartOnBoot -> false",
      );
      gFFI.invokeMethod(AndroidChannel.kSetStartOnBootOpt, false);
      return true;
    } else {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    Provider.of<FfiModel>(context);
    final outgoingOnly = bind.isOutgoingOnly();
    final incomingOnly = bind.isIncomingOnly();
    final customClientSection = CustomSettingsSection(
      child: Column(
        children: [
          if (bind.isCustomClient())
            Align(alignment: Alignment.center, child: loadPowered(context)),
          Align(alignment: Alignment.center, child: loadLogo()),
        ],
      ),
    );
    final List<AbstractSettingsTile> enhancementsTiles = [];
    final enable2fa = bind.mainHasValid2FaSync();
    final List<AbstractSettingsTile> tfaTiles = [
      SettingsTile.switchTile(
        leading: const Icon(CamelliaIcons.shield),
        title: Text(translate('enable-2fa-title')),
        initialValue: enable2fa,
        onToggle: (v) async {
          void update() {
            if (mounted) setState(() {});
          }

          if (v == false) {
            CommonConfirmDialog(
              gFFI.dialogManager,
              translate('cancel-2fa-confirm-tip'),
              () {
                change2fa(callback: update);
              },
            );
          } else {
            change2fa(callback: update);
          }
        },
      ),
      if (enable2fa)
        SettingsTile.switchTile(
          leading: const Icon(Icons.smart_toy_outlined),
          title: Text(translate('Telegram bot')),
          initialValue: bind.mainHasValidBotSync(),
          onToggle: (v) async {
            void update() {
              if (mounted) setState(() {});
            }

            if (v == false) {
              CommonConfirmDialog(
                gFFI.dialogManager,
                translate('cancel-bot-confirm-tip'),
                () {
                  changeBot(callback: update);
                },
              );
            } else {
              changeBot(callback: update);
            }
          },
        ),
      if (enable2fa)
        SettingsTile.switchTile(
          leading: const Icon(Icons.verified_user_outlined),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(translate('Enable trusted devices')),
              Text(
                '* ${translate('enable-trusted-devices-tip')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          initialValue: _enableTrustedDevices,
          onToggle: isOptionFixed(kOptionEnableTrustedDevices)
              ? null
              : (v) async {
                  await mainSetBoolOption(kOptionEnableTrustedDevices, v);
                  if (mounted) {
                    setState(() {
                      _enableTrustedDevices = v;
                    });
                  }
                },
        ),
      if (enable2fa && _enableTrustedDevices)
        SettingsTile(
          leading: const Icon(Icons.devices_rounded),
          title: Text(translate('Manage trusted devices')),
          trailing: const Icon(Icons.chevron_right_rounded),
          onPressed: (context) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const _ManageTrustedDevices(),
              ),
            );
          },
        ),
    ];

    final List<AbstractSettingsTile> shareScreenTiles = [
      SettingsTile.switchTile(
        leading: const Icon(Icons.wifi_off_rounded),
        title: Text(translate('Deny LAN discovery')),
        initialValue: _denyLANDiscovery,
        onToggle: isOptionFixed(kOptionEnableLanDiscovery)
            ? null
            : (v) async {
                await bind.mainSetOption(
                  key: kOptionEnableLanDiscovery,
                  value: bool2option(kOptionEnableLanDiscovery, !v),
                );
                final newValue = !option2bool(
                  kOptionEnableLanDiscovery,
                  await bind.mainGetOption(key: kOptionEnableLanDiscovery),
                );
                setState(() {
                  _denyLANDiscovery = newValue;
                });
              },
      ),
      SettingsTile.switchTile(
        leading: const Icon(Icons.checklist_rtl_rounded),
        title: Row(
          children: [
            Expanded(child: Text(translate('Use IP Whitelisting'))),
            Offstage(
              offstage: !_onlyWhiteList,
              child: Icon(
                Icons.warning_amber_rounded,
                color: CamelliaGlassTokens.of(context).statusHighLatency,
              ),
            ).marginOnly(left: 5),
          ],
        ),
        initialValue: _onlyWhiteList,
        onToggle: (_) async {
          void update() {
            final onlyWhiteList = whitelistNotEmpty();
            if (onlyWhiteList != _onlyWhiteList && mounted) {
              setState(() {
                _onlyWhiteList = onlyWhiteList;
              });
            }
          }

          changeWhiteList(callback: update);
        },
      ),
      SettingsTile.switchTile(
        leading: const Icon(Icons.speed_rounded),
        title: Text(translate('Adaptive bitrate')),
        initialValue: _enableAbr,
        onToggle: isOptionFixed(kOptionEnableAbr)
            ? null
            : (v) async {
                await mainSetBoolOption(kOptionEnableAbr, v);
                final newValue = await mainGetBoolOption(kOptionEnableAbr);
                setState(() {
                  _enableAbr = newValue;
                });
              },
      ),
      SettingsTile.switchTile(
        leading: const Icon(CamelliaIcons.record),
        title: Text(translate('Enable recording session')),
        initialValue: _enableRecordSession,
        onToggle: isOptionFixed(kOptionEnableRecordSession)
            ? null
            : (v) async {
                await mainSetBoolOption(kOptionEnableRecordSession, v);
                final newValue = await mainGetBoolOption(
                  kOptionEnableRecordSession,
                );
                setState(() {
                  _enableRecordSession = newValue;
                });
              },
      ),
      SettingsTile.switchTile(
        leading: const Icon(Icons.lan_outlined),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(translate("Direct IP Access")),
                  Offstage(
                    offstage: !_enableDirectIPAccess,
                    child: Text(
                      '${translate("Local Address")}: $_localIP${_directAccessPort.isEmpty ? "" : ":$_directAccessPort"}',
                      style: CamelliaTypography.tabular(
                        Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Offstage(
              offstage: !_enableDirectIPAccess,
              child: GlassIconButton(
                icon: CamelliaIcons.edit,
                size: 32,
                iconSize: 16,
                onPressed: isOptionFixed(kOptionDirectAccessPort)
                    ? null
                    : () async {
                        final port = await changeDirectAccessPort(
                          _localIP,
                          _directAccessPort,
                        );
                        if (port != null && mounted) {
                          setState(() {
                            _directAccessPort = port;
                          });
                        }
                      },
              ),
            ),
          ],
        ),
        initialValue: _enableDirectIPAccess,
        onToggle: isOptionFixed(kOptionEnableDirectServer)
            ? null
            : (_) async {
                final newValue = !_enableDirectIPAccess;
                String value = bool2option(kOptionEnableDirectServer, newValue);
                await bind.mainSetOption(
                  key: kOptionEnableDirectServer,
                  value: value,
                );
                if (mounted) {
                  setState(() {
                    _enableDirectIPAccess = newValue;
                  });
                }
              },
      ),
      SettingsTile.switchTile(
        leading: const Icon(Icons.timer_off_outlined),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(translate("auto_disconnect_option_tip")),
                  Offstage(
                    offstage: !_allowAutoDisconnect,
                    child: Text(
                      '${_autoDisconnectTimeout.isEmpty ? '10' : _autoDisconnectTimeout} min',
                      style: CamelliaTypography.tabular(
                        Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Offstage(
              offstage: !_allowAutoDisconnect,
              child: GlassIconButton(
                icon: CamelliaIcons.edit,
                size: 32,
                iconSize: 16,
                onPressed: isOptionFixed(kOptionAutoDisconnectTimeout)
                    ? null
                    : () async {
                        final timeout = await changeAutoDisconnectTimeout(
                          _autoDisconnectTimeout,
                        );
                        if (timeout != null && mounted) {
                          setState(() {
                            _autoDisconnectTimeout = timeout;
                          });
                        }
                      },
              ),
            ),
          ],
        ),
        initialValue: _allowAutoDisconnect,
        onToggle: isOptionFixed(kOptionAllowAutoDisconnect)
            ? null
            : (_) async {
                final newValue = !_allowAutoDisconnect;
                String value = bool2option(
                  kOptionAllowAutoDisconnect,
                  newValue,
                );
                await bind.mainSetOption(
                  key: kOptionAllowAutoDisconnect,
                  value: value,
                );
                if (mounted) {
                  setState(() {
                    _allowAutoDisconnect = newValue;
                  });
                }
              },
      ),
    ];

    if (_hasIgnoreBattery) {
      enhancementsTiles.insert(
        0,
        SettingsTile.switchTile(
          initialValue: _ignoreBatteryOpt,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(translate('Ignore Battery Optimizations')),
            ],
          ),
          onToggle: (v) async {
            if (v) {
              await AndroidPermissionManager.request(
                kRequestIgnoreBatteryOptimizations,
              );
            } else {
              final res = await gFFI.dialogManager.show<bool>(
                (setState, close, context) => CustomAlertDialog(
                  title: ModernDialogHeader.warning(
                    title: translate("Open System Setting"),
                    onClose: () => close(),
                  ),
                  content: Text(
                    translate("android_open_battery_optimizations_tip"),
                  ),
                  actions: [
                    dialogButton(
                      "Cancel",
                      onPressed: () => close(),
                      isOutline: true,
                    ),
                    dialogButton(
                      "Open System Setting",
                      onPressed: () => close(true),
                    ),
                  ],
                ),
              );
              if (res == true) {
                AndroidPermissionManager.startAction(
                  kActionApplicationDetailsSettings,
                );
              }
            }
          },
        ),
      );
    }

    enhancementsTiles.add(
      SettingsTile.switchTile(
        leading: const Icon(Icons.power_settings_new_rounded),
        initialValue: _enableStartOnBoot,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(translate('Start on boot')),
            Text(
              '* ${translate('Start the screen sharing service on boot, requires special permissions')}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        onToggle: (toValue) async {
          if (toValue) {
            if (!await AndroidPermissionManager.check(
              kRequestIgnoreBatteryOptimizations,
            )) {
              if (!await AndroidPermissionManager.request(
                kRequestIgnoreBatteryOptimizations,
              )) {
                return;
              }
            }
            if (!await AndroidPermissionManager.check(kSystemAlertWindow)) {
              if (!await AndroidPermissionManager.request(kSystemAlertWindow)) {
                return;
              }
            }
          }
          setState(() => _enableStartOnBoot = toValue);
          gFFI.invokeMethod(AndroidChannel.kSetStartOnBootOpt, toValue);
        },
      ),
    );

    enhancementsTiles.add(
      SettingsTile.switchTile(
        leading: const Icon(CamelliaIcons.terminal),
        initialValue: _showTerminalExtraKeys,
        title: Text(translate('Show terminal extra keys')),
        onToggle: (bool v) async {
          await mainSetLocalBoolOption(kOptionEnableShowTerminalExtraKeys, v);
          final newValue = mainGetLocalBoolOptionSync(
            kOptionEnableShowTerminalExtraKeys,
          );
          setState(() {
            _showTerminalExtraKeys = newValue;
          });
        },
      ),
    );

    Future<void> onFloatingWindowChanged(bool toValue) async {
      if (toValue) {
        if (!await AndroidPermissionManager.check(kSystemAlertWindow)) {
          if (!await AndroidPermissionManager.request(kSystemAlertWindow)) {
            return;
          }
        }
      }
      final disable = !toValue;
      bind.mainSetLocalOption(
        key: kOptionDisableFloatingWindow,
        value: disable ? 'Y' : defaultOptionNo,
      );
      setState(() => _floatingWindowDisabled = disable);
      gFFI.serverModel.androidUpdatekeepScreenOn();
    }

    enhancementsTiles.add(
      SettingsTile.switchTile(
        leading: const Icon(Icons.picture_in_picture_alt_rounded),
        initialValue: !_floatingWindowDisabled,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(translate('Floating window')),
            Text(
              '* ${translate('floating_window_tip')}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        onToggle: bind.mainIsOptionFixed(key: kOptionDisableFloatingWindow)
            ? null
            : onFloatingWindowChanged,
      ),
    );

    enhancementsTiles.add(
      _getPopupDialogRadioEntry(
        title: 'Keep screen on',
        leadingIcon: Icons.lightbulb_outline_rounded,
        list: [
          _RadioEntry('Never', _keepScreenOnToOption(KeepScreenOn.never)),
          _RadioEntry(
            'During controlled',
            _keepScreenOnToOption(KeepScreenOn.duringControlled),
          ),
          _RadioEntry(
            'During service is on',
            _keepScreenOnToOption(KeepScreenOn.serviceOn),
          ),
        ],
        getter: () => _keepScreenOnToOption(
          _floatingWindowDisabled
              ? KeepScreenOn.never
              : optionToKeepScreenOn(
                  bind.mainGetLocalOption(key: kOptionKeepScreenOn),
                ),
        ),
        asyncSetter:
            isOptionFixed(kOptionKeepScreenOn) || _floatingWindowDisabled
            ? null
            : (value) async {
                await bind.mainSetLocalOption(
                  key: kOptionKeepScreenOn,
                  value: value,
                );
                setState(() => _keepScreenOn = optionToKeepScreenOn(value));
                gFFI.serverModel.androidUpdatekeepScreenOn();
              },
      ),
    );

    final disabledSettings = bind.isDisableSettings();
    final hideSecuritySettings =
        bind.mainGetBuildinOption(key: kOptionHideSecuritySetting) == 'Y';

    final settings = ValueListenableBuilder<CamelliaThemeStyle>(
      valueListenable: MyTheme.themeStyleNotifier,
      builder: (context, _, _) => SettingsList(
        lightTheme: _camelliaSettingsTheme(context, Brightness.light),
        darkTheme: _camelliaSettingsTheme(context, Brightness.dark),
        contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
        sections: [
          customClientSection,
          if (!bind.isDisableAccount())
            SettingsSection(
              title: Text(translate('Account')),
              tiles: [
                SettingsTile(
                  title: Obx(() {
                    final user = gFFI.userModel;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user.userName.value.isEmpty
                              ? translate('Login')
                              : user.displayNameOrUserName,
                        ),
                        if (user.userName.value.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            user.email.value.trim().isNotEmpty
                                ? user.email.value.trim()
                                : '@${user.userName.value}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    );
                  }),
                  leading: Obx(() {
                    final avatar = bind.mainResolveAvatarUrl(
                      avatar: gFFI.userModel.avatar.value,
                    );
                    return buildAvatarWidget(
                          avatar: avatar,
                          size: 28,
                          borderRadius: null,
                          fallback: const Icon(Icons.person_outline_rounded),
                        ) ??
                        const Icon(Icons.person_outline_rounded);
                  }),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onPressed: (context) {
                    if (gFFI.userModel.userName.value.isEmpty) {
                      loginDialog();
                    } else {
                      logOutConfirmDialog();
                    }
                  },
                ),
              ],
            ),
          SettingsSection(
            title: Text(translate('General')),
            tiles: [
              SettingsTile(
                title: Text(translate('Theme')),
                value: ValueListenableBuilder<CamelliaThemePreference>(
                  valueListenable: MyTheme.themeNotifier,
                  builder: (context, pref, _) {
                    final label = switch (pref) {
                      CamelliaThemePreference.light => translate('Light'),
                      CamelliaThemePreference.dark => translate('Dark'),
                      CamelliaThemePreference.midnight => translate(
                        'OLED Midnight',
                      ),
                      CamelliaThemePreference.system => translate(
                        'Follow System',
                      ),
                    };
                    return Text(label);
                  },
                ),
                leading: ValueListenableBuilder<CamelliaThemePreference>(
                  valueListenable: MyTheme.themeNotifier,
                  builder: (context, pref, _) {
                    final icon = switch (pref) {
                      CamelliaThemePreference.light => Icons.light_mode_rounded,
                      CamelliaThemePreference.dark => Icons.dark_mode_rounded,
                      CamelliaThemePreference.midnight =>
                        Icons.nights_stay_rounded,
                      CamelliaThemePreference.system =>
                        Icons.brightness_auto_rounded,
                    };
                    return Icon(icon);
                  },
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onPressed: (context) {
                  showThemeSettings(gFFI.dialogManager, sheetContext: context);
                },
              ),
              SettingsTile(
                title: Text(translate('Theme Style')),
                value: ValueListenableBuilder<CamelliaThemeStyle>(
                  valueListenable: MyTheme.themeStyleNotifier,
                  builder: (context, style, _) {
                    final label = switch (style) {
                      CamelliaThemeStyle.auroraFrost => translate(
                        'Aurora Frost',
                      ),
                      CamelliaThemeStyle.obsidianCyber => translate(
                        'Obsidian Cyber',
                      ),
                      CamelliaThemeStyle.nordicTitanium => translate(
                        'Nordic Titanium',
                      ),
                    };
                    return Text(label);
                  },
                ),
                leading: const Icon(Icons.palette_outlined),
                trailing: const Icon(Icons.chevron_right_rounded),
                onPressed: (context) {
                  showThemeStyleSettings(context);
                },
              ),
              SettingsTile(
                title: Text(translate('Language')),
                leading: const Icon(Icons.translate_rounded),
                trailing: const Icon(Icons.chevron_right_rounded),
                onPressed: (context) {
                  showLanguageSettings(
                    gFFI.dialogManager,
                    sheetContext: context,
                  );
                },
              ),
              if (!bind.isDisableAccount())
                SettingsTile.switchTile(
                  leading: const Icon(Icons.edit_note_rounded),
                  title: Text(translate('note-at-conn-end-tip')),
                  initialValue: _allowAskForNoteAtEndOfConnection,
                  onToggle: (v) async {
                    if (v && !gFFI.userModel.isLogin) {
                      final res = await loginDialog();
                      if (res != true) return;
                    }
                    await mainSetLocalBoolOption(
                      kOptionAllowAskForNoteAtEndOfConnection,
                      v,
                    );
                    final newValue = mainGetLocalBoolOptionSync(
                      kOptionAllowAskForNoteAtEndOfConnection,
                    );
                    setState(() {
                      _allowAskForNoteAtEndOfConnection = newValue;
                    });
                  },
                ),
              if (!incomingOnly)
                SettingsTile.switchTile(
                  leading: const Icon(Icons.bedtime_off_rounded),
                  title: Text(
                    translate('keep-awake-during-outgoing-sessions-label'),
                  ),
                  initialValue: _preventSleepWhileConnected,
                  onToggle: (v) async {
                    await mainSetLocalBoolOption(
                      kOptionKeepAwakeDuringOutgoingSessions,
                      v,
                    );
                    setState(() {
                      _preventSleepWhileConnected = v;
                    });
                  },
                ),
            ],
          ),
          SettingsSection(
            title: Text(translate("Network")),
            tiles: [
              if (!disabledSettings && !_hideNetwork && !_hideServer)
                SettingsTile(
                  title: Text(translate('ID/Relay Server')),
                  leading: const Icon(Icons.dns_rounded),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onPressed: (context) {
                    showServerSettings(gFFI.dialogManager, (callback) async {
                      _isUsingPublicServer =
                          await bind.mainIsUsingPublicServer();
                      if (mounted) setState(callback);
                    });
                  },
                ),
              if (!_hideNetwork && !_hideProxy)
                SettingsTile(
                  title: Text(translate('Socks5/Http(s) Proxy')),
                  leading: const Icon(CamelliaIcons.tunnel),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onPressed: (context) {
                    changeSocks5Proxy();
                  },
                ),
              if (isAndroid && !bind.isOutgoingOnly())
                SettingsTile(
                  title: Text(translate('Deploy')),
                  leading: const Icon(CamelliaIcons.shield),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onPressed: (context) {
                    showDeployDialog();
                  },
                ),
              if (!disabledSettings && !_hideNetwork && !_hideWebSocket)
                SettingsTile.switchTile(
                  leading: const Icon(Icons.swap_calls_rounded),
                  title: Text(translate('Use WebSocket')),
                  initialValue: _allowWebSocket,
                  onToggle: isOptionFixed(kOptionAllowWebSocket)
                      ? null
                      : (v) async {
                          await mainSetBoolOption(kOptionAllowWebSocket, v);
                          final newValue = await mainGetBoolOption(
                            kOptionAllowWebSocket,
                          );
                          setState(() {
                            _allowWebSocket = newValue;
                          });
                        },
                ),
              if (isAndroid && !outgoingOnly && !_isUsingPublicServer)
                SettingsTile.switchTile(
                  leading: const Icon(Icons.portable_wifi_off_rounded),
                  title: Text(translate('Disable UDP')),
                  initialValue: _disableUdp,
                  onToggle: isOptionFixed(kOptionDisableUdp)
                      ? null
                      : (v) async {
                          await bind.mainSetOption(
                            key: kOptionDisableUdp,
                            value: v ? 'Y' : 'N',
                          );
                          final newValue =
                              bind.mainGetOptionSync(key: kOptionDisableUdp) ==
                              'Y';
                          setState(() {
                            _disableUdp = newValue;
                          });
                        },
                ),
              if (!incomingOnly)
                SettingsTile.switchTile(
                  leading: const Icon(Icons.bolt_rounded),
                  title: Text(translate('Enable UDP hole punching')),
                  initialValue: _enableUdpPunch,
                  onToggle: (v) async {
                    await mainSetLocalBoolOption(kOptionEnableUdpPunch, v);
                    final newValue = mainGetLocalBoolOptionSync(
                      kOptionEnableUdpPunch,
                    );
                    setState(() {
                      _enableUdpPunch = newValue;
                    });
                  },
                ),
              if (!incomingOnly)
                SettingsTile.switchTile(
                  leading: const Icon(Icons.public_rounded),
                  title: Text(translate('Enable IPv6 P2P connection')),
                  initialValue: _enableIpv6Punch,
                  onToggle: (v) async {
                    await mainSetLocalBoolOption(kOptionEnableIpv6Punch, v);
                    final newValue = mainGetLocalBoolOptionSync(
                      kOptionEnableIpv6Punch,
                    );
                    setState(() {
                      _enableIpv6Punch = newValue;
                    });
                  },
                ),
            ],
          ),
          if (!bind.isIncomingOnly()) defaultDisplaySection(),
          if (isAndroid)
            SettingsSection(
              title: Text(translate('Hardware Codec')),
              tiles: [
                SettingsTile.switchTile(
                  leading: const Icon(Icons.memory_rounded),
                  title: Text(translate('Enable hardware codec')),
                  initialValue: _enableHardwareCodec,
                  onToggle: isOptionFixed(kOptionEnableHwcodec)
                      ? null
                      : (v) async {
                          await mainSetBoolOption(kOptionEnableHwcodec, v);
                          final newValue = await mainGetBoolOption(
                            kOptionEnableHwcodec,
                          );
                          setState(() {
                            _enableHardwareCodec = newValue;
                          });
                        },
                ),
              ],
            ),
          if (isAndroid)
            SettingsSection(
              title: Text(translate("Recording")),
              tiles: [
                if (!outgoingOnly)
                  SettingsTile.switchTile(
                    leading: const Icon(CamelliaIcons.record),
                    title: Text(
                      translate('Automatically record incoming sessions'),
                    ),
                    initialValue: _autoRecordIncomingSession,
                    onToggle: isOptionFixed(kOptionAllowAutoRecordIncoming)
                        ? null
                        : (v) async {
                            await bind.mainSetOption(
                              key: kOptionAllowAutoRecordIncoming,
                              value: bool2option(
                                kOptionAllowAutoRecordIncoming,
                                v,
                              ),
                            );
                            final newValue = option2bool(
                              kOptionAllowAutoRecordIncoming,
                              await bind.mainGetOption(
                                key: kOptionAllowAutoRecordIncoming,
                              ),
                            );
                            setState(() {
                              _autoRecordIncomingSession = newValue;
                            });
                          },
                  ),
                if (!outgoingOnly)
                  SettingsTile.switchTile(
                    leading: const Icon(CamelliaIcons.upload),
                    title: Text(
                      translate('Upload incoming session recordings to server'),
                    ),
                    initialValue: _uploadRecordingsToServer,
                    onToggle: isOptionFixed(kOptionUploadRecordingsToServer)
                        ? null
                        : (v) async {
                            await mainSetBoolOption(
                              kOptionUploadRecordingsToServer,
                              v,
                            );
                            final newValue = await mainGetBoolOption(
                              kOptionUploadRecordingsToServer,
                            );
                            setState(() {
                              _uploadRecordingsToServer = newValue;
                            });
                          },
                  ),
                if (!incomingOnly)
                  SettingsTile.switchTile(
                    leading: const Icon(CamelliaIcons.record),
                    title: Text(
                      translate('Automatically record outgoing sessions'),
                    ),
                    initialValue: _autoRecordOutgoingSession,
                    onToggle: isOptionFixed(kOptionAllowAutoRecordOutgoing)
                        ? null
                        : (v) async {
                            await bind.mainSetLocalOption(
                              key: kOptionAllowAutoRecordOutgoing,
                              value: bool2option(
                                kOptionAllowAutoRecordOutgoing,
                                v,
                              ),
                            );
                            final newValue = option2bool(
                              kOptionAllowAutoRecordOutgoing,
                              bind.mainGetLocalOption(
                                key: kOptionAllowAutoRecordOutgoing,
                              ),
                            );
                            setState(() {
                              _autoRecordOutgoingSession = newValue;
                            });
                          },
                  ),
                SettingsTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(translate("Directory")),
                  description: Text(bind.mainVideoSaveDirectory(root: false)),
                ),
              ],
            ),
          if (isAndroid &&
              !disabledSettings &&
              !outgoingOnly &&
              !hideSecuritySettings)
            SettingsSection(title: Text(translate('2FA')), tiles: tfaTiles),
          if (isAndroid &&
              !disabledSettings &&
              !outgoingOnly &&
              !hideSecuritySettings)
            SettingsSection(
              title: Text(translate("Share screen")),
              tiles: shareScreenTiles,
            ),
          if (isAndroid &&
              !disabledSettings &&
              !outgoingOnly &&
              !hideSecuritySettings)
            SettingsSection(
              title: Text(translate("Enhancements")),
              tiles: enhancementsTiles,
            ),
          SettingsSection(
            title: Text(translate("About")),
            tiles: [
              SettingsTile(
                onPressed: (context) async {
                  await launchUrl(Uri.parse(url));
                },
                title: Text(
                  translate("Version: ") + version,
                  style: CamelliaTypography.tabular(
                    Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                description: const Text('github.com/camellia-nexus/remote-client'),
                leading: const Icon(Icons.info_outline_rounded),
                trailing: const Icon(Icons.open_in_new_rounded, size: 17),
              ),
              SettingsTile(
                title: Text(translate("Build Date")),
                value: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _buildDate,
                    style: CamelliaTypography.tabular(
                      Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
                leading: const Icon(Icons.schedule_rounded),
              ),
              if (isAndroid)
                SettingsTile(
                  onPressed: (context) => onCopyFingerprint(_fingerprint),
                  title: Text(translate("Fingerprint")),
                  description: Text(
                    _fingerprint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CamelliaTypography.tabular(
                      Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  leading: const Icon(Icons.fingerprint_rounded),
                  trailing: const Icon(CamelliaIcons.copy, size: 16),
                ),
              SettingsTile(
                title: Text(translate("Privacy Statement")),
                onPressed: (context) => launchUrlString(_privacyUrl),
                leading: const Icon(CamelliaIcons.shield),
                trailing: const Icon(Icons.open_in_new_rounded, size: 17),
              ),
            ],
          ),
        ],
      ),
    );
    return CamelliaBackdrop(child: settings);
  }

  Future<bool> canStartOnBoot() async {
    if (_hasIgnoreBattery && !_ignoreBatteryOpt) {
      return false;
    }
    if (!await AndroidPermissionManager.check(kSystemAlertWindow)) {
      return false;
    }
    return true;
  }

  SettingsSection defaultDisplaySection() {
    return SettingsSection(
      title: Text(translate("Display Settings")),
      tiles: [
        SettingsTile(
          title: Text(translate('Display Settings')),
          leading: const Icon(CamelliaIcons.display),
          trailing: const Icon(Icons.chevron_right_rounded),
          onPressed: (context) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const _DisplayPage(),
              ),
            );
          },
        ),
      ],
    );
  }
}

Future<void> showThemeStyleSettings(BuildContext sheetContext) async {
  var currentStyle = MyTheme.getThemeStyle();
  await showGlassBottomSheet<void>(
    context: sheetContext,
    title: translate('Theme Style'),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) {
        final theme = Theme.of(ctx);
        final dark = theme.brightness == Brightness.dark;
        final tokens =
            theme.extension<AppDesignTokens>() ?? MyTheme.tokens(ctx);
        final accent = dark
            ? theme.colorScheme.secondary
            : theme.colorScheme.primary;
        final styles = <(CamelliaThemeStyle, String, String, IconData)>[
          (
            CamelliaThemeStyle.auroraFrost,
            translate('Aurora Frost'),
            translate('Modern Liquid Glass'),
            Icons.auto_awesome_rounded,
          ),
          (
            CamelliaThemeStyle.obsidianCyber,
            translate('Obsidian Cyber'),
            translate('Aerospace Cyberpunk'),
            Icons.bolt_rounded,
          ),
          (
            CamelliaThemeStyle.nordicTitanium,
            translate('Nordic Titanium'),
            translate('Minimalist Brushed Metal'),
            Icons.layers_rounded,
          ),
        ];

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in styles)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: currentStyle == entry.$1
                          ? accent.withValues(alpha: dark ? 0.18 : 0.10)
                          : tokens.surfaceContainer.withValues(
                              alpha: dark ? 0.65 : 0.80,
                            ),
                      borderRadius: BorderRadius.circular(
                        CamelliaRadius.control,
                      ),
                      border: Border.all(
                        color: currentStyle == entry.$1
                            ? accent.withValues(alpha: 0.60)
                            : tokens.border.withValues(alpha: 0.85),
                        width: 0.85,
                      ),
                    ),
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        entry.$4,
                        color: currentStyle == entry.$1 ? accent : tokens.muted,
                      ),
                      title: Text(
                        entry.$2,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: currentStyle == entry.$1
                              ? FontWeight.w700
                              : FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        entry.$3,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: tokens.muted,
                        ),
                      ),
                      trailing: Icon(
                        CamelliaIcons.check,
                        size: 18,
                        color: currentStyle == entry.$1
                            ? accent
                            : Colors.transparent,
                      ),
                      onTap: () async {
                        setSheetState(() => currentStyle = entry.$1);
                        await MyTheme.changeThemeStyle(entry.$1);
                        if (ctx.mounted) Navigator.of(ctx).pop();
                      },
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

void showLanguageSettings(
  OverlayDialogManager dialogManager, {
  BuildContext? sheetContext,
}) async {
  List<dynamic> validLangs = [];
  try {
    final rawLangs = await bind.mainGetLangs();
    final decoded = json.decode(rawLangs);
    if (decoded is List) {
      validLangs = decoded.where((e) => e is List && e.length >= 2).toList();
    } else {
      throw const FormatException('Invalid language list format');
    }
  } catch (e) {
    debugPrint("Failed to load languages: $e");
    dialogManager.show(
      (setState, close, context) {
        return CustomAlertDialog(
          title: ModernDialogHeader.warning(
            title: translate('Language'),
            onClose: close,
          ),
          content: Text('${translate("Failed to load language list")}: $e'),
          actions: [
            dialogButton("Cancel", onPressed: close, isOutline: true),
            dialogButton(
              "Retry",
              onPressed: () {
                close();
                showLanguageSettings(dialogManager, sheetContext: sheetContext);
              },
            ),
          ],
        );
      },
      backDismiss: true,
      clickMaskDismiss: true,
    );
    return;
  }

  var lang = bind.mainGetLocalOption(key: kCommConfKeyLang);
  final isOptFixed = isOptionFixed(kCommConfKeyLang);

  if (sheetContext != null && sheetContext.mounted) {
    await showGlassBottomSheet<void>(
      context: sheetContext,
      title: translate('Language'),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          Future<void> setLang(String? v) async {
            if (v == null || lang == v) return;
            setSheetState(() => lang = v);
            await bind.mainSetLocalOption(key: kCommConfKeyLang, value: v);
            bind.mainChangeLanguage(lang: v);
            reloadCurrentWindow();
            if (ctx.mounted) Navigator.of(ctx).pop();
          }

          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.62,
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              shrinkWrap: true,
              children: [
                getRadio<String>(
                  Text(translate('Default')),
                  defaultOptionLang.toString(),
                  lang,
                  isOptFixed ? null : setLang,
                ),
                Divider(color: CamelliaGlassTokens.of(ctx).specularBottom),
                ...validLangs.map((e) {
                  final key = e[0].toString();
                  final name = e[1].toString();
                  return getRadio<String>(
                    Text(translate(name)),
                    key,
                    lang,
                    isOptFixed ? null : setLang,
                  );
                }),
              ],
            ),
          );
        },
      ),
    );
    return;
  }

  dialogManager.show(
    (setState, close, context) {
      bool isClosed = false;
      Timer? closeTimer;
      void safeClose() {
        if (!isClosed) {
          isClosed = true;
          closeTimer?.cancel();
          close();
        }
      }

      void setLang(String? v) async {
        if (v != null && lang != v) {
          setState(() {
            lang = v;
          });
          await bind.mainSetLocalOption(key: kCommConfKeyLang, value: v);
          bind.mainChangeLanguage(lang: v);
          reloadCurrentWindow();
          closeTimer?.cancel();
          closeTimer = Timer(const Duration(milliseconds: 200), safeClose);
        }
      }

      return CustomAlertDialog(
        content: Column(
          children:
              [
                getRadio<String>(
                  Text(translate('Default')),
                  defaultOptionLang.toString(),
                  lang,
                  isOptFixed ? null : setLang,
                ),
                Divider(color: CamelliaGlassTokens.of(context).specularBottom),
              ] +
              validLangs.map((e) {
                final key = e[0].toString();
                final name = e[1].toString();
                return getRadio<String>(
                  Text(translate(name)),
                  key,
                  lang,
                  isOptFixed ? null : setLang,
                );
              }).toList(),
        ),
        onCancel: safeClose,
      );
    },
    backDismiss: true,
    clickMaskDismiss: true,
  );
}

void showThemeSettings(
  OverlayDialogManager dialogManager, {
  BuildContext? sheetContext,
}) async {
  var themePref = MyTheme.getThemePreference();
  final isOptFixed = isOptionFixed(kCommConfKeyTheme);

  if (sheetContext != null && sheetContext.mounted) {
    await showGlassBottomSheet<void>(
      context: sheetContext,
      title: translate('Theme'),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final theme = Theme.of(ctx);
          final dark = theme.brightness == Brightness.dark;
          final tokens =
              theme.extension<AppDesignTokens>() ?? MyTheme.tokens(ctx);
          final accent = dark
              ? theme.colorScheme.secondary
              : theme.colorScheme.primary;
          final options = [
            (
              CamelliaThemePreference.system,
              translate('Follow System'),
              Icons.brightness_auto_rounded,
            ),
            (
              CamelliaThemePreference.light,
              translate('Light'),
              Icons.light_mode_rounded,
            ),
            (
              CamelliaThemePreference.dark,
              translate('Dark'),
              Icons.dark_mode_rounded,
            ),
            (
              CamelliaThemePreference.midnight,
              translate('OLED Midnight'),
              Icons.nights_stay_rounded,
            ),
          ];
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: options.map((entry) {
                final selected = themePref == entry.$1;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: selected
                          ? accent.withValues(alpha: dark ? 0.18 : 0.10)
                          : tokens.surfaceContainer.withValues(
                              alpha: dark ? 0.65 : 0.80,
                            ),
                      borderRadius: BorderRadius.circular(
                        CamelliaRadius.control,
                      ),
                      border: Border.all(
                        color: selected
                            ? accent.withValues(alpha: 0.60)
                            : tokens.border.withValues(alpha: 0.85),
                        width: 0.85,
                      ),
                    ),
                    child: ListTile(
                      dense: true,
                      enabled: !isOptFixed,
                      leading: Icon(
                        entry.$3,
                        color: selected ? accent : tokens.muted,
                      ),
                      title: Text(
                        entry.$2,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                      trailing: Icon(
                        CamelliaIcons.check,
                        size: 18,
                        color: selected ? accent : Colors.transparent,
                      ),
                      onTap: isOptFixed
                          ? null
                          : () {
                              setSheetState(() => themePref = entry.$1);
                              MyTheme.changeThemePreference(entry.$1);
                              Navigator.of(ctx).pop();
                            },
                    ),
                  ),
                );
              }).toList(),
            ),
          );
        },
      ),
    );
    return;
  }

  dialogManager.show(
    (setState, close, context) {
      bool isClosed = false;
      Timer? closeTimer;
      void safeClose() {
        if (!isClosed) {
          isClosed = true;
          closeTimer?.cancel();
          close();
        }
      }

      void setTheme(CamelliaThemePreference? v) {
        if (v != null && themePref != v) {
          setState(() {
            themePref = v;
          });
          MyTheme.changeThemePreference(v);
          closeTimer?.cancel();
          closeTimer = Timer(const Duration(milliseconds: 200), safeClose);
        }
      }

      return CustomAlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            getRadio(
              Text(translate('Light')),
              CamelliaThemePreference.light,
              themePref,
              isOptFixed ? null : setTheme,
            ),
            getRadio(
              Text(translate('Dark')),
              CamelliaThemePreference.dark,
              themePref,
              isOptFixed ? null : setTheme,
            ),
            getRadio(
              Text(translate('OLED Midnight')),
              CamelliaThemePreference.midnight,
              themePref,
              isOptFixed ? null : setTheme,
            ),
            getRadio(
              Text(translate('Follow System')),
              CamelliaThemePreference.system,
              themePref,
              isOptFixed ? null : setTheme,
            ),
          ],
        ),
        onCancel: safeClose,
      );
    },
    backDismiss: true,
    clickMaskDismiss: true,
  );
}

void showAbout(OverlayDialogManager dialogManager) {
  dialogManager.show(
    (setState, close, context) {
      return CustomAlertDialog(
        title: ModernDialogHeader(
          icon: Icons.info_outline_rounded,
          title: translate('About Camellia Remote'),
          onClose: close,
        ),
        content: Wrap(
          direction: Axis.vertical,
          spacing: 12,
          children: [
            Text(
              '${translate('Version')}: $version',
              style: CamelliaTypography.tabular(
                Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            InkWell(
              onTap: () async {
                await launchUrl(Uri.parse(url));
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'github.com/camellia-nexus/remote-client',
                  style: TextStyle(decoration: TextDecoration.underline),
                ),
              ),
            ),
          ],
        ),
        actions: [
          GlassButton(
            variant: GlassButtonVariant.secondary,
            onPressed: close,
            child: Text(translate('Close')),
          ),
        ],
      );
    },
    clickMaskDismiss: true,
    backDismiss: true,
  );
}

class ScanButton extends StatelessWidget {
  const ScanButton({super.key});

  @override
  Widget build(BuildContext context) {
    return GlassIconButton(
      icon: CamelliaIcons.qrScan,
      size: 36,
      iconSize: 18,
      tooltip: translate('Scan QR'),
      onPressed: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (BuildContext context) => const ScanPage()),
        );
      },
    );
  }
}

class _DisplayPage extends StatefulWidget {
  const _DisplayPage();

  @override
  State<_DisplayPage> createState() => __DisplayPageState();
}

class __DisplayPageState extends State<_DisplayPage> {
  @override
  Widget build(BuildContext context) {
    final tokens =
        Theme.of(context).extension<AppDesignTokens>() ??
        MyTheme.tokens(context);
    final Map codecsJson = jsonDecode(bind.mainSupportedHwdecodings());
    final h264 = codecsJson['h264'] ?? false;
    final h265 = codecsJson['h265'] ?? false;
    var codecList = [
      _RadioEntry('Auto', 'auto'),
      _RadioEntry('VP8', 'vp8'),
      _RadioEntry('VP9', 'vp9'),
      _RadioEntry('AV1', 'av1'),
      if (h264) _RadioEntry('H264', 'h264'),
      if (h265) _RadioEntry('H265', 'h265'),
    ];
    RxBool showCustomImageQuality = false.obs;

    return AppAmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          toolbarHeight: 56,
          leadingWidth: 52,
          flexibleSpace: GlassSurface(
            layer: CamelliaGlassLayer.sidebar,
            borderRadius: BorderRadius.zero,
            showShadow: false,
            strokeWidth: 0,
            child: const SizedBox.expand(),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(0.85),
            child: Container(
              height: 0.85,
              color: tokens.border.withValues(alpha: 0.72),
            ),
          ),
          leading: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Center(
              child: GlassIconButton(
                icon: CamelliaIcons.arrowBack,
                size: 36,
                iconSize: 18,
                tooltip: translate('Back'),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),
          title: Text(translate('Display Settings')),
          centerTitle: true,
        ),
        body: SettingsList(
          lightTheme: _camelliaSettingsTheme(context, Brightness.light),
          darkTheme: _camelliaSettingsTheme(context, Brightness.dark),
          contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          sections: [
            SettingsSection(
              tiles: [
                _getPopupDialogRadioEntry(
                  title: 'Default View Style',
                  leadingIcon: Icons.fit_screen_rounded,
                  list: [
                    _RadioEntry('Scale original', kRemoteViewStyleOriginal),
                    _RadioEntry('Scale adaptive', kRemoteViewStyleAdaptive),
                  ],
                  getter: () =>
                      bind.mainGetUserDefaultOption(key: kOptionViewStyle),
                  asyncSetter: isOptionFixed(kOptionViewStyle)
                      ? null
                      : (value) async {
                          await bind.mainSetUserDefaultOption(
                            key: kOptionViewStyle,
                            value: value,
                          );
                        },
                ),
                _getPopupDialogRadioEntry(
                  title: 'Default Image Quality',
                  leadingIcon: Icons.high_quality_outlined,
                  list: [
                    _RadioEntry('Good image quality', kRemoteImageQualityBest),
                    _RadioEntry('Balanced', kRemoteImageQualityBalanced),
                    _RadioEntry(
                      'Optimize reaction time',
                      kRemoteImageQualityLow,
                    ),
                    _RadioEntry('Custom', kRemoteImageQualityCustom),
                  ],
                  getter: () {
                    final v = bind.mainGetUserDefaultOption(
                      key: kOptionImageQuality,
                    );
                    showCustomImageQuality.value =
                        v == kRemoteImageQualityCustom;
                    return v;
                  },
                  asyncSetter: isOptionFixed(kOptionImageQuality)
                      ? null
                      : (value) async {
                          await bind.mainSetUserDefaultOption(
                            key: kOptionImageQuality,
                            value: value,
                          );
                          showCustomImageQuality.value =
                              value == kRemoteImageQualityCustom;
                        },
                  tail: customImageQualitySetting(),
                  showTail: showCustomImageQuality,
                  notCloseValue: kRemoteImageQualityCustom,
                ),
                _getPopupDialogRadioEntry(
                  title: 'Default Codec',
                  leadingIcon: Icons.video_settings_outlined,
                  list: codecList,
                  getter: () => bind.mainGetUserDefaultOption(
                    key: kOptionCodecPreference,
                  ),
                  asyncSetter: isOptionFixed(kOptionCodecPreference)
                      ? null
                      : (value) async {
                          await bind.mainSetUserDefaultOption(
                            key: kOptionCodecPreference,
                            value: value,
                          );
                        },
                ),
              ],
            ),
            SettingsSection(
              title: Text(translate('Other Default Options')),
              tiles: otherDefaultSettings()
                  .map((e) => otherRow(e.$1, e.$2))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  SettingsTile otherRow(String label, String key) {
    final value = bind.mainGetUserDefaultOption(key: key) == 'Y';
    final isOptFixed = isOptionFixed(key);
    return SettingsTile.switchTile(
      initialValue: value,
      title: Text(translate(label)),
      onToggle: isOptFixed
          ? null
          : (b) async {
              await bind.mainSetUserDefaultOption(
                key: key,
                value: b ? 'Y' : defaultOptionNo,
              );
              setState(() {});
            },
    );
  }
}

class _ManageTrustedDevices extends StatefulWidget {
  const _ManageTrustedDevices();

  @override
  State<_ManageTrustedDevices> createState() => __ManageTrustedDevicesState();
}

class __ManageTrustedDevicesState extends State<_ManageTrustedDevices> {
  final RxList<TrustedDevice> trustedDevices = RxList.empty(growable: true);
  final RxList<Uint8List> selectedDevices = RxList.empty();
  late Future<List<TrustedDevice>> _devicesFuture;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  void _loadDevices() {
    _devicesFuture = TrustedDevice.get().then((devices) {
      trustedDevices.assignAll(devices);
      return devices;
    });
  }

  @override
  Widget build(BuildContext context) {
    final glass = CamelliaGlassTokens.of(context);
    final tokens =
        Theme.of(context).extension<AppDesignTokens>() ??
        MyTheme.tokens(context);

    return AppAmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          toolbarHeight: 56,
          leadingWidth: 52,
          flexibleSpace: GlassSurface(
            layer: CamelliaGlassLayer.sidebar,
            borderRadius: BorderRadius.zero,
            showShadow: false,
            strokeWidth: 0,
            child: const SizedBox.expand(),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(0.85),
            child: Container(
              height: 0.85,
              color: tokens.border.withValues(alpha: 0.72),
            ),
          ),
          leading: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Center(
              child: GlassIconButton(
                icon: CamelliaIcons.arrowBack,
                size: 36,
                iconSize: 18,
                tooltip: translate('Back'),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),
          title: Text(translate('Manage trusted devices')),
          centerTitle: true,
          actions: [
            Obx(
              () => Padding(
                padding: const EdgeInsets.only(right: 12),
                child: GlassIconButton(
                  icon: CamelliaIcons.trash,
                  size: 36,
                  iconSize: 18,
                  accentColor: glass.statusAlert,
                  tooltip: translate('Delete'),
                  onPressed: selectedDevices.isEmpty
                      ? null
                      : () {
                          confrimDeleteTrustedDevicesDialog(
                            trustedDevices,
                            selectedDevices,
                          );
                        },
                ),
              ),
            ),
          ],
        ),
        body: FutureBuilder<List<TrustedDevice>>(
          future: _devicesFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Text('${translate("Error")}: ${snapshot.error}'),
              );
            }
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: trustedDevicesTable(trustedDevices, selectedDevices),
            );
          },
        ),
      ),
    );
  }
}

class _RadioEntry {
  final String label;
  final String value;
  _RadioEntry(this.label, this.value);
}

typedef _RadioEntryGetter = String Function();
typedef _RadioEntrySetter = Future<void> Function(String);

SettingsTile _getPopupDialogRadioEntry({
  required String title,
  required List<_RadioEntry> list,
  required _RadioEntryGetter getter,
  required _RadioEntrySetter? asyncSetter,
  IconData? leadingIcon,
  Widget? tail,
  RxBool? showTail,
  String? notCloseValue,
}) {
  RxString groupValue = ''.obs;
  RxString valueText = ''.obs;

  void init() {
    groupValue.value = getter();
    final e = list.firstWhereOrNull((e) => e.value == groupValue.value);
    if (e != null) {
      valueText.value = e.label;
    }
  }

  init();

  void showSheet(BuildContext sheetContext) async {
    var isSubmitting = false;
    await showGlassBottomSheet<void>(
      context: sheetContext,
      title: translate(title),
      builder: (ctx) {
        final onChanged = asyncSetter == null
            ? null
            : (String? value) async {
                if (value == null || isSubmitting) return;
                isSubmitting = true;
                try {
                  await asyncSetter(value);
                  init();
                  if (value != notCloseValue && ctx.mounted) {
                    Navigator.of(ctx).pop();
                  }
                } finally {
                  isSubmitting = false;
                }
              };

        return Obx(
          () => Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...list.map(
                  (e) => getRadio(
                    Text(translate(e.label)),
                    e.value,
                    groupValue.value,
                    onChanged,
                  ),
                ),
                if (tail != null && showTail != null && showTail.value == true)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
                    child: tail,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  return SettingsTile(
    leading: leadingIcon != null ? Icon(leadingIcon) : null,
    title: Text(translate(title)),
    trailing: const Icon(Icons.chevron_right_rounded),
    onPressed: asyncSetter == null ? null : (context) => showSheet(context),
    value: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Obx(() => Text(translate(valueText.value))),
    ),
  );
}
