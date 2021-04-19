import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:meta/meta.dart';
import 'package:sync_storage/src/services/network_availability_service.dart';
import 'package:sync_storage/src/storage/storage.dart';
import 'package:sync_storage/src/callbacks/storage_network_callbacks.dart';
import 'package:sync_storage/sync_storage.dart';
import 'errors/errors.dart';
import 'logs/logs.dart';
import 'storage_entry.dart';

@deprecated
void debugModePrint(String log, {bool enabled = true}) {
  assert((() {
    if (enabled) print(log);
    return true;
  })(), 'Debug mode print');
}

class SyncStorage {
  /// Returns last sync date
  DateTime get lastSync => entries.reduce((value, element) {
        if (element.lastSync == null) {
          return value;
        } else if (value.lastSync == null) {
          return element;
        } else {
          if (element.lastSync.isAfter(value.lastSync)) {
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

  final List<StorageEntry> _entries = [];
  List<StorageEntry> get entries => _entries;

  final NetworkAvailabilityService networkAvailabilityService;
  StreamSubscription<bool> _networkAvailabilitySubscription;

  bool get networkAvailable => _networkNotifier.value;
  final _networkNotifier = ValueNotifier<bool>(false);

  int get elementsToSyncCount =>
      entries.map<int>((e) => e.elementsToSyncCount).reduce((s, e) => s + e);

  Completer<void> _networkSyncTask;

  /// Whether [SyncStorage] is syncing entries with network.
  bool get isSyncing =>
      _networkSyncTask != null && _networkSyncTask.isCompleted == false;

  /// Check if [SyncStorage] contains not synced [StorageEntry].
  bool get needsNetworkSync => _entries.any((entry) => entry.needsNetworkSync);

  bool needsNetworkSyncWhere({@required int maxLevel}) {
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
    @required this.networkAvailabilityService,
    this.debug = false,
  }) : assert(
          networkAvailabilityService != null,
          'networkService cannot be null.',
        ) {
    _networkNotifier.value = networkAvailabilityService.isConnected ?? true;
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
        _logsStreamController.sink.add(SyncStorageInfo(
          'Network connection is now available.',
        ));

        /// This sync request is triggered internally, so it is
        /// not possible to catch error by the user.
        syncEntriesWithNetwork().catchError((dynamic _) {});
      }
    }
  }

  Future<void> initialize() => Hive.initFlutter();

  Future<void> _syncEntriesWithNetwork() async {
    int sortEntriesByLevelAscending(StorageEntry a, StorageEntry b) =>
        a.level.compareTo(b.level);

    final sortedEntriesToSync = entriesToSync
      ..sort(sortEntriesByLevelAscending);

    int errorLevel;
    final errors = <ExceptionDetail>[];
    try {
      for (final entry in sortedEntriesToSync) {
        if (errorLevel != null && entry.level > errorLevel) {
          throw SyncLevelException(errorLevel, errors);
        }
        try {
          _logsStreamController.sink
              .add(SyncStorageInfo('Syncing entry with name="${entry.name}".'));

          if (entry.isFetchDelayed && !entry.canFetch) {
            errorLevel = entry.level;
            continue;
          }

          /// Skip this [StorageEntry], if it is syncing on its own,
          /// or changes have been reverted.
          if (!entry.needsNetworkSync) continue;

          /// Stop sync task when network is no longer available.
          if (!networkAvailable) return;

          /// sync all cells with network.
          await entry.syncElementsWithNetwork();
        } on Exception catch (err, stackTrace) {
          _logsStreamController.sink.add(SyncStorageError(
            'Exception caught when syncing entry with name="${entry.name}".',
            error: err,
            stackTrace: stackTrace,
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
        'Breaking sync on level="$errorLevel".',
      ));
      _errorStreamController.add(ExceptionDetail(err, stackTrace));
      rethrow;
    }
  }

  /// Sync all entries with network when available.
  Future<void> syncEntriesWithNetwork() async {
    _logsStreamController.sink.add(SyncStorageInfo(
      'Requesting entries sync. Registered entries '
      'to sync: ${entriesToSync.length}.',
    ));

    /// If there is no network connection, do not perform
    /// the network synchronization steps
    if (!networkAvailable) {
      _logsStreamController.sink.add(SyncStorageWarning(
        'Network connection is currently not available. '
        'Waiting for connection...',
      ));
      return;
    }

    /// If already syncing return current sync task future if available.
    if (isSyncing) return _networkSyncTask?.future;

    _networkSyncTask = Completer<void>();
    try {
      await _syncEntriesWithNetwork();
    } finally {
      _networkSyncTask.complete();
    }
  }

  Future<StorageEntry<T, S>> registerEntry<T, S extends Storage<T>>({
    @required String name,
    @required S storage,
    @required StorageNetworkCallbacks<T> networkCallbacks,
    int level = 0,
    OnCellSyncError<T> onCellSyncError,
    ValueChanged<StorageCell<T>> onCellMaxAttemptsReached,
    DelayDurationGetter getDelayBeforeNextAttempt,
  }) async {
    _logsStreamController.sink
        .add(SyncStorageInfo('Registering entry with name="$name"'));

    if (getEntryWithName(name) != null) {
      throw ArgumentError.value(
        name,
        'name',
        'Entry with provided name is already registred.\n'
            'Instead use "getRegisteredEntry" method.',
      );
    }

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
      'Registered entry with name: "$name".\n'
      'elements to sync: ${entry.cellsToSync.length},\n'
      'needs fetch: ${needsFetch}.',
    ));
    // await syncEntriesWithNetwork();

    return entry;
  }

  Future<void> disposeEntryWithName(String name) async {
    final entry = getEntryWithName(name);
    if (entry == null) return;

    _entries.remove(entry);
    await entry.dispose();
  }

  StorageEntry getEntryWithName(String name) =>
      _entries.firstWhere((entry) => entry.name == name, orElse: () => null);

  StorageEntry<T, S> getRegisteredEntry<T, S extends Storage<T>>(String name) =>
      _entries.firstWhere(
        (entry) => entry is StorageEntry<T, S> && entry.name == name,
        orElse: () => null,
      );

  Future<void> disposeAllEntries() async {
    final entries = [..._entries];
    _entries.clear();
    for (final entry in entries) {
      await entry.dispose();
    }
  }

  Future<void> dispose() async {
    _networkNotifier.dispose();
    _networkAvailabilitySubscription.cancel();
    await disposeAllEntries();
    _logsStreamController.close();
  }
}
