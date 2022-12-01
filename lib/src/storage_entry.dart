import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sync_storage/src/sync_storage.dart';
import 'package:sync_storage/sync_storage.dart';

import 'core/node.dart';
import 'helpers/sync_indicator.dart';
import 'logs/cells_logs.dart';

import 'logs/storage_entry_logs.dart';

part 'storage_cell.dart';

typedef OnCellSyncError<T> = bool Function(
  StorageCell<T> cell,
  Exception exception,
  StackTrace stackTrace,
);

typedef OnCellMaxAttemptReached<T> = bool Function(
  StorageCell<T> cell,
);

Duration defaultGetDelayBeforeNextAttempt(int attemptNumber) {
  if (attemptNumber < 5) {
    return const [
      Duration(seconds: 1),
      Duration(minutes: 5),
      Duration(minutes: 30),
      Duration(hours: 1),
    ][attemptNumber];
  } else {
    return const Duration(days: 1);
  }
}

/// WIP:
/// Create [StorageEntry] interface
abstract class Entry<T, S extends Storage<T>> extends Node<Entry> {
  Entry({
    List<Entry<dynamic, Storage>>? children,
  }) : super(children: children ?? []);

  String get name;
  S get storage;
  StorageNetworkCallbacks<T> get callbacks;

  int get elementsToSyncCount;
  bool get needsNetworkSync;
  bool get isFetchDelayed;
  DateTime? get lastSync;
  bool get needsElementsSync;

  Future<void> initialize(SyncContext context);

  Future<void> syncElementsWithNetwork();

  Future<StorageCell<T>> createElement(T element);

  Future<void> clear();

  /// Remove all data and fetch new
  Future<void> refetch();

  Future<void> dispose();
}

/// TODO: Extract fetch functionality here
mixin EntryFetch<T, S extends Storage<T>> on Entry<T, S> {}

class StorageEntry<T, S extends Storage<T>> extends Entry<T, S> {
  @override
  final String name;

  @override
  final S storage;
  @override
  final StorageNetworkCallbacks<T> callbacks;
  @override
  final List<StorageEntry> children;

  final OnCellSyncError<T>? onCellSyncError;
  final OnCellMaxAttemptReached<T>? onCellMaxAttemptsReached;
  final DelayDurationGetter getDelayBeforeNextAttempt;
  // final Future<void>? Function() networkUpdateCallback;
  // final StreamSink<SyncStorageLog> _logsSink;

  @override
  DateTime? get lastSync => storage.config.lastSync;
  DateTime? get lastFetch => storage.config.lastFetch;
  bool get wasFetched => lastFetch != null;

  Completer<void>? _networkSyncTask;

  final SyncIndicator _fetchIndicator;
  DateTime? get nextFetchDelayedTo => _fetchIndicator.delayedTo;
  int get fetchAttempt => _fetchIndicator.attempt;
  bool get needsFetch => _fetchIndicator.needSync;
  bool get canFetch => _fetchIndicator.canSync;
  @override
  bool get isFetchDelayed => _fetchIndicator.isSyncDelayed;

  @override
  bool get needsElementsSync =>
      _cellsToSync.isNotEmpty &&
      // there is a chance that cell need to be synced
      // but sync is delayed. It could be delayed due to some
      // type of error.
      _cellsToSync.any((cell) => cell.isReadyForSync);

  @override
  int get elementsToSyncCount =>
      _cellsToSync.where((e) => e.isReadyForSync).length;

  /// Check if [StorageEntry] contains not synced [StorageCell].
  @override
  bool get needsNetworkSync => canFetch || needsElementsSync;

  /// Whether [StorageEntry] is syncing elements with network.

  bool get isSyncing =>
      _networkSyncTask != null && _networkSyncTask!.isCompleted == false;

  List<StorageCell<T?>> _cellsToSync = [];

  /// return [StorageCell]s that are saved only in the local storage.
  List<StorageCell<T>> get cellsToSync => List.unmodifiable(_cellsToSync);
  List<StorageCell<T>> get cellsReadyToSync => List.unmodifiable(
      _cellsToSync.where((cell) => cell.isReadyForSync).toList());

