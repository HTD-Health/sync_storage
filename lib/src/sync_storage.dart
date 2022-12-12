import 'dart:async';

import 'package:meta/meta.dart';
import 'package:rxdart/subjects.dart';
import 'package:scoped_logger/scoped_logger.dart';
import 'package:sync_storage/src/core/progress.dart';
import 'package:sync_storage/sync_storage.dart';

import 'core/core.dart';

enum SyncStorageStatus {
  idle,
  syncing,
  disposed,
}

@experimental
abstract class SyncRoot {
  ValueNotifier<bool> get networkNotifier;
}

class SyncContext {
  @experimental
  final SyncRoot root;
  final ValueNotifier<bool> networkNotifier;
  bool get isNetworkAvailable => networkNotifier.value;

  final ProgressController progress;

  final ScopedLogger logger;

  SyncContext({
    required this.logger,
    required this.progress,
    required this.root,
    required this.networkNotifier,
  });
}

class SyncStorage extends SyncNode implements SyncRoot {
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

  final ScopedLogger _logger;

  Stream<Log> get logs => _logger.logs;

  final _statusController =
      BehaviorSubject<SyncStorageStatus>.seeded(SyncStorageStatus.idle);
  Stream<SyncStorageStatus> get statuses => _statusController.stream;
  SyncStorageStatus get status => _statusController.value;

  final NetworkAvailabilityService networkAvailabilityService;
  late StreamSubscription<bool> _networkAvailabilitySubscription;

  @override
  ValueNotifier<bool> get networkNotifier => _networkNotifier.notifier;
  final _networkNotifier = ValueController<bool>(false);

  int get elementsToSyncCount =>
      traverse().fold<int>(0, (s, e) => s + e.elementsToSyncCount);

  Completer<void>? _networkSyncTask;

  /// Whether [SyncStorage] is syncing entries with network.
  bool get isSyncing =>
      _networkSyncTask != null && _networkSyncTask!.isCompleted == false;

  /// Check if [SyncStorage] contains not synced [StorageEntry].
  bool get needsNetworkSync =>
      traverse().any((entry) => entry.needsNetworkSync);

  List<Entry> get entriesToSync => traverse()
      // entries with fetch delayed needs to be added for
      // level functionality.
      .where((entry) => entry.needsNetworkSync || entry.isFetchDelayed)
      .toList();

  final _progress = ProgressController(SyncProgress({}));
  ValueNotifier<SyncProgress> get progress => _progress;

  /// After calling this method is not possible to add more children.
  Future<void> initialize() async {
    _lockAllChildren();

    await forEachChildrenLayered(
      (parent, child) => child.initialize(SyncContext(
        root: this,
        progress: _progress,
        logger: _logger.beginScope('Entry(${child.name})'),
        networkNotifier: networkNotifier,
      )),

      /// Childen are responsible for its' children initialization
      /// as the context can be scoped in the future
      singleLayer: true,
    );
  }

  SyncStorage({
    required this.networkAvailabilityService,
    List<Entry>? children,
    bool debug = false,
  })  : _logger = ScopedLogger(printer: debug ? PlainTextPrinter() : null),
        super(children: children ?? []) {
    _networkNotifier.value = networkAvailabilityService.isConnected;
    _networkAvailabilitySubscription = networkAvailabilityService
        .onConnectivityChanged
        .listen(_onNetworkChange);
  }

  void _onNetworkChange(bool networkAvailable) {
    if (networkAvailable != networkNotifier.value) {
      _networkNotifier.value = networkAvailable;
      if (networkAvailable) {
        _logger.i('Network connection is now available');

        syncEntriesWithNetwork().ignore();
      }
    }
  }

  void _lockAllChildren() {
    traverse().forEach((child) => child.lock());
  }

  void _unlockAllChildren() {
    traverse().forEach((child) => child.unlock());
  }

  /// Sync all entries with network when available.
  ///
  /// This method may throw an exception if synchronization has been interrupted
  Future<void> syncEntriesWithNetwork() async {
    _logger.i(
      'Requesting entries sync. Registered entries '
      'to sync: ${entriesToSync.length}.',
    );

    /// If there is no network connection, do not perform
    /// the network synchronization steps
    if (!_networkNotifier.value) {
      _logger.w(
        'Network connection is currently not available. '
        'Waiting for connection...',
      );
      throw ConnectionInterrupted();
    }

    /// If already syncing return current sync task future if available.
    if (isSyncing) return _networkSyncTask?.future;
    _statusController.sink.add(SyncStorageStatus.syncing);

    _networkSyncTask = Completer<void>();
    try {
      traverse().forEach((e) {
        final progress = EntrySyncProgress(
          initialFetchRequired: e.canFetch,
          fetchCompleted: e.canFetch,
          initialElementsToSyncCount: e.elementsToSyncCount,
          syncedElementsCount: 0,
        );
        _progress.register(e, progress);
      });

      await syncChildrenWithNetwork();
    } finally {
      // _progress.end();
      _networkSyncTask!.complete();
      _statusController.sink.add(SyncStorageStatus.idle);
      _progress.end();
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

    final removed = removeChild(entry, recursive: true);

    if (removed) {
      return entry;
    } else {
      throw StateError('Unable to remove the entry.');
    }
  }

  @protected
  Future<void> disposeAllEntries() async {
    for (final entry in traverse()) {
      await entry.dispose();
    }

    // Unlock all children to allow their removal
    _unlockAllChildren();
    removeChildren(recursive: true);
  }

  Future<void> dispose() async {
    if (disposed) {
      throw StateError('Sync storage was already disposed');
    }
    _statusController.sink.add(SyncStorageStatus.disposed);

    await disposeAllEntries();

    _networkNotifier.clear();
    _networkAvailabilitySubscription.cancel();
    _logger.dispose();
    _statusController.close();
  }
}
