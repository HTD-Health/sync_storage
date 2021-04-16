class ExceptionDetail {
  final Exception exception;
  final StackTrace stackTrace;

  ExceptionDetail(this.exception, this.stackTrace);
}

class SyncException implements Exception {
  final List<ExceptionDetail> errors;

  SyncException(this.errors);
}

class SyncLevelException extends SyncException {
  final int level;

  SyncLevelException(
    this.level,
    List<ExceptionDetail> errors,
  ) : super(errors);
}
