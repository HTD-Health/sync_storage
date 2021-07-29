typedef OnDeleteCallback<T> = Future<void>? Function(T element);
typedef OnCreateCallback<T> = Future<T?> Function(T element);
typedef OnUpdateCallback<T> = Future<T?> Function(T oldElement, T newElement);
typedef OnFetchCallback<T> = Future<List<T>?> Function();

/// Callbacks are called when storage want to update model.
abstract class StorageNetworkCallbacks<T> {
  const StorageNetworkCallbacks();

  const factory StorageNetworkCallbacks.inline({
    required OnDeleteCallback<T> onDelete,
    required OnCreateCallback<T> onCreate,
    required OnUpdateCallback<T> onUpdate,
    required OnFetchCallback<T> onFetch,
  }) = _InlineStorageNetworkCallbacks;

  StorageNetworkCallbacks copyWith({
    OnDeleteCallback<T>? onDelete,
    OnCreateCallback<T>? onCreate,
    OnUpdateCallback<T>? onUpdate,
    OnFetchCallback<T>? onFetch,
  }) =>
      _InlineStorageNetworkCallbacks<T>(
        onDelete: onDelete ?? this.onDelete,
        onCreate: onCreate ?? this.onCreate,
        onUpdate: onUpdate ?? this.onUpdate,
        onFetch: onFetch ?? this.onFetch,
      );

  /// Fetch all data for [StorageEntry].
  ///
  /// Returning null, will take no effect. To remove all data from storage,
  /// return empty list.
  Future<List<T>?> onFetch();

  /// This method is called on every element deletion.
  /// You should make an api request here.
  Future<void>? onDelete(T element);

  /// This method is called on every element creation.
  /// You should make an api request here.
  ///
  /// When this method returns the value (that is not null)
  /// it will update the element saved in the local storage.
  /// If you do not want to update the element saved
  /// in local storage, simply return null.
  Future<T?> onCreate(T element);

  /// This method is called on every element update.
  /// You should make an api request here.
  ///
  /// When this method returns the value (that is not null)
  /// it will update the element saved in the local storage.
  /// If you do not want to update the element saved
  /// in local storage, simply return null.
  Future<T?> onUpdate(T oldElement, T newElement);
}

class _InlineStorageNetworkCallbacks<T> extends StorageNetworkCallbacks<T> {
  final OnDeleteCallback<T> _onDelete;
  final OnCreateCallback<T> _onCreate;
  final OnUpdateCallback<T> _onUpdate;
  final OnFetchCallback<T> _onFetch;

  const _InlineStorageNetworkCallbacks({
    required OnDeleteCallback<T> onDelete,
    required OnCreateCallback<T> onCreate,
    required OnUpdateCallback<T> onUpdate,
    required OnFetchCallback<T> onFetch,
  })  : _onCreate = onCreate,
        _onDelete = onDelete,
        _onUpdate = onUpdate,
        _onFetch = onFetch;

  @override
  Future<T?> onCreate(T element) async => _onCreate.call(element);

  @override
  Future<void> onDelete(T element) async => _onDelete.call(element);

  @override
  Future<T?> onUpdate(T oldElement, T newELement) async =>
      _onUpdate.call(oldElement, newELement);

  @override
  Future<List<T>?> onFetch() => _onFetch.call();
}

class NullCallbacks<T> extends StorageNetworkCallbacks<T> {
  @override
  Future<T?> onCreate(T element) async {
    return null;
  }

  @override
  Future<void> onDelete(T element) async {}

  @override
  Future<List<T>?> onFetch() async {
    return null;
  }

  @override
  Future<T?> onUpdate(T oldElement, T newElement) async {
    return null;
  }
}
