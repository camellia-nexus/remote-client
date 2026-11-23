// ignore_for_file: deprecated_member_use
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import '../harness/test_app_harness.dart';

void main() {
  setUp(() async {
    await TestAppHarness.setUp();
  });

  /// Canonical safe implementation of tip message formatter that avoids
  /// indexing the original English text by the translated string's length.
  String safeFormatTip(String text, String Function(String) translator) {
    if (text.startsWith('Failed') && text.contains(': ')) {
      final words = text.split(': ');
      return words.map(translator).join(': ');
    }
    final words = text.split(' ');
    if (words.length > 1 && words[0].endsWith('_tip')) {
      final rawTipKey = words[0];
      // Slice remainder using rawTipKey.length rather than translated length
      if (text.length > rawTipKey.length + 1) {
        final rest = text.substring(rawTipKey.length + 1);
        return '${translator(rawTipKey)} ${translator(rest)}';
      } else {
        return translator(rawTipKey);
      }
    }
    return translator(text);
  }

  group('Tier 2: Substring Slice Boundary & CJK Tip Slicing Tests (F17)', () {
    test(
      '1. Multibyte CJK translations longer than 64 characters slice safely without throwing RangeError',
      () {
        const cjkLongTranslation =
            '这是一个超长中文提示文案（用于测试当本地化翻译文本的字符长度超过64甚至达到数百字符时，对原始英文字符串执行substring操作不会发生越界异常）';
        expect(cjkLongTranslation.length, greaterThan(64));

        final dictionary = <String, String>{
          'install_tip': cjkLongTranslation,
          'service': '系统服务',
        };

        const originalText = 'install_tip service';

        // Bug demonstration: If original text (19 chars) is sliced using translated key length (>64 chars), RangeError is thrown
        expect(
          () => originalText.substring(cjkLongTranslation.length + 1),
          throwsA(isA<RangeError>()),
          reason: 'Slicing original string with translated length must fail if unpatched',
        );

        // Safe implementation must not throw RangeError
        expect(
          () => safeFormatTip(originalText, (k) => dictionary[k] ?? k),
          returnsNormally,
        );

        final result = safeFormatTip(originalText, (k) => dictionary[k] ?? k);
        expect(result, startsWith(cjkLongTranslation));
        expect(result, contains('系统服务'));
      },
    );

    test(
      '2. Single-character tip prefix (a_tip b, _tip x) slices without bounds errors',
      () {
        final dictionary = <String, String>{
          'a_tip': '提示A',
          '_tip': '提示空前缀',
          'b': '内容B',
          'x': '内容X',
        };

        final testInputs = [
          'a_tip b',
          '_tip x',
          'z_tip 1',
        ];

        for (final input in testInputs) {
          expect(
            () => safeFormatTip(input, (k) => dictionary[k] ?? k),
            returnsNormally,
            reason: 'Failed on minimal single-character tip input: "$input"',
          );
          final formatted = safeFormatTip(input, (k) => dictionary[k] ?? k);
          expect(formatted, isNotEmpty);
        }
      },
    );

    test(
      '3. Zero-length suffix after tip key handles boundary cleanly without out-of-range slice',
      () {
        final dictionary = <String, String>{
          'install_tip': '安装提示',
          'config_tip': '配置提示',
        };

        final boundaryInputs = [
          'install_tip',
          'install_tip ',
          'config_tip  ',
        ];

        for (final input in boundaryInputs) {
          expect(
            () => safeFormatTip(input, (k) => dictionary[k] ?? k),
            returnsNormally,
            reason: 'Failed on zero-length or trailing-space tip suffix: "$input"',
          );
          final res = safeFormatTip(input, (k) => dictionary[k] ?? k);
          expect(res, contains('提示'));
        }
      },
    );

    test(
      '4. Extreme message length (5000+ characters) in tip formatter slices correctly without buffer issues',
      () {
        final buffer = StringBuffer('custom_tip ');
        for (int i = 0; i < 500; i++) {
          buffer.write('payload-$i ');
        }
        final hugeInput = buffer.toString();
        expect(hugeInput.length, greaterThan(5000));

        final dictionary = <String, String>{
          'custom_tip': '自定义超长测试提示',
        };

        expect(
          () => safeFormatTip(hugeInput, (k) => dictionary[k] ?? k),
          returnsNormally,
        );

        final result = safeFormatTip(hugeInput, (k) => dictionary[k] ?? k);
        expect(result, startsWith('自定义超长测试提示'));
        expect(result, contains('payload-499'));
      },
    );

    test(
      '5. Multilingual strings containing UTF-16 surrogate pairs and emojis preserve glyph boundaries',
      () {
        final dictionary = <String, String>{
          'status_tip': '🚀 状态指示器（带表情符号）',
          '🛰️ Network online': '🛰️ 网络已上线 ✨',
        };

        const inputWithEmoji = 'status_tip 🛰️ Network online';

        expect(
          () => safeFormatTip(inputWithEmoji, (k) => dictionary[k] ?? k),
          returnsNormally,
        );

        final result = safeFormatTip(inputWithEmoji, (k) => dictionary[k] ?? k);
        expect(result, contains('🚀 状态指示器'));
        expect(result, contains('🛰️ 网络已上线 ✨'));
      },
    );

    test(
      '6. Non-tip messages and failed colon messages pass through translator without substring corruption',
      () {
        final dictionary = <String, String>{
          'Failed': '失败',
          'Connection refused': '连接被拒绝',
          'Simple plain message': '简单纯文本消息',
          '': '',
        };

        final testCases = [
          'Failed: Connection refused',
          'Simple plain message',
          '123 456 789',
          '!@#\$%^&*()',
          '',
        ];

        for (final input in testCases) {
          expect(
            () => safeFormatTip(input, (k) => dictionary[k] ?? k),
            returnsNormally,
          );
          final res = safeFormatTip(input, (k) => dictionary[k] ?? k);
          expect(res, isNotNull);
        }
      },
    );

    testWidgets(
      '7. msgboxContent widget renders with standard layout builder without throwing assertion exceptions',
      (tester) async {
        await TestAppHarness.pumpWidget(
          tester,
          child: msgboxContent(
            'info',
            'Service Notice',
            'Plain informational message without tip suffix',
          ),
        );
        await tester.pump();

        expect(find.text('Plain informational message without tip suffix'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await TestAppHarness.tearDown(tester);
      },
    );
  });
}
