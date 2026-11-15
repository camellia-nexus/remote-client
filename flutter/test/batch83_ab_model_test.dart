import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/hbbs/hbbs.dart';
import 'package:camellia_remote_app/generated_bridge.dart';
import 'package:camellia_remote_app/models/ab_model.dart';
import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';

class _FakeRustdeskImpl extends RustdeskImpl {
  final Map<String, String> localOptions = {};
  final Map<String, String> flutterOptions = {};

  @override
  String mainGetLocalOption({required String key}) => localOptions[key] ?? '';
  @override
  String getLocalFlutterOption({required String k}) => flutterOptions[k] ?? '';
  @override
  Future<void> setLocalFlutterOption({required String k, required String v}) async {
    flutterOptions[k] = v;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeRustdeskImpl fakeBridge;

  setUp(() {
    isTest = true;
    fakeBridge = _FakeRustdeskImpl();
    platformFFI.ffiBind = fakeBridge;
  });

  group('STATE-032: Client Address Book Profile GUID Keying & Disambiguation', () {
    test('stores profiles with identical names under distinct GUIDs without dropping either', () {
      final model = AbModel();

      final profileAlice = AbProfile(
        'g1',
        'DevOps',
        'alice',
        'Alice DevOps',
        ShareRule.read.value,
        null,
      );
      final profileBob = AbProfile(
        'g2',
        'DevOps',
        'bob',
        'Bob DevOps',
        ShareRule.readWrite.value,
        null,
      );

      model.setAbProfiles([profileAlice, profileBob]);

      // Verify both profiles are stored under their respective GUIDs
      expect(model.addressbooks.length, equals(2));
      expect(model.addressbooks.containsKey('g1'), isTrue);
      expect(model.addressbooks.containsKey('g2'), isTrue);

      final bookAlice = model.addressbooks['g1']!;
      final bookBob = model.addressbooks['g2']!;

      expect(bookAlice.name(), equals('DevOps'));
      expect(bookAlice.sharedProfile()?.guid, equals('g1'));
      expect(bookAlice.sharedProfile()?.owner, equals('alice'));

      expect(bookBob.name(), equals('DevOps'));
      expect(bookBob.sharedProfile()?.guid, equals('g2'));
      expect(bookBob.sharedProfile()?.owner, equals('bob'));
    });

    test('getProfileDisplayName disambiguates duplicate profile names with (owner)', () {
      final model = AbModel();

      final profileAlice = AbProfile(
        'g1',
        'DevOps',
        'alice',
        '',
        ShareRule.read.value,
        null,
      );
      final profileBob = AbProfile(
        'g2',
        'DevOps',
        'bob',
        '',
        ShareRule.readWrite.value,
        null,
      );
      final profileUnique = AbProfile(
        'g3',
        'QA',
        'charlie',
        '',
        ShareRule.read.value,
        null,
      );
      final profileNoOwner = AbProfile(
        'g4',
        'DevOps',
        '',
        '',
        ShareRule.read.value,
        null,
      );

      model.setAbProfiles([profileAlice, profileBob, profileUnique, profileNoOwner]);

      // Method on AbModel
      expect(model.getProfileDisplayName(profileAlice), equals('DevOps (alice)'));
      expect(model.getProfileDisplayName(profileBob), equals('DevOps (bob)'));
      expect(model.getProfileDisplayName(profileUnique), equals('QA'));
      expect(model.getProfileDisplayName(profileNoOwner), equals('DevOps'));

      // Top-level function helper with explicit profile list
      expect(
        getProfileDisplayName(profileAlice, [profileAlice, profileBob]),
        equals('DevOps (alice)'),
      );
      expect(
        getProfileDisplayName(profileBob, [profileAlice, profileBob]),
        equals('DevOps (bob)'),
      );
      expect(
        getProfileDisplayName(profileUnique, [profileAlice, profileBob, profileUnique]),
        equals('QA'),
      );
    });

    test('deduplicates shared profiles strictly by GUID (preserving same names across owners)', () {
      final profiles = <AbProfile>[];

      final u1 = AbProfile('guid-1', 'Infra', 'alice', '', ShareRule.read.value, null);
      final u2 = AbProfile('guid-2', 'Infra', 'bob', '', ShareRule.read.value, null);
      final u1Updated = AbProfile('guid-1', 'Infra-Renamed', 'alice', '', ShareRule.fullControl.value, null);

      // Add u1
      int idx1 = profiles.indexWhere((e) => e.guid == u1.guid);
      if (idx1 < 0) {
        profiles.add(u1);
      } else {
        profiles[idx1] = u1;
      }

      // Add u2 (same name 'Infra', different guid 'guid-2') -> must be added, not replaced
      int idx2 = profiles.indexWhere((e) => e.guid == u2.guid);
      if (idx2 < 0) {
        profiles.add(u2);
      } else {
        profiles[idx2] = u2;
      }

      expect(profiles.length, equals(2));
      expect(profiles[0].guid, equals('guid-1'));
      expect(profiles[1].guid, equals('guid-2'));

      // Add u1Updated (same guid 'guid-1') -> must replace u1 at index 0
      int idx3 = profiles.indexWhere((e) => e.guid == u1Updated.guid);
      if (idx3 < 0) {
        profiles.add(u1Updated);
      } else {
        profiles[idx3] = u1Updated;
      }

      expect(profiles.length, equals(2));
      expect(profiles[0].guid, equals('guid-1'));
      expect(profiles[0].name, equals('Infra-Renamed'));
      expect(profiles[0].rule, equals(ShareRule.fullControl.value));
      expect(profiles[1].guid, equals('guid-2'));
    });

    test('cache serialization and deserialization restores GUID-keyed profiles', () async {
      final model = AbModel();

      final personalProfile = AbProfile(
        'personal-1',
        'My address book',
        'me',
        '',
        ShareRule.fullControl.value,
        null,
      );
      final sharedProfile = AbProfile(
        'shared-guid-99',
        'Production',
        'dev-team',
        '',
        ShareRule.readWrite.value,
        null,
      );

      model.setAbProfiles([personalProfile, sharedProfile]);
      await model.setCurrentGuid('shared-guid-99');

      final personalBook = model.addressbooks['personal-1']!;
      personalBook.tags.add('personal-tag');

      final sharedBook = model.addressbooks['shared-guid-99']!;
      sharedBook.tags.addAll(['prod-tag', 'db-tag']);
      sharedBook.peers.add(Peer.fromJson({'id': 'peer-1', 'alias': 'db-primary'}));
      sharedBook.tagColors['prod-tag'] = 0xFFFF0000;

      final serialized = model.serializeCache();
      expect(serialized.length, equals(2));

      // Verify entries are indexed by GUID
      final personalEntry = serialized.firstWhere((e) => e['guid'] == 'personal-1');
      expect(personalEntry['name'], equals('My address book'));
      expect(personalEntry['tags'], contains('personal-tag'));

      final sharedEntry = serialized.firstWhere((e) => e['guid'] == 'shared-guid-99');
      expect(sharedEntry['name'], equals('Production'));
      expect(sharedEntry['owner'], equals('dev-team'));
      expect(sharedEntry['tags'], containsAll(['prod-tag', 'db-tag']));
      expect(sharedEntry['peers'], hasLength(1));

      // Restore into fresh model
      final restoredModel = AbModel();
      restoredModel.deserializeCache({
        'access_token': 'test-token',
        'ab_entries': serialized,
      });

      expect(restoredModel.addressbooks.containsKey('personal-1'), isTrue);
      expect(restoredModel.addressbooks.containsKey('shared-guid-99'), isTrue);

      final restoredShared = restoredModel.addressbooks['shared-guid-99']!;
      expect(restoredShared.name(), equals('Production'));
      expect(restoredShared.sharedProfile()?.owner, equals('dev-team'));
      expect(restoredShared.tags, containsAll(['prod-tag', 'db-tag']));
      expect(restoredShared.peers, hasLength(1));
      expect(restoredShared.peers.first.id, equals('peer-1'));
      expect(restoredShared.tagColors['prod-tag'], equals(0xFFFF0000));
    });

    test('safely handles legacy caches that keyed by name without data loss', () {
      final model = AbModel();

      // Legacy format 1: List with missing or null guid
      final legacyListCache = {
        'access_token': 'test-token',
        'ab_entries': [
          {
            'name': 'My address book',
            'guid': null,
            'tags': ['legacy-personal'],
            'peers': [{'id': 'p1'}],
          },
          {
            'name': 'OldSharedBook',
            'guid': '',
            'owner': 'legacy-user',
            'tags': ['legacy-tag'],
            'peers': [{'id': 'p2', 'alias': 'old-server'}],
          },
        ],
      };

      model.deserializeCache(legacyListCache);
      expect(model.addressbooks.isNotEmpty, isTrue);
      expect(model.addressbooks.values.any((b) => b.name() == 'My address book'), isTrue);
      expect(model.addressbooks.values.any((b) => b.name() == 'OldSharedBook'), isTrue);

      // Legacy format 2: Map keyed by name
      final legacyMapCache = {
        'access_token': 'test-token',
        'ab_entries': {
          'Alpha': {
            'tags': ['tag-alpha'],
            'peers': [{'id': 'alpha-1'}],
          },
          'Beta': {
            'guid': 'beta-guid',
            'tags': ['tag-beta'],
            'peers': [{'id': 'beta-1'}],
          },
        },
      };

      model.deserializeCache(legacyMapCache);
      expect(model.addressbooks.length, equals(2));
      expect(model.addressbooks.values.any((b) => b.name() == 'Alpha'), isTrue);
      expect(model.addressbooks.values.any((b) => b.name() == 'Beta'), isTrue);
      expect(model.addressbooks.containsKey('beta-guid'), isTrue);
      expect(model.addressbooks['beta-guid']!.peers.first.id, equals('beta-1'));
    });

    test('selection tracking by _currentGuid with backwards-compatible currentName', () async {
      final model = AbModel();

      final p1 = AbProfile('g1', 'Name-1', 'owner1', '', ShareRule.read.value, null);
      final p2 = AbProfile('g2', 'Name-2', 'owner2', '', ShareRule.read.value, null);
      model.setAbProfiles([p1, p2]);

      await model.setCurrentGuid('g1');
      expect(model.currentGuid.value, equals('g1'));
      expect(model.currentName.value, equals('Name-1'));
      expect(model.currentName.toString(), equals('Name-1'));
      expect(model.current.name(), equals('Name-1'));

      await model.setCurrentGuid('g2');
      expect(model.currentGuid.value, equals('g2'));
      expect(model.currentName.value, equals('Name-2'));
      expect(model.currentName.toString(), equals('Name-2'));
      expect(model.current.name(), equals('Name-2'));

      // Backwards-compatible setCurrentName
      await model.setCurrentName('Name-1');
      expect(model.currentGuid.value, equals('g1'));
      expect(model.currentName.value, equals('Name-1'));
    });
  });
}
