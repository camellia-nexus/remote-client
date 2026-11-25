import 'dart:typed_data';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/brand_shell.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';
import 'package:camellia_remote_app/ui/glass_components.dart';
import 'package:flutter_test/flutter_test.dart';

class _ClientShellFixture extends StatelessWidget {
  const _ClientShellFixture();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 900;
        return Scaffold(
          body: CamelliaBackdrop(
            child: SafeArea(
              child: Row(
                children: [
                  if (isDesktop) const _StudioSidebar(),
                  Expanded(
                    child: Column(
                      children: [
                        _CommandBar(compact: !isDesktop),
                        const Expanded(child: _WorkspaceContent()),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StudioSidebar extends StatelessWidget {
  const _StudioSidebar();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      width: 220,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow.withValues(alpha: 0.78),
        border: Border(
          right: BorderSide(color: cs.outlineVariant, width: 0.85),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const CamelliaBrandMark(size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Camellia',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Studio Remote',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          const _SidebarNavRow(
            glyph: CamelliaGlyph.remoteDesktop,
            label: 'Connect',
            selected: true,
          ),
          const SizedBox(height: 4),
          const _SidebarNavRow(
            glyph: CamelliaGlyph.devices,
            label: 'Devices',
          ),
          const SizedBox(height: 4),
          const _SidebarNavRow(
            glyph: CamelliaGlyph.addressBook,
            label: 'Address Book',
          ),
          const Spacer(),
          const _SidebarNavRow(
            glyph: CamelliaGlyph.settings,
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class _SidebarNavRow extends StatelessWidget {
  const _SidebarNavRow({
    required this.glyph,
    required this.label,
    this.selected = false,
  });

  final CamelliaGlyph glyph;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fg = selected ? cs.primary : cs.onSurfaceVariant;
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: selected
            ? cs.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(CamelliaRadius.control),
      ),
      child: Row(
        children: [
          CamelliaVectorIcon(glyph, size: 17, color: fg, duotone: selected),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(
                color: selected ? cs.onSurface : cs.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CommandBar extends StatelessWidget {
  const _CommandBar({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      height: 58,
      padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 24),
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.65),
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant, width: 0.85),
        ),
      ),
      child: Row(
        children: [
          if (compact) ...[
            const CamelliaBrandMark(size: 30),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Remote Workspace',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'End-to-end encrypted studio sessions',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const GlassBadge(
            label: 'Relay Ready · 8 ms',
            tone: GlassBadgeTone.online,
            showDot: true,
            tabularNums: true,
            compact: true,
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
        final padding = desktop ? 26.0 : 16.0;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(padding, 22, padding, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CamelliaPageHeader(
                title: 'Control Deck',
                subtitle: 'Instant low-latency remote desktop, files, and terminal',
                actions: desktop
                    ? [
                        GlassButton(
                          variant: GlassButtonVariant.secondary,
                          minHeight: 38,
                          icon: const CamelliaVectorIcon(
                            CamelliaGlyph.search,
                            size: 16,
                          ),
                          onPressed: () {},
                          child: const Text('Command · ⌘K'),
                        ),
                        GlassButton(
                          variant: GlassButtonVariant.primary,
                          minHeight: 38,
                          icon: const CamelliaVectorIcon(
                            CamelliaGlyph.plus,
                            size: 16,
                            color: Colors.white,
                          ),
                          onPressed: () {},
                          child: const Text('Add Device'),
                        ),
                      ]
                    : const [],
              ),
              const SizedBox(height: 20),
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
              GlassCard(
                accent: CamelliaColors.statusOnlineLight,
                title: 'Local Identity & Security',
                subtitle: 'Hardware-verified TLS 1.3 session key active',
                trailing: const GlassBadge(
                  label: 'E2EE Verified',
                  tone: GlassBadgeTone.encrypted,
                  compact: true,
                ),
                child: Row(
                  children: [
                    const CamelliaStateIllustration(
                      glyph: CamelliaGlyph.shieldCheck,
                      size: 44,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '482 910 374',
                            style: CamelliaTypography.tabular(
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'One-time session password rotates automatically',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
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
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return GlassCard(
      accent: cs.primary,
      title: 'Quick Connect',
      subtitle: 'Enter remote workstation ID or alias',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassSegmentedControl<int>(
            expand: true,
            compact: true,
            selected: 0,
            onChanged: (_) {},
            items: const [
              GlassSegmentItem(value: 0, label: 'Control'),
              GlassSegmentItem(value: 1, label: 'Files'),
              GlassSegmentItem(value: 2, label: 'Terminal'),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(CamelliaRadius.control),
              border: Border.all(color: cs.outlineVariant, width: 0.85),
            ),
            child: Row(
              children: [
                CamelliaVectorIcon(
                  CamelliaGlyph.key,
                  size: 16,
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '819 204 516',
                    style: CamelliaTypography.tabular(
                      theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          GlassButton(
            variant: GlassButtonVariant.primary,
            expand: true,
            icon: const CamelliaVectorIcon(
              CamelliaGlyph.bolt,
              size: 16,
              color: Colors.white,
            ),
            onPressed: () {},
            child: const Text('Connect Session'),
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
    return const GlassCard(
      accent: CamelliaColors.indigo,
      title: 'Trusted Fleet',
      subtitle: '3 studio endpoints online',
      child: Column(
        children: [
          _DeviceRow(
            glyph: CamelliaGlyph.display,
            name: 'Mac Studio M4 Max',
            detail: 'macOS Sequoia · 192.168.1.24',
            online: true,
          ),
          Divider(height: 18),
          _DeviceRow(
            glyph: CamelliaGlyph.terminal,
            name: 'Render Cluster Node 01',
            detail: 'Ubuntu 24.04 LTS · Direct LAN',
            online: true,
          ),
          Divider(height: 18),
          _DeviceRow(
            glyph: CamelliaGlyph.devices,
            name: 'Pixel 9 Pro',
            detail: 'Android 15 · Standby',
            online: false,
          ),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.glyph,
    required this.name,
    required this.detail,
    required this.online,
  });

  final CamelliaGlyph glyph;
  final String name;
  final String detail;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final glass = CamelliaGlassTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: cs.outlineVariant, width: 0.85),
            ),
            child: Center(
              child: CamelliaVectorIcon(
                glyph,
                size: 18,
                color: cs.primary,
                duotone: true,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    CamelliaStatusDot(
                      color: online ? glass.statusOnline : cs.onSurfaceVariant,
                      size: 8,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CamelliaTypography.tabular(
                          theme.textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
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
          child: GlassCard(
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

  static const double tolerance = 0.01;

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
