import 'package:flutter/material.dart';

import '../../ui/camellia_design.dart';
import '../../ui/glass_components.dart';
import 'adaptive_layout.dart';

/// Opens settings without introducing another root navigation destination.
/// Compact layouts use a frosted bottom sheet; larger layouts stay in the
/// current workspace inside a Liquid Glass modal surface.
Future<T?> showSettingsOverlay<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  List<Widget> actions = const [],
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  final width = MediaQuery.sizeOf(context).width;
  if (width < AppLayout.compactBreakpoint) {
    return showGlassBottomSheet<T>(
      context: context,
      title: title,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.78,
        child: builder(sheetContext),
      ),
    );
  }

  final medium = width < AppLayout.expandedBreakpoint;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.42),
    transitionDuration: AppMotion.duration(context, AppMotion.modal),
    pageBuilder: (dialogContext, _, _) {
      final size = MediaQuery.sizeOf(dialogContext);
      final theme = Theme.of(dialogContext);
      final glass = CamelliaGlassTokens.of(dialogContext);
      final accent = theme.brightness == Brightness.dark
          ? theme.colorScheme.secondary
          : theme.colorScheme.primary;
      final radius = BorderRadius.circular(medium ? 20 : 24);

      final surface = GlassSurface(
        layer: CamelliaGlassLayer.modal,
        elevated: true,
        borderRadius: radius,
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            children: [
              SizedBox(
                height: 60,
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 12, 0),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          CamelliaIcons.settings,
                          size: 19,
                          color: accent,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge,
                        ),
                      ),
                      if (actions.isNotEmpty) ...[
                        const SizedBox(width: 12),
                        ...actions,
                      ],
                      const SizedBox(width: 8),
                      GlassIconButton(
                        icon: CamelliaIcons.close,
                        size: 36,
                        iconSize: 18,
                        tooltip: MaterialLocalizations.of(
                          dialogContext,
                        ).closeButtonTooltip,
                        onPressed: () => Navigator.of(dialogContext).pop(),
                      ),
                    ],
                  ),
                ),
              ),
              Divider(
                height: 1,
                thickness: 0.85,
                color: glass.specularBottom,
              ),
              Expanded(child: builder(dialogContext)),
            ],
          ),
        ),
      );

      if (medium) {
        return SafeArea(
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: (size.width * 0.90).clamp(520.0, 820.0),
                height: size.height,
                child: surface,
              ),
            ),
          ),
        );
      }
      return SafeArea(
        minimum: const EdgeInsets.all(28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 1040,
              maxHeight: 760,
              minWidth: 720,
              minHeight: 540,
            ),
            child: surface,
          ),
        ),
      );
    },
    transitionBuilder: (dialogContext, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: CamelliaMotion.springSnappy,
        reverseCurve: AppMotion.exitCurve,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: medium ? const Offset(0.04, 0) : const Offset(0, 0.025),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}
