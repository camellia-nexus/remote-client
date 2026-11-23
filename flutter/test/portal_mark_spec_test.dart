import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/ui/brand/portal_mark_spec.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('portal geometry stays inside its normalized canvas', () {
    for (final rect in [
      PortalMarkSpec.rearScreen,
      PortalMarkSpec.rearCutout,
      PortalMarkSpec.frontScreen,
      PortalMarkSpec.frontCutout,
    ]) {
      expect(rect.left, inInclusiveRange(0, 1));
      expect(rect.top, inInclusiveRange(0, 1));
      expect(rect.width, greaterThan(0));
      expect(rect.height, greaterThan(0));
      expect(rect.left + rect.width, lessThanOrEqualTo(1));
      expect(rect.top + rect.height, lessThanOrEqualTo(1));
      expect(rect.radius, greaterThan(0));
    }
  });

  test('screen cutouts remain contained by their frames', () {
    void expectContained(PortalRectSpec outer, PortalRectSpec inner) {
      expect(inner.left, greaterThan(outer.left));
      expect(inner.top, greaterThan(outer.top));
      expect(inner.left + inner.width, lessThan(outer.left + outer.width));
      expect(inner.top + inner.height, lessThan(outer.top + outer.height));
    }

    expectContained(PortalMarkSpec.rearScreen, PortalMarkSpec.rearCutout);
    expectContained(PortalMarkSpec.frontScreen, PortalMarkSpec.frontCutout);
  });

  test('connector remains centered and follows the screen offset axis', () {
    expect(PortalMarkSpec.connectorStartX, PortalMarkSpec.connectorStartY);
    expect(PortalMarkSpec.connectorEndX, PortalMarkSpec.connectorEndY);
    expect(
      PortalMarkSpec.connectorStartX + PortalMarkSpec.connectorEndX,
      closeTo(1, 0.000001),
    );
    expect(
      PortalMarkSpec.connectorStartY + PortalMarkSpec.connectorEndY,
      closeTo(1, 0.000001),
    );
  });

  test(
    'vector export contains unified Liquid Glass palette and evenodd cutouts',
    () {
      final colored = PortalMarkSpec.svg();
      final dark = PortalMarkSpec.svg(dark: true);
      final monochrome = PortalMarkSpec.svg(monochrome: true);

      expect(colored, contains('viewBox="0 0 1024 1024"'));
      expect(colored, isNot(contains('<mask')));
      expect(colored, contains('fill-rule="evenodd"'));
      expect(colored, contains(PortalMarkSpec.rearGradientStartHex));
      expect(colored, contains(PortalMarkSpec.rearGradientEndHex));
      expect(colored, contains(PortalMarkSpec.frontGradientStartHex));
      expect(colored, contains(PortalMarkSpec.frontGradientEndHex));
      expect(colored, contains(PortalMarkSpec.connectorGradientStartHex));
      expect(colored, contains(PortalMarkSpec.connectorGradientEndHex));
      expect(colored, contains('plate-specular'));
      expect(dark, contains(PortalMarkSpec.darkPlateStartHex));

      expect(monochrome, isNot(contains('<mask')));
      expect(monochrome, contains('fill-rule="evenodd"'));
      expect(monochrome, isNot(contains(PortalMarkSpec.rearGradientStartHex)));
      expect(monochrome, isNot(contains(PortalMarkSpec.frontGradientStartHex)));
      expect(monochrome, contains('stroke="#ffffff"'));
      expect(monochrome, contains('fill="#ffffff"'));
    },
  );

  test(
    'adaptiveForegroundSvg omits plate and preserves evenodd portal layers',
    () {
      final foreground = PortalMarkSpec.adaptiveForegroundSvg();
      final monoForeground = PortalMarkSpec.adaptiveForegroundSvg(
        monochrome: true,
      );

      expect(foreground, contains('viewBox="0 0 1024 1024"'));
      expect(foreground, isNot(contains('<rect')));
      expect(foreground, isNot(contains('<mask')));
      expect(foreground, contains('fill-rule="evenodd"'));
      expect(foreground, contains(PortalMarkSpec.rearGradientStartHex));
      expect(foreground, contains(PortalMarkSpec.frontGradientStartHex));
      expect(foreground, contains(PortalMarkSpec.connectorGradientStartHex));
      expect(foreground, contains('frame-specular'));

      expect(monoForeground, isNot(contains('<rect')));
      expect(monoForeground, contains('fill-rule="evenodd"'));
      expect(monoForeground, contains('stroke="#ffffff"'));
    },
  );

  testWidgets(
    'CamelliaBrandMark paints cleanly across light, dark, and monochrome modes',
    (tester) async {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: const Scaffold(
              body: Row(
                children: [
                  CamelliaBrandMark(size: 48, semanticLabel: 'Camellia Remote'),
                  CamelliaBrandMark(size: 32, withPlate: false),
                  CamelliaBrandMark(
                    size: 24,
                    withPlate: false,
                    monochrome: true,
                  ),
                  CamelliaAnimatedBrandMark(size: 42),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(CamelliaBrandMark), findsNWidgets(4));
      }
    },
  );
}
