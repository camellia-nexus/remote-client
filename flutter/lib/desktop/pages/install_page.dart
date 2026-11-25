import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/desktop/widgets/titlebar_widget.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher_string.dart';
import 'package:window_manager/window_manager.dart';

const String _kPrivacyAgreementUrl =
    'https://github.com/camellia-nexus/remote-client/blob/main/docs/privacy.md';

class InstallPage extends StatefulWidget {
  const InstallPage({super.key});

  @override
  State<InstallPage> createState() => _InstallPageState();
}

class _InstallPageState extends State<InstallPage> {
  @override
  Widget build(BuildContext context) {
    return DragToResizeArea(
      resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
      enableResizeEdges: windowManagerEnableResizeEdges,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: CamelliaBackdrop(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DesktopTitleBar(
                showBrand: true,
                transparent: true,
                labels: DesktopTitleBarLabels(
                  minimize: translate('Minimize'),
                  maximize: translate('Maximize'),
                  restore: translate('Restore'),
                  close: translate('Close'),
                ),
              ),
              const Expanded(
                child: _InstallPageBody(key: ValueKey('install')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InstallPageBody extends StatefulWidget {
  const _InstallPageBody({super.key});

  @override
  State<_InstallPageBody> createState() => _InstallPageBodyState();
}

class _InstallPageBodyState extends State<_InstallPageBody>
    with WindowListener {
  late final TextEditingController controller;
  final RxBool startmenu = true.obs;
  final RxBool desktopicon = true.obs;
  final RxBool printer = false.obs;
  final RxBool showProgress = false.obs;
  final RxBool btnEnabled = true.obs;

  _InstallPageBodyState() {
    controller = TextEditingController(text: bind.installInstallPath());
    try {
      final raw = bind.installInstallOptions();
      if (raw.isNotEmpty) {
        final installOptions = jsonDecode(raw);
        startmenu.value = installOptions['STARTMENUSHORTCUTS'] != '0';
        desktopicon.value = installOptions['DESKTOPSHORTCUTS'] != '0';
        printer.value = installOptions['PRINTER'] == '1';
      }
    } catch (_) {}
  }

  @override
  void initState() {
    windowManager.addListener(this);
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    controller.dispose();
    super.dispose();
  }

  @override
  void onWindowClose() {
    gFFI.close();
    super.onWindowClose();
    windowManager.setPreventClose(false);
    windowManager.close();
  }

  Widget _buildSwitchOptionRow({
    required BuildContext context,
    required RxBool option,
    required IconData icon,
    required String label,
    bool showDivider = false,
  }) {
    final theme = Theme.of(context);
    final tokens = AppVisual.tokens(context);
    final glass = CamelliaGlassTokens.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Obx(() {
          final enabled = btnEnabled.value;
          return Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(CamelliaRadius.control),
              hoverColor: enabled ? glass.hoverOverlay : Colors.transparent,
              highlightColor: Colors.transparent,
              splashColor: Colors.transparent,
              splashFactory: NoSplash.splashFactory,
              mouseCursor: enabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.forbidden,
              onTap: enabled ? () => option.value = !option.value : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 18,
                      color: enabled
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.onSurfaceVariant.withValues(
                              alpha: 0.45,
                            ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: enabled
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.onSurface.withValues(
                                  alpha: 0.5,
                                ),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Transform.scale(
                      scale: 0.86,
                      child: Switch.adaptive(
                        value: option.value,
                        onChanged: enabled ? (v) => option.value = v : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
        if (showDivider)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Container(height: 0.85, color: tokens.border),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppVisual.tokens(context);
    final glass = CamelliaGlassTokens.of(context);
    final printerLabel = translate('Install {} Printer')
        .replaceAll('{}', appName)
        .replaceAll('{\$appName}', appName);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: GlassCard(
            layer: CamelliaGlassLayer.floating,
            elevated: true,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Studio Installer Header
                Row(
                  children: [
                    const CamelliaBrandMark(size: 38, withPlate: true),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            translate('Installation'),
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            appName,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // Installation Path
                Text(
                  translate('Installation Path'),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Obx(
                  () => Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: GlassInput(
                          controller: controller,
                          readOnly: true,
                          enabled: btnEnabled.value,
                          showClearButton: false,
                          prefixIcon: Icons.folder_outlined,
                          minHeight: 42,
                        ).workaroundFreezeLinuxMint(),
                      ),
                      const SizedBox(width: 10),
                      GlassButton(
                        variant: GlassButtonVariant.secondary,
                        minHeight: 42,
                        icon: const Icon(Icons.drive_file_move_outline, size: 17),
                        onPressed: btnEnabled.value ? selectInstallPath : null,
                        child: Text(translate('Change Path')),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                // System & Shortcut Options
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.surfaceContainer.withValues(alpha: 0.68),
                    borderRadius: BorderRadius.circular(CamelliaRadius.surface),
                    border: Border.all(color: tokens.border, width: 0.85),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildSwitchOptionRow(
                        context: context,
                        option: startmenu,
                        icon: Icons.apps_rounded,
                        label: translate('Create start menu shortcuts'),
                        showDivider: true,
                      ),
                      _buildSwitchOptionRow(
                        context: context,
                        option: desktopicon,
                        icon: Icons.desktop_windows_outlined,
                        label: translate('Create desktop icon'),
                        showDivider: true,
                      ),
                      _buildSwitchOptionRow(
                        context: context,
                        option: printer,
                        icon: Icons.print_outlined,
                        label: printerLabel,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // License / Privacy Notice
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.surfaceContainer.withValues(alpha: 0.52),
                    borderRadius: BorderRadius.circular(CamelliaRadius.control),
                    border: Border.all(color: tokens.border, width: 0.85),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.verified_user_outlined,
                          size: 20,
                          color: glass.statusEncrypted,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                translate('agreement_tip'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface,
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 6),
                              MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: GestureDetector(
                                  onTap: () => launchUrlString(
                                    _kPrivacyAgreementUrl,
                                  ),
                                  child: Tooltip(
                                    message: _kPrivacyAgreementUrl,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.open_in_new_rounded,
                                          size: 14,
                                          color: theme.colorScheme.primary,
                                        ),
                                        const SizedBox(width: 5),
                                        Flexible(
                                          child: Text(
                                            translate(
                                              'End-user license agreement',
                                            ),
                                            style: theme.textTheme.labelMedium
                                                ?.copyWith(
                                                  color:
                                                      theme.colorScheme.primary,
                                                  decoration:
                                                      TextDecoration.underline,
                                                ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),

                // Progress indicator (NOT wrapped in Offstage)
                Obx(
                  () => showProgress.value
                      ? const Padding(
                          padding: EdgeInsets.only(bottom: 14),
                          child: LinearProgressIndicator(),
                        )
                      : const SizedBox.shrink(),
                ),

                // Footer Action Bar
                Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    Offstage(
                      offstage: !bind.installShowRunWithoutInstall(),
                      child: Obx(
                        () => GlassButton(
                          variant: GlassButtonVariant.secondary,
                          minHeight: 40,
                          icon: const Icon(
                            Icons.play_circle_outline_rounded,
                            size: 17,
                          ),
                          onPressed: btnEnabled.value
                              ? () => bind.installRunWithoutInstall()
                              : null,
                          child: Text(translate('Run without install')),
                        ),
                      ),
                    ),
                    Obx(
                      () => GlassButton(
                        variant: GlassButtonVariant.secondary,
                        minHeight: 40,
                        icon: const Icon(CamelliaIcons.close, size: 17),
                        onPressed: btnEnabled.value
                            ? () => windowManager.close()
                            : null,
                        child: Text(translate('Cancel')),
                      ),
                    ),
                    Obx(
                      () => GlassButton(
                        variant: GlassButtonVariant.primary,
                        minHeight: 40,
                        loading: showProgress.value,
                        icon: const Icon(CamelliaIcons.check, size: 17),
                        onPressed: btnEnabled.value ? install : null,
                        child: Text(translate('Accept and Install')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void install() {
    btnEnabled.value = false;
    showProgress.value = true;
    String args = '';
    if (startmenu.value) args += ' startmenu';
    if (desktopicon.value) args += ' desktopicon';
    if (printer.value) args += ' printer';
    bind.installInstallMe(options: args, path: controller.text);
  }

  Future<void> selectInstallPath() async {
    final String? installPath = await FilePicker.getDirectoryPath(
      initialDirectory: controller.text,
    );
    if (installPath != null) {
      controller.text = p.join(installPath, await bind.mainGetAppName());
    }
  }
}
