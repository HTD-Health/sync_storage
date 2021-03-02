part of './storage_entry.dart';

enum SyncAction {
  create,
  update,
  delete,
}

class StorageCell<T> {
  /// After 5 failed network sync attempts [StorageCell]
  /// should be removed from storage.
  static const maxNetworkSyncAttempts = 5;

  final DateTime createdAt;
  DateTime _updatedAt;
  DateTime get updatedAt => _updatedAt;
  DateTime lastSync;
  bool _deleted;
  bool get deleted => _deleted;
  set deleted(bool value) {
    if (_deleted != value) {
      _deleted = value;
      _updatedAt = DateTime.now();
    }
  }

  int _networkSyncAttemptsCount;

  /// The number of times that network synchronization was retried.
  int get networkSyncAttemptsCount => _networkSyncAttemptsCount;

  /// Register failed network synchronization.
  ///
  /// Cell will be deleted when retry count
  void registerSyncAttempt() {
    _networkSyncAttemptsCount++;
  }

  void resetSyncAttemptsCount() {
    _networkSyncAttemptsCount = 0;
  }

  /// This indicates that this [StorageCell] should be removed from storage.
  bool get maxSyncAttemptsReached =>
      networkSyncAttemptsCount >= maxNetworkSyncAttempts;

  T _oldElement;
  T get oldElement => _oldElement;
  T _element;
  T get element => _element;
  set element(T value) {
    _oldElement = _element;
    _element = value;

    _updatedAt = DateTime.now();
  }

  StorageCell({
    @required T element,
    T oldElement,
    DateTime createdAt,
    DateTime updatedAt,
    this.lastSync,
    bool deleted,
    int networkSyncAttemptsCount,
  })  : _element = element,
        createdAt = createdAt ?? DateTime.now(),
        _updatedAt = updatedAt,
        _oldElement = oldElement,
        _deleted = deleted ?? false,
        _networkSyncAttemptsCount = networkSyncAttemptsCount ?? 0;

  /// Sets [lastSync] date to the same value as [createdAt] to
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

  bool get wasSynced => lastSync != null;
  bool get needsNetworkSync => !(wasSynced &&
      ((updatedAt != null && !updatedAt.isAfter(lastSync)) ||
          (updatedAt == null && !createdAt.isAfter(lastSync))));

  String toJson(Serializer<T> serializer) {
    final jsonMap = <String, dynamic>{
      'deleted': deleted,
      'createdAt': createdAt?.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
      'lastSync': lastSync?.toIso8601String(),
      'networkSyncAttemptsCount': networkSyncAttemptsCount,
      'element': element == null ? null : serializer.toJson(element),
      if (oldElement != null) 'oldElement': serializer.toJson(oldElement),
    };

    return json.encode(jsonMap);
  }

  /// Marking this cell as ready for update.
  void markAsUpdateNeeded() {
    _updatedAt = DateTime.now();
  }

  /// Mark element as synced with network.
  void markAsSynced() {
    lastSync = DateTime.now();
  }

  SyncAction get actionNeeded {
    if (!needsNetworkSync) return null;

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

  factory StorageCell.fromJson(String data, Serializer<T> serializer) {
    final dynamic decodedJson = json.decode(data);

    return StorageCell(
      deleted: decodedJson['deleted'],
      networkSyncAttemptsCount: decodedJson['networkSyncAttemptsCount'],
      element: decodedJson['element'] == null
          ? null
          : serializer.fromJson(decodedJson['element']),
      oldElement: decodedJson['oldElement'] == null
          ? null
          : serializer.fromJson(decodedJson['oldElement']),
      createdAt: decodedJson['createdAt'] == null
          ? null
          : DateTime.tryParse(decodedJson['createdAt']),
      updatedAt: decodedJson['updatedAt'] == null
          ? null
          : DateTime.tryParse(decodedJson['updatedAt']),
      lastSync: decodedJson['lastSync'] == null
          ? null
          : DateTime.tryParse(decodedJson['lastSync']),
    );
  }
}
