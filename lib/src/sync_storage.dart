import 'dart:async';

import 'package:rxdart/subjects.dart';
import 'package:sync_storage/sync_storage.dart';

import 'services/network_availability_service.dart';

enum SyncStorageStatus {
  /// Sync storage was created and not initialized.
  ///
  /// New entries can be added and removed as the dependency tree is not locked.
  idle,

  /// SyncStorage is initializing itself and its' entries.
  ///
  /// During this process, the dependency tree is locked, therefore,
  /// it is not possible to remove or add new entries.
  ///
  /// If the [SyncStorage.initialize] method throws an exception,
  /// the dependency tree is unlocked and the status is set to [idle].
  initializing,

  /// SyncStorage has been successfully initialized and is fully operational.
  initialized,

  /// The sync is in progress.
  syncing,

  /// SyncStorage has been disposed and can no longer be used.
  disposed,
}

/// Basic data passed during ASyncStorage initialization from the root
/// ([SyncStorage]) down the tree to all entries.
class SyncContext {
  final NetworkConnectionStatus network;
  final ProgressController progress;
  final ScopedLogger logger;

  SyncContext({
    required this.logger,
    required this.progress,
    required this.network,
  });
}

class SyncStorage extends SyncNode {
  bool get isInitialized =>
      status != SyncStorageStatus.idle && status != SyncStorageStatus.disposed;
  bool get isDisposed => status == SyncStorageStatus.disposed;

  /// Returns last sync date
  DateTime? get lastSync => traverse().fold(null, (lastSync, element) {
        if (lastSync == null) {
          return element.lastSync;
        } else if (element.lastSync == null) {
          return lastSync;
        } else if (element.lastSync!.isAfter(lastSync)) {
          return element.lastSync;
        } else {
          return lastSync;
        }
      });

  final ScopedLogger _logger;

  final _statusController =
      BehaviorSubject<SyncStorageStatus>.seeded(SyncStorageStatus.idle);
  Stream<SyncStorageStatus> get statuses => _statusController.stream;
  SyncStorageStatus get status => _statusController.value;

  NetworkConnectionStatus get network => _networkAvailabilityService;
  final NetworkAvailabilityService _networkAvailabilityService;
  StreamSubscription<bool>? _networkAvailabilitySubscription;

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
  ListenableValue<SyncProgress> get progress => _progress;

  SyncStorage({
    required NetworkAvailabilityService networkAvailabilityService,
    List<Entry>? children,
    List<LogsHandler>? logsHandlers,
    bool debug = false,
  })  : _logger = ScopedLogger.fromScope(
            scope: LoggerScope(context: ['SyncStorage']),
            handlers: [
              if (debug) PlainTextPrinter(),
              if (logsHandlers != null) ...logsHandlers,
            ]),
        _networkAvailabilityService = networkAvailabilityService,
        super(children: children ?? []);

  /// After calling this method is not possible to add more children.
  Future<void> initialize() async {
    if (status != SyncStorageStatus.idle) {
      throw StateError(
        'Cannot initialize. '
        'The SyncStorage object was already initialized.',
      );
    }
    _lockAllChildren();

    try {
      _statusController.add(SyncStorageStatus.initializing);
      await forEachChildrenLayered(
        (parent, child) => child.initialize(SyncContext(
          progress: _progress,
          logger: _logger.beginScope('Entry(${child.name})'),
          network: _networkAvailabilityService,
        )),

        /// Childen are responsible for its' children initialization
        /// as the context can be scoped in the future
        recursive: false,
      );
      _networkAvailabilitySubscription = _networkAvailabilityService
          .onConnectivityChanged
          .listen(_onNetworkChange);
      _statusController.add(SyncStorageStatus.initialized);
    } on Exception {
      _unlockAllChildren();
      _statusController.add(SyncStorageStatus.idle);
    }
  }

  void _onNetworkChange(bool networkAvailable) {
    if (networkAvailable) {
      _logger.i('Network connection is now available.');

      syncEntriesWithNetwork().ignore();
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
    if (!_networkAvailabilityService.isConnected) {
      _logger.w(
        'Network connection is currently not available. '
        'Waiting for connection...',
      );
      throw ConnectionInterrupted();
    }

    /// If already syncing return current sync task future if available.
    if (isSyncing) return _networkSyncTask?.future;
    _statusController.value = SyncStorageStatus.syncing;

    _networkSyncTask = Completer<void>();
    try {
      traverse().forEach((e) {
        final fetchRequired = e.canFetch;
        final progress = EntrySyncProgress(
          initialFetchRequired: fetchRequired,
          fetchCompleted: !fetchRequired,
          initialElementsToSyncCount: e.elementsToSyncCount,
          syncedElementsCount: 0,
        );
        _progress.register(e, progress);
      });

      await syncChildrenWithNetwork();
    } finally {
      _networkSyncTask!.complete();
      _statusController.value = SyncStorageStatus.idle;
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

  /// Clears all entries belonging to this [SyncStorage] instance.
  Future<void> clear() async {
    await Future.wait(traverse().map(
      (entry) => entry.clear(),
    ));
  }

  /// Disposes all entries and sets [SyncStorage] to
  /// [SyncStorageStatus.idle] state.
  Future<void> reset() async {
    await Future.wait(traverse().map(
      (entry) => entry.reset(),
    ));
    await _disposeAllEntries();
    _statusController.value = SyncStorageStatus.idle;
  }

  /// Dispose all entries and remove them from the tree
  Future<void> _disposeAllEntries() async {
    await Future.wait(traverse().map(
      (entry) => entry.dispose(),
    ));

    // Unlock all children to allow their removal
    _unlockAllChildren();
    removeChildren(recursive: true);
  }

  Future<void> dispose() async {
    if (isDisposed) {
      throw StateError('Sync storage was already disposed');
    }
    _statusController.value = SyncStorageStatus.disposed;

    await _disposeAllEntries();
    _networkAvailabilitySubscription?.cancel();
    _progress.dispose();
    _statusController.close();
  }
}
