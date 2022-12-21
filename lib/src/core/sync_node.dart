import 'package:meta/meta.dart';
import 'package:sync_storage/sync_storage.dart';

/// This is a sync_storage wide [Node] implementation that introduces helper
/// methods that can be used with [SyncStorage] and any [Entry].
class SyncNode extends Node<Entry> {
  SyncNode({required super.children});

  /// Sync only current layer (only children) - children
  /// are responsible for fetching their children
  @protected
  Future<void> syncChildrenWithNetwork() {
    return forEachChildrenLayered(
      (_, child) => child.syncWithNetwork(),
      recursive: false,
    );
  }
}
