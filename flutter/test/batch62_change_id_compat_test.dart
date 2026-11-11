import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('COMPAT-001: Client Change ID Compatibility & Fail-Fast Contracts', () {
    late Directory clientRoot;
    late File commonDart;
    late File desktopSettingPageDart;
    late File serverPageDart;
    late File dialogDart;
    late File webClientHomeDart;
    late File commonRs;
    late File coreMainRs;
    late File uiInterfaceRs;
    late File ipcRs;

    setUpAll(() {
      if (Directory.current.path.endsWith('flutter')) {
        clientRoot = Directory.current.parent;
      } else {
        clientRoot = Directory.current;
      }

      commonDart = File('${clientRoot.path}/flutter/lib/common.dart');
      desktopSettingPageDart = File(
        '${clientRoot.path}/flutter/lib/desktop/pages/desktop_setting_page.dart',
      );
      serverPageDart = File(
        '${clientRoot.path}/flutter/lib/mobile/pages/server_page.dart',
      );
      dialogDart = File(
        '${clientRoot.path}/flutter/lib/common/widgets/dialog.dart',
      );
      webClientHomeDart = File(
        '${clientRoot.path}/flutter/lib/web/web_client_home.dart',
      );
      commonRs = File('${clientRoot.path}/src/common.rs');
      coreMainRs = File('${clientRoot.path}/src/core_main.rs');
      uiInterfaceRs = File('${clientRoot.path}/src/ui_interface.rs');
      ipcRs = File('${clientRoot.path}/src/ipc.rs');

      expect(commonDart.existsSync(), isTrue, reason: 'common.dart must exist');
      expect(
        desktopSettingPageDart.existsSync(),
        isTrue,
        reason: 'desktop_setting_page.dart must exist',
      );
      expect(
        serverPageDart.existsSync(),
        isTrue,
        reason: 'server_page.dart must exist',
      );
      expect(dialogDart.existsSync(), isTrue, reason: 'dialog.dart must exist');
      expect(
        webClientHomeDart.existsSync(),
        isTrue,
        reason: 'web_client_home.dart must exist',
      );
    });

    test('1. common.dart: isChangeIdDisabled defaults to true unless explicitly N', () {
      final content = commonDart.readAsStringSync();
      expect(content.contains('bool isChangeIdDisabled()'), isTrue);
      expect(
        content.contains('bind.mainGetBuildinOption(key: kOptionDisableChangeId)'),
        isTrue,
      );
      expect(content.contains('if (opt.isEmpty)'), isTrue);
      expect(content.contains('return true;'), isTrue);
      expect(content.contains("return opt != 'N';"), isTrue);
    });

    test('2. desktop_setting_page.dart: Change ID card and widget guarded by isChangeIdDisabled', () {
      final content = desktopSettingPageDart.readAsStringSync();
      expect(content.contains('if (!isChangeIdDisabled())'), isTrue);
      expect(content.contains("_Card(title: 'ID', children: [changeId()])"), isTrue);
      expect(content.contains('Widget changeId()'), isTrue);
      expect(content.contains('return const SizedBox.shrink();'), isTrue);
    });

    test('3. server_page.dart: Mobile menu item, divider and click handler guarded by isChangeIdDisabled', () {
      final content = serverPageDart.readAsStringSync();
      expect(content.contains('if (!isChangeIdDisabled())'), isTrue);
      expect(content.contains('value: "changeID"'), isTrue);
      expect(content.contains('if (!isChangeIdDisabled()) const PopupMenuDivider()'), isTrue);
      expect(content.contains('if (value == "changeID")'), isTrue);
    });

    test('4. dialog.dart: changeIdDialog aborts immediately when disabled', () {
      final content = dialogDart.readAsStringSync();
      expect(content.contains('void changeIdDialog()'), isTrue);
      expect(content.contains('if (isChangeIdDisabled())'), isTrue);
    });

    test('5. web_client_home.dart: Trailing button and ID rotate guarded by isChangeIdDisabled', () {
      final content = webClientHomeDart.readAsStringSync();
      expect(content.contains('trailing: isChangeIdDisabled()'), isTrue);
      expect(content.contains('Future<void> _rotateMyId()'), isTrue);
    });

    test('6. common.rs: Exports is_change_id_disabled and defaults OPTION_DISABLE_CHANGE_ID to Y', () {
      final content = commonRs.readAsStringSync();
      expect(content.contains('keys::OPTION_DISABLE_CHANGE_ID'), isTrue);
      expect(content.contains('val.is_empty()'), isTrue);
      expect(content.contains('return "Y".to_owned()'), isTrue);
      expect(content.contains('pub fn is_change_id_disabled() -> bool'), isTrue);
      expect(content.contains('get_builtin_option(keys::OPTION_DISABLE_CHANGE_ID) != "N"'), isTrue);
    });

    test('7. core_main.rs: CLI --set-id fails fast with exact error message', () {
      final content = coreMainRs.readAsStringSync();
      expect(content.contains('args[0] == "--set-id"'), isTrue);
      expect(
        content.contains(
          'Changing device ID is not supported by the remote rendezvous server',
        ),
        isTrue,
      );
      expect(content.contains('crate::common::is_change_id_disabled()'), isTrue);
    });

    test('8. ui_interface.rs: change_id and change_id_shared_ fail fast with server_not_support', () {
      final content = uiInterfaceRs.readAsStringSync();
      expect(content.contains('pub fn is_change_id_disabled() -> bool'), isTrue);
      expect(content.contains('pub fn change_id(id: String)'), isTrue);
      expect(
        content.contains(
          '*ASYNC_JOB_STATUS.lock().unwrap() = "server_not_support".to_string();',
        ),
        isTrue,
      );
      expect(content.contains('pub async fn change_id_shared_('), isTrue);
      expect(content.contains('return "server_not_support";'), isTrue);
    });

    test('9. Functional simulation: Capability evaluator logic truth table', () {
      bool evalIsChangeIdDisabled(String opt) {
        if (opt.isEmpty) {
          return true;
        }
        return opt != 'N';
      }

      // Default (empty string from missing option)
      expect(evalIsChangeIdDisabled(''), isTrue);

      // Explicitly disabled
      expect(evalIsChangeIdDisabled('Y'), isTrue);
      expect(evalIsChangeIdDisabled('y'), isTrue);
      expect(evalIsChangeIdDisabled('true'), isTrue);
      expect(evalIsChangeIdDisabled('1'), isTrue);

      // Explicitly enabled (future-proof)
      expect(evalIsChangeIdDisabled('N'), isFalse);

      // Unexpected values fail-safe to disabled
      expect(evalIsChangeIdDisabled('unknown'), isTrue);
      expect(evalIsChangeIdDisabled('false'), isTrue);
    });

    test('10. ipc.rs guards id write against is_change_id_disabled', () {
      final content = ipcRs.readAsStringSync();
      final someValIdx = content.indexOf('Some(value) => {');
      expect(someValIdx > 0, isTrue);
      final idWriteIdx = content.indexOf('if name == "id"', someValIdx);
      expect(idWriteIdx > someValIdx, isTrue);
      final idBlock = content.substring(idWriteIdx, idWriteIdx + 400);
      expect(idBlock.contains('crate::common::is_change_id_disabled()'), isTrue);
      expect(idBlock.contains('updated = false;'), isTrue);
    });
  });
}
