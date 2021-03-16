import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:meta/meta.dart';
import 'package:objectid/objectid.dart';
import 'package:sync_storage/src/storage/storage.dart';
import 'package:sync_storage/src/callbacks/storage_network_callbacks.dart';
import 'package:sync_storage/src/serializer.dart';

import 'sync_storage.dart';

part 'storage_cell.dart';

class SyncException implements Exception {}

typedef OnCellSyncError<T> = bool Function(
  StorageCell<T> cell,
  Exception exception,
  StackTrace stackTrace,
);

typedef OnCellMaxAttemptReached<T> = bool Function(
  StorageCell<T> cell,
);

class StorageEntry<T, S extends Storage<T>> {
  final String name;

  /// Indicates entry sync priority. Entries with lower level will be
  /// fetched / synced first.
  ///
  /// Long story short:
  /// If entries with level `0` are not synced. Entries with greater levels
  /// (`1`, `2`, `3` and so on) will not be synced too.
  ///
  /// It could be helpful for maintaining database relations.
  /// For example elements with level `1` are nested in elements with level
  /// `0`. So it is not possible to store level `1` element when its' parent (element with
  /// level `0`) does not exixt (is not fetched).
  ///
  /// By default, all entries have level set to `0`.
  final int level;
  final S storage;
  final StorageNetworkCallbacks<T> networkCallbacks;
  final OnCellSyncError<T> onCellSyncError;
  final OnCellMaxAttemptReached<T> onCellMaxAttemptsReached;
  final bool debug;
  final DelayDurationGetter getDelayBeforeNextAttempt;

  final Future<void> Function() networkUpdateCallback;

  bool get networkAvailable => networkNotifier.value;
  final ValueNotifier<bool> networkNotifier;

  Completer<void> _networkSyncTask;

  bool _needsFetch = false;
  bool get needsFetch => _needsFetch;

  bool get needsElementsSync =>
      _cellsToSync.isNotEmpty &&
      // there is a chance that cell need to be synced
      // but sync is delayed. It could be delayed due to some
      // type of error.
      _cellsToSync.any((cell) => cell.isReadyForSync);

  /// Check if [StorageEntry] contains not synced [StorageCell].
  bool get needsNetworkSync => needsFetch || needsElementsSync;

  /// Whether [StorageEntry] is syncing elements with network.

  bool get isSyncing =>
      _networkSyncTask != null && _networkSyncTask.isCompleted == false;

  List<StorageCell<T>> _cellsToSync = [];

  /// return [StorageCell]s that are saved only in the local storage.
  List<StorageCell<T>> get cellsToSync => List.unmodifiable(_cellsToSync);
  List<StorageCell<T>> get cellsReadyToSync => List.unmodifiable(
      _cellsToSync.where((cell) => cell.isReadyForSync).toList());

  StorageEntry({
    @required this.name,
    this.level = 0,
    @required this.storage,
    @required this.networkCallbacks,
    @required this.networkUpdateCallback,

    /// called on every cell network sync error
    this.onCellSyncError,

    /// called on every cell max sync attempts reached
    this.onCellMaxAttemptsReached,

    /// indicates network connection
    this.networkNotifier,

    /// if true, logs are printed to the console
    this.debug = false,

    /// Returns duration that will be used to delayed
    /// next sync attempt for cell.
    this.getDelayBeforeNextAttempt,
  });

  Future<List<StorageCell<T>>> _fetchAllElementsFromNetwork() async {
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
    _cellsToSync = (await storage.readNotSyncedCells()).toList();
  }

  /// Request network sync from sync_storage
  Future<void> requestNetworkSync() async {
    if (isSyncing) {
      return _networkSyncTask.future;
    } else if (needsNetworkSync) {
      await networkUpdateCallback();
    }
  }

