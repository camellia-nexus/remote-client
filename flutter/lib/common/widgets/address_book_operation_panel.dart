import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:flutter/material.dart';

import '../../common.dart' show translate;
import '../../models/address_book_mutations.dart';

/// Recovery is independent of cached content and connection actions. Closing a
/// status message cannot erase journal evidence or grant write admission.
class AddressBookOperationPanel extends StatelessWidget {
  final bool ready;
  final bool busy;
  final String storageError;
  final String status;
  final List<PendingAddressBookOperation> pending;
  final Future<void> Function() onRefresh;
  final Future<void> Function(PendingAddressBookOperation) onRecover;
  final Future<void> Function(PendingAddressBookOperation, String) onReconcile;

  const AddressBookOperationPanel({
    super.key,
    required this.ready,
    required this.busy,
    required this.storageError,
    required this.status,
    required this.pending,
    required this.onRefresh,
    required this.onRecover,
    required this.onReconcile,
  });

  Future<void> _reconcile(
    BuildContext context,
    PendingAddressBookOperation operation,
  ) async {
    final confirmedId = await showDialog<String>(
      context: context,
      builder: (_) => _ReconcileOperationDialog(operation: operation),
    );
    if (confirmedId == operation.operationId) {
      await onReconcile(operation, confirmedId!);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ready &&
        !busy &&
        storageError.isEmpty &&
        status.isEmpty &&
        pending.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final glass = CamelliaGlassTokens.of(context);
    final accent = storageError.isNotEmpty
        ? glass.statusAlert
        : pending.isNotEmpty
        ? glass.statusHighLatency
        : (theme.brightness == Brightness.dark
              ? theme.colorScheme.secondary
              : theme.colorScheme.primary);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.35,
      ),
      child: SingleChildScrollView(
        child: GlassCard(
          accent: accent,
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  GlassBadge(
                    label: storageError.isNotEmpty
                        ? 'Storage Error'
                        : pending.isNotEmpty
                        ? 'Pending Reconciliation'
                        : busy
                        ? 'Syncing'
                        : 'Status',
                    tone: storageError.isNotEmpty
                        ? GlassBadgeTone.danger
                        : pending.isNotEmpty
                        ? GlassBadgeTone.warning
                        : GlassBadgeTone.brand,
                    showDot: true,
                    pulse: busy,
                    compact: true,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (busy)
                Text(
                  'Address book operation in progress. Writes are disabled.',
                  style: theme.textTheme.bodySmall,
                ),
              if (!ready && !busy && storageError.isEmpty)
                Text(
                  'Check operation storage before editing the address book.',
                  style: theme.textTheme.bodySmall,
                ),
              if (storageError.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    storageError,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: glass.statusAlert,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(status, style: theme.textTheme.bodySmall),
                ),
              if (pending.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'An unresolved operation blocks new writes. Viewing and connecting remain available. '
                    'Look up its receipt using the original account and server; do not repeat the write.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              for (final operation in pending) ...[
                const SizedBox(height: 8),
                GlassSurface(
                  layer: CamelliaGlassLayer.floating,
                  showShadow: false,
                  enableBlur: false,
                  borderRadius: BorderRadius.circular(CamelliaRadius.control),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: SelectableText(
                    operation.operationId,
                    style: CamelliaTypography.tabular(
                      theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    TextButton(
                      onPressed: busy ? null : () => onRecover(operation),
                      child: Text(translate('Look up receipt')),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => _reconcile(context, operation),
                      child: Text(translate('Manual reconciliation')),
                    ),
                  ],
                ),
              ],
              if (!busy) ...[
                const SizedBox(height: 4),
                TextButton(
                  onPressed: onRefresh,
                  child: Text(translate('Check operation storage')),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ReconcileOperationDialog extends StatefulWidget {
  final PendingAddressBookOperation operation;
  const _ReconcileOperationDialog({required this.operation});

  @override
  State<_ReconcileOperationDialog> createState() =>
      _ReconcileOperationDialogState();
}

class _ReconcileOperationDialogState extends State<_ReconcileOperationDialog> {
  final _controller = TextEditingController();
  var _verified = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: GlassModalShell(
        maxWidth: 480,
        title: Text(
          'Manual operation reconciliation',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'First verify the original operation and resulting state on the original server and account. '
              'A missing receipt, expired retention, or failed connection does not prove that nothing changed. '
              'Clearing this record allows new writes and never retries the original operation.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            GlassSurface(
              layer: CamelliaGlassLayer.floating,
              showShadow: false,
              enableBlur: false,
              borderRadius: BorderRadius.circular(CamelliaRadius.control),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: SelectableText(
                widget.operation.operationId,
                style: CamelliaTypography.tabular(
                  theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('reconcile-operation-id'),
              controller: _controller,
              style: CamelliaTypography.tabular(theme.textTheme.bodyMedium),
              decoration: const InputDecoration(
                labelText: 'Enter the complete operation ID',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              key: const ValueKey('reconcile-verified'),
              contentPadding: EdgeInsets.zero,
              title: Text(
                'I verified the original state and resolved this operation manually.',
                style: theme.textTheme.bodySmall,
              ),
              value: _verified,
              onChanged: (value) => setState(() => _verified = value == true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('reconcile-confirm'),
            onPressed:
                _verified && _controller.text == widget.operation.operationId
                ? () => Navigator.pop(context, _controller.text)
                : null,
            child: Text(translate('Clear reconciled record')),
          ),
        ],
      ),
    );
  }
}
