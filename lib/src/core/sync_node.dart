import 'package:meta/meta.dart';

import '../storage_entry.dart';
import 'node.dart';

class SyncNode extends Node<Entry> {
  SyncNode({required super.children});

  /// Sync only current layer (only children) - children
  /// are responsible for fetching their children
  @protected
  Future<void> syncChildrenWithNetwork() {
    return Future.wait(children.map((e) => e.syncWithNetwork()));
  }
}
