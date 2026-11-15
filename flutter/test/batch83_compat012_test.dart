import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/models/address_book_mutations.dart';

void main() {
  group('COMPAT-012: Canonical JSON Number Normalization', () {
    test('normalizes -0.0 to 0', () {
      final res = publicMutationIntent(-0.0);
      expect(res, equals(0));
      expect(res is int, isTrue);
      expect(jsonEncode(res), equals('0'));

      final mapRes = publicMutationIntent({'key': -0.0}) as Map<String, dynamic>;
      expect(mapRes['key'], equals(0));
      expect(mapRes['key'] is int, isTrue);
      expect(jsonEncode(mapRes), equals('{"key":0}'));
    });

    test('normalizes 1.0 to 1 and keeps integer-valued doubles as int within safe bounds', () {
      final res = publicMutationIntent(1.0);
      expect(res, equals(1));
      expect(res is int, isTrue);
      expect(jsonEncode(res), equals('1'));

      final negRes = publicMutationIntent(-42.0);
      expect(negRes, equals(-42));
      expect(negRes is int, isTrue);
      expect(jsonEncode(negRes), equals('-42'));

      final maxSafe = publicMutationIntent(9007199254740991.0);
      expect(maxSafe, equals(9007199254740991));
      expect(maxSafe is int, isTrue);

      final minSafe = publicMutationIntent(-9007199254740991.0);
      expect(minSafe, equals(-9007199254740991));
      expect(minSafe is int, isTrue);
    });

    test('retains fractional floats like 1.5 and -0.25', () {
      final res1 = publicMutationIntent(1.5);
      expect(res1, equals(1.5));
      expect(res1 is double, isTrue);
      expect(jsonEncode(res1), equals('1.5'));

      final res2 = publicMutationIntent(-0.25);
      expect(res2, equals(-0.25));
      expect(res2 is double, isTrue);
      expect(jsonEncode(res2), equals('-0.25'));
    });

    test('rejects NaN and Infinity fail-closed', () {
      expect(
        () => publicMutationIntent(double.nan),
        throwsA(isA<AddressBookMutationException>().having(
          (e) => e.code,
          'code',
          'invalid_payload',
        )),
      );

      expect(
        () => publicMutationIntent(double.infinity),
        throwsA(isA<AddressBookMutationException>().having(
          (e) => e.code,
          'code',
          'invalid_payload',
        )),
      );

      expect(
        () => publicMutationIntent(double.negativeInfinity),
        throwsA(isA<AddressBookMutationException>().having(
          (e) => e.code,
          'code',
          'invalid_payload',
        )),
      );

      expect(
        () => publicMutationIntent({'val': double.nan}),
        throwsA(isA<AddressBookMutationException>()),
      );

      expect(
        () => publicMutationIntent([1, 2, double.infinity]),
        throwsA(isA<AddressBookMutationException>()),
      );
    });

    test('addressBookRequestDigest normalizes numbers and produces matching SHA-256', () {
      const operation = 'address_book_peer_add';
      const method = 'POST';
      const path = '/api/ab/peer/add';
      const expectedGeneration = 42;

      // Body with floats that must be normalized: 100.0 -> 100, -0.0 -> 0, 2.75 remains 2.75
      const bodyWithFloats = '{"count":100.0,"offset":-0.0,"scale":2.75}';
      final digest1 = addressBookRequestDigest(
        operation: operation,
        method: method,
        path: path,
        body: bodyWithFloats,
        expectedGeneration: expectedGeneration,
      );

      // Equivalent body already with normalized integers
      const bodyWithInts = '{"count":100,"offset":0,"scale":2.75}';
      final digest2 = addressBookRequestDigest(
        operation: operation,
        method: method,
        path: path,
        body: bodyWithInts,
        expectedGeneration: expectedGeneration,
      );

      // Both digests must be identical byte-for-byte
      expect(digest1, equals(digest2));

      // Manually calculate expected canonical document digest:
      // Canonical document keys sorted: args, body, expected_generation, has_body, method, operation, path
      // Inside body: count, offset, scale
      const canonicalJson = '{"args":{},"body":{"count":100,"offset":0,"scale":2.75},"expected_generation":42,"has_body":true,"method":"POST","operation":"address_book_peer_add","path":"/api/ab/peer/add"}';
      final expectedHash = sha256.convert(utf8.encode(canonicalJson)).toString();
      expect(digest1, equals(expectedHash));
    });

    test('addressBookRequestDigest rejects payloads containing NaN or infinity in body', () {
      expect(
        () => addressBookRequestDigest(
          operation: 'op',
          method: 'POST',
          path: '/path',
          body: '{"val":1e9999}', // becomes infinity in JSON
          expectedGeneration: 1,
        ),
        throwsA(isA<AddressBookMutationException>()),
      );
    });
  });
}
