class ExceptionDetail {
  final Exception exception;
  final StackTrace stackTrace;

  const ExceptionDetail(this.exception, this.stackTrace);

  @override
  String toString() => '$exception\n$stackTrace';
}

class SyncException implements Exception {
  final List<ExceptionDetail> errors;

  const SyncException(this.errors);

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.writeln('SyncException:');
    for (final error in errors) {
      buffer.writeln(error.toString());
    }
    return buffer.toString();
  }
}

/// Throws when the connection is interrupted and
/// e.g sync action is interrupted.
class ConnectionInterrupted implements Exception {}