  StorageEntry({
    required this.name,
    this.children = const [],
    required this.storage,
    required this.callbacks,
    // required this.networkUpdateCallback,

    /// called on every cell network sync error
    this.onCellSyncError,

    /// called on every cell max sync attempts reached
    this.onCellMaxAttemptsReached,

    /// Returns duration that will be used to delayed
    /// next sync attempt for cell.
    DelayDurationGetter? getDelayBeforeNextAttempt,
  })  : getDelayBeforeNextAttempt =
            getDelayBeforeNextAttempt ?? defaultGetDelayBeforeNextAttempt,
        _fetchIndicator = SyncIndicator(
          getDelay:
              getDelayBeforeNextAttempt ?? defaultGetDelayBeforeNextAttempt,
          needSync: false,
        );

  SyncRoot? _root;
  StreamSink<SyncStorageLog> get _logsSink => _root!.logsSink;

  @override
  Future<void> initialize(SyncContext context) async {
    _root = context.root;

    await storage.initialize();
    _fetchIndicator.reset(needSync: storage.config.needsFetch);
    // TODO: Propably there is no need for that
    // we can read them on demand during the sync process.
    _cellsToSync = (await storage.readNotSyncedCells()).toList();

    await forEachDependantsLayered(
      (d) => d.initialize(context),
      singleLayer: true,
    );
  }

  Future<List<StorageCell<T>>?> _fetchAllElementsFromNetwork() async {
    final data = await callbacks.onFetch();
    if (data == null) {
      return null;
    }

    StorageCell<T> toSyncedCell(T element) =>
        StorageCell<T>.synced(element: element);

    final cells = data.map(toSyncedCell).toList();

    return cells;
  }

  @Deprecated('In favor of syncElementsWithNetwork')
  Future<void> requestNetworkSync() async {
    /// ? We do not want to throw an exception outside the sync storage
    void ignoreError(dynamic _) {}

    await syncElementsWithNetwork().catchError(ignoreError);
  }

  @override
  Future<void> syncElementsWithNetwork() async {
    if (isSyncing) return _networkSyncTask!.future;
    if (!_root!.networkAvailable) {
      // No network, sync cannot be performed
      return;
    }

    _networkSyncTask = Completer<void>();

    try {
      if (needsElementsSync) {
        _logsSink.add(StorageEntryInfo(
          this.name,
          'Syncing elements with network...',
        ));
        await _syncElementsWithNetwork();

        _logsSink.add(StorageEntryInfo(
          this.name,
          'Elements sync completed.',
        ));
      }

      if (canFetch && !needsElementsSync) {
        _logsSink.add(StorageEntryInfo(
          this.name,
          'Fetching elements from the network...',
        ));

        final cells = await _fetchAllElementsFromNetwork();
        _fetchIndicator.reset(needSync: false);

        _logsSink.add(StorageEntryInfo(
          this.name,
          'Elements fetched: count=${cells?.length}.',
        ));

        /// If cells are null, current cells will not be replaced.
        if (cells != null) {
          /// All cells are fetched from the backend. All cells are up-to-date.
          _cellsToSync.clear();

          /// new cells are fetched from the network.
          /// Current cells should be replaced with new one.
          _logsSink.add(StorageEntryInfo(
            this.name,
            'Writing ${cells.length} cells to the storage.',
          ));
          await storage.writeAllCells(cells);
        }

        await storage.writeConfig(storage.config.copyWith(
          lastFetch: DateTime.now(),
          lastSync: DateTime.now(),
          needsFetch: false,
        ));
      }
    } on Exception {
      if (_fetchIndicator.needSync) {
        /// disable entry fetch for current session.
        /// Prevent infinit fetch actions when fetch action throws an exception.
        final fetchDelayDuration = _fetchIndicator.delay();
        _logsSink.add(StorageEntryFetchDelayed(
          name,
          'Fetch for entry with name "${name}" is '
          'delayed by ${fetchDelayDuration.inMilliseconds}ms.',
          duration: fetchDelayDuration,
          delayedTo: _fetchIndicator.delayedTo,
        ));
      }

      rethrow;
    } finally {
      _networkSyncTask!.complete();
      _networkSyncTask = null;
    }
  }

