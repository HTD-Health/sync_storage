import 'dart:async';

typedef NodeCallback<T> = FutureOr<void> Function(T value);

abstract class Node<T extends Node<T>> {
  List<T> get entries;

  /// Traverses [entries] using the traversal pre-order (NLR) algorithm.
  Iterable<T> traverse() sync* {
    for (final dependant in entries) {
      yield dependant;
      yield* dependant.traverse();
    }
  }

  /// For each dependency, call the provided async [callback] layer by layer.
  /// When any callback throws an exception traversing the tree will
  /// stop at the level of that layer.
  ///
  /// **This does not call [callback] for the current node.**
  ///
  /// If [singleLayer] is set to `true` only dependants of this instance
  /// will be called - no recurrent.
  FutureOr<void> forEachDependantsLayered(
    NodeCallback<T> callback, {
    bool singleLayer = false,
  }) {
    return Future.wait<void>(
      entries.map((d) async {
        await callback(d);

        if (!singleLayer) {
          await d.forEachDependantsLayered(callback);
        }
      }),
      eagerError: false,
    );
  }
}
