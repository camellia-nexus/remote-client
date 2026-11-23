import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:flutter_test/flutter_test.dart';

class _ClientShellFixture extends StatelessWidget {
  const _ClientShellFixture();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Scaffold(
          body: CamelliaBackdrop(
            child: const SafeArea(
              child: Column(
                children: [
                  _CommandBar(),
                  Expanded(child: _WorkspaceContent()),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CommandBar extends StatelessWidget {
  const _CommandBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Row(
        children: [
          const CamelliaAnimatedBrandMark(size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'Remote workspace',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  'Connect and manage trusted devices',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton.filledTonal(
            tooltip: 'Settings',
            onPressed: () {},
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceContent extends StatelessWidget {
  const _WorkspaceContent();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 760;
        final padding = desktop ? 28.0 : 16.0;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(padding, 22, padding, 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CamelliaPageHeader(
                title: 'Your devices',
                subtitle: 'Connect securely across every screen',
                actions: desktop
                    ? [
                        IconButton(
                          tooltip: 'Search',
                          onPressed: () {},
                          icon: const Icon(Icons.search_rounded),
                        ),
                        FilledButton.icon(
                          onPressed: () {},
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('Add device'),
                        ),
                      ]
                    : const [],
              ),
              const SizedBox(height: 22),
              if (desktop)
                const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 390, child: _ConnectSection()),
                    SizedBox(width: 18),
                    Expanded(child: _DeviceSection()),
                  ],
                )
              else ...[
                const _ConnectSection(),
                const SizedBox(height: 16),
                const _DeviceSection(),
              ],
              const SizedBox(height: 18),
              const CamelliaSection(
                accent: CamelliaColors.indigo,
                title: 'Recent activity',
                description: 'Session history stays on this device',
                padding: EdgeInsets.fromLTRB(16, 2, 16, 12),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: AppIconBadge(
                    icon: Icons.desktop_windows_outlined,
                    colors: [CamelliaColors.indigo],
                  ),
                  title: Text('Design workstation'),
                  subtitle: Text('File transfer - 18 minutes ago'),
                  trailing: Icon(Icons.chevron_right_rounded),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ConnectSection extends StatelessWidget {
  const _ConnectSection();

  @override
  Widget build(BuildContext context) {
    return CamelliaSection(
      accent: CamelliaColors.indigo,
      title: 'Quick connect',
      description: 'Enter a trusted device ID',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                value: 0,
                icon: Icon(Icons.desktop_windows_outlined),
                label: Text('Desktop'),
              ),
              ButtonSegment(
                value: 1,
                icon: Icon(Icons.folder_outlined),
                label: Text('Files'),
              ),
            ],
            selected: const {0},
          ),
          const SizedBox(height: 14),
          const TextField(
            decoration: InputDecoration(
              prefixIcon: Icon(Icons.tag_rounded),
              hintText: 'Device ID',
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.arrow_forward_rounded),
            label: const Text('Connect securely'),
          ),
        ],
      ),
    );
  }
}

class _DeviceSection extends StatelessWidget {
  const _DeviceSection();

  @override
  Widget build(BuildContext context) {
    return CamelliaSection(
      accent: CamelliaColors.indigo,
      title: 'Available now',
      description: '2 trusted devices nearby',
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 12),
      child: const Column(
        children: [
          _DeviceRow(
            icon: Icons.laptop_mac_rounded,
            name: 'Studio Mac',
            detail: 'macOS - Ready',
            tone: Color(0xFF087A55),
          ),
          Divider(),
          _DeviceRow(
            icon: Icons.phone_android_rounded,
            name: 'Pixel workspace',
            detail: 'Android - Nearby',
            tone: Color(0xFF087A55),
          ),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.icon,
    required this.name,
    required this.detail,
    required this.tone,
  });

  final IconData icon;
  final String name;
  final String detail;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: AppIconBadge(icon: icon, colors: [CamelliaColors.indigo]),
      title: Text(name),
      subtitle: Row(
        children: [
          CamelliaStatusDot(color: tone, size: 11),
          const SizedBox(width: 7),
          Flexible(child: Text(detail)),
        ],
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
    );
  }
}

class _TypographyFixture extends StatelessWidget {
  const _TypographyFixture();

  @override
  Widget build(BuildContext context) {
    Widget sample(String family, String title, String body) {
      return Expanded(
        child: DefaultTextStyle.merge(
          style: TextStyle(fontFamily: family),
          child: AppSurface(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: family,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  body,
                  style: TextStyle(
                    fontFamily: family,
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: CamelliaBackdrop(
        padding: const EdgeInsets.all(24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            sample(
              CamelliaTypography.simplifiedFamily,
              '简体中文 · English',
              '连接可信设备，保持清晰一致的字重。\nSecurely connect to a trusted device.',
            ),
            const SizedBox(width: 16),
            sample(
              CamelliaTypography.traditionalFamily,
              '繁體中文 · English',
              '連線可信任的裝置，維持清晰一致的字重。\nSecurely connect to a trusted device.',
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _renderGolden(
  WidgetTester tester, {
  required Size size,
  required ThemeData theme,
  required String file,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: const _ClientShellFixture(),
    ),
  );
  await tester.pump(const Duration(milliseconds: 700));
  await expectLater(find.byType(_ClientShellFixture), matchesGoldenFile(file));
}

class _TolerantGoldenComparator extends LocalFileComparator {
  _TolerantGoldenComparator(super.testFile);

  static const double tolerance = 0.005;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final ComparisonResult result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= tolerance) {
      result.dispose();
      return true;
    }
    final String error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}

void main() {
  setUpAll(() {
    final defaultComparator = goldenFileComparator as LocalFileComparator;
    goldenFileComparator = _TolerantGoldenComparator(
      defaultComparator.basedir.resolve('camellia_design_golden_test.dart'),
    );
  });

  testWidgets('desktop light visual review', (tester) async {
    await _renderGolden(
      tester,
      size: const Size(1440, 900),
      theme: MyTheme.lightTheme,
      file: 'goldens/camellia_desktop_light.png',
    );
  });

  testWidgets('desktop dark visual review', (tester) async {
    await _renderGolden(
      tester,
      size: const Size(1280, 800),
      theme: MyTheme.darkTheme,
      file: 'goldens/camellia_desktop_dark.png',
    );
  });

  testWidgets('mobile light visual review', (tester) async {
    await _renderGolden(
      tester,
      size: const Size(390, 844),
      theme: MyTheme.lightTheme,
      file: 'goldens/camellia_mobile_light.png',
    );
  });

  testWidgets('mobile dark visual review', (tester) async {
    await _renderGolden(
      tester,
      size: const Size(390, 844),
      theme: MyTheme.darkTheme,
      file: 'goldens/camellia_mobile_dark.png',
    );
  });

  testWidgets('simplified and traditional typography review', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(860, 280);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: MyTheme.lightTheme,
        home: const _TypographyFixture(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await expectLater(
      find.byType(_TypographyFixture),
      matchesGoldenFile('goldens/camellia_typography_sc_tc.png'),
    );
  });
}
