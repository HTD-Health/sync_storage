/// Abtract class that groups all sync_storage logs
abstract class SyncStorageLog {
  final String source;
  final String message;

  const SyncStorageLog(this.source, this.message);
}

/// All info level logs extends or implements [SyncStorageInfo] class
class SyncStorageInfo extends SyncStorageLog {
  const SyncStorageInfo(String source, String message) : super(source, message);
}

/// All warning level logs extends or implements [SyncStorageWarning] class
class SyncStorageWarning extends SyncStorageLog {
  const SyncStorageWarning(
    String source,
    String message,
  ) : super(source, message);
}

/// All error level logs extends or implements [SyncStorageError] class
class SyncStorageError extends SyncStorageLog {
  final Exception error;
  final StackTrace stackTrace;

  const SyncStorageError(
    String source,
    String message,
    this.error,
    this.stackTrace,
  ) : super(source, message);
}
