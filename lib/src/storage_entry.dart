import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:meta/meta.dart';
import 'package:sync_storage/src/storage/storage.dart';
import 'package:sync_storage/src/callbacks/storage_network_callbacks.dart';
import 'package:sync_storage/src/serializer.dart';

import 'sync_storage.dart';

part 'storage_cell.dart';

typedef OnCellSyncError<T> = void Function(
  StorageCell<T> cell,
  Exception exception,
  StackTrace stackTrace,
);

class StorageEntry<T> {
  final String name;
  final Storage<T> storage;
  final StorageNetworkCallbacks<T> networkCallbacks;
  final OnCellSyncError<T> onCellSyncError;
  final ValueChanged<StorageCell<T>> onCellMaxAttemptsReached;

  final Future<void> Function() networkUpdateCallback;

  bool get networkAvailable => networkNotifier.value;
  final ValueNotifier<bool> networkNotifier;

  Completer<void> _networkSyncTask;

  bool _needsFetch = false;
  bool get needsFetch => _needsFetch;

  bool get needsElementsSync => _cells.any((cell) => cell.needsNetworkSync);

  /// Check if [StorageEntry] contains not synced [StorageCell].

  bool get needsNetworkSync => needsFetch || needsElementsSync;

  /// Whether [StorageEntry] is syncing elements with network.

  bool get isSyncing =>
      _networkSyncTask != null && _networkSyncTask.isCompleted == false;

  List<StorageCell<T>> _cells;

  /// return [StorageCell]s that are saved only in the local storage.
  List<StorageCell<T>> get cellsToSync =>
      _cells.where((cell) => cell.needsNetworkSync).toList();

  /// Return cells that are saved only in the local storage.
  Iterable<StorageCell<T>> get cells => _cells;

  Iterable<T> get elements sync* {
    if (_cells == null) {
      throw StateError('Entries are not initialized.');
    } else {
      for (final cell in _cells) yield cell.element;
    }
  }

  StorageEntry({
    @required this.name,
    @required this.storage,
    @required this.networkCallbacks,
    @required this.networkUpdateCallback,

    /// called on every cell network sync error
    this.onCellSyncError,

    /// called on every cell max sync attempts reached
    this.onCellMaxAttemptsReached,

    /// indicates network connection
    this.networkNotifier,
  });

  Future<List<StorageCell<T>>> _fetchAllCellsFromNetwork() async {
    final data = await networkCallbacks.onFetch();
    if (data == null) {
      return null;
    }

    StorageCell<T> toSyncedCell(T element) =>
        StorageCell<T>.synced(element: element);

    final cells = data.map(toSyncedCell).toList();

    return cells;
  }

  Future<void> initialize() async {
    await storage.initialize();

    _needsFetch = storage.config.needsFetch;

    _cells = await storage.readAllCells();
  }

  /// Save updated cells to local DB.
  Future<void> _sync() async {
    if (isSyncing) return _networkSyncTask.future;
    return Future.wait<void>([
      syncWithStorage(),
      if (needsNetworkSync) networkUpdateCallback(),
    ]);
  }

  @visibleForTesting
  Future<void> syncWithStorage() async {
    debugModePrint(
      '[StorageEntry]: Wrtiting cells to storage.',
    );
    await storage.writeAllCells(_cells);
  }

  /// Called externally by [SyncStorage]
  Future<void> syncElementsWithNetwork() async {
    if (isSyncing) return _networkSyncTask.future;
    _networkSyncTask = Completer<void>();

    if (needsElementsSync) {
      debugModePrint('[StorageEntry]: Syncing elements with network.');
      await _syncElementsWithNetwork();
      debugModePrint('[StorageEntry]: Elements sync completed.');
    }

    try {
      if (needsFetch && !needsElementsSync) {
        debugModePrint('[StorageEntry]: Requesting elements fetch.');
        final cells = await _fetchAllCellsFromNetwork();
        debugModePrint('[StorageEntry]: Fetched elements: ${cells?.length}');

        /// If cells are null, current cells will not be replaced.
        if (cells != null) {
          _cells = cells;
          await syncWithStorage();
        }

        await storage.setConfig(storage.config.copyWith(
          lastFetch: DateTime.now(),
          needsFetch: false,
        ));
      }
    } on Exception catch (err) {
      print('Exception caught: $err');
    } finally {
      /// disable entry fetch for current session
      _needsFetch = false;
    }

    _networkSyncTask.complete();
  }

