import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:sync_storage/sync_storage.dart';
import 'package:test/test.dart';

import 'data.dart';
import 'sync_storage_count_test.dart';
import 'sync_storage_test.mocks.dart';

@GenerateMocks([StorageNetworkCallbacks])
void main() {
  group('SyncStorage', () {
    const boxName = 'BOX_NAME';

    final delaysBeforeNextAttempt = <Duration>[
      const Duration(microseconds: 0),
      const Duration(microseconds: 0),
      const Duration(microseconds: 0),
      const Duration(microseconds: 0),
      const Duration(microseconds: 0),
      const Duration(microseconds: 0),
    ];
    late SyncStorage syncStorage;
    late InMemoryStorage<TestElement> storage;
    late StorageEntry<TestElement, InMemoryStorage<TestElement>> entry;
    final networkAvailabilityService =
        MockedNetworkAvailabilityService(initialIsConnected: false);
    final networkCallbacks = MockStorageNetworkCallbacks<TestElement>();

    tearDownAll(() async {
      networkAvailabilityService.dispose();
    });

    setUp(() async {
      when(networkCallbacks.onFetch()).thenAnswer((_) async => []);
      when(networkCallbacks.onCreate(any)).thenAnswer((_) async => null);
      when(networkCallbacks.onDelete(any)).thenAnswer((_) async {});
      when(networkCallbacks.onUpdate(any, any)).thenAnswer((_) async => null);

      storage = InMemoryStorage(boxName);

      entry = StorageEntry<TestElement, InMemoryStorage<TestElement>>(
        name: 'test_elements',
        storage: storage,
        callbacks: networkCallbacks,
        getDelayBeforeNextAttempt: (attempt) =>
            delaysBeforeNextAttempt[attempt],
      );
      syncStorage = SyncStorage(
        networkAvailabilityService: networkAvailabilityService,
        children: [entry],
      );

      await syncStorage.initialize();

      await networkAvailabilityService.goOnline();

      await syncStorage.syncEntriesWithNetwork();

      await entry.setElements([
        for (int i = 0; i < 5; i++) TestElement(i),
      ]);
    });

    tearDown(() async {
      await syncStorage.dispose();
      reset(networkCallbacks);
    });

    test(
        'setElements with force=true removes all elements that need '
        'sync and do not cause network sync', () async {
      await networkAvailabilityService.goOffline();

      await entry.createElement(const TestElement(20));
      await entry.createElement(const TestElement(21));
      expect(entry.cellsToSync, hasLength(2));
      await entry.setElements([
        for (int i = 0; i < 10; i++) TestElement(i),
      ], force: true);
      expect(entry.cellsToSync, isEmpty);
      expect(entry.needsNetworkSync, isFalse);
      verifyNever(networkCallbacks.onCreate(any)).called(0);
      verifyNever(networkCallbacks.onUpdate(any, any)).called(0);
      verifyNever(networkCallbacks.onDelete(any)).called(0);
    });
    test(
        'setElements with force=false throws a StateError instead of removing '
        'all elements', () async {
      await networkAvailabilityService.goOffline();

      await entry.createElement(const TestElement(20));
      await entry.createElement(const TestElement(21));
      expect(entry.cellsToSync, hasLength(2));

      dynamic error;
      try {
        await entry.setElements([
          for (int i = 0; i < 10; i++) TestElement(i),
        ]);

        // ignore: avoid_catches_without_on_clauses
      } catch (e) {
        error = e;
      }

      expect(
        error,
        isA<StateError>(),
      );
      expect(entry.cellsToSync, isNotEmpty);
      expect(entry.needsNetworkSync, isTrue);
      verifyNever(networkCallbacks.onCreate(any)).called(0);
      verifyNever(networkCallbacks.onUpdate(any, any)).called(0);
      verifyNever(networkCallbacks.onDelete(any)).called(0);
    });

    test('needsNetworkSync getter works correctly.', () async {
      await networkAvailabilityService.goOffline();

      expect(entry.needsNetworkSync, isFalse);
      expect(entry.cellsToSync, isEmpty);

      final List<StorageCell<TestElement>> cells = await storage.readAll();

      expect(cells.where((cell) => cell.needsNetworkSync).isEmpty, isTrue);

      final cell = cells.first;
      cell.updateElement(const TestElement(12));
      expect(cell.needsNetworkSync, isTrue);
      await entry.updateCell(cell);

      expect(cells.where((cell) => cell.needsNetworkSync).isEmpty, isFalse);

      expect(
        entry.needsNetworkSync,
        isTrue,
      );
    });

    test('Deleting works correctly', () async {
      verifyNever(networkCallbacks.onDelete(any)).called(0);
      final List<StorageCell<TestElement>> cells = await storage.readAll();

      final cell1 = cells.first;
      final cell2 = cells.last;

      await entry.deleteCell(cell1);
      await entry.deleteCell(cell2);
      verify(
        networkCallbacks
            .onDelete(argThat(HasElementValue(equals(cell1.element.value)))),
      ).called(1);
      verify(
        networkCallbacks
            .onDelete(argThat(HasElementValue(equals(cell2.element.value)))),
      ).called(1);
      verifyNever(networkCallbacks.onCreate(any)).called(0);
      verifyNever(networkCallbacks.onUpdate(any, any)).called(0);

      expect(await storage.readAll(), hasLength(3));
    });

    test('Create works correctly', () async {
      verifyNever(networkCallbacks.onCreate(any)).called(0);

      final cell = await entry.createElement(const TestElement(100));
      final cells = await entry.createElements([
        const TestElement(101),
        const TestElement(102),
      ]);
      expect(cells, hasLength(2));
      verify(networkCallbacks.onCreate(cell.element)).called(1);
      verify(networkCallbacks.onCreate(cells[0].element)).called(1);
      verify(networkCallbacks.onCreate(cells[1].element)).called(1);
      verifyNever(networkCallbacks.onDelete(any)).called(0);
      verifyNever(networkCallbacks.onUpdate(any, any)).called(0);

      expect(await storage.readAll(), hasLength(8));
    });

    test('Update works correctly', () async {
      verifyNever(networkCallbacks.onUpdate(any, any)).called(0);

      const updatedTestElement = TestElement(200);

      final List<StorageCell<TestElement>> cells = await storage.readAll();

      final oldCell = cells.last;
      final currentElement = oldCell.element;

      expect(oldCell.element, isNot(equals(updatedTestElement)));

      oldCell.updateElement(updatedTestElement);
      await entry.updateCell(oldCell);

      expect(oldCell.element, equals(updatedTestElement));

      /// Old element will be removed after sync.
      expect(oldCell.oldElement, isNull);

      verify(networkCallbacks.onUpdate(currentElement, oldCell.element))
          .called(1);

      verifyNever(networkCallbacks.onCreate(any)).called(0);
      verifyNever(networkCallbacks.onDelete(any)).called(0);

      final List<StorageCell<TestElement>> readCells =
          await storage.readAll();
      expect(readCells, hasLength(5));
      expect(
        readCells.last.element.value,
        updatedTestElement.value,
      );
    });

    group('Offline support', () {
      test('successfully changes network state', () async {
        expect(syncStorage.network.isConnected, isTrue);
        await networkAvailabilityService.goOffline();

        /// wait for network changes to take effect
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(syncStorage.network.isConnected, isFalse);
      });

      test('Make only "create" call when not synced cell was updated',
          () async {
        await networkAvailabilityService.goOffline();

        /// wait for network changes to take effect
        await Future<void>.delayed(const Duration(milliseconds: 10));

        const newElement = TestElement(999);
        expect(entry.cellsToSync, hasLength(0));
        final storageCell = await entry.createElement(newElement);
        expect(storageCell.element.value, newElement.value);
        expect(entry.cellsToSync, hasLength(1));

        const updatedElement = TestElement(1000);
        storageCell.updateElement(updatedElement);
        await entry.updateCell(storageCell);
        expect(storageCell.element.value, updatedElement.value);
        expect(entry.cellsToSync, hasLength(1));

        /// calls
        verifyNever(networkCallbacks.onCreate(any)).called(0);
        verifyNever(networkCallbacks.onUpdate(any, any)).called(0);

        /// network become available
        await networkAvailabilityService.goOnline();

        /// calls
        verify(networkCallbacks.onCreate(updatedElement)).called(1);
        verifyNever(networkCallbacks.onUpdate(any, any)).called(0);
      });

      test('Successfully sync data when network is available', () async {
        await networkAvailabilityService.goOffline();

        expect(entry.needsNetworkSync, isFalse);
        final cell = await entry.createElement(const TestElement(100));

        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(cell.needsNetworkSync, isTrue);
        expect(entry.needsNetworkSync, isTrue);

        verifyNever(networkCallbacks.onCreate(any)).called(0);

        List<StorageCell<TestElement>> savedData = await storage.readAll();

        expect(savedData, hasLength(6));
        expect(savedData.last.needsNetworkSync, isTrue);

        await networkAvailabilityService.goOnline();

        verify(networkCallbacks.onCreate(any)).called(1);

        expect(cell.needsNetworkSync, isFalse);
        expect(entry.needsNetworkSync, isFalse);

        /// wait for save operation.
        await Future<void>.delayed(const Duration(milliseconds: 100));

        savedData = await storage.readAll();

        expect(savedData, hasLength(6));
        expect(savedData.last.needsNetworkSync, isFalse);
      });

      test(
          'Delays cell sync after sync failure and remove elements from '
          'storage after [maxNetworkSyncAttempts] reached.', () async {
        when(networkCallbacks.onCreate(any))
            .thenAnswer((_) => throw Exception());

        for (int i = 0; i < delaysBeforeNextAttempt.length; i++) {
          delaysBeforeNextAttempt[i] = Duration(milliseconds: 50 * i);
        }

        List<StorageCell<TestElement>> cells = await storage.readAll();

        /// 5 elements in storage
        expect(cells, hasLength(5));
        expect(entry.cellsToSync, hasLength(0));

        final cellFuture = entry.createElement(const TestElement(100));

        /// element is added to storage
        expect(entry.cellsToSync, hasLength(1));

        final cell = await cellFuture;
        cells = await storage.readAll();
        expect(cells, hasLength(6));

        /// make sure that after each delay cells are still delayed.
        for (var i = cell.networkSyncAttemptsCount;
            i < cell.maxNetworkSyncAttempts;
            i++) {
          expect(entry.cellsToSync, hasLength(1));
          expect(cell.isDelayed, isTrue);
          expect(
              cell.syncDelayedTo,
              (DateTime syncDelayedTo) =>
                  DateTime.now().isBefore(syncDelayedTo));
          expect(cell.needsNetworkSync, isTrue);
          expect(cell.isReadyForSync, isFalse);

          await Future<void>.delayed(
            delaysBeforeNextAttempt[cell.networkSyncAttemptsCount],
          );
          try {
            await syncStorage.syncEntriesWithNetwork();
          } on Exception {
            // ignore
          }
        }

        /// after max attempts cell should be removed from the storage
        expect(entry.cellsToSync, hasLength(0));

        cells = await storage.readAll();

        /// after [StorageCell.maxNetworkSyncAttempts] element is removed
        /// from storage.
        expect(cells, hasLength(5));

        verify(networkCallbacks.onCreate(any)).called(
          cell.maxNetworkSyncAttempts,
        );
        expect(
          cell.networkSyncAttemptsCount,
          equals(cell.maxNetworkSyncAttempts),
        );
      });
    });

    group('Move cells between entries', () {
      final networkAvailabilityService =
          MockedNetworkAvailabilityService(initialIsConnected: false);
      late SyncStorage syncStorage;
      late StorageEntry<TestElement, InMemoryStorage<TestElement>> entry1;
      late StorageEntry<TestElement, InMemoryStorage<TestElement>> entry2;
      late InMemoryStorage<TestElement> storage1;
      late InMemoryStorage<TestElement> storage2;

      setUp(() async {
        syncStorage = SyncStorage(
          networkAvailabilityService: networkAvailabilityService,
          children: [],
        );

        storage1 = InMemoryStorage<TestElement>('box1');
        storage2 = InMemoryStorage<TestElement>('box2');

        entry1 = StorageEntry<TestElement, InMemoryStorage<TestElement>>(
          name: 'box1',
          storage: storage1,
          callbacks: networkCallbacks,
        );
        entry2 = StorageEntry<TestElement, InMemoryStorage<TestElement>>(
          name: 'box2',
          storage: storage2,
          callbacks: networkCallbacks,
        );

        syncStorage
          ..addChild(entry1)
          ..addChild(entry2);
        await syncStorage.initialize();
        await networkAvailabilityService.goOnline();
        await syncStorage.syncEntriesWithNetwork();
      });

      test('Successfully moves cells between entries', () async {
        List<StorageCell<TestElement>> cells1 = await storage1.readAll();
        List<StorageCell<TestElement>> cells2 = await storage2.readAll();

        expect(entry1.needsElementsSync, isFalse);
        expect(entry2.needsElementsSync, isFalse);
        expect(cells1, hasLength(0));
        expect(cells2, hasLength(0));

        const newElement = TestElement(999);
        final cell = await entry1.createElement(newElement);
        verify(networkCallbacks.onCreate(newElement)).called(1);

        cells1 = await storage1.readAll();
        cells2 = await storage2.readAll();

        expect(entry1.needsElementsSync, isFalse);
        expect(entry2.needsElementsSync, isFalse);
        expect(cells1, hasLength(1));
        expect(cells2, hasLength(0));

        await entry1.removeCell(cell);

        cells1 = await storage1.readAll();
        cells2 = await storage2.readAll();

        expect(cell.element, equals(newElement));
        expect(entry1.needsElementsSync, isFalse);
        expect(entry2.needsElementsSync, isFalse);
        expect(cells1, hasLength(0));
        expect(cells2, hasLength(0));

        await entry2.addCell(cell);

        cells1 = await storage1.readAll();
        cells2 = await storage2.readAll();

        expect(entry1.needsElementsSync, isFalse);
        expect(entry2.needsElementsSync, isFalse);
        expect(cells1, hasLength(0));
        expect(cells2, hasLength(1));

        verifyNever(networkCallbacks.onDelete(newElement)).called(0);
        verifyNever(networkCallbacks.onCreate(newElement)).called(0);
      });

      test('Cannot add cell to the same entry multiple times', () async {
        List<StorageCell<TestElement>> cells1 = await storage1.readAll();

        expect(entry1.needsElementsSync, isFalse);
        expect(cells1, isEmpty);

        const newElement = TestElement(10);
        final cell = await entry1.createElement(newElement);
        verify(networkCallbacks.onCreate(newElement)).called(1);

        cells1 = await storage1.readAll();

        expect(entry1.needsElementsSync, isFalse);
        expect(cells1, hasLength(1));
        StateError? err;
        try {
          await entry1.addCell(cell);
          // ignore: avoid_catching_errors
        } on StateError catch (e) {
          err = e;
        }
        expect(err, isA<StateError>());

        cells1 = await storage1.readAll();
        expect(cells1, hasLength(1));
      });
    });

    group('onFetch callback works correctly', () {
      const elementsToFetch = [TestElement(0), TestElement(1)];
      const storageName = 'onFetch_test_box';

      MockStorageNetworkCallbacks<TestElement>? networkCallbacks;

      late SyncStorage syncStorage;

      setUpAll(() async {
        networkCallbacks = MockStorageNetworkCallbacks<TestElement>();
      });

      setUp(() async {
        await networkAvailabilityService.goOnline();
        syncStorage = SyncStorage(
          networkAvailabilityService: networkAvailabilityService,
          children: [],
        );
        when(networkCallbacks!.onCreate(any)).thenAnswer((_) async => null);
        when(networkCallbacks!.onFetch())
            .thenAnswer((_) async => elementsToFetch);
      });

      tearDown(() async {
        await syncStorage.dispose();
        reset(networkCallbacks);
      });

      test(
          'Do not call fetch method with entry '
          'fetch entry only after user call.', () async {
        await networkAvailabilityService.goOnline();

        verifyNever(networkCallbacks!.onFetch()).called(0);
        final storage = InMemoryStorage<TestElement>(storageName);
        entry = StorageEntry<TestElement, InMemoryStorage<TestElement>>(
          name: storageName,
          storage: storage,
          callbacks: networkCallbacks!,
        );
        syncStorage.addChild(entry);
        await syncStorage.initialize();

        verifyNever(networkCallbacks!.onFetch()).called(0);
        List<StorageCell<TestElement>> cells = await storage.readAll();
        expect(cells, isEmpty);

        await syncStorage.syncEntriesWithNetwork();
        verify(networkCallbacks!.onFetch()).called(1);
        cells = await storage.readAll();

        expect(
          cells.map((e) => e.element.value).toList(),
          equals(
            elementsToFetch.map((e) => e.value).toList(),
          ),
        );
        expect(entry.storage.config.needsFetch, isFalse);
        expect(entry.storage.config.lastFetch, isA<DateTime>());
      });

      test('Do not fetch data when already fetched.', () async {
        /// Go online
        await networkAvailabilityService.goOnline();

        /// Create entry
        /// Entry will be automatically synced with the network
        final storage = InMemoryStorage<TestElement>(storageName);
        entry = StorageEntry<TestElement, InMemoryStorage<TestElement>>(
          name: storageName,
          storage: storage,
          callbacks: networkCallbacks!,
        );
        syncStorage.addChild(entry);
        await syncStorage.initialize();

        verifyNever(networkCallbacks!.onFetch()).called(0);

        await syncStorage.syncEntriesWithNetwork();

        /// check whether entry is synced correctly
        verify(networkCallbacks!.onFetch()).called(1);

        final List<StorageCell<TestElement>> cells = await storage.readAll();
        final elements = cells.map((e) => e.element).toList();

        expect(elements, hasLength(2));
        expect(elements[0].value, elementsToFetch[0].value);
        expect(elements[1].value, elementsToFetch[1].value);
        expect(entry.storage.config.needsFetch, isFalse);
        expect(entry.storage.config.lastFetch!, isA<DateTime>());

        /// Reset callback
        reset(networkCallbacks);

        /// Dispose syncStorage
        await syncStorage.dispose();

        /// Recreate syncStorage
        syncStorage = SyncStorage(
          networkAvailabilityService: networkAvailabilityService,
          children: [],
        );

        /// Recreate entry
        entry = StorageEntry<TestElement, InMemoryStorage<TestElement>>(
          name: storageName,
          storage: storage,
          callbacks: networkCallbacks!,
        );
        syncStorage.addChild(entry);
        await syncStorage.initialize();

        /// Make sure that entry was not fetched again
        verifyNever(networkCallbacks!.onFetch()).called(0);
        expect(elements[0].value, elementsToFetch[0].value);
        expect(elements[1].value, elementsToFetch[1].value);
        expect(entry.storage.config.needsFetch, isFalse);
        expect(entry.storage.config.lastFetch, isA<DateTime>());
      });

      test('Sync entry created offline correctly.', () async {
        // Go offline
        await networkAvailabilityService.goOffline();

        // Create storage
        final storage = InMemoryStorage<TestElement>('onFetch_offline_test');

        // Create entry
        entry = StorageEntry<TestElement, InMemoryStorage<TestElement>>(
          name: 'onFetch_offline_test',
          storage: storage,
          callbacks: networkCallbacks!,
        );
        syncStorage.addChild(entry);
        await syncStorage.initialize();

        // Get currently stored cells
        List<StorageCell<TestElement>> cells = await storage.readAll();

        verifyNever(networkCallbacks!.onFetch()).called(0);
        expect(cells, hasLength(0));
        expect(entry.storage.config.needsFetch, isTrue);
        expect(entry.storage.config.lastFetch, isNull);

        /// Create elements when offline.
        const newElement1 = TestElement(10);
        const newElement2 = TestElement(11);
        await entry.createElement(newElement1);
        await entry.createElement(newElement2);

        /// Elements should not be synced when offline
        verifyNever(networkCallbacks!.onFetch()).called(0);
        verifyNever(networkCallbacks!.onCreate(any)).called(0);

        cells = await storage.readAll();
        var elements = cells.map((e) => e.element).toList();
        expect(elements, hasLength(2));
        expect(elements[0].value, equals(newElement1.value));
        expect(elements[1].value, equals(newElement2.value));

        /// Go online
        await networkAvailabilityService.goOnline();

        /// Elements are synced with network.
        verify(networkCallbacks!.onCreate(newElement1)).called(1);
        verify(networkCallbacks!.onCreate(newElement2)).called(1);
        verify(networkCallbacks!.onFetch()).called(1);

        /// Storage data is fetched from the network
        cells = await storage.readAll();
        elements = cells.map((e) => e.element).toList();
        expect(elements, hasLength(2));
        expect(elements[0].value, equals(elementsToFetch[0].value));
        expect(elements[1].value, equals(elementsToFetch[1].value));
      });
    });
  });
}