  /// Called externally by [SyncStorage]. Should not be called by user.
  Future<void> syncElementsWithNetwork() async {
    if (isSyncing) return _networkSyncTask.future;
    _networkSyncTask = Completer<void>();

    try {
      if (needsElementsSync) {
        debugModePrint(
          '[$runtimeType]: Syncing elements with network...',
          enabled: debug,
        );
        await _syncElementsWithNetwork();
        debugModePrint(
          '[$runtimeType]: Elements sync completed.',
          enabled: debug,
        );
      }

      if (needsFetch && !needsElementsSync) {
        debugModePrint(
          '[$runtimeType]: Fetching elements from the network...',
          enabled: debug,
        );
        final cells = await _fetchAllElementsFromNetwork();
        _needsFetch = false;
        debugModePrint(
          '[$runtimeType]: Elements fetched: count=${cells?.length}.',
          enabled: debug,
        );

        /// If cells are null, current cells will not be replaced.
        if (cells != null) {
          /// All cells are fetched from the backend. All cells are up-to-date.
          _cellsToSync.clear();

          /// new cells are fetched from the network.
          /// Current cells should be replaced with new one.
          await storage.writeAllCells(cells);
        }

        await storage.writeConfig(storage.config.copyWith(
          lastFetch: DateTime.now(),
          needsFetch: false,
        ));
      }
    } on Exception catch (err, stackTrace) {
      debugModePrint(
        '[$runtimeType]: Error during "syncElementsWithNetwork" action: $err $stackTrace',
        enabled: debug,
      );
      rethrow;
    } finally {
      /// disable entry fetch for current session
      // _needsFetch = false;
      _networkSyncTask.complete();
    }
  }

  Future<void> refetch() async {
    debugModePrint(
      '[$runtimeType]: Marked the entry as refetch is needed.',
      enabled: debug,
    );
    _needsFetch = true;
    await requestNetworkSync();
  }

  Future<void> _syncElementsWithNetwork() async {
    bool hasError = false;

    for (final cell in cellsReadyToSync) {
      /// end task when network is not available
      if (!networkAvailable) break;

      try {
        T newElement;
        switch (cell.actionNeeded) {
          case SyncAction.create:
            debugModePrint(
              '[$runtimeType]: Sync action: CREATE ${cell.element.runtimeType}',
              enabled: debug,
            );

            /// Make CREATE request
            newElement = await networkCallbacks.onCreate(cell.element);

            break;
          case SyncAction.update:
            debugModePrint(
              '[$runtimeType]: Sync action: UPDATE ${cell.element.runtimeType}',
              enabled: debug,
            );

            /// Make UPDATE request
            newElement = await networkCallbacks.onUpdate(
              cell.oldElement,
              cell.element,
            );

            break;
          case SyncAction.delete:
            debugModePrint(
              '[$runtimeType]: Sync action: DELETE ${cell.element.runtimeType}',
              enabled: debug,
            );

            /// if cell was synced (it exists on the network),
            /// remove its representation from the network
            if (cell.wasSynced) {
              await networkCallbacks.onDelete(cell.element);
            }
            break;

          case SyncAction.none:
            debugModePrint(
              '[$runtimeType]: No action is required for cell with id=${cell.id.hexString}. Skipping...',
              enabled: debug,
            );
            break;
          default:
            debugModePrint(
              '[$runtimeType]: Not supported sync action, skipping...',
              enabled: debug,
            );
            break;
        }

        if (newElement != null) {
          // If newElement returned from onUpdate or onCreate functions is not null,
          // cell element will be replaced with the new one.
          cell._element = newElement;
        }

        // After successfull sync action. Cell is marked as synced.
        cell.markAsSynced();

        // synced cell should be removed from cells to sync.
        _removeCellFromCellsToSync(cell);

        if (cell.deleted) {
          // deleted celll should be removed from the storage
          await storage.deleteCell(cell);
        } else {
          // Changes were made for current cell. It should be synced with storage.
          await storage.writeCell(cell);
        }
      } catch (err, stackTrace) {
        debugModePrint(
          '[$runtimeType]: Exception caught during network sync: $err, $stackTrace',
          enabled: debug,
        );

        /// register sync attempt on failed sync.
        cell.registerSyncAttempt(
          getDelayBeforeNextAttempt: getDelayBeforeNextAttempt,
        );

        final bool delete =
            onCellSyncError?.call(cell, err, stackTrace) ?? false;
        if (delete) {
          await _removeCell(cell);
        } else {
          await storage.writeCell(cell);
        }

        hasError = true;
      } finally {
        if (cell.maxSyncAttemptsReached) {
          final bool delete = onCellMaxAttemptsReached?.call(cell) ?? true;
          if (delete) {
            await _removeCell(cell);
          }
        }
      }
    }

    /// If new changes to elements have been maed sync them with network.
    if (needsElementsSync && networkAvailable) {
      await _syncElementsWithNetwork();
    }

    if (hasError) throw SyncException();
  }

