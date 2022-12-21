import 'package:collection/collection.dart';
import 'package:sync_storage/sync_storage.dart';

typedef AsyncAction<T> = Future<void> Function(T element);

class ParallelException implements Exception {
  final List<ExceptionDetail> errors;

  ParallelException(this.errors);
}

/// Calls provided [callback] for each element in [elements] iterable
/// in parallel.
///
/// The [maxConcurrentActions] argument determines
/// how many callbacks will be called simultaneously.
///
/// Throws [ParallelException] if any [callback] call failed.
Future<void> parallel<T>(
  AsyncAction<T> callback,
  Iterable<T> elements, {
  int maxConcurrentActions = 5,
}) async {
  final queue = QueueList<T>.from(elements);
  final errors = <ExceptionDetail>[];
  Future<void> run() async {
    while (queue.isNotEmpty) {
      final element = queue.removeFirst();
      try {
        await callback(element);
      } on Exception catch (e, st) {
        errors.add(ExceptionDetail(e, st));
      }
    }
  }

  final tasks = List.generate(maxConcurrentActions, (_) => run());
  await Future.wait(tasks);

  if (errors.isNotEmpty) {
    throw ParallelException(errors);
  }
}
