/// Abstract class that groups all sync_storage logs
abstract class SyncStorageLog {
  final String source;
  final String message;

  const SyncStorageLog(this.source, this.message);
}

/// All info level logs extend or implement [SyncStorageInfo] class
class SyncStorageInfo extends SyncStorageLog {
  const SyncStorageInfo(String source, String message) : super(source, message);
}

/// All warning level logs extend or implement [SyncStorageWarning] class
class SyncStorageWarning extends SyncStorageLog {
  const SyncStorageWarning(
    String source,
    String message,
  ) : super(source, message);
}

/// All error level logs extend or implement [SyncStorageError] class
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
