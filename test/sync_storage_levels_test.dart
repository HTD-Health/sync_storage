import 'package:hive/hive.dart';
import 'package:mockito/mockito.dart';
import 'package:sync_storage/src/errors/errors.dart';
import 'package:sync_storage/src/sync_storage.dart';
import 'package:sync_storage/src/storage_entry.dart';
import 'package:sync_storage/sync_storage.dart';
import 'package:test/test.dart';

import 'data.dart';

void main() {
  group('Entries levels', () {
    const List<int> levels = [4, 2, 1, 2, 0];
    final entries = <StorageEntry<TestElement, HiveStorageMock<TestElement>>>[];

    final networkAvailabilityService =
        MockedNetworkAvailabilityService(initialIsConnected: false);
    SyncStorage syncStorage;

    StorageEntry<TestElement, HiveStorageMock<TestElement>> getEntryWithLevel(
            int level) =>
        entries.firstWhere(
          (element) => element.level == level,
          orElse: () => null,
        );

    setUpAll(() async {
      entries.clear();
      syncStorage = SyncStorage(
        // debug: true,
        networkAvailabilityService: networkAvailabilityService,
      );

      for (int i = 0; i < levels.length; i++) {
        final level = levels[i];

        final storage = HiveStorageMock<TestElement>(
          'sync_storage_levels_box$i',
          const TestElementSerializer(),
        );
        final callbacks = StorageNetworkCallbacksMock<TestElement>();
        final entry = await syncStorage
            .registerEntry<TestElement, HiveStorageMock<TestElement>>(
          name: 'sync_storage_levels_box$i',
          level: level,
          getDelayBeforeNextAttempt: (_) => const Duration(seconds: 2),
          storage: storage,
          networkCallbacks: callbacks,
        );

        entries.add(entry);
      }

      Iterable<Future<void>> initializeEntries() =>
          entries.map((e) => e.initialize());

      await Future.wait(initializeEntries());
    });

    setUp(() async {
      await networkAvailabilityService.goOffline();
      for (final entry in entries) {
        await entry.clear();
        await entry.refetch();
      }
    });

    tearDownAll(() async {
      await syncStorage.dispose();
      await Future.wait([
        for (int i = 0; i < entries.length; i++)
          Hive.deleteBoxFromDisk((entries[i].storage).boxName),
      ]);
    });

    test(
        'Do not sync cells that with larger levels '
        'when exception occured in lower level', () async {
      final errorEntry = getEntryWithLevel(2);
      when(errorEntry.networkCallbacks.onCreate(any))
          .thenThrow(SyncException([]));

      for (final entry in entries) {
        const newElement = TestElement(1);
        await entry.createElement(newElement);
      }

      for (final entry in entries) {
        expect(entry.needsElementsSync, isTrue);
      }

      await networkAvailabilityService.goOnline();
      // wait for current sync end
      await syncStorage.syncEntriesWithNetwork();

      int level2ElementsToSyncCount = 0;
      for (final entry in entries) {
        final hasElementsToSync = entry.cellsToSync.isNotEmpty;

        if (entry.level == 2 && hasElementsToSync) {
          level2ElementsToSyncCount++;
        } else if (entry.level >= 3) {
          expect(hasElementsToSync, isTrue);
        } else {
          expect(hasElementsToSync, isFalse);
        }
      }

      /// Only one entry with level 2 is not synced
      expect(level2ElementsToSyncCount, equals(1));
    });

    test(
        'Do not fetch cells with larger levels '
        'when exception occured in lower level', () async {
      final entry = getEntryWithLevel(2);
      expect(entry.fetchAttempt, equals(-1));
      expect(entry.needsFetch, isTrue);
      expect(entry.canFetch, isTrue);

      for (final entry in entries) {
        when(entry.networkCallbacks.onFetch()).thenAnswer((_) async => [
              const TestElement(1),
              const TestElement(2),
              const TestElement(3),
              const TestElement(4),
            ]);
      }

      when(entry.networkCallbacks.onFetch()).thenThrow(SyncException([]));

      await networkAvailabilityService.goOnline();

      await syncStorage.syncEntriesWithNetwork();

      expect(entry.fetchAttempt, equals(0));
      expect(entry.needsFetch, isTrue);
      expect(entry.canFetch, isFalse);

      int notFetchedLevel2Count = 0;
      for (final entry in entries) {
        final cells = await entry.storage.readAllCells();
        // print("level ${entry.level}:  cellsCount=${cells.length}");

        if (entry.level == 2 && cells.isEmpty) {
          notFetchedLevel2Count++;
        } else if (entry.level >= 3) {
          expect(cells, hasLength(0));
        } else {
          expect(cells, hasLength(4));
        }
      }

      /// Only one entry with level 2 is not fetched
      expect(notFetchedLevel2Count, equals(1));

      when(entry.networkCallbacks.onFetch()).thenAnswer((_) async => [
            const TestElement(1),
            const TestElement(2),
            const TestElement(3),
            const TestElement(4),
          ]);

      // Wait for fetch avaiability if needed.
      final diff = entry.nextFetchDelayedTo.difference(DateTime.now());
      if (!diff.isNegative) {
        await Future<void>.delayed(diff);
      }

      await syncStorage.syncEntriesWithNetwork();

      for (final entry in entries) {
        final cells = await entry.storage.readAllCells();
        // print("level ${entry.level}:  cellsCount=${cells.length}");

        expect(cells, hasLength(4));
      }
    });
  });
}
