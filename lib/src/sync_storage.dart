import 'dart:async';

import 'package:flutter/material.dart';
import 'package:meta/meta.dart';
import 'package:rxdart/subjects.dart';
import 'package:sync_storage/src/core/node.dart';
import 'package:sync_storage/sync_storage.dart';

enum SyncStorageStatus {
  idle,
  syncing,
  disposed,
}

@experimental
abstract class SyncRoot {
  StreamSink<SyncStorageLog> get logsSink;
  ValueNotifier<bool> get networkNotifier;

  bool get networkAvailable;
}

class SyncContext {
  final SyncRoot root;

  SyncContext(this.root);
}

class SyncStorage extends Node<Entry> implements SyncRoot {
  @override
  @experimental
  StreamSink<SyncStorageLog> get logsSink => _logsStreamController.sink;

  bool get disposed => status == SyncStorageStatus.disposed;

  /// Returns last sync date
  DateTime? get lastSync => traverse().reduce((value, element) {
        if (element.lastSync == null) {
          return value;
        } else if (value.lastSync == null) {
          return element;
        } else {
          if (element.lastSync!.isAfter(value.lastSync!)) {
            return element;
          } else {
            return value;
          }
        }
      }).lastSync;

  final _logsStreamController = StreamController<SyncStorageLog>.broadcast();
  Stream<SyncStorageLog> get logs => _logsStreamController.stream;
  final _errorStreamController = StreamController<ExceptionDetail>.broadcast();
  Stream<ExceptionDetail> get errors => _errorStreamController.stream;

  final _statusController =
      BehaviorSubject<SyncStorageStatus>.seeded(SyncStorageStatus.idle);
  Stream<SyncStorageStatus> get statuses => _statusController.stream;
  SyncStorageStatus get status => _statusController.value;

  final NetworkAvailabilityService networkAvailabilityService;
  late StreamSubscription<bool> _networkAvailabilitySubscription;

  @override
  bool get networkAvailable => _networkNotifier.value;
  @override
  ValueNotifier<bool> get networkNotifier => _networkNotifier;
  final _networkNotifier = ValueNotifier<bool>(false);

  int get elementsToSyncCount =>
      children.map<int>((e) => e.elementsToSyncCount).reduce((s, e) => s + e);

  Completer<void>? _networkSyncTask;

  // Stream<SyncProgressEvent?> get progress => _progress.stream;
  // final _progress = SyncProgress();

  /// Whether [SyncStorage] is syncing entries with network.
  bool get isSyncing =>
      _networkSyncTask != null && _networkSyncTask!.isCompleted == false;

  /// Check if [SyncStorage] contains not synced [StorageEntry].
  bool get needsNetworkSync =>
      traverse().any((entry) => entry.needsNetworkSync);

  // bool needsNetworkSyncWhere({required int? maxLevel}) {
  //   if (maxLevel == null) {
  //     return needsNetworkSync;
  //   } else {
  //     return _entries.any(
  //       (entry) => (entry.level <= maxLevel) && entry.needsNetworkSync,
  //     );
  //   }
  // }

  List<Entry> get entriesToSync => traverse()
      // entries with fetch delayed needs to be added for
      // level functionality.
      .where((entry) => entry.needsNetworkSync || entry.isFetchDelayed)
      .toList();

  final bool debug;

  Future<void> initialize() async {
    await forEachDependantsLayered(
      (value) => value.initialize(SyncContext(this)),

      /// Dependants are responsible for its' dependants initialization
      /// as the context can be scoped in the future
      singleLayer: true,
    );
  }

  SyncStorage({
    required this.networkAvailabilityService,
    List<Entry> children = const [],
    this.debug = false,
  }) : super(children: children) {
    _networkNotifier.value = networkAvailabilityService.isConnected;
    _networkAvailabilitySubscription = networkAvailabilityService
        .onConnectivityChanged
        .listen(_onNetworkChange);

    if (debug) {
      _logsStreamController.stream.listen((event) {
        print('[${event.source}] ${event.message}');
      });
    }
  }

  void _onNetworkChange(bool networkAvailable) {
    if (networkAvailable != _networkNotifier.value) {
      _networkNotifier.value = networkAvailable;
      if (networkAvailable) {
        _logsStreamController.sink.add(const SyncStorageInfo(
          'sync_storage',
          'Network connection is now available.',
        ));

        syncEntriesWithNetwork();
      }
    }
  }

  Future<void> _syncEntriesWithNetwork() async {
    await forEachDependantsLayered(
      (entry) => entry.syncElementsWithNetwork(),
    );
  }

  /// Sync all entries with network when available.
  Future<void>? syncEntriesWithNetwork() async {
    _logsStreamController.sink.add(SyncStorageInfo(
      'sync_storage',
      'Requesting entries sync. Registered entries '
          'to sync: ${entriesToSync.length}.',
    ));

    /// If there is no network connection, do not perform
    /// the network synchronization steps
    if (!networkAvailable) {
      _logsStreamController.sink.add(const SyncStorageWarning(
        'sync_storage',
        'Network connection is currently not available. '
            'Waiting for connection...',
      ));
      _errorStreamController.add(ExceptionDetail(
        ConnectionInterrupted(),
        StackTrace.current,
      ));
      return;
    }

    /// If already syncing return current sync task future if available.
    if (isSyncing) return _networkSyncTask?.future;
    _statusController.sink.add(SyncStorageStatus.syncing);

    // _progress.start(entryName: null, actionsCount: entriesToSync.length);
    _networkSyncTask = Completer<void>();
    try {
      await _syncEntriesWithNetwork();
    } on Exception {
      //? Errors should not be thrown when sync failed.

    } finally {
      // _progress.end();
      _networkSyncTask!.complete();
      _statusController.sink.add(SyncStorageStatus.idle);
    }
  }

  StorageEntry<T, S>? getEntryWithName<T, S extends Storage<T>>(
    String name,
  ) =>
      traverse().cast<StorageEntry?>().firstWhere(
            (entry) => entry is StorageEntry<T, S> && entry.name == name,
            orElse: () => null,
          ) as StorageEntry<T, S>;

  Future<StorageEntry<T, S>?> removeEntryWithName<T, S extends Storage<T>>(
      String name) async {
    final entry = getEntryWithName<T, S>(name);
    if (entry == null) {
      throw StateError('Entry with provided name=\"$name\" is not registered.');
    }

    final removed = removeChild(entry, nested: true);

    if (removed) {
      return entry;
    } else {
      throw StateError('Unable to remove the entry.');
    }
  }

  Future<void> disposeAllEntries() async {
    for (final entry in traverse()) {
      await entry.dispose();
    }
    removeChildren(nested: true);
  }

  Future<void> dispose() async {
    if (disposed) {
      throw StateError('Sync storage was already disposed');
    }
    _statusController.sink.add(SyncStorageStatus.disposed);

    await disposeAllEntries();

    // _progress.dispose();
    _networkNotifier.dispose();
    _networkAvailabilitySubscription.cancel();
    _logsStreamController.close();
    _statusController.close();
  }
}
