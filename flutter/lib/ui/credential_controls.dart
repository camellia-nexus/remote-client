// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../common.dart' show AppVisual, translate;
import 'camellia_design.dart';

/// Accessible credential persistence toggle supporting both a labeled full-row
/// target (`compactIconOnly: false`, default) and a compact 40x40 icon toggle
/// (`compactIconOnly: true`).
class CredentialRememberControl extends StatelessWidget {
  const CredentialRememberControl({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.compactIconOnly = false,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool compactIconOnly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final accent = dark ? scheme.secondary : scheme.primary;

    if (compactIconOnly) {
      return Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Semantics(
          button: true,
          toggled: value,
          enabled: onChanged != null,
          label: label,
          child: Tooltip(
            message: label,
            child: SizedBox.square(
              dimension: 40,
              child: IconButton(
                onPressed: onChanged == null ? null : () => onChanged!(!value),
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  minimumSize: const Size(40, 40),
                  maximumSize: const Size(40, 40),
                  backgroundColor: value
                      ? accent.withValues(alpha: dark ? 0.22 : 0.14)
                      : scheme.surfaceContainer,
                  foregroundColor: value ? accent : scheme.onSurfaceVariant,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(CamelliaRadius.control),
                    side: BorderSide(
                      color: value
                          ? accent.withValues(alpha: 0.45)
                          : scheme.outlineVariant,
                      width: 0.85,
                    ),
                  ),
                ),
                icon: Icon(
                  value
                      ? Icons.bookmark_added_rounded
                      : Icons.bookmark_add_outlined,
                  size: 19,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: value
          ? accent.withValues(alpha: dark ? 0.12 : 0.07)
          : scheme.surfaceContainer.withValues(alpha: dark ? 0.45 : 0.55),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CamelliaRadius.control),
        side: BorderSide(
          color: value
              ? accent.withValues(alpha: 0.35)
              : scheme.outlineVariant.withValues(alpha: 0.65),
          width: 0.85,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: CheckboxListTile(
        value: value,
        onChanged:
            onChanged == null ? null : (next) => onChanged!(next ?? false),
        dense: true,
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        minTileHeight: 50,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CamelliaRadius.control),
        ),
        title: Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: value ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// Precision 4-segment password strength indicator for credential setup flows.
class PasswordStrengthMeter extends StatelessWidget {
  const PasswordStrengthMeter({
    super.key,
    required this.password,
  });

  final String password;

  static int evaluateScore(String input) {
    if (input.isEmpty) return 0;
    var score = 0;
    if (input.length >= 6) score++;
    if (input.length >= 10) score++;
    final hasUpper = input.contains(RegExp(r'[A-Z]'));
    final hasLower = input.contains(RegExp(r'[a-z]'));
    final hasDigit = input.contains(RegExp(r'[0-9]'));
    final hasSymbol = input.contains(RegExp(r'[^A-Za-z0-9]'));
    if ((hasUpper && hasLower) || (hasLower && hasDigit) || (hasUpper && hasDigit)) {
      score++;
    }
    if (hasSymbol && input.length >= 8) {
      score++;
    }
    return score.clamp(1, 4);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppVisual.tokens(context);
    final score = evaluateScore(password);
    if (score == 0) return const SizedBox.shrink();

    final (Color activeColor, String label) = switch (score) {
      1 => (tokens.danger, translate('Weak')),
      2 => (tokens.warning, translate('Fair')),
      3 => (tokens.info, translate('Good')),
      _ => (tokens.success, translate('Strong')),
    };

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          for (var i = 0; i < 4; i++) ...[
            Expanded(
              child: AnimatedContainer(
                duration: CamelliaMotion.resolve(context, CamelliaMotion.hover),
                height: 4,
                decoration: BoxDecoration(
                  color: i < score
                      ? activeColor
                      : tokens.border.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(CamelliaRadius.pill),
                ),
              ),
            ),
            if (i < 3) const SizedBox(width: 5),
          ],
          const SizedBox(width: 10),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: activeColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
