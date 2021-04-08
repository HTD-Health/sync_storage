import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:meta/meta.dart';
import 'package:sync_storage/src/services/network_availability_service.dart';
import 'package:sync_storage/src/storage/storage.dart';
import 'package:sync_storage/src/callbacks/storage_network_callbacks.dart';
import 'package:sync_storage/sync_storage.dart';
import 'storage_entry.dart';

void debugModePrint(String log, {bool enabled = true}) {
  assert((() {
    if (enabled) print(log);
    return true;
  })());
}

class SyncStorage {
  final List<StorageEntry<dynamic>> _entries = [];
  List<StorageEntry<dynamic>> get entries => _entries;

  final NetworkAvailabilityService networkAvailabilityService;
  StreamSubscription<bool> _networkAvailabilitySubscription;

  bool get networkAvailable => _networkNotifier.value;
  final _networkNotifier = ValueNotifier<bool>(false);

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

  List<StorageEntry<dynamic>> get entriesToSync => _entries
      // entries with fetch delayed needs to be added for
      // level functionality.
      .where((entry) => entry.needsNetworkSync || entry.isFetchDelayed)
      .toList();

  final bool debug;

  SyncStorage({
    @required this.networkAvailabilityService,
    this.debug = false,
  }) {
    assert(
        networkAvailabilityService != null, 'networkService cannot be null.');

    _networkNotifier.value = networkAvailabilityService.isConnected ?? true;
    _networkAvailabilitySubscription = this
        .networkAvailabilityService
        .onConnectivityChanged
        .listen(_onNetworkChange);
  }

  void _onNetworkChange(bool networkAvailable) {
    if (networkAvailable != _networkNotifier.value) {
      _networkNotifier.value = networkAvailable;
      if (networkAvailable) {
        syncEntriesWithNetwork();
      }
    }
  }

  Future<void> initialize() => Hive.initFlutter();

  Future<void> _syncEntriesWithNetwork() async {
    sortEntriesByLevelAscending(StorageEntry a, StorageEntry b) =>
        a.level.compareTo(b.level);

    final sortedEntriesToSync = entriesToSync
      ..sort(sortEntriesByLevelAscending);

    int errorLevel;
    try {
      for (final entry in sortedEntriesToSync) {
        if (errorLevel != null && entry.level > errorLevel) {
          throw SyncException();
        }
        try {
          debugModePrint(
            '[SyncStorage]: Syncing entry with name: "${entry.name}".',
            enabled: debug,
          );

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
          debugModePrint(
            '[$runtimeType]: Exception caught during entry (${entry.name}) sync: $err, $stackTrace',
            enabled: debug,
          );
          if (errorLevel != null && entry.level > errorLevel) {
            throw SyncException();
          } else {
            errorLevel = entry.level;
          }
        }
      }

      /// If during sync network sync, new data were added.
      /// Sync it too.
      if (needsNetworkSyncWhere(maxLevel: errorLevel)) {
        await _syncEntriesWithNetwork();
      }
    } on SyncException {
      debugModePrint(
        '[$runtimeType]: Breaking sync on level: $errorLevel',
        enabled: debug,
      );
      // rethrow;
    }
  }

  /// Sync all entries with network when available.
  Future<void> syncEntriesWithNetwork() async {
    debugModePrint(
      '[SyncStorage]: Requesting entries sync.',
      enabled: debug,
    );

    debugModePrint(
      '[SyncStorage]: Registered entries to sync: ${entriesToSync.length}.',
      enabled: debug,
    );

    /// If network not available or already syncing
    /// and return current sync task future if available.
    if (!networkAvailable || isSyncing) return _networkSyncTask?.future;

    _networkSyncTask = Completer<void>();

    await _syncEntriesWithNetwork();

    _networkSyncTask.complete();
  }

  Future<StorageEntry<T>> registerEntry<T>({
    @required String name,
    @required Storage<T> storage,
    @required StorageNetworkCallbacks<T> networkCallbacks,
    int level = 0,
    OnCellSyncError<T> onCellSyncError,
    ValueChanged<StorageCell<T>> onCellMaxAttemptsReached,
    DelayDurationGetter getDelayBeforeNextAttempt,
  }) async {
    debugModePrint(
      '[SyncStorage]: Registering entry with name: $name',
      enabled: debug,
    );

    if (getEntryWithName(name) != null) {
      throw ArgumentError.value(
        name,
        'name',
        'Entry with provided name is already registred.\n'
            'Instead use "getRegisteredEntry" method.',
      );
    }

    final entry = StorageEntry<T>(
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
    );
    await entry.initialize();
    _entries.add(entry);

    debugModePrint(
      '[SyncStorage]: Registered entry with name: "$name", '
      'Elements to sync: ${entry.cellsToSync.length}.',
      enabled: debug,
    );

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

  StorageEntry<T> getRegisteredEntry<T>(String name) => _entries.firstWhere(
        (entry) => entry is StorageEntry<T> && entry.name == name,
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
  }
}
