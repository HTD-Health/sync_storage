import 'logs.dart';

abstract class StorageEntryLog {
  String get storageEntryName;
}

class StorageEntryInfo extends SyncStorageInfo implements StorageEntryLog {
  @override
  final String storageEntryName;

  StorageEntryInfo(this.storageEntryName, String message)
      : super('sync_storage/entries/$storageEntryName', message);
}

class StorageEntryError extends SyncStorageError implements StorageEntryLog {
  @override
  final String storageEntryName;

  StorageEntryError(
    this.storageEntryName,
    String message,
    Exception error,
    StackTrace stackTrace,
  ) : super(
          'sync_storage/entries/$storageEntryName',
          message,
          error,
          stackTrace,
        );
}

class StorageEntryFetchDelayed extends SyncStorageWarning
    implements StorageEntryLog {
  @override
  final String storageEntryName;

  final Duration duration;
  final DateTime? delayedTo;

  StorageEntryFetchDelayed(
    this.storageEntryName,
    String message, {
    required this.duration,
    required this.delayedTo,
  }) : super(
          'sync_storage/entries/$storageEntryName',
          message,
        );
}
