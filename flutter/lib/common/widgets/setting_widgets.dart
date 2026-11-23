import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:debounce_throttle/debounce_throttle.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

Widget customImageQualityWidget({
  required double initQuality,
  required double initFps,
  required Function(double)? setQuality,
  required Function(double)? setFps,
  required bool showFps,
  required bool showMoreQuality,
}) {
  return CustomImageQualityWidget(
    initQuality: initQuality,
    initFps: initFps,
    setQuality: setQuality,
    setFps: setFps,
    showFps: showFps,
    showMoreQuality: showMoreQuality,
  );
}

class CustomImageQualityWidget extends StatefulWidget {
  final double initQuality;
  final double initFps;
  final Function(double)? setQuality;
  final Function(double)? setFps;
  final bool showFps;
  final bool showMoreQuality;

  const CustomImageQualityWidget({
    super.key,
    required this.initQuality,
    required this.initFps,
    required this.setQuality,
    required this.setFps,
    required this.showFps,
    required this.showMoreQuality,
  });

  @override
  State<CustomImageQualityWidget> createState() =>
      _CustomImageQualityWidgetState();
}

class _CustomImageQualityWidgetState extends State<CustomImageQualityWidget> {
  late final RxDouble qualityValue;
  late final RxDouble fpsValue;
  late final RxBool moreQualityChecked;
  late final Debouncer<double> debouncerQuality;
  late final Debouncer<double> debouncerFps;

  @override
  void initState() {
    super.initState();
    double q = widget.initQuality;
    if (q < kMinQuality ||
        q > (widget.showMoreQuality ? kMaxMoreQuality : kMaxQuality)) {
      q = kDefaultQuality;
    }
    double f = widget.initFps;
    if (f < kMinFps || f > kMaxFps) {
      f = kDefaultFps;
    }
    qualityValue = q.obs;
    fpsValue = f.obs;
    moreQualityChecked = RxBool(qualityValue.value > kMaxQuality);
    debouncerQuality = Debouncer<double>(
      const Duration(milliseconds: 1000),
      onChanged: widget.setQuality,
      initialValue: qualityValue.value,
    );
    debouncerFps = Debouncer<double>(
      const Duration(milliseconds: 1000),
      onChanged: widget.setFps,
      initialValue: fpsValue.value,
    );
  }

  @override
  void dispose() {
    debouncerQuality.cancel();
    debouncerFps.cancel();
    super.dispose();
  }

  void onMoreChanged(bool? value) {
    if (value == null) return;
    moreQualityChecked.value = value;
    if (!value && qualityValue.value > 100) {
      qualityValue.value = 100;
    }
    debouncerQuality.value = qualityValue.value;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassSurface(
      layer: CamelliaGlassLayer.floating,
      showShadow: false,
      enableBlur: false,
      borderRadius: BorderRadius.circular(CamelliaRadius.control),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Obx(() {
            final maxQ = moreQualityChecked.value
                ? kMaxMoreQuality
                : kMaxQuality;
            final clampedQ = qualityValue.value.clamp(kMinQuality, maxQ);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      translate('Bitrate'),
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    GlassBadge(
                      label: '${clampedQ.round()}%',
                      tone: GlassBadgeTone.brand,
                      tabularNums: true,
                      compact: true,
                    ),
                    const Spacer(),
                    if (widget.showMoreQuality)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            translate('More'),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Switch.adaptive(
                            value: moreQualityChecked.value,
                            onChanged: widget.setQuality == null
                                ? null
                                : (v) => onMoreChanged(v),
                          ),
                        ],
                      ),
                  ],
                ),
                Slider(
                  value: clampedQ,
                  min: kMinQuality,
                  max: maxQ,
                  divisions: moreQualityChecked.value
                      ? ((kMaxMoreQuality - kMinQuality) / 10).round()
                      : ((kMaxQuality - kMinQuality) / 5).round(),
                  onChanged: widget.setQuality == null
                      ? null
                      : (double value) {
                          qualityValue.value = value;
                          debouncerQuality.value = value;
                        },
                ),
              ],
            );
          }),
          if (widget.showFps)
            Obx(() {
              final clampedFps = fpsValue.value.clamp(kMinFps, kMaxFps);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        translate('FPS'),
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      GlassBadge(
                        label: '${clampedFps.round()} FPS',
                        tone: GlassBadgeTone.encrypted,
                        tabularNums: true,
                        compact: true,
                      ),
                    ],
                  ),
                  Slider(
                    value: clampedFps,
                    min: kMinFps,
                    max: kMaxFps,
                    divisions: ((kMaxFps - kMinFps) / 5).round(),
                    onChanged: widget.setFps == null
                        ? null
                        : (double value) {
                            fpsValue.value = value;
                            debouncerFps.value = value;
                          },
                  ),
                ],
              );
            }),
        ],
      ),
    );
  }
}

