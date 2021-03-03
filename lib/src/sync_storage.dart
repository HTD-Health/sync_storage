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

  List<StorageEntry<dynamic>> get entriesToSync =>
      _entries.where((entry) => entry.needsNetworkSync).toList();

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
    for (final entry in entriesToSync) {
      debugModePrint(
        '[SyncStorage]: Syncing entry with name: "${entry.name}".',
        enabled: debug,
      );

      /// Skip this [StorageEntry], if it is syncing on its own,
      /// or changes have been reverted.
      if (!entry.needsNetworkSync || entry.isSyncing) continue;

      /// Stop sync task when network is no longer available.
      if (!networkAvailable) return;

      /// sync all cells with network.
      await entry.syncElementsWithNetwork();
    }

    /// If during sync network sync, new data were added.
    /// Sync it too.
    if (needsNetworkSync) {
      await _syncEntriesWithNetwork();
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
    OnCellSyncError<T> onCellSyncError,
    ValueChanged<StorageCell<T>> onCellMaxAttemptsReached,
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
      storage: storage,
      networkCallbacks: networkCallbacks,
      networkUpdateCallback: syncEntriesWithNetwork,
      onCellSyncError: onCellSyncError,
      onCellMaxAttemptsReached: onCellMaxAttemptsReached,
      networkNotifier: _networkNotifier,
    );
    await entry.initialize();
    _entries.add(entry);

    debugModePrint(
      '[SyncStorage]: Registered entry with name: "$name", '
      'Available elements: ${entry.cells.length}.',
      enabled: debug,
    );

    await syncEntriesWithNetwork();

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
