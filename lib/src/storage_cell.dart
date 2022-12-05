part of './storage_entry.dart';

typedef DelayDurationGetter = Duration Function(int attempt);

/// Synchronization action that is required for [StorageCell].
enum SyncAction {
  create,
  update,
  delete,
  none,
}

class StorageCell<T> {
  /// current cell identifier
  final ObjectId id;

  /// After 5 failed network sync attempts [StorageCell]
  /// should be removed from storage.
  int get maxNetworkSyncAttempts => _defaultMaxNetworkSyncAttempts;
  static const _defaultMaxNetworkSyncAttempts = 5;

  DateTime? _syncDelayedTo;
  DateTime? get syncDelayedTo => _syncDelayedTo;
  bool get isDelayed =>
      _syncDelayedTo != null && DateTime.now().isBefore(_syncDelayedTo!);
  final DateTime createdAt;
  DateTime? get updatedAt => _updatedAt;
  DateTime? _updatedAt;
  DateTime? get lastSync => _lastSync;
  DateTime? _lastSync;
  bool _deleted;
  bool get deleted => _deleted;

  /// Current element stored in the cell.
  T get element => _element;
  T _element;

  /// Previous element (eg. before update)
  T? get oldElement => _oldElement;
  T? _oldElement;

  /// The number of times that network synchronization was retried.
  int get networkSyncAttemptsCount => _networkSyncAttemptsCount;
  int _networkSyncAttemptsCount;

  /// Register failed network synchronization.
  ///
  /// Cell will be delayed or deleted if [maxSyncAttemptsReached] is
  /// already reached.
  ///
  /// Sync will be delayed by the provided [delay] value.
  Duration registerSyncAttempt({
    required Duration delay,
  }) {
    if (isDelayed) {
      throw StateError('Cannot register sync attempt for delayed cell.');
    }

    _networkSyncAttemptsCount++;

    _syncDelayedTo = DateTime.now().add(delay);

    return delay;
  }

  void resetSyncAttemptsCount() {
    _syncDelayedTo = null;
    _networkSyncAttemptsCount = 0;
  }

  /// This indicates that this [StorageCell] should be removed from storage.
  bool get maxSyncAttemptsReached =>
      networkSyncAttemptsCount >= maxNetworkSyncAttempts;

  void updateElement(T newElement) {
    if (deleted) {
      throw StateError('Cannot update element which is marked as deleted.');
    }

    if (newElement == element) {
      throw ArgumentError.value(
        newElement,
        'newElement',
        'The element cannot be updated by itself (newElement == element).',
      );
    }

    final isElementChanged = newElement != _element;
    if (!isElementChanged) return;

    /// If element is changed.
    _oldElement = _element;
    _element = newElement;

    _updatedAt = DateTime.now();
  }

  StorageCell({
    ObjectId? id,
    required T element,
    T? oldElement,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastSync,
    bool? deleted,
    int? networkSyncAttemptsCount,
    DateTime? syncDelayedTo,
  })  : _element = element,
        id = id ?? ObjectId(),
        createdAt = createdAt ?? DateTime.now(),
        _updatedAt = updatedAt,
        _lastSync = lastSync,
        _syncDelayedTo = syncDelayedTo,
        _oldElement = oldElement,
        _deleted = deleted ?? false,
        _networkSyncAttemptsCount = networkSyncAttemptsCount ?? 0;

  /// Sets [_lastSync] date to the same value as [createdAt] to
  /// indicate that [StorageCell] is synced.
  factory StorageCell.synced({
    required T element,
    DateTime? createdAt,
    bool? deleted,
  }) {
    final creationDate = createdAt ?? DateTime.now();

    return StorageCell(
      element: element,
      deleted: deleted,
      createdAt: creationDate,
      lastSync: creationDate,
    );
  }

  /// Current cell has its representation in network layer.
  bool get wasSynced => lastSync != null;
  bool get needsNetworkSync => !(wasSynced &&
      // Element was updated after last sync
      ((updatedAt != null && !updatedAt!.isAfter(lastSync!)) ||
          // element was created after last sync
          (updatedAt == null && !createdAt.isAfter(lastSync!))));

  /// Whether current cell could be synced with network.
  bool get isReadyForSync => !isDelayed && needsNetworkSync;

  /// Marking this cell as ready for update.
  void markUpdateNeeded() {
    _updatedAt = DateTime.now();
  }

  /// Mark element as synced with network.
  void markSynced() {
    _oldElement = null;
    _lastSync = DateTime.now();
    resetSyncAttemptsCount();
  }

  void markDeleted() {
    if (!_deleted) {
      _deleted = true;
      _updatedAt = DateTime.now();
    }
  }

  SyncAction get actionNeeded {
    if (!needsNetworkSync) {
      return SyncAction.none;
    }

    /// when cell is marked as deleted it will be removed from backend and
    /// after that from the storage.
    if (deleted) {
      return SyncAction.delete;

      /// When [updatedAt] is defined, cell will be updated.
      ///
      /// if lastSync is null, element is not created at the backend
      /// so it cannot be updated. Instead it will be created with other data.
    } else if (wasSynced && updatedAt != null) {
      return SyncAction.update;

      /// Otherwise CREATE request should be made.
    } else {
      return SyncAction.create;
    }
  }

  @deprecated
  StorageCell<T> copy() {
    return StorageCell<T>(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt,
      lastSync: lastSync,
      syncDelayedTo: syncDelayedTo,
      deleted: deleted,
      networkSyncAttemptsCount: networkSyncAttemptsCount,
      element: element,
      oldElement: oldElement,
    );
  }
}