Widget customImageQualitySetting() {
  const qualityKey = 'custom_image_quality';
  const fpsKey = 'custom-fps';

  final initQuality =
      double.tryParse(bind.mainGetUserDefaultOption(key: qualityKey)) ??
      kDefaultQuality;
  final isQualityFixed = isOptionFixed(qualityKey);
  final initFps =
      double.tryParse(bind.mainGetUserDefaultOption(key: fpsKey)) ??
      kDefaultFps;
  final isFpsFixed = isOptionFixed(fpsKey);

  return customImageQualityWidget(
    initQuality: initQuality,
    initFps: initFps,
    setQuality: isQualityFixed
        ? null
        : (v) {
            bind.mainSetUserDefaultOption(key: qualityKey, value: v.toString());
          },
    setFps: isFpsFixed
        ? null
        : (v) {
            bind.mainSetUserDefaultOption(key: fpsKey, value: v.toString());
          },
    showFps: true,
    showMoreQuality: true,
  );
}

List<Widget> ServerConfigImportExportWidgets(
  List<TextEditingController> controllers,
  List<RxString> errMsgs,
) {
  void import() {
    Clipboard.getData(Clipboard.kTextPlain).then((value) {
      importConfig(controllers, errMsgs, value?.text);
    });
  }

  void export() {
    final text = ServerConfig(
      idServer: controllers[0].text.trim(),
      relayServer: controllers[1].text.trim(),
      apiServer: controllers[2].text.trim(),
      key: controllers[3].text.trim(),
    ).encode();
    debugPrint("ServerConfig export: $text");
    Clipboard.setData(ClipboardData(text: text));
    showToast(translate('Export server configuration successfully'));
  }

  return [
    GlassIconButton(
      icon: CamelliaIcons.paste,
      size: 36,
      iconSize: 18,
      tooltip: translate('Import server config'),
      onPressed: import,
    ),
    const SizedBox(width: 6),
    GlassIconButton(
      icon: CamelliaIcons.copy,
      size: 36,
      iconSize: 18,
      tooltip: translate('Export Server Config'),
      onPressed: export,
    ),
  ];
}

List<(String, String)> otherDefaultSettings() {
  final v = <(String, String)>[
    ('View Mode', kOptionViewOnly),
    if (isDesktop || isWebDesktop) ('show_monitors_tip', kKeyShowMonitorsToolbar),
    if (isDesktop || isWebDesktop) ('Collapse toolbar', kOptionCollapseToolbar),
    ('Show remote cursor', kOptionShowRemoteCursor),
    ('Follow remote cursor', kOptionFollowRemoteCursor),
    ('Follow remote window focus', kOptionFollowRemoteWindow),
    if (isDesktop || isWebDesktop) ('Zoom cursor', kOptionZoomCursor),
    ('Show quality monitor', kOptionShowQualityMonitor),
    ('Mute', kOptionDisableAudio),
    if (isDesktop) ('Enable file copy and paste', kOptionEnableFileCopyPaste),
    ('Disable clipboard', kOptionDisableClipboard),
    ('Lock after session end', kOptionLockAfterSessionEnd),
    ('Privacy mode', kOptionPrivacyMode),
    if (!isWeb) ('True color (4:4:4)', kOptionI444),
    ('Reverse mouse wheel', kKeyReverseMouseWheel),
    ('swap-left-right-mouse', kOptionSwapLeftRightMouse),
    if (isDesktop)
      (
        'Show displays as individual windows',
        kKeyShowDisplaysAsIndividualWindows,
      ),
    if (isDesktop)
      (
        'Use all my displays for the remote session',
        kKeyUseAllMyDisplaysForTheRemoteSession,
      ),
    ('Keep terminal sessions on disconnect', kOptionTerminalPersistent),
  ];

  return v;
}

class TrackpadSpeedWidget extends StatefulWidget {
  final SimpleWrapper<int> value;
  // If null, no debouncer will be applied.
  final Function(int)? onDebouncer;

  const TrackpadSpeedWidget({
    super.key,
    required this.value,
    this.onDebouncer,
  });

  @override
  TrackpadSpeedWidgetState createState() => TrackpadSpeedWidgetState();
}

class TrackpadSpeedWidgetState extends State<TrackpadSpeedWidget> {
  final TextEditingController _controller = TextEditingController();
  late final Debouncer<int> debouncerSpeed;

  set value(int v) => widget.value.value = v;
  int get value => widget.value.value;

  void updateValue(int newValue) {
    setState(() {
      value = newValue.clamp(kMinTrackpadSpeed, kMaxTrackpadSpeed);
      _controller.text = value.toString();
      if (widget.onDebouncer != null) {
        debouncerSpeed.setValue(value);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    debouncerSpeed = Debouncer<int>(
      const Duration(milliseconds: 1000),
      onChanged: widget.onDebouncer,
      initialValue: widget.value.value,
    );
  }

  @override
  void dispose() {
    debouncerSpeed.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_controller.text.isEmpty) {
      _controller.text = value.toString();
    }
    final clamped = value
        .clamp(kMinTrackpadSpeed, kMaxTrackpadSpeed)
        .toDouble();
    return Row(
      children: [
        Expanded(
          child: Slider(
            value: clamped,
            min: kMinTrackpadSpeed.toDouble(),
            max: kMaxTrackpadSpeed.toDouble(),
            divisions: ((kMaxTrackpadSpeed - kMinTrackpadSpeed) / 10).round(),
            onChanged: (double v) => updateValue(v.round()),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 64,
          child: TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            onSubmitted: (text) {
              final v = int.tryParse(text);
              if (v != null) {
                updateValue(v);
              }
            },
            style: CamelliaTypography.tabular(
              theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                vertical: 8.0,
                horizontal: 8.0,
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '%',
          style: CamelliaTypography.tabular(
            theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
