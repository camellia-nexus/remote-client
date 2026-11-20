import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/dialog.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrapWithTheme(Widget child, {Brightness brightness = Brightness.light}) {
    return MaterialApp(
      navigatorKey: globalKey,
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

  group('ModernDialogHeader Tests', () {
    testWidgets('renders title, subtitle, badge container, and close button', (tester) async {
      bool closed = false;
      await tester.pumpWidget(
        wrapWithTheme(
          ModernDialogHeader(
            title: 'Test Dialog Title',
            subtitle: 'Helpful explanation here',
            icon: Icons.security_rounded,
            tone: AppTone.brand,
            onClose: () => closed = true,
          ),
        ),
      );

      expect(find.text('Test Dialog Title'), findsOneWidget);
      expect(find.text('Helpful explanation here'), findsOneWidget);
      expect(find.byIcon(Icons.security_rounded), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      expect(closed, isTrue);
    });

    testWidgets('ModernDialogHeader.confirm constructor initializes with success tone and checkmark', (tester) async {
      await tester.pumpWidget(
        wrapWithTheme(
          const ModernDialogHeader.confirm(
            title: 'Operation Confirmed',
            subtitle: 'Changes saved successfully',
          ),
        ),
      );

      expect(find.text('Operation Confirmed'), findsOneWidget);
      expect(find.text('Changes saved successfully'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
    });

    testWidgets('ModernDialogHeader.warning constructor initializes with warning tone and icon', (tester) async {
      await tester.pumpWidget(
        wrapWithTheme(
          const ModernDialogHeader.warning(
            title: 'Caution Required',
            subtitle: 'This action cannot be undone',
          ),
        ),
      );

      expect(find.text('Caution Required'), findsOneWidget);
      expect(find.text('This action cannot be undone'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('ModernDialogHeader.error constructor initializes with danger tone and icon', (tester) async {
      await tester.pumpWidget(
        wrapWithTheme(
          const ModernDialogHeader.error(
            title: 'Connection Error',
            subtitle: 'Target peer rejected authentication',
          ),
        ),
      );

      expect(find.text('Connection Error'), findsOneWidget);
      expect(find.text('Target peer rejected authentication'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    });

    testWidgets('ModernDialogHeader.info constructor initializes with info tone and icon', (tester) async {
      await tester.pumpWidget(
        wrapWithTheme(
          const ModernDialogHeader.info(
            title: 'Information Notice',
            subtitle: 'Session protocol negotiated',
          ),
        ),
      );

      expect(find.text('Information Notice'), findsOneWidget);
      expect(find.text('Session protocol negotiated'), findsOneWidget);
      expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
    });

    testWidgets('adapts smoothly across Dark and Light themes', (tester) async {
      // Light mode
      await tester.pumpWidget(
        wrapWithTheme(
          const ModernDialogHeader.confirm(title: 'Theme Adaptation Test'),
          brightness: Brightness.light,
        ),
      );
      expect(find.text('Theme Adaptation Test'), findsOneWidget);

      // Dark mode
      await tester.pumpWidget(
        wrapWithTheme(
          const ModernDialogHeader.confirm(title: 'Theme Adaptation Test'),
          brightness: Brightness.dark,
        ),
      );
      expect(find.text('Theme Adaptation Test'), findsOneWidget);
    });
  });

  group('ModernToastPill & Notification Tests', () {
    testWidgets('renders pill with frosted BackdropFilter, elevation, icon, and text', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(
        wrapWithTheme(
          ModernToastPill(
            text: 'Connection established',
            tone: AppTone.success,
            icon: Icons.check_circle_outline_rounded,
            onTap: () => tapped = true,
          ),
        ),
      );

      expect(find.byKey(const Key('modern_toast_pill')), findsOneWidget);
      expect(find.byKey(const Key('modern_toast_text')), findsOneWidget);
      expect(find.text('Connection established'), findsOneWidget);
      expect(find.byKey(const Key('modern_toast_icon')), findsOneWidget);

      final backdropFilter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
      expect(backdropFilter.filter, isNotNull);

      await tester.tap(find.byKey(const Key('modern_toast_pill')));
      expect(tapped, isTrue);
    });

    testWidgets('adapts toast pill styling under dark mode', (tester) async {
      await tester.pumpWidget(
        wrapWithTheme(
          const ModernToastPill(
            text: 'Device reboot scheduled',
            tone: AppTone.warning,
          ),
          brightness: Brightness.dark,
        ),
      );

      expect(find.text('Device reboot scheduled'), findsOneWidget);
      expect(find.byKey(const Key('modern_toast_pill')), findsOneWidget);
    });

    testWidgets('showToast rapidly called replaces previous toast without orphaning or duplicate entries', (tester) async {
      await tester.pumpWidget(
        wrapWithTheme(
          Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () {
                  showToast('First Toast');
                  showToast('Second Toast');
                },
                child: const Text('Fire Toasts'),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('Fire Toasts'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Second Toast'), findsOneWidget);
      expect(find.text('First Toast'), findsNothing);
      expect(find.byKey(const Key('modern_toast_pill')), findsOneWidget);
    });
  });

  group('msgboxIcon & msgboxContent Modernization Tests', () {
    testWidgets('renders modern icon badge for error and success types', (tester) async {
      await tester.pumpWidget(
        wrapWithTheme(
          Column(
            children: [
              msgboxContent('error', 'Error Title', 'Something went wrong'),
              msgboxContent('success', 'Success Title', 'Action completed successfully'),
            ],
          ),
        ),
      );

      expect(find.text('Error Title'), findsOneWidget);
      expect(find.text('Something went wrong'), findsOneWidget);
      expect(find.text('Success Title'), findsOneWidget);
      expect(find.text('Action completed successfully'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
    });
  });

  group('CustomAlertDialog Integration Tests', () {
    testWidgets('renders CustomAlertDialog with title, content, actions, and responds to Escape key', (tester) async {
      bool cancelled = false;
      bool submitted = false;

      await tester.pumpWidget(
        wrapWithTheme(
          CustomAlertDialog(
            title: const ModernDialogHeader.info(title: 'Dialog Modal Test'),
            content: const Text('Modal Body Content'),
            actions: [
              TextButton(onPressed: () => cancelled = true, child: const Text('Cancel')),
              ElevatedButton(onPressed: () => submitted = true, child: const Text('Confirm')),
            ],
            onCancel: () => cancelled = true,
            onSubmit: () => submitted = true,
          ),
        ),
      );

      expect(find.text('Dialog Modal Test'), findsOneWidget);
      expect(find.text('Modal Body Content'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Confirm'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(cancelled, isTrue);

      await tester.tap(find.text('Confirm'));
      await tester.pump();
      expect(submitted, isTrue);
    });
  });
}
