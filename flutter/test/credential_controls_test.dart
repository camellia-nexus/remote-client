import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/credential_controls.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('desktop remember control stays compact and exposes state', (
    tester,
  ) async {
    var remembered = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: CamelliaTheme.build(
          brightness: Brightness.light,
          desktopDensity: true,
        ),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => CredentialRememberControl(
              label: 'Remember password',
              value: remembered,
              compactIconOnly: true,
              onChanged: (next) => setState(() => remembered = next),
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(IconButton)), const Size(40, 40));
    expect(find.text('Remember password'), findsNothing);
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(remembered, isTrue);
    expect(find.byIcon(Icons.bookmark_added_rounded), findsOneWidget);
  });

  testWidgets('touch remember control keeps a visible label and target', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 280,
            child: CredentialRememberControl(
              label: 'Remember password',
              value: false,
              compactIconOnly: false,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('Remember password'), findsOneWidget);
    final height = tester.getSize(find.byType(CheckboxListTile)).height;
    expect(height, inInclusiveRange(48, 56));
  });
}
