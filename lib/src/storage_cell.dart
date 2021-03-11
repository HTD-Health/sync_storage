part of './storage_entry.dart';

typedef DelayDurationGetter = Duration Function(int attempt);

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
  static const maxNetworkSyncAttempts = 5;

  DateTime _syncDelayedTo;
  DateTime get syncDelayedTo => _syncDelayedTo;
  bool get isDelayed =>
      _syncDelayedTo != null && DateTime.now().isBefore(_syncDelayedTo);
  final DateTime createdAt;
  DateTime get updatedAt => _updatedAt;
  DateTime _updatedAt;
  DateTime get lastSync => _lastSync;
  DateTime _lastSync;
  bool _deleted;
  bool get deleted => _deleted;

  /// The number of times that network synchronization was retried.
  int get networkSyncAttemptsCount => _networkSyncAttemptsCount;
  int _networkSyncAttemptsCount;

  static Duration defaultGetDelayBeforeNextAttempt(int attemptNumber) {
    if (attemptNumber < 5) {
      return const [
        Duration(seconds: 10),
        Duration(minutes: 1),
        Duration(minutes: 5),
        Duration(minutes: 10),
        Duration(hours: 1),
      ][attemptNumber];
    } else {
      return Duration(days: 1);
    }
  }

  /// Register failed network synchronization.
  ///
  /// Cell will be deleted when retry count
  void registerSyncAttempt({DelayDurationGetter getDelayBeforeNextAttempt}) {
    final getDelay =
        getDelayBeforeNextAttempt ?? defaultGetDelayBeforeNextAttempt;
    final attempt = _networkSyncAttemptsCount++;
    final delay = getDelay(attempt);

    _syncDelayedTo = DateTime.now().add(delay);
  }

  void resetSyncAttemptsCount() {
    _syncDelayedTo = null;
    _networkSyncAttemptsCount = 0;
  }

  /// This indicates that this [StorageCell] should be removed from storage.
  bool get maxSyncAttemptsReached =>
      networkSyncAttemptsCount >= maxNetworkSyncAttempts;

  T _oldElement;
  T get oldElement => _oldElement;
  T _element;
  T get element => _element;
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
    ObjectId id,
    @required T element,
    T oldElement,
    DateTime createdAt,
    DateTime updatedAt,
    DateTime lastSync,
    bool deleted,
    int networkSyncAttemptsCount,
    DateTime syncDelayedTo,
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
    @required T element,
    DateTime createdAt,
    bool deleted,
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
      ((updatedAt != null && !updatedAt.isAfter(lastSync)) ||
          // element was created after last sync
          (updatedAt == null && !createdAt.isAfter(lastSync))));

  /// Whether current cell could be synced with network.
  bool get isReadyForSync => !isDelayed && needsNetworkSync;

  /// Marking this cell as ready for update.
  void markAsUpdateNeeded() {
    _updatedAt = DateTime.now();
  }

  /// Mark element as synced with network.
  void markAsSynced() {
    _oldElement = null;
    _lastSync = DateTime.now();
    resetSyncAttemptsCount();
  }

  void markAsDeleted() {
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

  StorageCell copy() {
    return StorageCell(
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

  String toJson(Serializer<T> serializer) {
    final jsonMap = <String, dynamic>{
      'id': id.hexString,
      'deleted': deleted,
      'syncDelayedTo': _syncDelayedTo?.toIso8601String(),
      'createdAt': createdAt?.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
      'lastSync': lastSync?.toIso8601String(),
      'networkSyncAttemptsCount': networkSyncAttemptsCount,
      'element': element == null ? null : serializer.toJson(element),
      if (oldElement != null) 'oldElement': serializer.toJson(oldElement),
    };

    return json.encode(jsonMap);
  }

  factory StorageCell.fromJson(String data, Serializer<T> serializer) {
    final dynamic decodedJson = json.decode(data);

    final id = decodedJson['id'];
    final element = decodedJson['element'];
    final oldElement = decodedJson['oldElement'];
    final createdAt = decodedJson['createdAt'];
    final updatedAt = decodedJson['updatedAt'];
    final lastSync = decodedJson['lastSync'];
    final syncDelayedTo = decodedJson['syncDelayedTo'];

    return StorageCell(
      id: id == null

          /// If current cell does not contain id, generate a new one.
          /// (silent data migration)
          ? null
          : ObjectId.fromHexString(id),
      deleted: decodedJson['deleted'],
      networkSyncAttemptsCount: decodedJson['networkSyncAttemptsCount'],
      element: element == null ? null : serializer.fromJson(element),
      oldElement: oldElement == null ? null : serializer.fromJson(oldElement),
      createdAt: createdAt == null ? null : DateTime.tryParse(createdAt),
      updatedAt: updatedAt == null ? null : DateTime.tryParse(updatedAt),
      lastSync: lastSync == null ? null : DateTime.tryParse(lastSync),
      syncDelayedTo:
          syncDelayedTo == null ? null : DateTime.tryParse(syncDelayedTo),
    );
  }
}
