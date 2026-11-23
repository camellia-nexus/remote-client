import 'package:camellia_remote_app/ui/camellia_design.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('section gives flex-based trailing a bounded width', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    const widths = [320.0, 560.0, 680.0, 1062.0];
    const scales = [1.0, 1.5, 2.0];

    for (final width in widths) {
      for (final scale in scales) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: SingleChildScrollView(
              child: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: width,
                  child: CamelliaSection(
                    title: 'Connect to a trusted remote device',
                    description:
                        'Choose a mode and enter a trusted device identifier',
                    trailing: const _FlexibleStatus(),
                    child: const SizedBox(height: 80),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(
          tester.takeException(),
          isNull,
          reason: 'width $width, text scale $scale',
        );
        final trailingRect = tester.getRect(find.byKey(_trailingKey));
        final titleRect = tester.getRect(
          find.text('Connect to a trusted remote device'),
        );
        expect(trailingRect.width, lessThanOrEqualTo((width - 28) / 2));
        expect(trailingRect.left.isFinite, isTrue);
        expect(trailingRect.right, lessThanOrEqualTo(width));
        expect(titleRect.right, lessThanOrEqualTo(trailingRect.left));
      }
    }
  });
}

const _trailingKey = ValueKey('flex-based-section-trailing');

class _FlexibleStatus extends StatelessWidget {
  const _FlexibleStatus();

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      key: _trailingKey,
      constraints: const BoxConstraints(minHeight: 42),
      child: Row(
        children: const [
          Flexible(
            child: Text(
              'Online and ready for incoming connections',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(width: 8),
          Flexible(
            child: Text(
              'Configure server',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
