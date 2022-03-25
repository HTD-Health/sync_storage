import 'package:sync_storage/src/logs/storage_entry_logs.dart';
import 'package:sync_storage/sync_storage.dart';

/// All cell logs implement the [CellLog] class.
abstract class CellLog extends StorageEntryLog {
  String get cellId;
}

/// All info level cell logs implement the [CellInfo] class.
class CellInfo extends SyncStorageInfo implements CellLog {
  @override
  final String storageEntryName;
  @override
  final String cellId;

  CellInfo(
    this.storageEntryName,
    this.cellId,
    String message,
  ) : super(
          'sync_storage/entries/$storageEntryName/cells/$cellId',
          message,
        );
}

/// Cell sync [action] is performed for cell with [cellId].
class CellSyncAction extends CellInfo {
  final SyncAction action;

  CellSyncAction(
    String storageEntryName,
    String cellId,
    String message, {
    required this.action,
  }) : super(storageEntryName, cellId, message);
}

/// All warning level cell logs implement the [CellWarning] class.
class CellWarning extends SyncStorageWarning implements CellLog {
  @override
  final String storageEntryName;
  @override
  final String cellId;

  const CellWarning(
    this.storageEntryName,
    this.cellId,
    String message,
  ) : super(
          'sync_storage/entries/$storageEntryName/cells/$cellId',
          message,
        );
}

/// Cell sync with provided [cellId] was delayed.
class CellSyncDelayed extends CellWarning {
  final Duration duration;
  final DateTime? delayedTo;

  CellSyncDelayed(
    String storageEntryName,
    String cellId,
    String message, {
    required this.duration,
    required this.delayedTo,
  }) : super(
          storageEntryName,
          cellId,
          message,
        );
}

/// Warns about the cell sync action.
class CellSyncActionWarning extends CellWarning {
  final SyncAction action;

  const CellSyncActionWarning(
    String storageEntryName,
    String cellId,
    String message, {
    required this.action,
  }) : super(
          storageEntryName,
          cellId,
          message,
        );
}

/// All error level cell logs implement the [CellError] class.
class CellError extends SyncStorageError implements CellLog {
  @override
  final String storageEntryName;
  @override
  final String cellId;

  const CellError(
    this.storageEntryName,
    this.cellId,
    String message,
    Exception error,
    StackTrace stackTrace,
  ) : super(
          'sync_storage/entries/$storageEntryName/cells/$cellId',
          message,
          error,
          stackTrace,
        );
}

/// Informs about the unsuccessfull cell sync action.
class CellSyncActionError extends CellError {
  final SyncAction action;

  const CellSyncActionError(
    String storageEntryName,
    String cellId,
    String message, {
    required this.action,
    required Exception error,
    required StackTrace stackTrace,
  }) : super(storageEntryName, cellId, message, error, stackTrace);
}
