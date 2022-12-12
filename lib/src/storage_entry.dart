import 'dart:async';

import 'package:meta/meta.dart';
import 'package:scoped_logger/scoped_logger.dart';
import 'package:sync_storage/src/sync_storage.dart';
import 'package:sync_storage/sync_storage.dart';

import 'core/core.dart';
import 'helpers/sync_indicator.dart';

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
abstract class Entry<T, S extends Storage<T>> extends SyncNode {
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

  Future<void> syncWithNetwork();

  Future<StorageCell<T>> createElement(T element);

  Future<void> clear();

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

  // TODO: REMOVE, Read on demand
  List<StorageCell<T?>> _cellsToSync = [];

  // TODO: REMOVE, Read on demand
  /// return [StorageCell]s that are saved only in the local storage.
  List<StorageCell<T>> get cellsToSync => List.unmodifiable(_cellsToSync);
  // TODO: REMOVE, Read on demand
  List<StorageCell<T>> get cellsReadyToSync => List.unmodifiable(
      _cellsToSync.where((cell) => cell.isReadyForSync).toList());

  StorageEntry({
    required this.name,
    this.children = const [],
    required this.storage,
    required this.callbacks,

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

  SyncContext? _context;

  ScopedLogger get _logger => _context!.logger;

  @override
  Future<void> initialize(SyncContext context) async {
    _context = context;

    await storage.initialize();
    _fetchIndicator.reset(needSync: storage.config.needsFetch);
    // TODO: Propably there is no need for that
    // we can read them on demand during the sync process.
    _cellsToSync = (await storage.readNotSynced()).toList();

    await forEachChildrenLayered(
      (_, child) => child.initialize(SyncContext(
        logger: _logger.beginScope('Entry(${child.name})'),
        root: context.root,
        networkNotifier: context.networkNotifier,
      )),
      singleLayer: true,
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

  @Deprecated('In favor of syncWithNetwork')
  Future<void> requestNetworkSync() async {
    /// ? We do not want to throw an exception outside the sync storage
    void ignoreError(dynamic _) {}

    await syncWithNetwork().catchError(ignoreError);
  }

  @override
  Future<void> syncWithNetwork() async {
    if (isSyncing) return _networkSyncTask!.future;
    if (!_context!.root.networkAvailable) {
      // No network, sync cannot be performed
      return;
    }

    _networkSyncTask = Completer<void>();

    try {
      if (needsElementsSync) {
        _logger.i('Syncing elements with network...');
        await syncElementsWithNetwork();
        _logger.i('Elements sync completed.');
      }

      if (canFetch && !needsElementsSync) {
        _logger.i('Fetching elements from the network...');

        final cells = await fetchElementsFromNetwork();
        _fetchIndicator.reset(needSync: false);

        _logger.i('Elements fetched: count=${cells?.length}.');

        /// If cells are null, current cells will not be replaced.
        if (cells != null) {
          /// All cells are fetched from the backend. All cells are up-to-date.
          _cellsToSync.clear();

          /// new cells are fetched from the network.
          /// Current cells should be replaced with new one.
          _logger.i('Replacing the cells with the ${cells.length} fetched.');
          await storage.clear();

          /// It is possible that fetch does not return any elements
          if (cells.isNotEmpty) {
            await storage.writeAll(cells);
          }
        }

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

      if (_fetchIndicator.needSync) {
        /// disable entry fetch for current session.
        /// Prevent infinit fetch actions when fetch action throws an exception.
        final fetchDelayDuration = _fetchIndicator.delay();
        _logger.w(
          'Fetch for entry with name "${name}" is '
          'delayed by ${fetchDelayDuration.inMilliseconds}ms '
          'until ${_fetchIndicator.delayedTo?.toLocal()}.',
        );
      }

      rethrow;
    } finally {
      _networkSyncTask!.complete();
      _networkSyncTask = null;
    }
  }

  @override
  Future<void> refetch() async {
    _logger.i(
      'Marked the entry as refetch is needed.',
    );
    _fetchIndicator.reset(needSync: true);
    await storage.writeConfig(storage.config.copyWith(
      needsFetch: true,
    ));
    await requestNetworkSync();
  }

  Future<void> reset() async {
    _logger.i(
      'Entry reset performed.',
    );
    await clear();
    _fetchIndicator.reset(needSync: true);
    await storage.writeConfig(storage.config.copyWith(
      needsFetch: true,
    ));
  }

  Future<void> markAsFetchNeeded() async {
    _logger.i(
      'Marked as fetch needed.',
    );
    _fetchIndicator.reset(needSync: true);
    await storage.writeConfig(storage.config.copyWith(
      needsFetch: true,
    ));
  }

  @protected
  Future<void> syncCell(StorageCell<T> cell) async {
    final logger = _logger.beginScope('Cell(${cell.id})');

    /// end task when network is not available
    if (!_context!.root.networkAvailable) {
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
      final delay = cell.registerSyncAttempt(
        delay: getDelayBeforeNextAttempt(cell.networkSyncAttemptsCount),
      );

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
    }
  }

  /// The [batchSize] (defaults to `5`) is the maximum requests
  /// that will be called in paraller.
  @protected
  Future<void> syncElementsWithNetwork({int batchSize = 5}) async {
    _logger.i(
      'Synchronize ${cellsReadyToSync.length} items '
      'using a batch size of ${batchSize}....',
    );
    bool hasError = false;
    while (needsElementsSync && _context!.root.networkAvailable) {
      try {
        // TODO: Do not wait for all 5 requests to end
        await Future.wait<void>(cellsReadyToSync.take(batchSize).map(syncCell));
        // ignore: avoid_catches_without_on_clauses
      } catch (err) {
        hasError = true;
        // ignore the error
      }
    }

    _logger.i('Elements sync completed.');

    await storage.writeConfig(storage.config.copyWith(
      lastSync: DateTime.now(),
    ));

    if (hasError) throw const SyncException([]);
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

  /// Utility functions

  /// Clears storage data.
  /// This will not cause refetch.
  /// To refetch all data use [refetch] method.
  @override
  Future<void> clear() async {
    _logger.i(
      'Clearing entry with name=\"$name\"...',
    );

    /// Wait for ongoing sync task
    await _networkSyncTask?.future;

    _fetchIndicator.reset(needSync: false);
    _cellsToSync.clear();
    await storage.clear();

    _logger.i(
      'Entry with name=\"$name\" cleared.',
    );
  }

  @override
  Future<void> dispose() async {
    /// Wait for ongoing sync task
    await _networkSyncTask?.future;
    // TODO?: Should storage be disposed by the sync_storage?
    await storage.dispose();
  }

  Future<void> addCell(StorageCell<T> cell) async {
    await storage.write(cell);

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
    await storage.write(cell);
    await requestNetworkSync();
    return cell;
  }

  /// Enable creating multiple [StorageCell]s based on elements.
  Future<List<StorageCell<T>>> createElements(List<T> elements) async {
    final cells =
        elements.map((element) => StorageCell(element: element)).toList();
    _cellsToSync.addAll(cells);

    await Future.wait(cells.map(storage.write));

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

    final currentCell = await storage.read(cell.id);
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
    await storage.write(cell);
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
    await requestNetworkSync();
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
    List<T> elements, {
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

    await storage.writeAll(cells);

    return cells.toList();
  }
}