  void _removeCellFromCellsToSync(StorageCell<T> cell) {
    _cellsToSync.removeWhere((c) => c.id == cell.id);
  }

  /// Remove cell from local storage.
  /// Cell is not deleted from the network.
  Future<void> _removeCell(StorageCell<T> cell) async {
    _removeCellFromCellsToSync(cell);
    await storage.deleteCell(cell);
  }

  /// Utility functions

  /// Clears storage data.
  /// This will not cause refetch.
  /// To refetch all data use [refetch] method.
  Future<void> clear() async {
    debugModePrint(
      '[$runtimeType]: Clearing entry...',
      enabled: debug,
    );

    /// Wait for ongoing sync task
    await _networkSyncTask?.future;

    _cellsToSync.clear();
    await storage.clear();

    debugModePrint(
      '[$runtimeType]: Entry cleared.',
      enabled: debug,
    );
  }

  Future<void> dispose() async {
    /// Wait for ongoing sync task
    await _networkSyncTask?.future;
    await storage.dispose();
  }

  Future<void> addCell(StorageCell<T> cell) async {
    await storage.writeCell(cell);

    if (cell.needsNetworkSync || cell.isDelayed) {
      _cellsToSync.add(cell);
      await requestNetworkSync();
    }
  }

  /// Creates new element.
  /// Wraps element with cell and request network sync.
  Future<StorageCell<T>> createElement(T element) async {
    final cell = StorageCell<T>(element: element);
    _cellsToSync.add(cell);
    await storage.writeCell(cell);
    await requestNetworkSync();
    return cell;
  }

  /// Enable creating multiple [StorageCell]s based on elements.
  Future<List<StorageCell<T>>> createElements(List<T> elements) async {
    final cells =
        elements.map((element) => StorageCell(element: element)).toList();
    _cellsToSync.addAll(cells);

    await Future.wait(cells.map(storage.writeCell));

    await requestNetworkSync();
    return cells;
  }

  /// Update element in storage and network.
  Future<void> updateCell(
    StorageCell<T> cell,
  ) async {
    ArgumentError.checkNotNull(cell, 'cell');

    if (!cell.needsNetworkSync) {
      throw ArgumentError.value(
        cell,
        'cell',
        'Provided cell does not require any additional sync action',
      );
    }

    final currentCell = await storage.readCell(cell.id);
    if (currentCell == null) {
      throw ArgumentError.value(
        cell,
        'cell',
        'Cannot update cell with id="${cell.id.hexString}. '
            'Cell with provided id does not exist.',
      );
    }

    final cellIndex =
        _cellsToSync.indexWhere((cellToSync) => cellToSync.id == cell.id);
    final isCellAlreadyInCellsToSync = cellIndex >= 0;
    if (isCellAlreadyInCellsToSync) {
      _cellsToSync[cellIndex] = cell;
    } else {
      _cellsToSync.add(cell);
    }

    await storage.writeCell(cell);
    await requestNetworkSync();
  }

  /// Deletes current cell from storage and network.
  Future<void> deleteCell(StorageCell<T> cell) async {
    final currentCell = await storage.readCell(cell.id);

    if (currentCell == null) {
      throw ArgumentError.value(
        cell,
        'cell',
        'Cannot delete cell with id="${cell.id.hexString}. '
            'Cell with provided id does not exist.',
      );
    }

    if (cell.wasSynced) {
      cell.markAsDeleted();

      /// save updated cell with delete flag
      /// Cell will be removed from storage after successfull delete callback.
      await updateCell(cell);
    } else {
      _cellsToSync.removeWhere((cell) => cell.id == cell.id);
      await storage.deleteCell(cell);
    }
  }

  /// Setting elements by this method will mark all as synced.
  /// This method can be used for replacing current data with
  /// data from the network.
  ///
  /// ### This method will remove all elements even not synced.
  /// You can use
  /// [needsNetworkSync] property to determine whether some objects
  /// of this entry need to be synced.
  Future<List<StorageCell<T>>> setElements(List<T> elements) async {
    final time = DateTime.now();

    final cells = elements
        .map((element) => StorageCell.synced(
              element: element,
              createdAt: time,
            ))
        .toList();

    _cellsToSync.clear();

    await storage.writeAllCells(cells);

    return cells.toList();
  }
}