  @override
  Future<void> refetch() async {
    _logsSink.add(StorageEntryInfo(
      this.name,
      'Marked the entry as refetch is needed.',
    ));
    _fetchIndicator.reset(needSync: true);
    await storage.writeConfig(storage.config.copyWith(
      needsFetch: true,
    ));
    await requestNetworkSync();
  }

  Future<void> reset() async {
    _logsSink.add(StorageEntryInfo(
      this.name,
      'Entry reset performed.',
    ));
    await clear();
    _fetchIndicator.reset(needSync: true);
    await storage.writeConfig(storage.config.copyWith(
      needsFetch: true,
    ));
  }

  Future<void> markAsFetchNeeded() async {
    _logsSink.add(StorageEntryInfo(
      this.name,
      'Marked as fetch needed.',
    ));
    _fetchIndicator.reset(needSync: true);
    await storage.writeConfig(storage.config.copyWith(
      needsFetch: true,
    ));
  }

  Future<void> _syncElementsWithNetwork() async {
    final List<ExceptionDetail> errors = [];

    for (final cell in cellsReadyToSync) {
      /// end task when network is not available
      if (!_root!.networkAvailable) {
        errors.add(ExceptionDetail(
          ConnectionInterrupted(),
          StackTrace.current,
        ));

        break;
      }

      try {
        T? newElement;
        switch (cell.actionNeeded) {
          case SyncAction.create:
            _logsSink.add(CellSyncAction(
              this.name,
              cell.id.hexString,
              'Calling onCreate network callback for '
              'element with id=${cell.id.hexString}',
              action: cell.actionNeeded,
            ));

            /// Make CREATE request
            newElement = await callbacks.onCreate(cell.element);

            break;
          case SyncAction.update:
            _logsSink.add(CellSyncAction(
              this.name,
              cell.id.hexString,
              'Calling onUpdate network callback for '
              'element with id=${cell.id.hexString}',
              action: cell.actionNeeded,
            ));

            /// Make UPDATE request
            newElement = await callbacks.onUpdate(
              cell.oldElement!,
              cell.element,
            );

            break;
          case SyncAction.delete:
            _logsSink.add(CellSyncAction(
              this.name,
              cell.id.hexString,
              'Calling onDelete network callback for '
              'element with id=${cell.id.hexString}',
              action: cell.actionNeeded,
            ));

            /// if cell was synced (it exists on the network),
            /// remove its representation from the network
            if (cell.wasSynced) {
              await callbacks.onDelete(cell.element);
            }
            break;

          case SyncAction.none:
            _logsSink.add(CellSyncActionWarning(
              this.name,
              cell.id.hexString,
              'No action is required for cell with '
              'id=${cell.id.hexString}. Skipping...',
              action: cell.actionNeeded,
            ));
            break;
          default:
            _logsSink.add(CellSyncActionWarning(
              this.name,
              cell.id.hexString,
              'Not supported sync action (${cell.actionNeeded}) for cell '
              'with id=${cell.id.hexString}. Skipping...',
              action: cell.actionNeeded,
            ));
            break;
        }

        if (newElement != null) {
          // If newElement returned from onUpdate or onCreate functions
          // is not null, cell element will be replaced with the new one.
          cell._element = newElement;
          _logsSink.add(CellInfo(
            this.name,
            cell.id.hexString,
            'New element received from the network for cell '
            'with id=${cell.id.hexString}. Updated.',
          ));
        }

        // After successfull sync action. Cell is marked as synced.
        cell.markSynced();

        _logsSink.add(CellInfo(
          this.name,
          cell.id.hexString,
          'Cell with id=${cell.id.hexString} synced successfully.',
        ));

        // synced cell should be removed from cells to sync.
        _removeCellFromCellsToSync(cell);

        if (cell.deleted) {
          // deleted cell should be removed from the storage
          await storage.deleteCell(cell);
        } else {
          // Changes were made for current cell. It should be
          // synced with storage.
          await storage.writeCell(cell);
        }
      } on Exception catch (err, stackTrace) {
        _logsSink.add(CellSyncActionError(
          this.name,
          cell.id.hexString,
          'Exception caught during cell sync (cell id=${cell.id.hexString}).',
          action: cell.actionNeeded,
          error: err,
          stackTrace: stackTrace,
        ));

        /// register sync attempt on failed sync.
        final delay = cell.registerSyncAttempt(
          getDelayBeforeNextAttempt: getDelayBeforeNextAttempt,
        );

        _logsSink.add(CellSyncDelayed(
          this.name,
          cell.id.hexString,
          'Sync for cell with id=${cell.id.hexString} delayed '
          'by ${delay.inMilliseconds}ms',
          delayedTo: cell.syncDelayedTo,
          duration: delay,
        ));

        final bool delete =
            onCellSyncError?.call(cell, err, stackTrace) ?? false;
        if (delete) {
          await removeCell(cell);
        } else {
          await storage.writeCell(cell);
        }

        errors.add(ExceptionDetail(err, stackTrace));
      } finally {
        if (cell.maxSyncAttemptsReached) {
          final bool delete = onCellMaxAttemptsReached?.call(cell) ?? true;
          if (delete) {
            await removeCell(cell);
          }
        }
      }
    }

    /// If new changes to elements have been made sync them with network.
    if (needsElementsSync && _root!.networkAvailable) {
      await _syncElementsWithNetwork();
    } else {
      await storage.writeConfig(storage.config.copyWith(
        lastSync: DateTime.now(),
      ));
    }

    if (errors.isNotEmpty) throw SyncException(errors);
  }

