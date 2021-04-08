import '../../sync_storage.dart';

class SyncIndicator {
  final DelayDurationGetter getDelay;

  bool get needSync => _needSync;
  bool _needSync;

  int get attempt => _attempt;
  int _attempt;

  DateTime get delayedTo => _delayedTo;
  DateTime _delayedTo;

  bool get canSync =>
      needSync &&
      (delayedTo.isAtSameMomentAs(DateTime.now()) ||
          delayedTo.isBefore(DateTime.now()));

  bool get isSyncDelayed => attempt >= 0;

  SyncIndicator({
    this.getDelay,
    bool needSync,
  }) {
    ArgumentError.checkNotNull(getDelay, 'getDelay');

    reset(needSync: needSync);
  }

  void reset({bool needSync}) {
    _needSync = needSync ?? false;
    _attempt = -1;
    _delayedTo = DateTime.now();
  }

  Duration delay() {
    if (!canSync) {
      throw StateError('$runtimeType is already delayed.');
    }

    final delay = getDelay(++_attempt);
    _delayedTo = DateTime.now().add(delay);
    return delay;
  }
}
