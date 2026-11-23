import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common/formatter/id_formatter.dart';
import '../../../models/platform_model.dart';
import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:camellia_remote_app/common/widgets/peer_card.dart';
import 'package:camellia_remote_app/ui/camellia_design.dart';

@visibleForTesting
List<Peer> mergeAutocompletePeers({
  Iterable<Peer> addressBookPeers = const [],
  Iterable<Peer> groupPeers = const [],
  Iterable<Peer> lanPeers = const [],
  Iterable<Peer> recentPeers = const [],
  Iterable<String> restRecentPeerIds = const [],
}) {
  final combinedPeers = <String, Peer>{};

  void addPeer(Peer peer) {
    if (peer.id.isEmpty) {
      return;
    }
    final existingPeer = combinedPeers[peer.id];
    if (existingPeer == null) {
      combinedPeers[peer.id] = Peer.copy(peer);
    } else if (peer.online) {
      existingPeer.online = true;
    }
  }

  for (final peer in addressBookPeers) {
    addPeer(peer);
  }
  for (final peer in groupPeers) {
    addPeer(peer);
  }
  for (final peer in lanPeers) {
    addPeer(peer);
  }
  for (final peer in recentPeers) {
    addPeer(peer);
  }
  for (final id in restRecentPeerIds) {
    if (id.isNotEmpty && !combinedPeers.containsKey(id)) {
      combinedPeers[id] = Peer.fromJson({'id': id});
    }
  }

  return combinedPeers.values.toList(growable: false);
}

@visibleForTesting
bool updateAutocompletePeerOnlineStates(
  List<Peer> peers, {
  required Set<String> onlines,
  required Set<String> offlines,
}) {
  var changed = false;
  for (final peer in peers) {
    if (onlines.contains(peer.id)) {
      if (!peer.online) {
        peer.online = true;
        changed = true;
      }
    } else if (offlines.contains(peer.id)) {
      if (peer.online) {
        peer.online = false;
        changed = true;
      }
    }
  }
  return changed;
}

@visibleForTesting
List<String> autocompleteOnlineQueryIds(
  Iterable<Peer> options, {
  required int limit,
}) {
  final ids = <String>[];
  final seenIds = <String>{};
  for (final peer in options) {
    if (peer.id.isEmpty || seenIds.contains(peer.id)) {
      continue;
    }
    seenIds.add(peer.id);
    ids.add(peer.id);
    if (ids.length >= limit) {
      break;
    }
  }
  return ids;
}

class AllPeersLoader {
  List<Peer> peers = [];

  bool _isPeersLoading = false;
  bool _isPeersLoaded = false;
  Set<String> _lastQueryOnlineIds = {};
  DateTime _lastQueryOnlineTime = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _queryOnlineTimer;
  List<Peer> _lastQueryOnlineOptions = const [];
  Set<String> _lastOnlineIds = {};
  Set<String> _lastOfflineIds = {};
  final Future<void> Function(List<String> ids) _queryOnlines;
  final Duration _queryOnlineDebounce;
  void Function(VoidCallback)? _setState;
  bool _isCleared = false;

  final String _listenerKey = 'AllPeersLoader';
  static const String _cbQueryOnlines = 'callback_query_onlines';
  static const Duration _queryOnlineInterval = Duration(seconds: 5);
  static const Duration _defaultQueryOnlineDebounce =
      Duration(milliseconds: 300);
  static const int _maxQueryOnlineOptions = 20;

  bool get needLoad => !_isPeersLoaded && !_isPeersLoading;
  bool get isPeersLoaded => _isPeersLoaded;

  AllPeersLoader({
    @visibleForTesting Future<void> Function(List<String> ids)? queryOnlines,
    @visibleForTesting Duration? queryOnlineDebounce,
  })  : _queryOnlines = queryOnlines ?? ((ids) => bind.queryOnlines(ids: ids)),
        _queryOnlineDebounce =
            queryOnlineDebounce ?? _defaultQueryOnlineDebounce;

  void init(void Function(VoidCallback) setState) {
    _setState = setState;
    _isCleared = false;
    gFFI.recentPeersModel.addListener(_mergeAllPeers);
    gFFI.lanPeersModel.addListener(_mergeAllPeers);
    gFFI.abModel.addPeerUpdateListener(_listenerKey, _mergeAllPeers);
    gFFI.groupModel.addPeerUpdateListener(_listenerKey, _mergeAllPeers);
    platformFFI.registerEventHandler(_cbQueryOnlines, _listenerKey,
        (evt) async {
      _updateOnlineState(evt);
    });
  }

  void clear() {
    gFFI.recentPeersModel.removeListener(_mergeAllPeers);
    gFFI.lanPeersModel.removeListener(_mergeAllPeers);
    gFFI.abModel.removePeerUpdateListener(_listenerKey);
    gFFI.groupModel.removePeerUpdateListener(_listenerKey);
    platformFFI.unregisterEventHandler(_cbQueryOnlines, _listenerKey);
    _queryOnlineTimer?.cancel();
    _lastQueryOnlineOptions = const [];
    _setState = null;
    _isCleared = true;
  }

  Future<void> getAllPeers() async {
    if (!needLoad) {
      return;
    }
    _isPeersLoading = true;

    if (gFFI.recentPeersModel.peers.isEmpty) {
      bind.mainLoadRecentPeers();
    }
    if (gFFI.lanPeersModel.peers.isEmpty) {
      bind.mainLoadLanPeers();
    }
    // No need to care about peers from abModel, and group model.
    // Because they will pull data in `refreshCurrentUser()` on startup.

    final startTime = DateTime.now();
    _mergeAllPeers();
    final diffTime = DateTime.now().difference(startTime).inMilliseconds;
    if (diffTime < 100) {
      await Future.delayed(Duration(milliseconds: diffTime));
    }
  }