  void _removeCellFromCellsToSync(StorageCell<T> cell) {
    _cellsToSync.removeWhere((c) => c.id == cell.id);
  }

  /// Remove cell from local storage.
  /// Cell is not deleted from the network.
  Future<void> removeCell(StorageCell<T> cell) async {
    _removeCellFromCellsToSync(cell);
    await storage.deleteCell(cell);
  }

  /// Utility functions

  /// Clears storage data.
  /// This will not cause refetch.
  /// To refetch all data use [refetch] method.
  @override
  Future<void> clear() async {
    _logsSink.add(StorageEntryInfo(
      name,
      'Clearing entry with name=\"$name\"...',
    ));

    /// Wait for ongoing sync task
    await _networkSyncTask?.future;

    _fetchIndicator.reset(needSync: false);
    _cellsToSync.clear();
    await storage.clear();

    _logsSink.add(StorageEntryInfo(
      name,
      'Entry with name=\"$name\" cleared.',
    ));
  }

  @override
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
  @override
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

  /// Puts cell to the storage.
  ///
  /// Unlike the [updateCell] method. This method will not trigger
  /// a network sync. Also, provided cell will be marked as synced.
  ///
  /// Calling putCell with a storage cell that is already queued for sync
  /// will throw the StateError.
  @experimental
  Future<void> putCell(
    StorageCell<T> cell,
  ) async {
    ArgumentError.checkNotNull(cell, 'cell');

    final currentCell = await storage.readCell(cell.id);
    if (currentCell == null) {
      throw ArgumentError.value(
        cell,
        'cell',
        'Cannot put cell with id="${cell.id.hexString}. '
            'Cell with provided id does not exist.',
      );
    }

    final cellIndex =
        _cellsToSync.indexWhere((cellToSync) => cellToSync.id == cell.id);
    final isCellAlreadyInCellsToSync = cellIndex >= 0;

    if (isCellAlreadyInCellsToSync) {
      throw StateError('Provided StorageCell is already queued for sync.');
    }

    cell.markSynced();
    await storage.writeCell(cell);
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
      cell.markDeleted();

      /// save updated cell with delete flag
      /// Cell will be removed from storage after successfull delete callback.
      await updateCell(cell);
    } else {
      await removeCell(cell);
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
