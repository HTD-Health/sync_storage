import 'dart:async';

import 'package:meta/meta.dart';
import 'package:sync_storage/src/sync_storage.dart';
import 'package:sync_storage/sync_storage.dart';

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

/// Create [StorageEntry] interface
abstract class Entry<T, S extends Storage<T>> extends SyncNode {
  Entry({super.children = const []});

  String get name;
  S get storage;
  StorageNetworkCallbacks<T> get callbacks;

  int get elementsToSyncCount;
  bool get needsNetworkSync;
  DateTime? get lastSync;
  bool get needsElementsSync;
  bool get wasFetched;
  bool get needsFetch;
  bool get isDataUpToDate;

  Future<void> initialize(SyncContext context);

  Future<void> syncWithNetwork();

  Future<StorageCell<T>> createElement(T element);

  /// Clears entry, fetch will not be set as required
  Future<void> clear();

  /// Clears data and marks entry as fetch needed
  Future<void> reset();

  /// Remove all data and fetch new
  Future<void> refetch();

  Future<void> dispose();
}

class StorageEntry<T, S extends Storage<T>> extends Entry<T, S> {
  @override
  final String name;

  @override
  final S storage;
  @override
  final StorageNetworkCallbacks<T> callbacks;

  final OnCellSyncError<T>? onCellSyncError;
  final OnCellMaxAttemptReached<T>? onCellMaxAttemptsReached;
  final DelayDurationGetter getDelayBeforeNextAttempt;

  /// If an error occurs during initialization, the data of this storage
  /// will be cleared and the storage will be marked as fetch required.
  final bool clearOnError;

  @override
  DateTime? get lastSync => storage.config.lastSync;
  DateTime? get lastFetch => storage.config.lastFetch;
  @override
  bool get wasFetched => lastFetch != null;

  Completer<void>? _networkSyncTask;

  bool _needsFetch = false;
  @override
  bool get needsFetch => _needsFetch;
  @override
  bool get isDataUpToDate => wasFetched && !needsFetch;

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
  bool get needsNetworkSync => needsFetch || needsElementsSync;

  /// Whether [StorageEntry] is syncing elements with network.

  bool get isSyncing =>
      _networkSyncTask != null && _networkSyncTask!.isCompleted == false;

  List<StorageCell<T?>> _cellsToSync = [];

  // TODO: REMOVE, Read on demand
  /// return [StorageCell]s that are saved only in the local storage.
  List<StorageCell<T>> get cellsToSync => List.unmodifiable(_cellsToSync);
  // TODO: REMOVE, Read on demand
  List<StorageCell<T>> get cellsReadyToSync => List.unmodifiable(
      _cellsToSync.where((cell) => cell.isReadyForSync).toList());

  StorageEntry({
    required this.name,
    super.children,
    required this.storage,
    required this.callbacks,
    this.clearOnError = false,

    /// called on every cell network sync error
    this.onCellSyncError,

    /// called on every cell max sync attempts reached
    this.onCellMaxAttemptsReached,

    /// Returns duration that will be used to delayed
    /// next sync attempt for cell.
    DelayDurationGetter? getDelayBeforeNextAttempt,
  }) : getDelayBeforeNextAttempt =
            getDelayBeforeNextAttempt ?? defaultGetDelayBeforeNextAttempt;

  SyncContext? _context;

  ScopedLogger get _logger => _context!.logger;

