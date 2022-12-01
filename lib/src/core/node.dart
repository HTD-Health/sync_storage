import 'dart:async';

typedef NodeCallback<T> = FutureOr<void> Function(T value);

abstract class Node<T extends Node<T>> {
  List<T> get children => List.unmodifiable(_children);
  final List<T> _children;

  Node({required List<T> children}) : _children = children;

  /// Traverses [children] using the traversal pre-order (NLR) algorithm.
  Iterable<T> traverse() sync* {
    for (final dependant in children) {
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
      children.map((d) async {
        await callback(d);

        if (!singleLayer) {
          await d.forEachDependantsLayered(callback);
        }
      }),
      eagerError: false,
    );
  }

  void addChildren(List<T> entries) {
    _children.addAll(entries);
  }

  void addChild(T entry) {
    _children.add(entry);
  }

  bool removeChild(T entry, {bool nested = false}) {
    final removed = _children.remove(entry);

    if (nested && !removed) {
      for (final child in traverse()) {
        final removed = child.removeChild(entry, nested: false);
        if (removed) return true;
      }
    }

    return removed;
  }

  void removeChildren({bool nested = false}) {
    if (nested) {
      void removeNestedChildren(T child) => child.removeChildren(nested: true);
      _children.forEach(removeNestedChildren);
    }
    _children.clear();
  }
}
