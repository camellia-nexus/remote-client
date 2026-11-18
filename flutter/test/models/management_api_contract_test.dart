import 'package:camellia_remote_app/models/management_api_contract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  const headers = {
    'x-camellia-response-schema': '1',
    'x-camellia-response-kind': 'success',
    'content-type': 'application/json',
  };

  test('accepts v1 objects and rejects missing transport or body versions', () {
    final accepted = http.Response(
      '{"response_schema_version":1,"value":7}',
      200,
      headers: headers,
    );
    expect(decodeManagementObject(accepted, accepted.body)['value'], 7);

    final missingHeader = http.Response(
      '{"response_schema_version":1,"value":7}',
      200,
    );
    expect(
      () => decodeManagementObject(missingHeader, missingHeader.body),
      throwsFormatException,
    );

    final oldBody = http.Response(
      '{"response_schema_version":0,"value":7}',
      200,
      headers: headers,
    );
    expect(
      () => decodeManagementObject(oldBody, oldBody.body),
      throwsFormatException,
    );
  });

  test('parses canonical machine errors and 204 empty successes', () {
    final error = http.Response(
      '{"response_schema_version":1,"code":"oidc_poll_invalid","message":"localized","retryable":false}',
      400,
      headers: const {
        'x-camellia-response-schema': '1',
        'x-camellia-response-kind': 'error',
        'content-type': 'application/json',
      },
    );
    expect(
      () => decodeManagementObject(error, error.body),
      throwsA(
        isA<ManagementApiException>()
            .having((value) => value.code, 'code', 'oidc_poll_invalid')
            .having((value) => value.message, 'message', 'localized'),
      ),
    );

    final empty = http.Response(
      '',
      204,
      headers: const {
        'x-camellia-response-schema': '1',
        'x-camellia-response-kind': 'empty',
        'content-type': 'application/json',
      },
    );
    expect(() => requireManagementEmptySuccess(empty), returnsNormally);

    final wrongKind = http.Response(
      '{"response_schema_version":1,"value":7}',
      200,
      headers: {...headers, 'x-camellia-response-kind': 'accepted'},
    );
    expect(
      () => decodeManagementObject(wrongKind, wrongKind.body),
      throwsFormatException,
    );

    final legacy = http.Response('', 200, headers: headers);
    expect(() => requireManagementEmptySuccess(legacy), throwsFormatException);
  });
}
