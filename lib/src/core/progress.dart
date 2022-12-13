import 'dart:math' as math;

import 'package:sync_storage/src/utils/utils.dart';
import 'package:sync_storage/sync_storage.dart';

class EntrySyncProgress {
  final bool initialFetchRequired;
  final bool fetchCompleted;

  final int initialElementsToSyncCount;
  final int syncedElementsCount;

  const EntrySyncProgress({
    required this.initialFetchRequired,
    required this.fetchCompleted,
    required this.initialElementsToSyncCount,
    required this.syncedElementsCount,
  });

  EntrySyncProgress copyWith({
    bool? initialFetchRequired,
    bool? fetchCompleted,
    int? initialElementsToSyncCount,
    int? syncedElementsCount,
  }) =>
      EntrySyncProgress(
        initialFetchRequired: initialFetchRequired ?? this.initialFetchRequired,
        fetchCompleted: fetchCompleted ?? this.fetchCompleted,
        initialElementsToSyncCount:
            initialElementsToSyncCount ?? this.initialElementsToSyncCount,
        syncedElementsCount: syncedElementsCount ?? this.syncedElementsCount,
      );
}

class SyncProgress {
  final Map<Entry, EntrySyncProgress> _progresses;

  SyncProgress(this._progresses);

  SyncProgress copyAndSet(Entry entry, EntrySyncProgress progress) {
    return SyncProgress(Map.of(_progresses)..[entry] = progress);
  }

  int get syncedElements =>
      _progresses.values.fold(0, (p, e) => p + e.syncedElementsCount);

  int get _initialElementsToSyncCount =>
      _progresses.values.fold(0, (p, e) => p + e.initialElementsToSyncCount);
  int get _fetchedEntriesCount =>
      _progresses.values.fold(0, (p, e) => e.fetchCompleted ? p + 1 : p);
  int get _initialFetchRequiredCount =>
      _progresses.values.fold(0, (p, e) => e.initialFetchRequired ? p + 1 : p);

  int get overalSyncActionCount =>
      _initialElementsToSyncCount + _initialFetchRequiredCount;
  int get performedSyncActions => syncedElements + _fetchedEntriesCount;
  double get progress => performedSyncActions / overalSyncActionCount;
  double get progressStep => 1 / overalSyncActionCount;
}

class ProgressController implements ValueNotifier<SyncProgress> {
  final ValueController<SyncProgress> _notifierController;

  ProgressController(SyncProgress progress)
      : _notifierController = ValueController<SyncProgress>(progress);

  @override
  SyncProgress get value => _notifierController.value;

  @override
  void addListener(ValueChanged<SyncProgress> callback) =>
      _notifierController.notifier.addListener(callback);

  @override
  void removeListener(ValueChanged<SyncProgress> callback) =>
      _notifierController.notifier.removeListener(callback);

  @override
  Stream<SyncProgress> get stream => _notifierController.notifier.stream;

  @override
  void dispose() => _notifierController.notifier.dispose();

  void register(Entry entry, EntrySyncProgress progress) {
    _notifierController.value = value.copyAndSet(entry, progress);
  }

  void raportElementSynced(Entry entry) {
    final entryProgress = getEntryProgress(entry);
    if (entryProgress == null) return;

    final syncedElementsCount = entryProgress.syncedElementsCount + 1;

    final newEntryProgress = entryProgress.copyWith(
      syncedElementsCount: syncedElementsCount,
      initialElementsToSyncCount: math.max(
        entryProgress.initialElementsToSyncCount,
        syncedElementsCount,
      ),
    );
    _notifierController.value = value.copyAndSet(entry, newEntryProgress);
  }

  void raportFetchDone(Entry entry) {
    final entryProgress = getEntryProgress(entry);
    if (entryProgress == null) return;

    final newEntryProgress = entryProgress.copyWith(fetchCompleted: true);
    _notifierController.value = value.copyAndSet(entry, newEntryProgress);
  }

  EntrySyncProgress? getEntryProgress(Entry entry) {
    return _notifierController.value._progresses[entry];
  }

  void end() {
    _notifierController.value = SyncProgress({});
  }
}
