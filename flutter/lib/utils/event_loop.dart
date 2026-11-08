import 'dart:async';

import 'package:flutter/foundation.dart';

typedef EventCallback<Data> = Future<dynamic> Function(Data data);

abstract class BaseEvent<EventType, Data> {
  EventType type;
  Data data;

  /// Constructor.
  BaseEvent(this.type, this.data);

  /// Consume this event.
  @visibleForTesting
  Future<dynamic> consume() async {
    final cb = findCallback(type);
    if (cb == null) {
      return null;
    } else {
      return cb(data);
    }
  }

  EventCallback<Data>? findCallback(EventType type);
}

abstract class BaseEventLoop<EventType, Data> {
  static const int maxQueueCapacity = 1000;
  final List<BaseEvent<EventType, Data>> _evts = [];
  Timer? _timer;
  bool _closed = false;
  int _generation = 0;
  bool _isConsuming = false;

  bool get isClosed => _closed;
  int get generation => _generation;
  List<BaseEvent<EventType, Data>> get evts => _evts;

  Future<void> onReady() async {
    if (_closed) return;
    _timer?.cancel();
    // Poll every 100ms.
    _timer = Timer.periodic(const Duration(milliseconds: 100), _handleTimer);
  }

  /// An Event is about to be consumed.
  Future<void> onPreConsume(BaseEvent<EventType, Data> evt) async {}

  /// An Event was consumed.
  Future<void> onPostConsume(BaseEvent<EventType, Data> evt) async {}

  /// Events are all handled and cleared.
  Future<void> onEventsClear() async {}

  /// Events start to consume.
  Future<void> onEventsStartConsuming() async {}

  Future<void> _handleTimer(Timer timer) async {
    final currentGen = _generation;
    if (_closed || _generation != currentGen || _isConsuming) {
      if (_closed || _generation != currentGen) {
        timer.cancel();
      }
      return;
    }
    if (_evts.isEmpty) {
      return;
    }
    timer.cancel();
    _timer = null;
    _isConsuming = true;
    try {
      if (_closed || _generation != currentGen) return;
      await onEventsStartConsuming();
      while (_evts.isNotEmpty) {
        if (_closed || _generation != currentGen) break;
        final evt = _evts.removeAt(0);
        if (_closed || _generation != currentGen) break;
        await onPreConsume(evt);
        if (_closed || _generation != currentGen) break;
        await evt.consume();
        if (_closed || _generation != currentGen) break;
        await onPostConsume(evt);
      }
      if (!_closed && _generation == currentGen) {
        await onEventsClear();
      }
    } catch (e, stack) {
      debugPrint("BaseEventLoop error during consumption: $e\n$stack");
    } finally {
      _isConsuming = false;
      if (!_closed && _generation == currentGen) {
        _timer?.cancel();
        _timer = Timer.periodic(
          const Duration(milliseconds: 100),
          _handleTimer,
        );
      }
    }
  }

  Future<void> close({Duration timeout = const Duration(seconds: 2)}) async {
    _closed = true;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _evts.clear();

    if (_isConsuming) {
      final deadline = DateTime.now().add(timeout);
      while (_isConsuming && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
    }
  }

  bool pushEvent(BaseEvent<EventType, Data> evt) {
    if (_closed) {
      debugPrint(
        "Warning: BaseEventLoop is closed, event rejected: ${evt.type}",
      );
      return false;
    }
    if (_evts.length >= maxQueueCapacity) {
      debugPrint(
        "Warning: BaseEventLoop queue full ($maxQueueCapacity), event dropped: ${evt.type}",
      );
      return false;
    }
    _evts.add(evt);
    return true;
  }

  void clear() {
    _evts.clear();
  }
}
