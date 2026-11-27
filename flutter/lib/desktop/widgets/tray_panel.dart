import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/formatter/id_formatter.dart';
import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:camellia_remote_app/utils/multi_window_manager.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';

/// Lightweight Liquid Glass tray floating panel displaying status, ID, and quick actions.
class CamelliaTrayPanel extends StatelessWidget {
  const CamelliaTrayPanel({super.key});

  static Future<void> show(BuildContext context, {Offset? anchor}) async {
    final renderBox = context.findRenderObject() as RenderBox?;
    final targetPosition =
        anchor ??
        (renderBox != null
            ? renderBox.localToGlobal(Offset.zero)
            : const Offset(20, 40));

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.2),
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        final maxLeft = (size.width - 332.0).clamp(12.0, double.infinity);
        final maxTop = (size.height - 380.0).clamp(12.0, double.infinity);
        return Stack(
          children: [
            Positioned(
              left: targetPosition.dx.clamp(12.0, maxLeft),
              top: targetPosition.dy.clamp(12.0, maxTop),
              child: const Material(
                color: Colors.transparent,
                child: SizedBox(width: 320, child: CamelliaTrayPanel()),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppVisual.tokens(context);
    final glass = CamelliaGlassTokens.of(context);

    return ListenableBuilder(
      listenable: gFFI.serverModel,
      builder: (context, _) {
        return Obx(() {
          final status = stateGlobal.svcStatus.value;
          final svcStopped = Get.isRegistered<RxBool>(tag: 'stop-service')
              ? Get.find<RxBool>(tag: 'stop-service').value
              : false;
          final statusTone = svcStopped
              ? GlassBadgeTone.warning
              : switch (status) {
                  SvcStatus.ready => GlassBadgeTone.online,
                  SvcStatus.connecting => GlassBadgeTone.connecting,
                  SvcStatus.notReady => GlassBadgeTone.danger,
                };

          final statusLabel = svcStopped
              ? translate('Service is not running')
              : switch (status) {
                  SvcStatus.ready => translate('Ready'),
                  SvcStatus.connecting => translate('connecting_status'),
                  SvcStatus.notReady => translate('not_ready_status'),
                };

          final myId = gFFI.serverModel.serverId.text.trim();
          final activeConnections = gFFI.serverModel.clients.length;
          final sessionsLabel = translate(
            '{} active sessions',
          ).replaceAll('{}', '$activeConnections');

          return GlassSurface(
            layer: CamelliaGlassLayer.modal,
            elevated: true,
            borderRadius: BorderRadius.circular(CamelliaRadius.sheet),
            borderTopColor: glass.specularTop,
            borderBottomColor: tokens.border,
            strokeWidth: 0.85,
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Top Header: Studio Brand Mark + Status Badge
                Row(
                  children: [
                    const CamelliaBrandMark(size: 26, withPlate: true),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        translate('Camellia Remote'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GlassBadge(
                      label: statusLabel,
                      tone: statusTone,
                      showDot: true,
                      pulse: false,
                      compact: true,
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Local Device ID Hardware Key Inset
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.surfaceContainer.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(CamelliaRadius.control),
                    border: Border.all(color: tokens.border, width: 0.85),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                translate('Your ID'),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                myId.isNotEmpty ? formatID(myId) : '---',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: CamelliaTypography.tabular(
                                  theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.6,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        GlassIconButton(
                          icon: CamelliaIcons.copy,
                          size: 32,
                          iconSize: 15,
                          tooltip: translate('Copy ID'),
                          onPressed: myId.isNotEmpty && myId != '-'
                              ? () {
                                  Clipboard.setData(ClipboardData(text: myId));
                                  showToast(translate('Copied'));
                                }
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                // Active Connections indicator
                if (activeConnections > 0) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: glass.statusOnline.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(
                        CamelliaRadius.control,
                      ),
                      border: Border.all(
                        color: glass.statusOnline.withValues(alpha: 0.25),
                        width: 0.85,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.sensors_rounded,
                          size: 14,
                          color: glass.statusOnline,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            sessionsLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CamelliaTypography.tabular(
                              theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],

                Container(height: 0.85, color: tokens.border),
                const SizedBox(height: 6),

                // Quick Actions List
                _TrayActionRow(
                  icon: Icons.open_in_new_rounded,
                  label: translate('Open Main Window'),
                  onTap: () async {
                    Navigator.of(context, rootNavigator: true).pop();
                    await windowOnTop(null);
                  },
                ),
                _TrayActionRow(
                  icon: svcStopped
                      ? Icons.play_arrow_rounded
                      : Icons.stop_rounded,
                  iconColor: svcStopped
                      ? glass.statusOnline
                      : glass.statusAlert,
                  label: svcStopped
                      ? translate('Start service')
                      : translate('Stop service'),
                  onTap: () async {
                    Navigator.of(context, rootNavigator: true).pop();
                    await start_service(svcStopped);
                  },
                ),
                if (activeConnections > 0)
                  _TrayActionRow(
                    icon: Icons.link_off_rounded,
                    iconColor: glass.statusAlert,
                    label: translate('Disconnect All Sessions'),
                    onTap: () async {
                      Navigator.of(context, rootNavigator: true).pop();
                      await gFFI.serverModel.closeAll();
                      await rustDeskWinManager.closeAllSubWindows();
                    },
                  ),
                _TrayActionRow(
                  icon: Icons.power_settings_new_rounded,
                  iconColor: glass.statusAlert,
                  label: translate('Quit'),
                  onTap: () async {
                    Navigator.of(context, rootNavigator: true).pop();
                    if (isDesktop) {
                      try {
                        await saveWindowPosition(WindowType.Main, flush: true);
                      } catch (e) {
                        debugPrint('Error saving main window position: $e');
                      }
                    }
                    await rustDeskWinManager.closeAllSubWindows();
                    await windowManager.setPreventClose(false);
                    await windowManager.close();
                    if (isMacOS) {
                      supervisedMacOSTerminate();
                    }
                  },
                ),
              ],
            ),
          );
        });
      },
    );
  }
}

class _TrayActionRow extends StatelessWidget {
  const _TrayActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(CamelliaRadius.control),
        hoverColor: glass.hoverOverlay,
        highlightColor: Colors.transparent,
        splashColor: Colors.transparent,
        splashFactory: NoSplash.splashFactory,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: iconColor ?? theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