  Future<void> _syncElementsWithNetwork() async {
    for (final cell in cellsToSync) {
      /// end task when network is not available
      if (!networkAvailable) break;

      try {
        T newElement;
        switch (cell.actionNeeded) {
          case SyncAction.create:
            debugModePrint(
                '[StorageEntry]: Sync action: CREATE ${cell.element.runtimeType}');

            /// Make CREATE request
            newElement = await networkCallbacks.onCreate(cell.element);

            break;
          case SyncAction.update:
            debugModePrint(
                '[StorageEntry]: Sync action: UPDATE ${cell.element.runtimeType}');

            /// Make UPDATE request
            newElement = await networkCallbacks.onUpdate(
              cell.oldElement,
              cell.element,
            );

            break;
          case SyncAction.delete:
            debugModePrint(
                '[StorageEntry]: Sync action: DELETE ${cell.element.runtimeType}');

            /// if cell was synced, remove it representation from the network
            if (cell.wasSynced) {
              await networkCallbacks.onDelete(cell.element);
            }
            _cells.remove(cell);
            break;

          default:
            debugModePrint(
              '[StorageEntry]: Not supported sync action, skipping...',
            );
            continue;
        }

        cell

          /// If newElement returned from onUpdate or onCreate functions is not null,
          /// cell element will be replaced with the new one.
          ..element = newElement ?? cell.element
          .._oldElement = null
          ..resetSyncAttemptsCount()
          ..markAsSynced();
      } catch (err, stackTrace) {
        /// register sync attempt on failed sync.
        cell.registerSyncAttempt();
        onCellSyncError?.call(cell, err, stackTrace);
      } finally {
        if (cell.maxSyncAttemptsReached) {
          _cells.remove(cell);
          onCellMaxAttemptsReached?.call(cell);
        }
      }
    }

    /// Save changes to storage.
    await syncWithStorage();

    /// If new changes to elements have been maed sync them with network.
    if (needsElementsSync && networkAvailable) {
      await _syncElementsWithNetwork();
    }
  }

  /// Utility functions

  /// Clears storage data.
  Future<void> clear() async {
    /// Wait for ongoing sync task
    await _networkSyncTask;

    _cells = [];
    await storage.clear();
    _needsFetch = true;
  }

  Future<void> dispose() async {
    /// Wait for ongoing sync task
    await _networkSyncTask;
    await storage.dispose();
  }

  Future<StorageCell<T>> updateElementWhere(
    bool test(T cell),
    T updatedEntry,
  ) async {
    final cell =
        _cells.firstWhere((cell) => test(cell.element), orElse: () => null);

    if (cell == null) {
      throw ArgumentError('There is no entry matching the test.');
    }

    cell.element = updatedEntry;

    await _sync();
    return cell;
  }

  Future<StorageCell<T>> createElement(T element) async {
    final cell = StorageCell(element: element);
    _cells.add(cell);

    await _sync();

    return cell;
  }

  Future<List<StorageCell<T>>> createElements(List<T> elements) async {
    final cells = [
      for (final element in elements) StorageCell(element: element)
    ];
    _cells.addAll(cells);

    await _sync();
    return cells;
  }

  Future<StorageCell<T>> deleteElementWhere(bool test(T cell)) async {
    final cell = _cells.firstWhere(
      (cell) => test(cell.element),
      orElse: () => null,
    );

    if (cell == null) {
      throw ArgumentError('There is no cell matching the test.');
    }

    cell.deleted = true;

    await _sync();
    return cell;
  }

  /// Setting elements by this method will mark all as synced.
  /// This method can be used for replacing current data with
  /// data from the network.
  Future<List<StorageCell<T>>> setElements(List<T> elements) async {
    final time = DateTime.now();

    final cells = [
      for (final element in elements)
        StorageCell.synced(
          element: element,
          createdAt: time,
        )
    ];

    _cells
      ..clear()
      ..addAll(cells);

    await _sync();

    return cells;
  }

  /// Removes cell from entry
  ///
  /// This will not cause network DELETE callback invocation.
  StorageCell<T> removeCellWhere(bool test(T element)) {
    ArgumentError.checkNotNull(test, 'test');

    final cell = _cells.firstWhere(
      (cell) => test(cell.element),
      orElse: () => null,
    );

    if (cell != null) {
      _cells.remove(cell);
    }

    return cell;
  }

  /// This method adds cell to this entry.
  ///
  /// If provided cell `needsNetworkSync` it will trigger appropriate network callback.
  Future<void> putCell(StorageCell<T> cell) async {
    ArgumentError.checkNotNull(cell, 'cell');
    if (_cells.contains(cell)) {
      throw ArgumentError('Provided cell aready exists.');
    }

    _cells.add(cell);

    await _sync();
  }
}
