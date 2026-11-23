import 'package:camellia_remote_app/common/hbbs/hbbs.dart';
import 'package:camellia_remote_app/models/model.dart';
import 'package:camellia_remote_app/models/peer_model.dart';

/// Reusable test fixtures for desktop E2E tests.
class TestDataFixtures {
  TestDataFixtures._();

  static Peer createPeerAlice() {
    final peer = Peer.fromJson({
      'id': '100001',
      'username': 'Alice',
      'hostname': 'Office-PC',
      'platform': 'Windows',
      'alias': 'Alice Workstation',
      'tags': ['Work', 'Dev'],
      'hash': '',
      'password': '',
      'forceAlwaysRelay': 'false',
      'rdpPort': '3389',
      'rdpUsername': 'alice_admin',
      'loginName': 'alice@camellia.corp',
      'device_group_name': 'Engineering',
      'note': 'Primary developer workstation',
    });
    peer.online = true;
    return peer;
  }

  static Peer createPeerBob() {
    final peer = Peer.fromJson({
      'id': '100002',
      'username': 'Bob',
      'hostname': 'MacBook-Pro',
      'platform': 'macOS',
      'alias': 'Bob Laptop',
      'tags': ['Design'],
      'hash': '',
      'password': '',
      'forceAlwaysRelay': 'false',
      'rdpPort': '',
      'rdpUsername': '',
      'loginName': 'bob@camellia.corp',
      'device_group_name': 'Design',
      'note': 'Creative MacBook M3 Max',
    });
    peer.online = true;
    return peer;
  }

  static Peer createPeerCharlie() {
    final peer = Peer.fromJson({
      'id': '100003',
      'username': 'Charlie',
      'hostname': 'Linux-Server',
      'platform': 'Linux',
      'alias': 'Prod Server',
      'tags': ['Ops', 'Prod'],
      'hash': '',
      'password': '',
      'forceAlwaysRelay': 'false',
      'rdpPort': '',
      'rdpUsername': '',
      'loginName': 'charlie@camellia.corp',
      'device_group_name': 'Infrastructure',
      'note': 'Ubuntu 24.04 LTS host',
    });
    peer.online = false;
    return peer;
  }

  static Peer createPeerDiana() {
    final peer = Peer.fromJson({
      'id': '100004',
      'username': 'Diana',
      'hostname': 'Test-Rig',
      'platform': 'Windows',
      'alias': 'QA Rig',
      'tags': ['QA'],
      'hash': '',
      'password': '',
      'forceAlwaysRelay': 'false',
      'rdpPort': '',
      'rdpUsername': '',
      'loginName': 'diana@camellia.corp',
      'device_group_name': 'Testing',
      'note': 'Automated regression rig',
    });
    peer.online = false;
    return peer;
  }

  static List<Peer> get allStandardPeers => [
        createPeerAlice(),
        createPeerBob(),
        createPeerCharlie(),
        createPeerDiana(),
      ];

  static AbProfile createDevOpsProfile() {
    return AbProfile(
      'guid-devops-001',
      'DevOps Team',
      'alice',
      'Shared DevOps remote systems',
      ShareRule.readWrite.value,
      null,
    );
  }

  static AbProfile createDesignProfile() {
    return AbProfile(
      'guid-design-002',
      'Design Team',
      'bob',
      'UI/UX workstation machines',
      ShareRule.read.value,
      null,
    );
  }

  /// Seeds default fixtures into the provided global FFI instance.
  static void seedDefaultFixtures(FFI ffi) {
    // 1. Seed Recent Peers
    final alice = createPeerAlice();
    final bob = createPeerBob();
    ffi.recentPeersModel.peers = [alice, bob];
    ffi.recentPeersModel.hasLoaded = true;
    ffi.recentPeersModel.isLoading = false;

    // 2. Seed Favorite Peers
    final charlie = createPeerCharlie();
    ffi.favoritePeersModel.peers = [bob, charlie];
    ffi.favoritePeersModel.hasLoaded = true;
    ffi.favoritePeersModel.isLoading = false;

    // 3. Seed LAN / Discovered Peers
    final diana = createPeerDiana();
    ffi.lanPeersModel.peers = [alice, diana];
    ffi.lanPeersModel.hasLoaded = true;
    ffi.lanPeersModel.isLoading = false;

    // 4. Seed Address Book Profiles
    try {
      ffi.abModel.setAbProfiles([createDevOpsProfile(), createDesignProfile()]);
    } catch (_) {}
  }
}