  @override
  Future<void> initialize(SyncContext context) async {
    _context = context;

    final logger = _logger.beginScope('initialize');

    try {
      await storage.initialize();
      _needsFetch = storage.config.needsFetch ?? true;
      // TODO?: We can read them on demand during the sync process?
      _cellsToSync = await storage.readNotSynced();
    } on Exception {
      if (clearOnError) {
        logger.w('Unable to initialize storage. Clearing the storage.');
        _needsFetch = true;
        await storage.clear();
        logger.i('Storage cleared.');
        await storage.writeConfig(storage.config.copyWith(needsFetch: true));
        logger.i('Config written.');
      } else {
        logger.w(
          'Failed to initialize the storage. '
          'You can also clear the storage in the following situation '
          'by setting the "clearOnError" argument to true.',
        );
        rethrow;
      }
    }

    await forEachChildrenLayered(
      (_, child) => child.initialize(SyncContext(
        logger: _logger.beginScope('Entry(${child.name})'),
        progress: context.progress,
        network: context.network,
      )),
      recursive: false,
    );
  }

  @protected
  Future<List<StorageCell<T>>?> fetchElementsFromNetwork() async {
    final data = await callbacks.onFetch();
    if (data == null) {
      return null;
    }

    StorageCell<T> toSyncedCell(T element) =>
        StorageCell<T>.synced(element: element);

    final cells = data.map(toSyncedCell).toList();

    return cells;
  }

