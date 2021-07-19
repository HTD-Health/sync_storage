class ExceptionDetail {
  final Exception exception;
  final StackTrace stackTrace;

  ExceptionDetail(this.exception, this.stackTrace);

  @override
  String toString() => '$exception\n$stackTrace';
}

class SyncException implements Exception {
  final List<ExceptionDetail> errors;

  SyncException(this.errors);

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.write('$runtimeType:\n');
    for (final error in errors) {
      buffer.write(error.toString());
      buffer.write('\n');
    }
    return buffer.toString();
  }
}

class SyncLevelException extends SyncException {
  final int level;

  SyncLevelException(
    this.level,
    List<ExceptionDetail> errors,
  ) : super(errors);
}
