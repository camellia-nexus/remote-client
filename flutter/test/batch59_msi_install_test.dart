import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('INSTALL-001: MSI CustomAction Hardening & Rollback Contracts', () {
    late Directory clientRoot;
    late File customActionsWxs;
    late File rustdeskWxs;
    late File remotePrinterCpp;
    late File customActionsCpp;
    late File firewallRulesCpp;
    late File commonH;

    late String caContent;
    late String rdContent;
    late String rpContent;
    late String caCppContent;
    late String fwContent;
    late String chContent;

    setUpAll(() {
      clientRoot = Directory.current.parent;
      final msiDir = Directory('${clientRoot.path}/res/msi');

      customActionsWxs = File('${msiDir.path}/Package/Fragments/CustomActions.wxs');
      rustdeskWxs = File('${msiDir.path}/Package/Components/RustDesk.wxs');
      remotePrinterCpp = File('${msiDir.path}/CustomActions/RemotePrinter.cpp');
      customActionsCpp = File('${msiDir.path}/CustomActions/CustomActions.cpp');
      firewallRulesCpp = File('${msiDir.path}/CustomActions/FirewallRules.cpp');
      commonH = File('${msiDir.path}/CustomActions/Common.h');

      expect(customActionsWxs.existsSync(), isTrue, reason: 'CustomActions.wxs must exist');
      expect(rustdeskWxs.existsSync(), isTrue, reason: 'RustDesk.wxs must exist');
      expect(remotePrinterCpp.existsSync(), isTrue, reason: 'RemotePrinter.cpp must exist');
      expect(customActionsCpp.existsSync(), isTrue, reason: 'CustomActions.cpp must exist');
      expect(firewallRulesCpp.existsSync(), isTrue, reason: 'FirewallRules.cpp must exist');
      expect(commonH.existsSync(), isTrue, reason: 'Common.h must exist');

      caContent = customActionsWxs.readAsStringSync();
      rdContent = rustdeskWxs.readAsStringSync();
      rpContent = remotePrinterCpp.readAsStringSync();
      caCppContent = customActionsCpp.readAsStringSync();
      fwContent = firewallRulesCpp.readAsStringSync();
      chContent = commonH.readAsStringSync();
    });

    test('1. Transaction-critical actions are configured with Return="check"', () {
      final criticalActions = [
        'CreateStartService',
        'TryStopDeleteService',
        'AddFirewallRules',
        'RemoveFirewallRules',
        'InstallPrinter',
        'UninstallPrinter',
        'AddRegSoftwareSASGeneration',
        'SetPropertyIsServiceRunning',
        'SetPropertyServiceStop',
      ];

      for (final action in criticalActions) {
        final pattern = 'Id="$action"';
        expect(caContent.contains(pattern), isTrue, reason: 'Missing action $action');
        final line = caContent.split('\n').firstWhere((l) => l.contains(pattern));
        expect(
          line.contains('Return="check"'),
          isTrue,
          reason: 'Critical action $action must specify Return="check" (found: $line)',
        );
      }
    });

    test('2. Explicit best-effort actions are configured with Return="ignore"', () {
      final bestEffortActions = [
        'CustomActionHello',
        'RemoveRuntimeGeneratedFiles',
        'TerminateProcesses',
        'TerminateBrokers',
        'TryDeleteStartupShortcut',
        'RemoveAmyuniIdd',
      ];

      for (final action in bestEffortActions) {
        final pattern = 'Id="$action"';
        expect(caContent.contains(pattern), isTrue, reason: 'Missing action $action');
        final line = caContent.split('\n').firstWhere((l) => l.contains(pattern));
        expect(
          line.contains('Return="ignore"'),
          isTrue,
          reason: 'Best-effort action $action must specify Return="ignore" (found: $line)',
        );
      }
    });

    test('3. Paired rollback CustomActions are defined with Execute="rollback" and Return="check"', () {
      final rollbackActions = {
        'RollbackCreateStartService': 'TryStopDeleteService',
        'RollbackFirewallRules': 'AddFirewallRules',
        'RollbackPrinter': 'UninstallPrinter',
      };

      for (final entry in rollbackActions.entries) {
        final rbId = entry.key;
        final dllEntry = entry.value;

        final pattern = 'Id="$rbId"';
        expect(caContent.contains(pattern), isTrue, reason: 'Missing rollback action $rbId');
        final line = caContent.split('\n').firstWhere((l) => l.contains(pattern));

        expect(line.contains('Execute="rollback"'), isTrue, reason: '$rbId must specify Execute="rollback"');
        expect(line.contains('Return="check"'), isTrue, reason: '$rbId must specify Return="check"');
        expect(line.contains('Impersonate="no"'), isTrue, reason: '$rbId must specify Impersonate="no"');
        expect(line.contains('DllEntry="$dllEntry"'), isTrue, reason: '$rbId must bind to DllEntry="$dllEntry"');
      }
    });

    test('4. InstallExecuteSequence sequences rollback actions before deferred actions', () {
      expect(
        rdContent.contains('Id="RollbackCreateStartService.SetParam"'),
        isTrue,
        reason: 'RollbackCreateStartService.SetParam must be defined',
      );
      expect(
        rdContent.contains('Id="RollbackFirewallRules.SetParam"'),
        isTrue,
        reason: 'RollbackFirewallRules.SetParam must be defined',
      );

      // Verify sequence ordering
      expect(
        rdContent.contains('<Custom Action="RollbackCreateStartService.SetParam" Before="RollbackCreateStartService"'),
        isTrue,
      );
      expect(
        rdContent.contains('<Custom Action="RollbackCreateStartService" Before="CreateStartService.SetParam"'),
        isTrue,
      );
      expect(
        rdContent.contains('<Custom Action="RollbackPrinter" Before="InstallPrinter.SetParam"'),
        isTrue,
      );
      expect(
        rdContent.contains('<Custom Action="RollbackFirewallRules.SetParam" Before="RollbackFirewallRules"'),
        isTrue,
      );
      expect(
        rdContent.contains('<Custom Action="RollbackFirewallRules" Before="AddFirewallRules.SetParam"'),
        isTrue,
      );
    });

    test('5. RemotePrinter.cpp closes spooler handle on success (RES-029)', () {
      expect(
        rpContent.contains('ClosePrinter(hPrinter);'),
        isTrue,
        reason: 'addPrinter must close hPrinter handle to eliminate spooler handle leak',
      );
    });

    test('6. RemotePrinter.cpp returns HRESULT and prevents orphan port on missing INF', () {
      expect(
        rpContent.contains('HRESULT installUpdatePrinter(const std::wstring &installFolder)'),
        isTrue,
        reason: 'installUpdatePrinter must return HRESULT',
      );
      expect(
        rpContent.contains('HRESULT uninstallPrinter()'),
        isTrue,
        reason: 'uninstallPrinter must return HRESULT',
      );

      final infCheckIdx = rpContent.indexOf('FileExists(infFile)');
      final portAddIdx = rpContent.indexOf('addLocalPort(RD_PRINTER_PORT)');
      expect(infCheckIdx, isNonNegative);
      expect(portAddIdx, isNonNegative);
      expect(
        infCheckIdx < portAddIdx,
        isTrue,
        reason: 'INF existence check must precede port addition to prevent orphan ports on missing INF',
      );

      expect(rpContent.contains('HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)'), isTrue);
      expect(rpContent.contains('checkDeleteLocalPort(RD_PRINTER_PORT)'), isTrue);
    });

    test('7. CustomActions.cpp checks HRESULTs and fixes SAS pointer bug', () {
      expect(
        caCppContent.contains('hr = RemotePrinter::installUpdatePrinter(installFolder);'),
        isTrue,
      );
      expect(
        caCppContent.contains('ExitOnFailure(hr, "Failed to install RD printer");'),
        isTrue,
      );
      expect(
        caCppContent.contains('hr = RemotePrinter::uninstallPrinter();'),
        isTrue,
      );
      expect(
        caCppContent.contains('ExitOnFailure(hr, "Failed to uninstall RD printer");'),
        isTrue,
      );
      expect(
        caCppContent.contains('HRESULT_FROM_WIN32(ERROR_SERVICE_NOT_ACTIVE)'),
        isTrue,
      );
      expect(
        caCppContent.contains('reinterpret_cast<const BYTE*>(&valueData)'),
        isTrue,
        reason: 'AddRegSoftwareSASGeneration must pass &valueData address to fix 998 ERROR_NOACCESS',
      );
    });

    test('8. Common.h and FirewallRules.cpp declare and handle typed HRESULTs', () {
      expect(chContent.contains('HRESULT AddFirewallRuleEx(bool add, LPWSTR exeName, LPWSTR exeFile);'), isTrue);
      expect(chContent.contains('HRESULT installUpdatePrinter(const std::wstring& installFolder);'), isTrue);
      expect(chContent.contains('HRESULT uninstallPrinter();'), isTrue);
      expect(fwContent.contains('HRESULT AddFirewallRuleEx(bool add, LPWSTR exeName, LPWSTR exeFile)'), isTrue);
      expect(fwContent.contains('HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)'), isTrue);
    });

    test('9. MSI transaction failure and rollback simulation model in Dart', () {
      final List<String> ports = [];
      final List<String> drivers = [];
      final List<String> printers = [];
      final List<String> services = [];
      final List<void Function()> rollbackStack = [];

      void rollback() {
        while (rollbackStack.isNotEmpty) {
          rollbackStack.removeLast()();
        }
      }

      int installPrinterSimulation({required bool infExists, required bool driverFail}) {
        rollbackStack.add(() {
          printers.remove('Camellia Printer');
          drivers.remove('Camellia v4 Printer Driver');
          ports.remove('Camellia Printer');
        });

        if (!infExists) {
          return 2; // ERROR_FILE_NOT_FOUND
        }

        var portCreated = false;
        if (!ports.contains('Camellia Printer')) {
          ports.add('Camellia Printer');
          portCreated = true;
        }

        if (driverFail) {
          if (portCreated) {
            ports.remove('Camellia Printer');
          }
          return 13; // ERROR_INVALID_DATA
        }
        drivers.add('Camellia v4 Printer Driver');
        printers.add('Camellia Printer');
        return 0; // S_OK
      }

      // Scenario A: Missing INF deterministically fails and creates 0 ports
      final errA = installPrinterSimulation(infExists: false, driverFail: false);
      expect(errA, equals(2));
      rollback();
      expect(ports, isEmpty, reason: 'Port must not be orphaned on missing INF');
      expect(drivers, isEmpty);
      expect(printers, isEmpty);

      // Scenario B: Driver failure rolls back newly created port
      final errB = installPrinterSimulation(infExists: true, driverFail: true);
      expect(errB, equals(13));
      rollback();
      expect(ports, isEmpty, reason: 'Port must be rolled back on driver install failure');
      expect(drivers, isEmpty);
      expect(printers, isEmpty);

      // Scenario C: Success followed by service start failure triggers full reverse rollback
      final errC = installPrinterSimulation(infExists: true, driverFail: false);
      expect(errC, equals(0));
      expect(ports, contains('Camellia Printer'));
      expect(drivers, contains('Camellia v4 Printer Driver'));
      expect(printers, contains('Camellia Printer'));

      // Service failure pushes rollback and fails
      rollbackStack.add(() {
        services.remove('Camellia Remote');
      });
      const serviceFail = true;
      if (serviceFail) {
        rollback();
      }

      expect(services, isEmpty);
      expect(printers, isEmpty);
      expect(drivers, isEmpty);
      expect(ports, isEmpty);
    });
  });
}
