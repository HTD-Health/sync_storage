import 'package:hive/hive.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:sync_storage/sync_storage.dart';
import 'package:test/test.dart';

import 'data.dart';
import 'sync_storage_levels_test.mocks.dart';

StorageEntry createEntry({
  required String name,
  List<StorageEntry> dependants = const [],
}) {
  final storage = HiveStorageMock<TestElement>(
    name,
    const TestElementSerializer(),
  );
  final callbacks = MockStorageNetworkCallbacks<TestElement>();
  when(callbacks.onCreate(any))
      .thenAnswer((realInvocation) => Future.value(null));
  when(callbacks.onFetch()).thenAnswer((realInvocation) => Future.value([]));
  return StorageEntry<TestElement, HiveStorageMock<TestElement>>(
    children: dependants,
    name: name,
    getDelayBeforeNextAttempt: (_) => const Duration(seconds: 2),
    storage: storage,
    callbacks: callbacks,
  );
}

@GenerateMocks([StorageNetworkCallbacks])
void main() {
  group('Entries levels', () {
    final networkAvailabilityService =
        MockedNetworkAvailabilityService(initialIsConnected: false);
    late SyncStorage syncStorage;

    setUpAll(() async {
      syncStorage = SyncStorage(
        networkAvailabilityService: networkAvailabilityService,
        children: [
          createEntry(
            name: '0',
            dependants: [
              createEntry(
                name: '0-0',
                dependants: [
                  createEntry(name: '0-0-0', dependants: [
                    createEntry(name: '0-0-0-0'),
                  ]),
                  createEntry(name: '0-0-1')
                ],
              ),
            ],
          ),
        ],
      );

      await syncStorage.initialize();
    });

    setUp(() async {
      await networkAvailabilityService.goOffline();
      for (final entry in syncStorage.traverse()) {
        await entry.clear();
        await entry.refetch();
      }
    });

    tearDownAll(() async {
      await Future.wait([
        for (final entry in syncStorage.traverse())
          Hive.deleteBoxFromDisk((entry.storage as HiveStorage).boxName),
      ]);
      await syncStorage.dispose();
    });

    test(
        'Do not sync cells that with larger levels '
        'when exception occurred in lower level', () async {
      final errorEntry =
          syncStorage.traverse().firstWhere((e) => e.name == '0-0-0');

      when((errorEntry.callbacks as MockStorageNetworkCallbacks).onCreate(any))
          .thenThrow(const SyncException([]));

      for (final entry in syncStorage.traverse()) {
        const newElement = TestElement(1);
        await entry.createElement(newElement);
      }

      for (final entry in syncStorage.traverse()) {
        expect(entry.needsElementsSync, isTrue);
      }

      await networkAvailabilityService.goOnline();
      // wait for current sync end
      await syncStorage.syncEntriesWithNetwork();

      final syncStatus = {
        for (final entry in syncStorage.traverse())
          entry.name: (entry as StorageEntry).cellsToSync.isNotEmpty,
      };

      expect(syncStatus, <String, bool>{
        '0': false, // synced
        '0-0': false, // synced
        '0-0-0': true, // not synced
        '0-0-0-0': true, // not synced
        '0-0-1': false, // synced
      });
    });

    test(
        'Do not fetch cells with larger levels '
        'when exception occurred in lower level', () async {
      final errorEntry = syncStorage
          .traverse()
          .firstWhere((e) => e.name == '0-0-0') as StorageEntry;
      expect(errorEntry.fetchAttempt, equals(-1));
      expect(errorEntry.needsFetch, isTrue);
      expect(errorEntry.canFetch, isTrue);

      for (final entry in syncStorage.traverse()) {
        when((entry.callbacks as MockStorageNetworkCallbacks).onFetch())
            .thenAnswer((_) async => <TestElement>[
                  const TestElement(1),
                  const TestElement(2),
                  const TestElement(3),
                  const TestElement(4),
                ]);
      }

      when(errorEntry.callbacks.onFetch()).thenThrow(const SyncException([]));

      await networkAvailabilityService.goOnline();

      await syncStorage.syncEntriesWithNetwork();

      expect(errorEntry.fetchAttempt, equals(0));
      expect(errorEntry.needsFetch, isTrue);
      expect(errorEntry.canFetch, isFalse);

      var entryElementsCount = {
        for (final entry in syncStorage.traverse())
          entry.name: (await entry.storage.readAllCells()).length,
      };

      /// Only one entry with level 2 are not fetched
      expect(entryElementsCount, <String, int>{
        '0': 4,
        '0-0': 4,
        '0-0-0': 0,
        '0-0-0-0': 0,
        '0-0-1': 4,
      });

      when((errorEntry.callbacks as MockStorageNetworkCallbacks).onFetch())
          .thenAnswer((_) async => <TestElement>[
                const TestElement(1),
                const TestElement(2),
                const TestElement(3),
                const TestElement(4),
              ]);

      // // // Wait for fetch availability if needed.
      final diff = errorEntry.nextFetchDelayedTo!.difference(DateTime.now());
      if (!diff.isNegative) {
        await Future<void>.delayed(diff);
      }

      await syncStorage.syncEntriesWithNetwork();

      entryElementsCount = {
        for (final entry in syncStorage.traverse())
          entry.name: (await entry.storage.readAllCells()).length,
      };

      /// All elements are fetched
      expect(entryElementsCount, <String, int>{
        '0': 4,
        '0-0': 4,
        '0-0-0': 4,
        '0-0-0-0': 4,
        '0-0-1': 4,
      });
    });
  });
}
