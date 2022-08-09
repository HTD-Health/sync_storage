import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rxdart/subjects.dart';
import 'package:sync_storage/src/logs/storage_entry_logs.dart';
import 'package:sync_storage/sync_storage.dart';

enum SyncStorageStatus {
  idle,
  syncing,
  disposed,
}

class SyncStorage {
  bool get disposed => status == SyncStorageStatus.disposed;

  /// Returns last sync date
  DateTime? get lastSync => entries.reduce((value, element) {
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

  final List<StorageEntry> _entries = [];
  List<StorageEntry> get entries => _entries;

  final NetworkAvailabilityService networkAvailabilityService;
  late StreamSubscription<bool> _networkAvailabilitySubscription;

  bool get networkAvailable => _networkNotifier.value;
  ValueNotifier<bool> get networkNotifier => _networkNotifier;
  final _networkNotifier = ValueNotifier<bool>(false);

  int get elementsToSyncCount =>
      entries.map<int>((e) => e.elementsToSyncCount).reduce((s, e) => s + e);

  Completer<void>? _networkSyncTask;

  Stream<SyncProgressEvent?> get progress => _progress.stream;
  final _progress = SyncProgress();

  /// Whether [SyncStorage] is syncing entries with network.
  bool get isSyncing =>
      _networkSyncTask != null && _networkSyncTask!.isCompleted == false;

  /// Check if [SyncStorage] contains not synced [StorageEntry].
  bool get needsNetworkSync => _entries.any((entry) => entry.needsNetworkSync);

  bool needsNetworkSyncWhere({required int? maxLevel}) {
    if (maxLevel == null) {
      return needsNetworkSync;
    } else {
      return _entries.any(
        (entry) => (entry.level <= maxLevel) && entry.needsNetworkSync,
      );
    }
  }

  List<StorageEntry> get entriesToSync => _entries
      // entries with fetch delayed needs to be added for
      // level functionality.
      .where((entry) => entry.needsNetworkSync || entry.isFetchDelayed)
      .toList();

  final bool debug;

  SyncStorage({
    required this.networkAvailabilityService,
    this.debug = false,
  }) {
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
    int sortEntriesByLevelAscending(StorageEntry? a, StorageEntry? b) =>
        a!.level.compareTo(b!.level);

    final sortedEntriesToSync = entriesToSync
      ..sort(sortEntriesByLevelAscending);

    int? errorLevel;
    final errors = <ExceptionDetail>[];
    try {
      for (final entry in sortedEntriesToSync) {
        if (errorLevel != null && entry.level > errorLevel) {
          throw SyncLevelException(errorLevel, errors);
        }
        try {
          _logsStreamController.sink.add(StorageEntryInfo(
            entry.name,
            'Syncing "${entry.name}" entry...',
          ));
          _progress.update(
            entryName: entry.name,
            actionIndex: _progress.currentEvent!.actionIndex + 1,
            actionsCount: sortedEntriesToSync.length,
          );

          if (entry.isFetchDelayed && !entry.canFetch) {
            errorLevel = entry.level;
            continue;
          }

          /// Skip this [StorageEntry], if it is syncing on its own,
          /// or changes have been reverted.
          if (!entry.needsNetworkSync) continue;

          /// Stop sync task when network is no longer available.
          if (!networkAvailable) {
            _errorStreamController.add(ExceptionDetail(
              ConnectionInterrupted(),
              StackTrace.current,
            ));

            return;
          }

          /// sync all cells with network.
          await entry.syncElementsWithNetwork();
        } on Exception catch (err, stackTrace) {
          _logsStreamController.sink.add(StorageEntryError(
            entry.name,
            'Caught exception while synchronizing "${entry.name}" entry.',
            err,
            stackTrace,
          ));
          _errorStreamController.add(ExceptionDetail(err, stackTrace));

          if (errorLevel != null && entry.level > errorLevel) {
            throw SyncLevelException(errorLevel, errors);
          } else {
            errors.add(ExceptionDetail(err, stackTrace));
            errorLevel = entry.level;
          }
        }
      }

      /// If during sync network sync, new data were added.
      /// Sync it too.
      if (needsNetworkSyncWhere(maxLevel: errorLevel)) {
        await _syncEntriesWithNetwork();
      }
    } on SyncException catch (err, stackTrace) {
      _logsStreamController.sink.add(SyncStorageWarning(
        'sync_storage',
        'Breaking sync on level="$errorLevel".',
      ));
      _errorStreamController.add(ExceptionDetail(err, stackTrace));
      rethrow;
    }
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
      return;
    }

    /// If already syncing return current sync task future if available.
    if (isSyncing) return _networkSyncTask?.future;
    _statusController.sink.add(SyncStorageStatus.syncing);

    _progress.start(entryName: null, actionsCount: entriesToSync.length);
    _networkSyncTask = Completer<void>();
    try {
      await _syncEntriesWithNetwork();
    } on Exception {
      //? Errors should not be thrown when sync failed.

    } finally {
      _progress.end();
      _networkSyncTask!.complete();
      _statusController.sink.add(SyncStorageStatus.idle);
    }
  }

  Future<StorageEntry<T, S>> registerEntry<T, S extends Storage<T>>({
    required String name,
    required S storage,
    required StorageNetworkCallbacks<T> networkCallbacks,
    int level = 0,
    OnCellSyncError<T>? onCellSyncError,
    OnCellMaxAttemptReached<T>? onCellMaxAttemptsReached,
    DelayDurationGetter? getDelayBeforeNextAttempt,
  }) async {
    if (disposed) {
      throw StateError('Cannot register entry. $runtimeType was disposed.');
    }

    _logsStreamController.sink
        .add(SyncStorageInfo('sync_storage', 'Registering "$name" entry...'));

    if (getEntryWithName(name) != null) {
      throw ArgumentError.value(
        name,
        'name',
        'Entry with provided name is already registered.\n'
            'Instead use "getRegisteredEntry" method.',
      );
    }
    try {
      final entry = StorageEntry<T, S>(
        debug: debug,
        name: name,
        level: level,
        storage: storage,
        networkCallbacks: networkCallbacks,
        networkUpdateCallback: syncEntriesWithNetwork,
        onCellSyncError: onCellSyncError,
        onCellMaxAttemptsReached: onCellMaxAttemptsReached,
        networkNotifier: _networkNotifier,
        getDelayBeforeNextAttempt: getDelayBeforeNextAttempt,
        logsSink: _logsStreamController.sink,
      );
      await entry.initialize();
      _entries.add(entry);
      final needsFetch = entry.needsFetch;
      _logsStreamController.sink.add(SyncStorageInfo(
        'sync_storage',
        'Registered "$name" entry.\n'
            'elements to sync: ${entry.cellsToSync.length},\n'
            'needs fetch: ${needsFetch}.',
      ));
      // await syncEntriesWithNetwork();
      return entry;
    } on Exception catch (err, st) {
      _logsStreamController.sink.add(SyncStorageError(
        'sync_storage',
        'Caught exception while initializing "${name}" entry.',
        err,
        st,
      ));
      _errorStreamController.add(ExceptionDetail(err, st));

      rethrow;
    }
  }

  Future<void> disposeEntryWithName(String name) async {
    final entry = getEntryWithName(name);
    if (entry == null) {
      throw StateError('Entry with provided name=\"$name\" is not registered.');
    }

    _entries.remove(entry);
    await entry.dispose();
  }

  StorageEntry? getEntryWithName(String name) => _entries
      .cast<StorageEntry?>()
      .firstWhere((entry) => entry!.name == name, orElse: () => null);

  StorageEntry<T, S>? getRegisteredEntry<T, S extends Storage<T>>(
    String name,
  ) =>
      _entries.cast<StorageEntry?>().firstWhere(
            (entry) => entry is StorageEntry<T, S> && entry.name == name,
            orElse: () => null,
          ) as StorageEntry<T, S>;

  Future<void> removeEntryWithName(String name) async {
    final entry = getEntryWithName(name);
    if (entry == null) {
      throw StateError('Entry with provided name=\"$name\" is not registered.');
    }
    _entries.remove(entry);
    await entry.dispose();
  }

  @protected
  @visibleForTesting
  Future<void> disposeAllEntries() async {
    final entries = [..._entries];
    _entries.clear();
    for (final entry in entries) {
      await entry.dispose();
    }
  }

  /// Dispose and remove all entries from the sync storage.
  Future<void> clear() async {
    await disposeAllEntries();
    _entries.clear();
  }

  Future<void> dispose() async {
    if (disposed) {
      throw StateError('Sync storage was already disposed');
    }
    _statusController.sink.add(SyncStorageStatus.disposed);

    await clear();
    _progress.dispose();
    _networkNotifier.dispose();
    _networkAvailabilitySubscription.cancel();
    _logsStreamController.close();
    _statusController.close();
  }
}
