import 'dart:convert';

import 'package:http/http.dart' as http;

const managementResponseSchemaVersion = 1;
const managementResponseSchemaHeader = 'x-camellia-response-schema';
const managementResponseKindHeader = 'x-camellia-response-kind';

class ManagementApiException implements Exception {
  ManagementApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    required this.retryable,
  });

  final int statusCode;
  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

void requireManagementResponseHeaders(http.Response response) {
  if (response.headers[managementResponseSchemaHeader] !=
      managementResponseSchemaVersion.toString()) {
    throw const FormatException('Unsupported Management response schema');
  }
  final contentType = response.headers['content-type']
      ?.split(';')
      .first
      .trim()
      .toLowerCase();
  if (contentType != 'application/json') {
    throw const FormatException('Invalid Management response content type');
  }
  final kind = response.headers[managementResponseKindHeader];
  if (kind == null || kind.isEmpty) {
    throw const FormatException('Missing Management response kind');
  }
}

void _requireManagementKind(
  http.Response response,
  Map<String, dynamic> payload,
) {
  final kind = response.headers[managementResponseKindHeader];
  final expected = response.statusCode >= 400
      ? 'error'
      : response.statusCode == 202
      ? (payload['pending'] == true ? 'pending' : 'accepted')
      : 'success';
  if (kind != expected) {
    throw const FormatException('Invalid Management response kind');
  }
}

Map<String, dynamic> decodeManagementObject(
  http.Response response,
  String decodedBody,
) {
  requireManagementResponseHeaders(response);
  final payload = jsonDecode(decodedBody);
  if (payload is! Map<String, dynamic> ||
      payload['response_schema_version'] != managementResponseSchemaVersion) {
    throw const FormatException('Invalid Management response object');
  }
  _requireManagementKind(response, payload);
  if (response.statusCode >= 400) {
    final code = payload['code'];
    final message = payload['message'];
    final retryable = payload['retryable'];
    if (code is! String ||
        !RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(code) ||
        message is! String ||
        message.isEmpty ||
        message.length > 256 ||
        retryable is! bool) {
      throw const FormatException('Invalid Management error response');
    }
    throw ManagementApiException(
      statusCode: response.statusCode,
      code: code,
      message: message,
      retryable: retryable,
    );
  }
  return payload;
}

List<dynamic> decodeManagementList(http.Response response, String decodedBody) {
  requireManagementResponseHeaders(response);
  if (response.statusCode >= 400) {
    decodeManagementObject(response, decodedBody);
  }
  final payload = jsonDecode(decodedBody);
  if (payload is! List<dynamic>) {
    throw const FormatException('Invalid Management response list');
  }
  if (response.statusCode != 200 ||
      response.headers[managementResponseKindHeader] != 'success') {
    throw const FormatException('Invalid Management response kind');
  }
  return payload;
}

void requireManagementEmptySuccess(http.Response response) {
  requireManagementResponseHeaders(response);
  if (response.statusCode != 204 ||
      response.headers[managementResponseKindHeader] != 'empty' ||
      response.bodyBytes.isNotEmpty) {
    if (response.statusCode >= 400 && response.bodyBytes.isNotEmpty) {
      decodeManagementObject(response, utf8.decode(response.bodyBytes));
    }
    throw const FormatException('Invalid Management empty response');
  }
}
