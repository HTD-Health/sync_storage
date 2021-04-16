import 'package:meta/meta.dart';
import 'package:sync_storage/sync_storage.dart';

/// Log levels:
/// 0 - info
/// 1 - warning
/// 2 - error
abstract class SyncStorageLog {
  final String source;
  final String message;
  final int level;

  SyncStorageLog(this.source, this.message, this.level);
}

class SyncStorageInfo extends SyncStorageLog {
  SyncStorageInfo(
    String message,
  ) : super('SyncStorage', message, 0);
}

class SyncStorageWarning extends SyncStorageLog {
  SyncStorageWarning(String message) : super('SyncStorage', message, 1);
}

class SyncStorageError extends SyncStorageLog {
  final Exception error;
  final StackTrace stackTrace;

  SyncStorageError(
    String message, {
    @required this.error,
    @required this.stackTrace,
  }) : super('SyncStorage', message, 2);
}

class StorageEntryLog extends SyncStorageLog {
  StorageEntryLog(String storageEntryName, String message, [int level = 0])
      : super(storageEntryName, message, level);
}

class StorageEntryInfo extends StorageEntryLog {
  StorageEntryInfo(String storageEntryName, String message)
      : super(storageEntryName, message, 0);
}

class StorageEntryError extends StorageEntryLog {
  final Exception error;
  final StackTrace stackTrace;

  StorageEntryError(
    String storageEntryName,
    String message, {
    @required this.error,
    @required this.stackTrace,
  }) : super(storageEntryName, message, 2);
}

class StorageEntryFetchDelayed extends StorageEntryLog {
  final Duration duration;
  final DateTime delayedTo;

  StorageEntryFetchDelayed(
    String storageEntryName,
    String message, {
    @required this.duration,
    @required this.delayedTo,
  }) : super(storageEntryName, message, 1);
}

/// Cell logs

class CellInfo extends StorageEntryLog {
  final String cellId;
  CellInfo(String storageEntryName, this.cellId, String message,
      [int level = 0])
      : super(storageEntryName, message, level);
}

class CellSyncDelayed extends CellInfo {
  final Duration duration;
  final DateTime delayedTo;

  CellSyncDelayed(
    String storageEntryName,
    String cellId,
    String message, {
    @required this.duration,
    @required this.delayedTo,
  }) : super(storageEntryName, cellId, message, 1);
}

class CellSyncAction extends CellInfo {
  final SyncAction action;

  CellSyncAction(
    String storageEntryName,
    String cellId,
    String message, {
    @required this.action,
  }) : super(storageEntryName, cellId, message, 0);
}

class CellSyncActionWarning extends CellInfo {
  final SyncAction action;

  CellSyncActionWarning(
    String storageEntryName,
    String cellId,
    String message, {
    @required this.action,
  }) : super(storageEntryName, cellId, message, 1);
}

class CellSyncActionError extends CellInfo {
  final SyncAction action;
  final Exception error;
  final StackTrace stackTrace;

  CellSyncActionError(
    String storageEntryName,
    String cellId,
    String message, {
    @required this.action,
    @required this.error,
    @required this.stackTrace,
  }) : super(storageEntryName, cellId, message, 2);
}