  void _mergeAllPeers() {
    if (_isCleared) {
      return;
    }
    peers = mergeAutocompletePeers(
      addressBookPeers: gFFI.abModel.allPeers(),
      groupPeers: gFFI.groupModel.peers,
      lanPeers: gFFI.lanPeersModel.peers,
      recentPeers: gFFI.recentPeersModel.peers,
      restRecentPeerIds: gFFI.recentPeersModel.restPeerIds,
    );
    _applyLastOnlineState(peers);
    _scheduleSetState(() {
      _isPeersLoading = false;
      _isPeersLoaded = true;
    });
  }

  void _updateOnlineState(Map<String, dynamic> evt) {
    if (_isCleared) {
      return;
    }
    _lastOnlineIds = _splitPeerIds(evt['onlines']);
    _lastOfflineIds = _splitPeerIds(evt['offlines']);
    final peersChanged = _applyLastOnlineState(peers);
    final optionsChanged = _applyLastOnlineState(_lastQueryOnlineOptions);
    if (peersChanged || optionsChanged) {
      _scheduleSetState(() {});
    }
  }

  void _scheduleSetState(VoidCallback callback) {
    if (_isCleared) {
      return;
    }
    final setState = _setState;
    if (setState == null) {
      callback();
    } else {
      setState(callback);
    }
  }

  bool _applyLastOnlineState(List<Peer> peers) {
    return updateAutocompletePeerOnlineStates(
      peers,
      onlines: _lastOnlineIds,
      offlines: _lastOfflineIds,
    );
  }

  Set<String> _splitPeerIds(dynamic ids) {
    if (ids is! String || ids.isEmpty) {
      return {};
    }
    return ids.split(',').where((id) => id.isNotEmpty).toSet();
  }

  void queryOnlines(Iterable<Peer> options) {
    if (_isCleared) {
      return;
    }
    _lastQueryOnlineOptions = options.toList(growable: false);
    final ids = autocompleteOnlineQueryIds(
      _lastQueryOnlineOptions,
      limit: _maxQueryOnlineOptions,
    ).toSet();
    _queryOnlineTimer?.cancel();
    _queryOnlineTimer = null;
    if (ids.isEmpty) {
      return;
    }
    final now = DateTime.now();
    if (setEquals(ids, _lastQueryOnlineIds) &&
        now.difference(_lastQueryOnlineTime) < _queryOnlineInterval) {
      return;
    }

    _queryOnlineTimer = Timer(_queryOnlineDebounce, () async {
      try {
        await _queryOnlines(ids.toList(growable: false));
        if (_isCleared) {
          return;
        }
        _lastQueryOnlineIds = ids;
        _lastQueryOnlineTime = DateTime.now();
      } catch (e) {
        debugPrint('query autocomplete online state failed: $e');
      }
    });
  }

  @visibleForTesting
  void updateOnlineStateForTesting(Map<String, dynamic> evt) {
    _updateOnlineState(evt);
  }

  @visibleForTesting
  bool applyLastOnlineStateForTesting(List<Peer> peers) {
    return _applyLastOnlineState(peers);
  }
}

class AutocompletePeerTile extends StatefulWidget {
  final VoidCallback onSelect;
  final Peer peer;

  const AutocompletePeerTile({
    super.key,
    required this.onSelect,
    required this.peer,
  });

  @override
  AutocompletePeerTileState createState() => AutocompletePeerTileState();
}

class AutocompletePeerTileState extends State<AutocompletePeerTile> {
  List _frontN<T>(List list, int n) {
    if (list.length <= n) {
      return list;
    } else {
      return list.sublist(0, n);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppVisual.tokens(context);
    final name =
        '${widget.peer.username}${widget.peer.username.isNotEmpty && widget.peer.hostname.isNotEmpty ? '@' : ''}${widget.peer.hostname}';
    final greyStyle = TextStyle(
      fontSize: 11,
      color: tokens.muted,
    );

    final child = Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(CamelliaRadius.control),
        onTap: widget.onSelect,
        child: Container(
          height: 44,
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.max,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: tokens.surfaceContainer,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: tokens.border.withValues(alpha: 0.5),
                    width: 1,
                  ),
                ),
                alignment: Alignment.center,
                width: 34,
                height: 34,
                padding: const EdgeInsets.all(4),
                child: getPlatformImage(
                  widget.peer.platform,
                  size: 22,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        CamelliaStatusDot(
                          color: widget.peer.online
                              ? tokens.success
                              : tokens.muted,
                          size: 7,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            widget.peer.alias.isEmpty
                                ? formatID(widget.peer.id)
                                : widget.peer.alias,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(
                                  fontSize: 13,
                                  height: 1.2,
                                  fontWeight: FontWeight.w600,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                          ),
                        ),
                        if (widget.peer.alias.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 4, right: 4),
                            child: Text(
                              "(${widget.peer.id})",
                              style: greyStyle.copyWith(
                                height: 1.2,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 1),
                    Text(
                      name,
                      style: greyStyle.copyWith(height: 1.2),
                      textAlign: TextAlign.start,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final colors = _frontN(widget.peer.tags, 25)
        .map((e) => gFFI.abModel.getCurrentAbTagColor(e))
        .toList();

    return Tooltip(
      message: !(isDesktop || isWebDesktop)
          ? ''
          : widget.peer.tags.isNotEmpty
              ? '${translate('Tags')}: ${widget.peer.tags.join(', ')}'
              : '',
      child: Stack(
        children: [
          child,
          if (colors.isNotEmpty)
            Positioned(
              top: 5,
              right: 10,
              child: CustomPaint(
                painter: TagPainter(radius: 3, colors: colors),
              ),
            ),
        ],
      ),
    );
  }
}
