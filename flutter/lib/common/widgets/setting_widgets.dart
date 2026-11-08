import 'package:debounce_throttle/debounce_throttle.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
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
    Key? key,
    required this.initQuality,
    required this.initFps,
    required this.setQuality,
    required this.setFps,
    required this.showFps,
    required this.showMoreQuality,
  }) : super(key: key);

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
      Duration(milliseconds: 1000),
      onChanged: widget.setQuality,
      initialValue: qualityValue.value,
    );
    debouncerFps = Debouncer<double>(
      Duration(milliseconds: 1000),
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
    return Column(
      children: [
        Obx(() => Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Slider(
                    value: qualityValue.value,
                    min: kMinQuality,
                    max: moreQualityChecked.value
                        ? kMaxMoreQuality
                        : kMaxQuality,
                    divisions: moreQualityChecked.value
                        ? ((kMaxMoreQuality - kMinQuality) / 10).round()
                        : ((kMaxQuality - kMinQuality) / 5).round(),
                    onChanged: widget.setQuality == null
                        ? null
                        : (double value) async {
                            qualityValue.value = value;
                            debouncerQuality.value = value;
                          },
                  ),
                ),
                Expanded(
                    flex: 1,
                    child: Text(
                      '${qualityValue.value.round()}%',
                      style: const TextStyle(fontSize: 15),
                    )),
                Expanded(
                    flex: isMobile ? 2 : 1,
                    child: Text(
                      translate('Bitrate'),
                      style: const TextStyle(fontSize: 15),
                    )),
                // mobile doesn't have enough space
                if (widget.showMoreQuality && !isMobile)
                  Expanded(
                      flex: 1,
                      child: Row(
                        children: [
                          Checkbox(
                            value: moreQualityChecked.value,
                            onChanged: onMoreChanged,
                          ),
                          Expanded(
                            child: Text(translate('More')),
                          )
                        ],
                      ))
              ],
            )),
        if (widget.showMoreQuality && isMobile)
          Obx(() => Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Checkbox(
                        value: moreQualityChecked.value,
                        onChanged: onMoreChanged,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(translate('More')),
                  )
                ],
              )),
        if (widget.showFps)
          Obx(() => Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Slider(
                      value: fpsValue.value,
                      min: kMinFps,
                      max: kMaxFps,
                      divisions: ((kMaxFps - kMinFps) / 5).round(),
                      onChanged: widget.setFps == null
                          ? null
                          : (double value) async {
                              fpsValue.value = value;
                              debouncerFps.value = value;
                            },
                    ),
                  ),
                  Expanded(
                      flex: 1,
                      child: Text(
                        '${fpsValue.value.round()}',
                        style: const TextStyle(fontSize: 15),
                      )),
                  Expanded(
                      flex: 2,
                      child: Text(
                        translate('FPS'),
                        style: const TextStyle(fontSize: 15),
                      ))
                ],
              )),
      ],
    );
  }
}

customImageQualitySetting() {
  final qualityKey = 'custom_image_quality';
  final fpsKey = 'custom-fps';

  final initQuality =
      (double.tryParse(bind.mainGetUserDefaultOption(key: qualityKey)) ??
          kDefaultQuality);
  final isQuanlityFixed = isOptionFixed(qualityKey);
  final initFps =
      (double.tryParse(bind.mainGetUserDefaultOption(key: fpsKey)) ??
          kDefaultFps);
  final isFpsFixed = isOptionFixed(fpsKey);

  return customImageQualityWidget(
      initQuality: initQuality,
      initFps: initFps,
      setQuality: isQuanlityFixed
          ? null
          : (v) {
              bind.mainSetUserDefaultOption(
                  key: qualityKey, value: v.toString());
            },
      setFps: isFpsFixed
          ? null
          : (v) {
              bind.mainSetUserDefaultOption(key: fpsKey, value: v.toString());
            },
      showFps: true,
      showMoreQuality: true);
}

List<Widget> ServerConfigImportExportWidgets(
  List<TextEditingController> controllers,
  List<RxString> errMsgs,
) {
  import() {
    Clipboard.getData(Clipboard.kTextPlain).then((value) {
      importConfig(controllers, errMsgs, value?.text);
    });
  }

  export() {
    final text = ServerConfig(
            idServer: controllers[0].text.trim(),
            relayServer: controllers[1].text.trim(),
            apiServer: controllers[2].text.trim(),
            key: controllers[3].text.trim())
        .encode();
    debugPrint("ServerConfig export: $text");
    Clipboard.setData(ClipboardData(text: text));
    showToast(translate('Export server configuration successfully'));
  }

  return [
    Tooltip(
      message: translate('Import server config'),
      child: IconButton(
          icon: Icon(Icons.paste, color: Colors.grey), onPressed: import),
    ),
    Tooltip(
        message: translate('Export Server Config'),
        child: IconButton(
            icon: Icon(Icons.copy, color: Colors.grey), onPressed: export))
  ];
}

List<(String, String)> otherDefaultSettings() {
  List<(String, String)> v = [
    ('View Mode', kOptionViewOnly),
    if ((isDesktop || isWebDesktop))
      ('show_monitors_tip', kKeyShowMonitorsToolbar),
    if ((isDesktop || isWebDesktop))
      ('Collapse toolbar', kOptionCollapseToolbar),
    ('Show remote cursor', kOptionShowRemoteCursor),
    ('Follow remote cursor', kOptionFollowRemoteCursor),
    ('Follow remote window focus', kOptionFollowRemoteWindow),
    if ((isDesktop || isWebDesktop)) ('Zoom cursor', kOptionZoomCursor),
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
        kKeyShowDisplaysAsIndividualWindows
      ),
    if (isDesktop)
      (
        'Use all my displays for the remote session',
        kKeyUseAllMyDisplaysForTheRemoteSession
      ),
    ('Keep terminal sessions on disconnect', kOptionTerminalPersistent),
  ];

  return v;
}

class TrackpadSpeedWidget extends StatefulWidget {
  final SimpleWrapper<int> value;
  // If null, no debouncer will be applied.
  final Function(int)? onDebouncer;

  TrackpadSpeedWidget({Key? key, required this.value, this.onDebouncer});

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
      // Scale the trackpad speed value to a percentage for display purposes.
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
      Duration(milliseconds: 1000),
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
    if (_controller.text.isEmpty) {
      _controller.text = value.toString();
    }
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Slider(
            value: value.toDouble(),
            min: kMinTrackpadSpeed.toDouble(),
            max: kMaxTrackpadSpeed.toDouble(),
            divisions: ((kMaxTrackpadSpeed - kMinTrackpadSpeed) / 10).round(),
            onChanged: (double v) => updateValue(v.round()),
          ),
        ),
        Expanded(
            flex: 1,
            child: Row(
              children: [
                SizedBox(
                  width: 56,
                  child: TextField(
                    controller: _controller,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    onSubmitted: (text) {
                      int? v = int.tryParse(text);
                      if (v != null) {
                        updateValue(v);
                      }
                    },
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      contentPadding:
                          EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
                    ),
                  ),
                ).marginOnly(right: 8.0),
                Text(
                  '%',
                  style: const TextStyle(fontSize: 15),
                )
              ],
            )),
      ],
    );
  }
}
