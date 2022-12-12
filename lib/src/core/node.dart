import 'dart:async';

import 'package:meta/meta.dart';

import '../utils/utils.dart';

typedef NodeCallback<T> = FutureOr<void> Function(Node parent, T child);

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
  FutureOr<void> forEachChildrenLayered(
    NodeCallback<T> callback, {
    bool singleLayer = false,
  }) {
    return Future.wait<void>(
      children.map((d) async {
        await callback(this, d);

        if (!singleLayer) {
          await d.forEachChildrenLayered(callback);
        }
      }),
      eagerError: false,
    );
  }

  bool get isLocked => _isLocked;
  bool _isLocked = false;

  @mustCallSuper
  @protected
  void lock() {
    if (isLocked) {
      throw StateError('Cannot lock, already locked.');
    }
    _isLocked = true;
  }

  @mustCallSuper
  @protected
  void unlock() {
    if (!isLocked) {
      throw StateError('Cannot unlock, not locked.');
    }
    _isLocked = false;
  }

  /// Throws [StateError] when the current [Node] is locked.
  @protected
  void assertNotLocked() {
    if (isLocked) {
      throw StateError(
        'This action cannot be performed when the '
        '${getOptimizedRuntimeType(this, 'Node')} is locked.',
      );
    }
  }

  /// Whether the node contains an node equal to [node].
  ///
  /// If [recursive] is true, the child is searched for in
  /// the entire subtree. Defaults to `false`.
  bool contains(T node, {bool recursive = false}) {
    if (recursive) {
      return traverse().contains(node);
    } else {
      return _children.contains(node);
    }
  }

  /// Throws [StateError] when the current [Node] already contains [node].
  @protected
  void assertNotContains(T node) {
    final containsNode = contains(node, recursive: true);
    if (containsNode) {
      throw StateError(
        'This subtree already contains the following '
        '${getOptimizedRuntimeType(node, 'node')}.',
      );
    }
  }

  /// Adds multiple child nodes to this node
  ///
  /// Throws a [StateError] if the node [isLocked].
  @mustCallSuper
  void addChildren(List<T> children) {
    assertNotLocked();
    _children.addAll(children);
  }

  /// Adds a single [child] to this node
  ///
  /// Throws a [StateError] if the node [isLocked].
  @mustCallSuper
  void addChild(T child) {
    assertNotLocked();
    assertNotContains(child);
    _children.add(child);
  }

  /// Remove child from the node.
  ///
  /// If [recursive] is true, then [child] is
  /// removed from all nodes in the subtree. Defaults to `false`.
  bool removeChild(T child, {bool recursive = false}) {
    assertNotLocked();
    final removed = _children.remove(child);

    if (recursive && !removed) {
      for (final node in traverse()) {
        final removed = node.removeChild(child, recursive: false);
        if (removed) return true;
      }
    }

    return removed;
  }

  /// Remove all children of this node.
  ///
  /// If recursive is set to true, all children of this node
  /// will also have their children removed.
  void removeChildren({bool recursive = false}) {
    assertNotLocked();
    if (recursive) {
      void removeNestedChildren(T child) =>
          child.removeChildren(recursive: true);
      _children.forEach(removeNestedChildren);
    }
    _children.clear();
  }
}