  /// This method is used internally by the [addCell], [updateCell]
  /// and [deleteCell] methods.
  ///
  /// If network is not available, the sync action should not be performed.
  Future<void> _requestNetworkSync() async {
    /// If network is not available, do not sync with network.
    if (!_context!.network.isConnected) return;
    try {
      await syncWithNetwork();
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {
      // Do not throw an error outside of sync_storage,
      // as the request will be retried inside the library.
      // Also, instead of an exception, for example,
      // the [addCell] method returns [StorageCell],
      // which can be used to get the current sync state.
    }
  }

  /// The [maxConcurrentActions] (defaults to `5`) is the maximum requests
  /// that will be called in parallel.
  @override
  Future<void> syncWithNetwork({int maxConcurrentActions = 5}) async {
    if (isSyncing) {
      _logger.i(
        'Network synchronization already underway. '
        'Awaiting that task...',
      );
      return _networkSyncTask!.future;
    }
    if (!_context!.network.isConnected) {
      final error = ConnectionInterrupted();
      _logger.w('No network. Cannot sync.', error, StackTrace.current);
      throw error;
    }

    _networkSyncTask = Completer<void>();

    try {
      if (needsElementsSync) {
        _logger.i('Syncing elements with network...');
        await syncElementsWithNetwork(
          maxConcurrentActions: maxConcurrentActions,
        );
        _logger.i('Elements sync completed.');
      }

      if (needsFetch && !needsElementsSync) {
        _logger.i('Fetching elements from the network...');

        final cells = await fetchElementsFromNetwork();
        _needsFetch = false;

        _logger.i('Elements fetched: count=${cells?.length}.');

        /// If cells are null, current cells will not be replaced.
        if (cells != null) {
          /// All cells are fetched from the backend. All cells are up-to-date.
          _cellsToSync.clear();

          /// new cells are fetched from the network.
          /// Current cells should be replaced with new one.
          _logger.i('Replacing the cells with the ${cells.length} fetched.');
          await storage.writeAll(cells);
        }

        _context!.progress.raportFetchDone(this);
        await storage.writeConfig(storage.config.copyWith(
          lastFetch: DateTime.now(),
          lastSync: DateTime.now(),
          needsFetch: false,
        ));
      }

      /// All data is up-to-date
      if (!needsFetch && !needsElementsSync) {
        await syncChildrenWithNetwork();
      }
    } on Exception catch (err, st) {
      _logger.e('Error occured.', err, st);

      rethrow;
    } finally {
      _networkSyncTask!.complete();
      _networkSyncTask = null;
    }
  }

  @override
  Future<void> refetch() async {
    _logger.i('Marked the entry as refetch is needed.');
    _needsFetch = true;
    await storage.writeConfig(storage.config.copyWith(
      needsFetch: true,
    ));
    await _requestNetworkSync();
  }

  @override
  Future<void> reset() async {
    _logger.i('Entry reset performed.');
    await clear();
    _needsFetch = true;
    await storage.writeConfig(storage.config.copyWith(
      needsFetch: true,
    ));
  }

  Future<void> markAsFetchNeeded() async {
    _logger.i(
      'Marked as fetch needed.',
    );
    _needsFetch = true;
    await storage.writeConfig(storage.config.copyWith(
      needsFetch: true,
    ));
  }

  @protected
  Future<void> syncCell(StorageCell<T> cell) async {
    final logger = _logger.beginScope('Cell(${cell.id})');

    /// end task when network is not available
    if (!_context!.network.isConnected) {
      _logger.w('Cannot sync cell, no network. Skipping...');
      return;
    }

    try {
      T? newElement;
      switch (cell.actionNeeded) {
        case SyncAction.create:
          logger.i('Calling onCreate network callback...');

          /// Make CREATE request
          newElement = await callbacks.onCreate(cell.element);
          logger.i('The onCreate callback was successful.');

          break;
        case SyncAction.update:
          logger.i(
            'Calling the onUpdate network callback...',
          );

          /// Make UPDATE request
          newElement = await callbacks.onUpdate(
            cell.oldElement!,
            cell.element,
          );

          logger.i('The onUpdate callback was successful.');

          break;
        case SyncAction.delete:
          logger.i('Calling the onDelete network callback... ');

          /// if cell was synced (it exists on the network),
          /// remove its representation from the network
          if (cell.wasSynced) {
            await callbacks.onDelete(cell.element);
          }
          logger.i('The onDelete callback was successful.');

          break;

        case SyncAction.none:
          logger.i(
            'No action is required for cell. '
            'Skipping...',
          );
          break;
        default:
          logger.w(
            'Not supported sync action (${cell.actionNeeded}). '
            'Skipping...',
          );
          break;
      }

      if (newElement != null) {
        // If newElement returned from onUpdate or onCreate functions
        // is not null, cell element will be replaced with the new one.
        cell._element = newElement;
        logger.i(
          'New element received from the network. '
          'Cell element updated.',
        );
      }

      // After successfull sync action. Cell is marked as synced.
      cell.markSynced();

      logger.i('Cell synced successfully.');

      // synced cell should be removed from cells to sync.
      // TODO: Load cells to sync on demand
      _removeCellFromCellsToSync(cell);

      if (cell.deleted) {
        // deleted cell should be removed from the storage
        await storage.delete(cell);
      } else {
        // Changes were made for current cell. It should be
        // synced with storage.
        await storage.write(cell);
      }
    } on Exception catch (err, stackTrace) {
      logger.e('Exception caught during cell sync.', err, stackTrace);

      /// register sync attempt on failed sync.
      final delay = getDelayBeforeNextAttempt(cell.networkSyncAttemptsCount);
      cell.registerSyncAttempt(delay: delay);

      logger.w(
        'The cell sync delayed by ${delay.inMilliseconds}ms '
        'until ${cell.syncDelayedTo?.toLocal()}.',
      );

      final bool delete = onCellSyncError?.call(cell, err, stackTrace) ?? false;
      if (delete) {
        await removeCell(cell);
      } else if (cell.maxSyncAttemptsReached) {
        final bool delete = onCellMaxAttemptsReached?.call(cell) ?? true;
        if (delete) {
          await removeCell(cell);
        }
      } else {
        await storage.write(cell);
      }

      rethrow;
    } finally {
      _context!.progress.raportElementSynced(this);
    }
  }

  /// The [maxConcurrentActions] is the maximum requests
  /// that will be called in parallel.
  @protected
  Future<void> syncElementsWithNetwork({
    required int maxConcurrentActions,
  }) async {
    _logger.i(
      'Synchronizing ${cellsReadyToSync.length} elements '
      'using up to ${maxConcurrentActions} concurrent actions...',
    );

    SyncException? syncException;
    while (needsElementsSync && _context!.network.isConnected) {
      try {
        // Perform multiple cell sync simultaneously.
        await parallel(syncCell, cellsReadyToSync, maxConcurrentActions: 5);
      } on ParallelException catch (e) {
        syncException = SyncException(e.errors);
        // ignore the error
      }
    }

    _logger.i('Elements sync completed.');

    await storage.writeConfig(storage.config.copyWith(
      lastSync: DateTime.now(),
    ));

    if (syncException != null) throw syncException;
  }

  void _removeCellFromCellsToSync(StorageCell<T> cell) {
    _cellsToSync.removeWhere((c) => c.id == cell.id);
  }

  /// Remove cell from local storage.
  /// Cell is not deleted from the network.
  Future<void> removeCell(StorageCell<T> cell) async {
    _removeCellFromCellsToSync(cell);
    await storage.delete(cell);
  }

  /// --- Utility functions ---

  /// Clears storage data.
  /// This will not cause refetch.
  /// To refetch all data use [refetch] method.
  @override
  Future<void> clear() async {
    _logger.i('Clearing entry...');

    /// Wait for ongoing sync task
    await _networkSyncTask?.future;

    _needsFetch = false;
    _cellsToSync.clear();
    await storage.clear();

    _logger.i('Entry cleared.');
  }

  @override
  Future<void> dispose() async {
    /// Wait for ongoing sync task
    await _networkSyncTask?.future;
    // TODO?: Should storage be disposed by the sync_storage?
    await storage.dispose();
  }

  Future<void> addCell(StorageCell<T> cell) async {
    final cellFromStorage = await storage.read(cell.id);

    if (cellFromStorage != null) {
      throw StateError(
        'Cannot add cell. Cell with '
        'id=${cell.id} is already in the storage.',
      );
    }

    await storage.write(cell);

    if (cell.needsNetworkSync || cell.isDelayed) {
      _cellsToSync.add(cell);
      await _requestNetworkSync();
    }
  }

  /// Creates new element.
  /// Wraps element with cell and request network sync.
  @override
  Future<StorageCell<T>> createElement(T element) async {
    final cell = StorageCell<T>(element: element);
    final logger = _logger.beginScope('Cell(${cell.id})');
    logger.t('Creating new element...');
    _cellsToSync.add(cell);
    await storage.write(cell);
    logger.t('Cell stored in storage.');
    logger.t('Requesting network sync...');
    await _requestNetworkSync();
    logger.t('Network sync request done.');
    return cell;
  }

  /// Enable creating multiple [StorageCell]s based on elements.
  Future<List<StorageCell<T>>> createElements(List<T> elements) async {
    final cells =
        elements.map((element) => StorageCell(element: element)).toList();
    _cellsToSync.addAll(cells);

    await Future.wait(cells.map(storage.write));

    await _requestNetworkSync();
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

    final currentCell = await storage.read(cell.id);
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

    await storage.write(cell);
    await _requestNetworkSync();
  }

  /// Deletes current cell from storage and network.
  Future<void> deleteCell(StorageCell<T> cell) async {
    final currentCell = await storage.read(cell.id);

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
  /// As long as the [force] argument is not set to true,
  /// this method will throw a [StateError] when there are
  /// unsynchronized elements.
  Future<List<StorageCell<T>>> setElements(
    Iterable<T> elements, {
    bool force = false,
  }) async {
    if (!force && needsNetworkSync) {
      throw StateError(
        'Elements cannot be set because '
        'the current data has not yet been synchronized. '
        'To overwrite unsynchronized elements, '
        'use this method with the `force` argument set to true.',
      );
    }

    final time = DateTime.now();

    final cells = elements
        .map((element) => StorageCell.synced(
              element: element,
              createdAt: time,
            ))
        .toList();

    _cellsToSync.clear();

    await storage.clear();
    await storage.writeAll(cells);

    return cells.toList();
  }
}
