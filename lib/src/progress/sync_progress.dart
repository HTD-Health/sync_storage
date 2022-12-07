import 'dart:async';
import 'dart:math';

import 'package:meta/meta.dart';

@deprecated
class SyncProgressEvent {
  final String? entryName;
  final int actionIndex;
  final int actionsCount;

  double get progress => max(actionIndex, 0) / actionsCount;

  const SyncProgressEvent({
    required this.entryName,
    required this.actionIndex,
    required this.actionsCount,
  });

  SyncProgressEvent copyWith({
    String? entryName,
    int? actionIndex,
    int? actionsCount,
  }) {
    if (actionIndex != null &&
        actionIndex > (actionsCount ?? this.actionsCount)) {
      throw ArgumentError.value(
        actionIndex,
        'actionIndex',
        'actionIndex is larger than actionsCount',
      );
    }

    return SyncProgressEvent(
      entryName: entryName ?? this.entryName,
      actionIndex: actionIndex ?? this.actionIndex,
      actionsCount: actionsCount ?? this.actionsCount,
    );
  }
}

class SyncProgress {
  final _syncProgress = StreamController<SyncProgressEvent?>.broadcast();
  Stream<SyncProgressEvent?> get stream => _syncProgress.stream;

  bool get isStarted => _currentEvent != null;

  SyncProgressEvent? _currentEvent;
  SyncProgressEvent? get currentEvent => _currentEvent;

  void start({
    required String? entryName,
    required int actionsCount,
  }) {
    ArgumentError.checkNotNull(actionsCount, 'resourcesCount');
    if (isStarted) {
      throw StateError('Cannot start $runtimeType. Already started.');
    }

    _currentEvent = SyncProgressEvent(
      actionIndex: -1,
      actionsCount: actionsCount,
      entryName: entryName,
    );
    send();
  }

  void update({
    String? entryName,
    int? actionIndex,
    int? actionsCount,
  }) {
    if (!isStarted) {
      throw StateError('Cannot update $runtimeType. Not started.');
    }
    _currentEvent = _currentEvent!.copyWith(
      actionIndex: actionIndex,
      actionsCount: actionsCount,
      entryName: entryName,
    );
    send();
  }

  void end() {
    if (!isStarted) {
      throw StateError('Cannot end $runtimeType. Not started.');
    }
    _syncProgress.sink.add(_currentEvent!.copyWith(
      entryName: null,
      actionIndex: _currentEvent!.actionsCount,
    ));
    _currentEvent = null;
    send();
  }

  @visibleForTesting
  void send() {
    _syncProgress.sink.add(_currentEvent);
  }

  void dispose() {
    _syncProgress.close();
  }
}
