import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/device_workspace_controls.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('device controls choose stable responsive layouts', () {
    expect(deviceCategoryLayoutForWidth(390), DeviceCategoryLayout.selector);
    expect(deviceCategoryLayoutForWidth(519), DeviceCategoryLayout.selector);
    expect(deviceCategoryLayoutForWidth(520), DeviceCategoryLayout.bar);
    expect(deviceCategoryLayoutForWidth(839), DeviceCategoryLayout.bar);
    expect(deviceCategoryLayoutForWidth(840), DeviceCategoryLayout.bar);
  });

  test('desktop search width is bounded without consuming the action row', () {
    expect(deviceSearchWidth(390), 390);
    expect(deviceSearchWidth(520), 208);
    expect(deviceSearchWidth(1024), 208);
    expect(deviceSearchWidth(1280, focused: true), 280);
  });

  testWidgets('option menu uses one compact selectable row contract', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: CamelliaTheme.build(
          brightness: Brightness.light,
          desktopDensity: true,
        ),
        home: Scaffold(
          body: Center(
            child: DeviceOptionMenuButton<String>(
              tooltip: 'Change view',
              icon: Icons.grid_view_rounded,
              selectedValue: 'grid',
              options: const [
                DeviceOptionMenuItem(
                  value: 'grid',
                  label: 'Big tiles',
                  icon: Icons.grid_view_rounded,
                ),
                DeviceOptionMenuItem(
                  value: 'list',
                  label: 'List',
                  icon: Icons.view_list_rounded,
                ),
              ],
              onSelected: (value) => selected = value,
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(PopupMenuButton<String>)),
      const Size(44, 44),
    );
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('Big tiles'), findsOneWidget);
    expect(find.text('List'), findsOneWidget);
    expect(find.text('Change view'), findsNothing);
    await tester.tap(find.text('List'));
    await tester.pumpAndSettle();
    expect(selected, 'list');
  });
}
