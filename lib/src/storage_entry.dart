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
  final bool debug;
  final DelayDurationGetter getDelayBeforeNextAttempt;

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

    /// if true, logs are printed to the console
    this.debug = false,

    /// Returns duration that will be used to delayed
    /// next sync attempt for cell.
    this.getDelayBeforeNextAttempt,
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

    _cells = (await storage.readAllCells()).toList();
  }

  /// Request network sync from sync_storage
  Future<void> requestNetworkSync() async {
    if (isSyncing) return _networkSyncTask.future;
    if (needsNetworkSync) await networkUpdateCallback();
  }

  /// Called externally by [SyncStorage]. Should not be called by user.
  Future<void> syncElementsWithNetwork() async {
    if (isSyncing) return _networkSyncTask.future;
    _networkSyncTask = Completer<void>();

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

    try {
      if (needsFetch && !needsElementsSync) {
        debugModePrint(
          '[$runtimeType]: Fetching elements from the network...',
          enabled: debug,
        );
        final cells = await _fetchAllCellsFromNetwork();
        debugModePrint(
          '[$runtimeType]: Elements fetched: count=${cells?.length}.',
          enabled: debug,
        );

        /// If cells are null, current cells will not be replaced.
        if (cells != null) {
          _cells = cells;

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
        enabled: true,
      );
    } finally {
      /// disable entry fetch for current session
      _needsFetch = false;
    }

    _networkSyncTask.complete();
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
    for (final cell in cellsToSync) {
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

            /// if cell was synced, remove it representation from the network
            if (cell.wasSynced) {
              await networkCallbacks.onDelete(cell.element);
            }
            _cells.remove(cell);
            await storage.deleteCell(cell);
            break;

          default:
            debugModePrint(
              '[$runtimeType]: Not supported sync action, skipping...',
              enabled: debug,
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

        if (!cell.deleted) {
          /// Changes were made for current cell. It should be synced with storage.
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
        onCellSyncError?.call(cell, err, stackTrace);
      } finally {
        if (cell.maxSyncAttemptsReached) {
          _cells.remove(cell);
          onCellMaxAttemptsReached?.call(cell);
        }
      }
    }

    /// If new changes to elements have been maed sync them with network.
    if (needsElementsSync && networkAvailable) {
      await _syncElementsWithNetwork();
    }
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

    _cells = [];
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
    _cells.add(cell);

    await storage.writeCell(cell);

    await requestNetworkSync();
  }

  /// Wrapper around [addCell] method that instead of [StorageCell] accepts element.
  Future<StorageCell<T>> createElement(T element) async {
    final cell = StorageCell<T>(element: element);
    await addCell(cell);

    return cell;
  }

  /// Enable creating multiple [StorageCell]s based on elements.
  Future<List<StorageCell<T>>> createElements(List<T> elements) async {
    final cells =
        elements.map((element) => StorageCell(element: element)).toList();
    _cells.addAll(cells);

    await Future.wait(cells.map(storage.writeCell));

    await requestNetworkSync();
    return cells;
  }

  /// This method allow cell updating.
  Future<void> updateCell(
    StorageCell<T> cell,
  ) async {
    ArgumentError.checkNotNull(cell, 'cell');

    final currentCell = await storage.readCell(cell.id);
    if (currentCell == null) {
      throw ArgumentError.value(
        cell,
        'cell',
        'Cannot update cell with id="${cell.id.hexString}. '
            'Cell with provided id does not exist.',
      );
    }
    final cellIndex = _cells.indexOf(cell);
    _cells[cellIndex] = cell;

    await storage.writeCell(cell);
    await requestNetworkSync();
  }

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
      cell.deleted = true;

      /// save updated cell with delete flag
      /// Cell will be removed from storage after successfull delete callback.
      await updateCell(cell);
    } else {
      _cells.remove(cell);
      await storage.deleteCell(cell);
    }
  }

  /// Setting elements by this method will mark all as synced.
  /// This method can be used for replacing current data with
  /// data from the network.
  Future<List<StorageCell<T>>> setElements(List<T> elements) async {
    final time = DateTime.now();

    final cells = elements
        .map((element) => StorageCell.synced(
              element: element,
              createdAt: time,
            ))
        .toList();

    _cells
      ..clear()
      ..addAll(cells);

    await storage.writeAllCells(cells);

    return cells.toList();
  }
}
