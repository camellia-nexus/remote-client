// ignore: deprecated_member_use
import 'package:flutter/material.dart';

class CredentialRememberControl extends StatelessWidget {
  const CredentialRememberControl({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.compactIconOnly,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool compactIconOnly;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
                      ? scheme.primaryContainer
                      : scheme.surfaceContainer,
                  foregroundColor: value
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: scheme.outlineVariant),
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
    return CheckboxListTile(
      value: value,
      onChanged: onChanged == null ? null : (next) => onChanged!(next ?? false),
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
      minTileHeight: 48,
      visualDensity: VisualDensity.compact,
      title: Text(
        label,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}
