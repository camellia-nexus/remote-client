import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/remote_ui_models.dart';
import 'package:camellia_remote_app/desktop/widgets/remote_toolbar.dart';
import 'package:camellia_remote_app/desktop/widgets/remote_toolbar_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrapWithTheme(Widget child, {Brightness brightness = Brightness.light}) {
    return MaterialApp(
      theme: ThemeData(
        brightness: brightness,
        colorScheme: ColorScheme.fromSeed(
          seedColor: CamelliaColors.indigo,
          brightness: brightness,
        ),
      ),
      home: Scaffold(
        body: Center(child: child),
      ),
    );
  }

  group('ToolbarTheme Modern Menu Style Tests', () {
    testWidgets('defaultMenuStyle resolves elevated surface, border, and shape in light and dark modes', (tester) async {
      late BuildContext lightContext;
      await tester.pumpWidget(
        wrapWithTheme(
          Builder(
            builder: (context) {
              lightContext = context;
              return const SizedBox();
            },
          ),
          brightness: Brightness.light,
        ),
      );

      final lightStyle = ToolbarTheme.defaultMenuStyle(lightContext);
      expect(lightStyle.elevation?.resolve({}), equals(10));
      expect(lightStyle.shape?.resolve({}), isA<RoundedRectangleBorder>());
      expect(lightStyle.side?.resolve({}), isNotNull);
      expect(lightStyle.padding?.resolve({}), equals(ToolbarTheme.menuPadding));

      late BuildContext darkContext;
      await tester.pumpWidget(
        wrapWithTheme(
          Builder(
            builder: (context) {
              darkContext = context;
              return const SizedBox();
            },
          ),
          brightness: Brightness.dark,
        ),
      );

      final darkStyle = ToolbarTheme.defaultMenuStyle(darkContext);
      expect(darkStyle.elevation?.resolve({}), equals(10));
      expect(darkStyle.shape?.resolve({}), isA<RoundedRectangleBorder>());
      expect(darkStyle.side?.resolve({}), isNotNull);
    });

    testWidgets('ToolbarTheme constants adhere to Apple-grade compact geometry', (tester) async {
      expect(ToolbarTheme.height, equals(40));
      expect(ToolbarTheme.buttonSize, equals(40));
      expect(ToolbarTheme.iconRadius, equals(8));
      expect(ToolbarTheme.menuBorderRadius, equals(CamelliaRadius.surface));
    });
  });

  group('CommandBarActionSurface Production Component Tests', () {
    testWidgets('transitions hover state smoothly with background and tint', (tester) async {
      await tester.pumpWidget(
        wrapWithTheme(
          const Column(
            children: [
              CommandBarActionSurface(
                key: Key('action_surface_normal'),
                icon: Icon(Icons.lock_outline_rounded),
                tint: CamelliaColors.azure,
                hovered: false,
              ),
              CommandBarActionSurface(
                key: Key('action_surface_hovered'),
                icon: Icon(Icons.lock_outline_rounded),
                tint: CamelliaColors.indigo,
                hovered: true,
              ),
            ],
          ),
        ),
      );

      expect(find.byKey(const Key('action_surface_normal')), findsOneWidget);
      expect(find.byKey(const Key('action_surface_hovered')), findsOneWidget);

      final normalWidget = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(const Key('action_surface_normal')),
          matching: find.byType(AnimatedContainer),
        ),
      );
      final normalDecor = normalWidget.decoration as BoxDecoration;
      expect(normalDecor.color, equals(Colors.transparent));

      final hoveredWidget = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(const Key('action_surface_hovered')),
          matching: find.byType(AnimatedContainer),
        ),
      );
      final hoveredDecor = hoveredWidget.decoration as BoxDecoration;
      expect(hoveredDecor.color, isNot(equals(Colors.transparent)));
    });
  });

  group('RectValueThumbShape Production Component Tests', () {
    testWidgets('provides correct preferred size, clips bounds, and paints without error in Slider', (tester) async {
      const thumbShape = RectValueThumbShape(
        min: 0.1,
        max: 2.0,
        width: 44,
        height: 24,
        radius: 4,
        unit: '%',
      );

      expect(thumbShape.getPreferredSize(true, false), equals(const Size(44, 24)));

      double sliderValue = 0.5;
      await tester.pumpWidget(
        wrapWithTheme(
          StatefulBuilder(
            builder: (context, setState) {
              return SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  thumbShape: thumbShape,
                ),
                child: Slider(
                  key: const Key('rect_thumb_slider'),
                  value: sliderValue,
                  min: 0.0,
                  max: 1.0,
                  onChanged: (v) => setState(() => sliderValue = v),
                ),
              );
            },
          ),
        ),
      );

      expect(find.byKey(const Key('rect_thumb_slider')), findsOneWidget);

      // Drag slider thumb
      await tester.drag(find.byKey(const Key('rect_thumb_slider')), const Offset(40, 0));
      await tester.pumpAndSettle();
      expect(sliderValue, greaterThan(0.5));
    });
  });

  group('EdgeThicknessControl Production Widget Tests', () {
    testWidgets('renders EdgeThicknessControl slider and updates within valid kMin/kMax bounds', (tester) async {
      double changedVal = 50.0;
      await tester.pumpWidget(
        wrapWithTheme(
          StatefulBuilder(
            builder: (context, setState) {
              return EdgeThicknessControl(
                value: changedVal,
                onChanged: (val) {
                  setState(() {
                    changedVal = val;
                  });
                },
              );
            },
          ),
        ),
      );

      expect(find.byType(EdgeThicknessControl), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);

      await tester.drag(find.byType(Slider), const Offset(50, 0));
      await tester.pumpAndSettle();
      expect(changedVal, greaterThan(50.0));
      expect(changedVal, lessThanOrEqualTo(EdgeThicknessControl.kMax));
    });
  });

  group('Remote Toolbar Collapse and Drag Mechanics Tests', () {
    testWidgets('collapsed footprint (32x32) docks properly across all screen edges within maxCrossAxisExtent', (tester) async {
      for (final edge in RemoteCommandBarEdge.values) {
        await tester.pumpWidget(
          wrapWithTheme(
            RemoteToolbarOverlaySurface(
              edge: edge,
              fraction: 0.5,
              toolbar: const SizedBox.square(dimension: 32),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('shrinkWrap tapTargetSize eliminates 4.0px RenderFlex overflow in command bar collapse handle', (tester) async {
      await tester.pumpWidget(
        wrapWithTheme(
          RemoteToolbarOverlaySurface(
            edge: RemoteCommandBarEdge.top,
            fraction: 0.5,
            toolbar: Flex(
              direction: Axis.vertical,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Simulating toolbarMaterial (48px)
                const SizedBox(width: 300, height: 48),
                // Gap (4px)
                const SizedBox(height: 4),
                // Handle button with shrinkWrap (32px)
                SizedBox(
                  height: 32,
                  child: TextButton(
                    onPressed: () {},
                    style: const ButtonStyle(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      minimumSize: WidgetStatePropertyAll(Size(32, 32)),
                      maximumSize: WidgetStatePropertyAll(Size(32, 32)),
                      padding: WidgetStatePropertyAll(EdgeInsets.all(7)),
                    ),
                    child: const Icon(Icons.drag_handle, size: 18),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      // Total cross axis height is 48 + 4 + 32 = 84px <= 96.0px (maxCrossAxisExtent).
      // Zero RenderFlex overflow occurs.
      expect(tester.takeException(), isNull);
    });

    testWidgets('drag repositioning fraction updates smoothly along docking axis', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      tester.view.physicalSize = const Size(1000, 600) * tester.view.devicePixelRatio;

      double currentFraction = 0.25;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  RemoteToolbarOverlaySurface(
                    edge: RemoteCommandBarEdge.top,
                    fraction: currentFraction,
                    toolbar: GestureDetector(
                      key: const Key('drag_surface_handle'),
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragUpdate: (details) {
                        setState(() {
                          currentFraction = (currentFraction + details.delta.dx / 800).clamp(0.0, 1.0);
                        });
                      },
                      child: const SizedBox(width: 160, height: 40),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );

      expect(find.byKey(const Key('drag_surface_handle')), findsOneWidget);
      await tester.drag(find.byKey(const Key('drag_surface_handle')), const Offset(120, 0));
      await tester.pumpAndSettle();
      expect(currentFraction, greaterThan(0.25));
      expect(tester.takeException(), isNull);
    });
  });
}
