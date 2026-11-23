import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/widgets/adaptive_layout.dart';
import 'package:camellia_remote_app/consts.dart';
import 'package:camellia_remote_app/models/ab_model.dart';
import 'package:camellia_remote_app/models/peer_tab_model.dart';
import 'package:camellia_remote_app/models/state_model.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:window_manager/window_manager.dart';

import '../../common.dart';
import '../../models/peer_model.dart';
import '../../models/platform_model.dart';
import 'peer_card.dart';

typedef PeerFilter = bool Function(Peer peer);
typedef PeerCardBuilder = Widget Function(Peer peer);

class PeerSortType {
  static const String remoteId = 'Remote ID';
  static const String remoteHost = 'Remote Host';
  static const String username = 'Username';
  static const String status = 'Status';

  static List<String> values = [
    PeerSortType.remoteId,
    PeerSortType.remoteHost,
    PeerSortType.username,
    PeerSortType.status,
  ];
}

class LoadEvent {
  static const String recent = 'load_recent_peers';
  static const String favorite = 'load_fav_peers';
  static const String lan = 'load_lan_peers';
  static const String addressBook = 'load_address_book_peers';
  static const String group = 'load_group_peers';
}

class PeersModelName {
  static const String recent = 'recent peer';
  static const String favorite = 'fav peer';
  static const String lan = 'discovered peer';
  static const String addressBook = 'address book peer';
  static const String group = 'group peer';
}

/// for peer search text, global obs value
final peerSearchText = ''.obs;

/// for peer sort, global obs value
RxString? _peerSort;
RxString get peerSort {
  _peerSort ??= bind.getLocalFlutterOption(k: kOptionPeerSorting).obs;
  return _peerSort!;
}

// list for listener
RxList<RxString> get obslist => [peerSearchText, peerSort].obs;

final peerSearchTextController = TextEditingController(
  text: peerSearchText.value,
);

class _PeersView extends StatefulWidget {
  final Peers peers;
  final PeerFilter? peerFilter;
  final PeerCardBuilder peerCardBuilder;
  final PeerTabIndex peerTabIndex;

  const _PeersView({
    required this.peers,
    required this.peerCardBuilder,
    required this.peerTabIndex,
    this.peerFilter,
  });

  @override
  _PeersViewState createState() => _PeersViewState();
}

/// State for the peer widget.
class _PeersViewState extends State<_PeersView>
    with WindowListener, WidgetsBindingObserver {
  static const int _maxQueryCount = 3;
  final HashMap<String, String> _emptyMessages = HashMap.from({
    LoadEvent.recent: 'empty_recent_tip',
    LoadEvent.favorite: 'empty_favorite_tip',
    LoadEvent.lan: 'empty_lan_tip',
    LoadEvent.addressBook: 'empty_address_book_tip',
  });
  final space = (isDesktop || isWebDesktop) ? 12.0 : 8.0;
  final _curPeers = <String>{};
  var _lastChangeTime = DateTime.now();
  var _lastQueryPeers = <String>{};
  var _lastQueryTime = DateTime.now();
  var _lastWindowRestoreTime = DateTime.now();
  var _queryCount = 0;
  var _exit = false;
  bool _isActive = true;

  final _scrollController = ScrollController();

  _PeersViewState() {
    _startCheckOnlines();
  }

  @override
  void initState() {
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    _exit = true;
    super.dispose();
  }

  @override
  void onWindowFocus() {
    _queryCount = 0;
    _isActive = true;
  }

  @override
  void onWindowBlur() {
    if (isWindows &&
        DateTime.now().difference(_lastWindowRestoreTime) <
            const Duration(milliseconds: 300)) {
      return;
    }
    _queryCount = _maxQueryCount;
    _isActive = false;
  }

  @override
  void onWindowRestore() {
    if (!isWindows) return;
    _queryCount = 0;
    _isActive = true;
    _lastWindowRestoreTime = DateTime.now();
  }

  @override
  void onWindowMinimize() {
    // Window minimize also triggers `onWindowBlur()`.
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (isDesktop || isWebDesktop) return;
    if (state == AppLifecycleState.resumed) {
      _isActive = true;
      _queryCount = 0;
    } else if (state == AppLifecycleState.inactive) {
      _isActive = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<Peers>.value(
      value: widget.peers,
      child: Consumer<Peers>(
        builder: (context, peers, child) {
          if (peers.peers.isEmpty) {
            gFFI.peerTabModel.setCurrentTabCachedPeers([]);
            if (peers.isLoading && !peers.hasLoaded) {
              return AppStatePane(
                state: AppContentState.loading,
                title: translate('Loading...'),
                message: translate('Please wait'),
              );
            }
            return AppStatePane(
              state: AppContentState.empty,
              title: translate('Empty'),
              message: translate(
                _emptyMessages[widget.peers.loadEvent] ?? 'Empty',
              ),
            );
          } else {
            return _buildPeersView(peers);
          }
        },
      ),
    );
  }

  void onVisibilityChanged(VisibilityInfo info) {
    final peerId = _peerId((info.key as ValueKey).value);
    if (info.visibleFraction > 0.00001) {
      _curPeers.add(peerId);
    } else {
      _curPeers.remove(peerId);
    }
    _lastChangeTime = DateTime.now();
  }

  String _cardId(String id) => widget.peers.name + id;
  String _peerId(String cardId) => cardId.replaceAll(widget.peers.name, '');

  Widget _buildPeersView(Peers peers) {
    final updateEvent = peers.event;
    final body = ObxValue<RxList>((filters) {
      return FutureBuilder<List<Peer>>(
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            var peers = snapshot.data!;
            if (peers.length > 1000) peers = peers.sublist(0, 1000);
            gFFI.peerTabModel.setCurrentTabCachedPeers(peers);
            if (peers.isEmpty) {
              return AppStatePane(
                state: AppContentState.noResults,
                title: translate('Search'),
                message: translate('Empty'),
              );
            }

            Widget buildOnePeer(Peer peer, bool isPortrait) {
              final visibilityChild = VisibilityDetector(
                key: ValueKey(_cardId(peer.id)),
                onVisibilityChanged: onVisibilityChanged,
                child: widget.peerCardBuilder(peer),
              );
              if (isPortrait) return visibilityChild;
              return Obx(
                () => peerCardUiType.value == PeerUiType.list
                    ? SizedBox(height: 58, child: visibilityChild)
                    : visibilityChild,
              );
            }

            final Widget child = Obx(() {
              if (stateGlobal.isPortrait.isTrue) {
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: peers.length,
                  itemBuilder: (BuildContext context, int index) {
                    return buildOnePeer(peers[index], true).marginOnly(
                      top: index == 0 ? 0 : space / 2,
                      bottom: space / 2,
                    );
                  },
                );
              }
              if (peerCardUiType.value == PeerUiType.list) {
                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: peers.length,
                  itemBuilder: (BuildContext context, int index) {
                    return buildOnePeer(peers[index], false).marginOnly(
                      top: index == 0 ? 0 : 4,
                      bottom: 4,
                    );
                  },
                );
              }
              if (peerCardUiType.value == PeerUiType.tile) {
                return GridView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.only(bottom: 12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 300,
                    mainAxisExtent: 64,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: peers.length,
                  itemBuilder: (BuildContext context, int index) {
                    return buildOnePeer(peers[index], false);
                  },
                );
              }
              return GridView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.only(bottom: 12),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 280,
                  mainAxisExtent: 156,
                  crossAxisSpacing: 14,
                  mainAxisSpacing: 14,
                ),
                itemCount: peers.length,
                itemBuilder: (BuildContext context, int index) {
                  return buildOnePeer(peers[index], false);
                },
              );
            });

            if (updateEvent == UpdateEvent.load) {
              _curPeers.clear();
              _curPeers.addAll(peers.map((e) => e.id));
              _queryOnlines(true);
            }
            return child;
          } else {
            return AppStatePane(
              state: AppContentState.loading,
              title: translate('Loading...'),
              message: translate('Please wait'),
            );
          }
        },
        future: matchPeers(filters[0].value, filters[1].value, peers.peers),
      );
    }, obslist);

    return body;
  }

  var _queryInterval = const Duration(seconds: 20);

  void _startCheckOnlines() {
    () async {
      final p = await bind.mainIsUsingPublicServer();
      if (!p) {
        _queryInterval = const Duration(seconds: 6);
      }
      while (!_exit) {
        final now = DateTime.now();
        if (!setEquals(_curPeers, _lastQueryPeers)) {
          if (now.difference(_lastChangeTime) > const Duration(seconds: 1)) {
            _queryOnlines(false);
          }
        } else {
          final skipIfIsWeb =
              isWeb && !(stateGlobal.isWebVisible && stateGlobal.isInMainPage);
          final skipIfMobile =
              (isAndroid || isIOS) && !stateGlobal.isInMainPage;
          final skipIfNotActive = skipIfIsWeb || skipIfMobile || !_isActive;
          if (!skipIfNotActive && (_queryCount < _maxQueryCount || !p)) {
            if (now.difference(_lastQueryTime) >= _queryInterval) {
              if (_curPeers.isNotEmpty) {
                bind.queryOnlines(ids: _curPeers.toList(growable: false));
                _lastQueryTime = DateTime.now();
                _queryCount += 1;
              }
            }
          }
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }();
  }

  void _queryOnlines(bool isLoadEvent) {
    if (_curPeers.isNotEmpty) {
      bind.queryOnlines(ids: _curPeers.toList(growable: false));
      _queryCount = 0;
    }
    _lastQueryPeers = {..._curPeers};
    if (isLoadEvent) {
      _lastChangeTime = DateTime.now();
    } else {
      _lastQueryTime = DateTime.now().subtract(_queryInterval);
    }
  }

  Future<List<Peer>>? matchPeers(
    String searchText,
    String sortedBy,
    List<Peer> peers,
  ) {
    if (!PeerSortType.values.contains(sortedBy)) {
      sortedBy = PeerSortType.remoteId;
      bind.setLocalFlutterOption(k: kOptionPeerSorting, v: sortedBy);
    }
    return matchPeersStatic(
      searchText: searchText,
      sortedBy: sortedBy,
      peers: peers,
      peerFilter: widget.peerFilter,
      isRecent: widget.peers.loadEvent == LoadEvent.recent,
      peerTabIndex: widget.peerTabIndex,
    );
  }
}

Future<List<Peer>> matchPeersStatic({
  required String searchText,
  required String sortedBy,
  required List<Peer> peers,
  PeerFilter? peerFilter,
  bool isRecent = false,
  PeerTabIndex peerTabIndex = PeerTabIndex.recent,
}) async {
  List<Peer> workingPeers = List<Peer>.from(peers);
  if (peerFilter != null) {
    workingPeers = workingPeers.where((peer) => peerFilter(peer)).toList();
  }

  if (!PeerSortType.values.contains(sortedBy)) {
    sortedBy = PeerSortType.remoteId;
  }

  if (!isRecent) {
    switch (sortedBy) {
      case PeerSortType.remoteId:
        workingPeers.sort((p1, p2) => p1.getId().compareTo(p2.getId()));
        break;
      case PeerSortType.remoteHost:
        workingPeers.sort(
          (p1, p2) =>
              p1.hostname.toLowerCase().compareTo(p2.hostname.toLowerCase()),
        );
        break;
      case PeerSortType.username:
        workingPeers.sort(
          (p1, p2) =>
              p1.username.toLowerCase().compareTo(p2.username.toLowerCase()),
        );
        break;
      case PeerSortType.status:
        workingPeers.sort((p1, p2) {
          if (p1.online != p2.online) {
            return p1.online ? -1 : 1;
          }
          return p1.getId().compareTo(p2.getId());
        });
        break;
    }
  }

  searchText = searchText.trim();
  if (searchText.isEmpty) {
    return workingPeers;
  }
  searchText = searchText.toLowerCase();
  final matches = await Future.wait(
    workingPeers.map((peer) => matchPeer(searchText, peer, peerTabIndex)),
  );
  final filteredList = List<Peer>.empty(growable: true);
  for (var i = 0; i < workingPeers.length; i++) {
    if (matches[i]) {
      filteredList.add(workingPeers[i]);
    }
  }

  return filteredList;
}

abstract class BasePeersView extends StatelessWidget {
  final PeerTabIndex peerTabIndex;
  final PeerFilter? peerFilter;
  final PeerCardBuilder peerCardBuilder;

  const BasePeersView({
    super.key,
    required this.peerTabIndex,
    this.peerFilter,
    required this.peerCardBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final Peers peers = switch (peerTabIndex) {
      PeerTabIndex.recent => gFFI.recentPeersModel,
      PeerTabIndex.fav => gFFI.favoritePeersModel,
      PeerTabIndex.lan => gFFI.lanPeersModel,
      PeerTabIndex.ab => gFFI.abModel.peersModel,
      PeerTabIndex.group => gFFI.groupModel.peersModel,
    };
    return _PeersView(
      peers: peers,
      peerFilter: peerFilter,
      peerCardBuilder: peerCardBuilder,
      peerTabIndex: peerTabIndex,
    );
  }
}

class RecentPeersView extends BasePeersView {
  RecentPeersView({
    super.key,
    EdgeInsets? menuPadding,
    ScrollController? scrollController,
  }) : super(
         peerTabIndex: PeerTabIndex.recent,
         peerCardBuilder: (Peer peer) =>
             RecentPeerCard(peer: peer, menuPadding: menuPadding),
       );
}

class FavoritePeersView extends BasePeersView {
  FavoritePeersView({
    super.key,
    EdgeInsets? menuPadding,
    ScrollController? scrollController,
  }) : super(
         peerTabIndex: PeerTabIndex.fav,
         peerCardBuilder: (Peer peer) =>
             FavoritePeerCard(peer: peer, menuPadding: menuPadding),
       );
}

class DiscoveredPeersView extends BasePeersView {
  DiscoveredPeersView({
    super.key,
    EdgeInsets? menuPadding,
    ScrollController? scrollController,
  }) : super(
         peerTabIndex: PeerTabIndex.lan,
         peerCardBuilder: (Peer peer) =>
             DiscoveredPeerCard(peer: peer, menuPadding: menuPadding),
       );
}

class AddressBookPeersView extends BasePeersView {
  AddressBookPeersView({
    super.key,
    EdgeInsets? menuPadding,
    ScrollController? scrollController,
  }) : super(
         peerTabIndex: PeerTabIndex.ab,
         peerFilter: (Peer peer) =>
             _hitTag(gFFI.abModel.selectedTags, peer.tags),
         peerCardBuilder: (Peer peer) =>
             AddressBookPeerCard(peer: peer, menuPadding: menuPadding),
       );

  static bool _hitTag(List<dynamic> selectedTags, List<dynamic> idents) {
    if (selectedTags.isEmpty) {
      return true;
    }
    final selectedNormalTags = selectedTags
        .where((tag) => tag != kUntagged)
        .toList();
    if (selectedTags.contains(kUntagged)) {
      if (idents.isEmpty) return true;
      if (selectedNormalTags.isEmpty) return false;
    }
    if (gFFI.abModel.filterByIntersection.value) {
      for (final tag in selectedNormalTags) {
        if (!idents.contains(tag)) {
          return false;
        }
      }
      return true;
    } else {
      for (final tag in selectedNormalTags) {
        if (idents.contains(tag)) {
          return true;
        }
      }
      return false;
    }
  }
}

class MyGroupPeerView extends BasePeersView {
  MyGroupPeerView({
    super.key,
    EdgeInsets? menuPadding,
    ScrollController? scrollController,
  }) : super(
         peerTabIndex: PeerTabIndex.group,
         peerFilter: filter,
         peerCardBuilder: (Peer peer) =>
             MyGroupPeerCard(peer: peer, menuPadding: menuPadding),
       );

  static bool filter(Peer peer) {
    final model = gFFI.groupModel;
    if (model.searchAccessibleItemNameText.isNotEmpty) {
      final text = model.searchAccessibleItemNameText.value.toLowerCase();
      final searchPeersOfUser = model.users.any(
        (user) =>
            user.name == peer.loginName &&
            (user.name.toLowerCase().contains(text) ||
                user.displayNameOrName.toLowerCase().contains(text)),
      );
      final searchPeersOfDeviceGroup =
          peer.device_group_name.toLowerCase().contains(text) &&
          model.deviceGroups.any((g) => g.name == peer.device_group_name);
      if (!searchPeersOfUser && !searchPeersOfDeviceGroup) {
        return false;
      }
    }
    if (model.selectedAccessibleItemName.isNotEmpty) {
      if (model.isSelectedDeviceGroup.value) {
        if (model.selectedAccessibleItemName.value != peer.device_group_name) {
          return false;
        }
      } else {
        if (model.selectedAccessibleItemName.value != peer.loginName) {
          return false;
        }
      }
    }
    return true;
  }
}
