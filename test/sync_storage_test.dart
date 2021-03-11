import 'package:hive/hive.dart';
import 'package:mockito/mockito.dart';
import 'package:sync_storage/src/sync_storage.dart';
import 'package:sync_storage/src/storage_entry.dart';
import 'package:sync_storage/sync_storage.dart';
import 'package:test/test.dart';

import 'data.dart';

void main() {
  group('SyncStorage', () {
    final boxName = 'BOX_NAME';

    final delaysBeforeNextAttempt = <Duration>[
      Duration(microseconds: 0),
      Duration(microseconds: 0),
      Duration(microseconds: 0),
      Duration(microseconds: 0),
      Duration(microseconds: 0),
      Duration(microseconds: 0),
    ];
    SyncStorage syncStorage;
    HiveStorageMock<TestElement> storage;
    StorageEntry<TestElement> entry;
    final networkAvailabilityService =
        MockedNetworkAvailabilityService(initialIsConnected: false);
    final networkCallbacks = StorageNetworkCallbacksMock<TestElement>();

    /// remove box if already exists
    setUpAll(() async {
      await Hive.deleteBoxFromDisk(boxName);
      Hive.init('./');
    });

    tearDownAll(() async {
      await Hive.deleteBoxFromDisk(boxName);
      networkAvailabilityService.dispose();
    });

    setUp(() async {
      when(networkCallbacks.onFetch()).thenAnswer((_) async => []);

      await Hive.deleteBoxFromDisk(boxName);

      syncStorage = SyncStorage(
        networkAvailabilityService: networkAvailabilityService,
      );
      storage = HiveStorageMock(boxName, const TestElementSerializer());

      entry = await syncStorage.registerEntry<TestElement>(
        name: 'test_elements',
        storage: storage,
        networkCallbacks: networkCallbacks,
        getDelayBeforeNextAttempt: (attempt) =>
            delaysBeforeNextAttempt[attempt],
      );

      await networkAvailabilityService.goOnline();

      await entry.setElements([
        for (int i = 0; i < 5; i++) TestElement(i),
      ]);
    });

    tearDown(() async {
      syncStorage.dispose();
      reset(networkCallbacks);
    });

    test(
        'setElements removes all ements that neeeds sync and do not cause network sync',
        () async {
      entry.createElement(TestElement(20));
      entry.createElement(TestElement(21));
      expect(entry.cellsToSync, hasLength(2));
      await entry.setElements([
        for (int i = 0; i < 10; i++) TestElement(i),
      ]);
      expect(entry.cellsToSync, isEmpty);
      expect(entry.needsNetworkSync, isFalse);
      verifyNever(networkCallbacks.onCreate(any)).called(0);
      verifyNever(networkCallbacks.onUpdate(any, any)).called(0);
      verifyNever(networkCallbacks.onDelete(any)).called(0);
    });

    test('needsNetworkSync getter works correctly.', () async {
      await networkAvailabilityService.goOffline();

      expect(entry.needsNetworkSync, isFalse);
      expect(entry.cellsToSync, isEmpty);

      final cells = await storage.readAllCells();

      expect(cells.where((cell) => cell.needsNetworkSync).isEmpty, isTrue);

      final cell = cells.first;
      cell.updateElement(TestElement(12));
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
      final cells = await storage.readAllCells();

      final cell1 = cells.first;
      final cell2 = cells.last;

      await entry.deleteCell(cell1);
      await entry.deleteCell(cell2);
      verify(networkCallbacks.onDelete(cell1.element)).called(1);
      verify(networkCallbacks.onDelete(cell2.element)).called(1);
      verifyNever(networkCallbacks.onCreate(any)).called(0);
      verifyNever(networkCallbacks.onUpdate(any, any)).called(0);

      expect(await storage.readAllCells(), hasLength(3));
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

      expect(await storage.readAllCells(), hasLength(8));
    });

    test('Update works correctly', () async {
      verifyNever(networkCallbacks.onUpdate(any, any)).called(0);

      final updatedTestElement = const TestElement(200);

      final cells = await storage.readAllCells();

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

      final readedCells = await storage.readAllCells();
      expect(readedCells, hasLength(5));
      expect(
        readedCells.last.element.value,
        updatedTestElement.value,
      );
    });

    group('Offline support', () {
      test('succesfully changes network state', () async {
        expect(syncStorage.networkAvailable, isTrue);
        await networkAvailabilityService.goOffline();

        /// wait for network changes to take effect
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(syncStorage.networkAvailable, isFalse);
      });

      test('Make only "create" call when not synced cell was updated',
          () async {
        await networkAvailabilityService.goOffline();

        /// wait for network changes to take effect
        await Future<void>.delayed(const Duration(milliseconds: 10));

        final newElement = const TestElement(999);
        expect(entry.cellsToSync, hasLength(0));
        final storageCell = await entry.createElement(newElement);
        expect(storageCell.element.value, newElement.value);
        expect(entry.cellsToSync, hasLength(1));

        final updatedElement = const TestElement(1000);
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

      test('Succesfully sync data when network is available', () async {
        await networkAvailabilityService.goOffline();

        expect(entry.needsNetworkSync, isFalse);
        final cell = await entry.createElement(const TestElement(100));

        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(cell.needsNetworkSync, isTrue);
        expect(entry.needsNetworkSync, isTrue);

        verifyNever(networkCallbacks.onCreate(any)).called(0);

        var savedData = await storage.readAllCells();

        expect(savedData, hasLength(6));
        expect(savedData.last.needsNetworkSync, isTrue);

        await networkAvailabilityService.goOnline();

        verify(networkCallbacks.onCreate(any)).called(1);

        expect(cell.needsNetworkSync, isFalse);
        expect(entry.needsNetworkSync, isFalse);

        /// wait for save operation.
        await Future<void>.delayed(const Duration(milliseconds: 100));

        savedData = await storage.readAllCells();

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

        var cells = await storage.readAllCells();

        /// 5 elements in storage
        expect(cells, hasLength(5));
        expect(entry.cellsToSync, hasLength(0));

        final cellFuture = entry.createElement(const TestElement(100));

        /// element is added to storage
        expect(entry.cellsToSync, hasLength(1));

        final cell = await cellFuture;
        cells = await storage.readAllCells();
        expect(cells, hasLength(6));

        /// make sure that after each delay cells are still delayed.
        for (var i = cell.networkSyncAttemptsCount;
            i < StorageCell.maxNetworkSyncAttempts;
            i++) {
          expect(entry.cellsToSync, hasLength(1));
          expect(cell.isDelayed, isTrue);
          expect(
              cell.syncDelayedTo,
              (DateTime syncDelayedTo) =>
                  DateTime.now().isBefore(syncDelayedTo));
          expect(cell.needsNetworkSync, isTrue);
          expect(cell.isReadyForSync, isFalse);

          await Future.delayed(
            delaysBeforeNextAttempt[cell.networkSyncAttemptsCount],
          );
          await syncStorage.syncEntriesWithNetwork();
        }

        /// after max attempts cell should be removed from the storage
        expect(entry.cellsToSync, hasLength(0));

        cells = await storage.readAllCells();

        /// after [StorageCell.maxNetworkSyncAttempts] element is removed
        /// from storage.
        expect(cells, hasLength(5));

        verify(networkCallbacks.onCreate(any)).called(
          StorageCell.maxNetworkSyncAttempts,
        );
        expect(
          cell.networkSyncAttemptsCount,
          equals(StorageCell.maxNetworkSyncAttempts),
        );
      });
    });

    group('Move cells between entries', () {
      final networkAvailabilityService =
          MockedNetworkAvailabilityService(initialIsConnected: false);
      final syncStorage = SyncStorage(
        networkAvailabilityService: networkAvailabilityService,
      );
      StorageEntry<TestElement> entry1;
      StorageEntry<TestElement> entry2;
      HiveStorageMock<TestElement> storage1;
      HiveStorageMock<TestElement> storage2;

      setUpAll(() async {
        storage1 = HiveStorageMock<TestElement>(
          'box1',
          const TestElementSerializer(),
        );
        storage2 = HiveStorageMock<TestElement>(
          'box2',
          const TestElementSerializer(),
        );

        entry1 = await syncStorage.registerEntry<TestElement>(
          name: 'box1',
          storage: storage1,
          networkCallbacks: networkCallbacks,
        );
        entry2 = await syncStorage.registerEntry<TestElement>(
          name: 'box2',
          storage: storage2,
          networkCallbacks: networkCallbacks,
        );

        await Future.wait([
          entry1.initialize(),
          entry2.initialize(),
        ]);
      });

      tearDownAll(() async {
        await Future.wait([
          Hive.deleteBoxFromDisk('box1'),
          Hive.deleteBoxFromDisk('box2'),
        ]);
      });

      test('Succesfully moves cells between entries', () async {
        await networkAvailabilityService.goOffline();

        var cells1 = await storage1.readAllCells();
        var cells2 = await storage2.readAllCells();

        expect(entry1.needsElementsSync, isFalse);
        expect(entry2.needsElementsSync, isFalse);
        expect(cells1, hasLength(0));
        expect(cells2, hasLength(0));

        final newElement = const TestElement(999);
        final cell = await entry1.createElement(newElement);

        cells1 = await storage1.readAllCells();
        cells2 = await storage2.readAllCells();

        expect(entry1.needsElementsSync, isTrue);
        expect(entry2.needsElementsSync, isFalse);
        expect(cells1, hasLength(1));
        expect(cells2, hasLength(0));

        await entry1.deleteCell(cell);

        cells1 = await storage1.readAllCells();
        cells2 = await storage2.readAllCells();

        expect(cell.element, equals(newElement));
        expect(entry1.needsElementsSync, isFalse);
        expect(entry2.needsElementsSync, isFalse);
        expect(cells1, hasLength(0));
        expect(cells2, hasLength(0));

        await entry2.addCell(cell);

        cells1 = await storage1.readAllCells();
        cells2 = await storage2.readAllCells();

        expect(entry1.needsElementsSync, isFalse);
        expect(entry2.needsElementsSync, isTrue);
        expect(cells1, hasLength(0));
        expect(cells2, hasLength(1));

        verifyNever(networkCallbacks.onCreate(newElement)).called(0);

        await networkAvailabilityService.goOnline();

        verify(networkCallbacks.onCreate(newElement)).called(1);
      });
    });
    group('onFetch callback works correctly', () {
      const elementsToFetch = [TestElement(0), TestElement(1)];
      const boxName = 'onFetch_test_box';

      StorageNetworkCallbacksMock<TestElement> networkCallbacks;

      SyncStorage syncStorage;

      tearDownAll(() async {
        await Hive.deleteBoxFromDisk(boxName);
      });

      setUpAll(() async {
        networkCallbacks = StorageNetworkCallbacksMock<TestElement>();
      });

      setUp(() async {
        await networkAvailabilityService.goOnline();
        syncStorage = SyncStorage(
          networkAvailabilityService: networkAvailabilityService,
        );

        when(networkCallbacks.onFetch())
            .thenAnswer((_) async => elementsToFetch);
      });

      tearDown(() async {
        Future<void> deleteStorage(StorageEntry<dynamic> entry) =>
            entry.storage.delete();

        await Future.wait(syncStorage.entries.map(deleteStorage));
        await syncStorage.dispose();
        reset(networkCallbacks);
      });

      test(
          'Successfully calls fetch method with entry '
          'registration when network is available.', () async {
        await networkAvailabilityService.goOnline();

        verifyNever(networkCallbacks.onFetch()).called(0);
        final storage = HiveStorageMock(boxName, const TestElementSerializer());
        entry = await syncStorage.registerEntry<TestElement>(
          name: boxName,
          storage: storage,
          networkCallbacks: networkCallbacks,
        );

        verify(networkCallbacks.onFetch()).called(1);
        final cells = await storage.readAllCells();

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
        var storage = HiveStorageMock(boxName, const TestElementSerializer());
        entry = await syncStorage.registerEntry<TestElement>(
          name: boxName,
          storage: storage,
          networkCallbacks: networkCallbacks,
        );

        /// check whether entry is synced correctly
        verify(networkCallbacks.onFetch()).called(1);

        final cells = await storage.readAllCells();
        final elements = cells.map((e) => e.element).toList();

        expect(elements, hasLength(2));
        expect(elements[0].value, elementsToFetch[0].value);
        expect(elements[1].value, elementsToFetch[1].value);
        expect(entry.storage.config.needsFetch, isFalse);
        expect(entry.storage.config.lastFetch, isA<DateTime>());

        /// Reset callback
        reset(networkCallbacks);

        /// Remove registred entries from syncStorage
        await syncStorage.disposeAllEntries();

        /// Recreate entry
        storage = HiveStorageMock(boxName, const TestElementSerializer());
        entry = await syncStorage.registerEntry<TestElement>(
          name: boxName,
          storage: storage,
          networkCallbacks: networkCallbacks,
        );

        /// Make sure that entry was not fetched again
        verifyNever(networkCallbacks.onFetch()).called(0);
        expect(elements[0].value, elementsToFetch[0].value);
        expect(elements[1].value, elementsToFetch[1].value);
        expect(entry.storage.config.needsFetch, isFalse);
        expect(entry.storage.config.lastFetch, isA<DateTime>());
      });

      test('Sync entry created offline correctly.', () async {
        /// Go offline
        await networkAvailabilityService.goOffline();

        final storage = HiveStorageMock(
          'onFetch_offline_test',
          const TestElementSerializer(),
        );

        /// Create entry
        entry = await syncStorage.registerEntry<TestElement>(
          name: 'onFetch_offline_test',
          storage: storage,
          networkCallbacks: networkCallbacks,
        );

        var cells = await storage.readAllCells();

        verifyNever(networkCallbacks.onFetch()).called(0);
        expect(cells, hasLength(0));
        expect(entry.storage.config.needsFetch, isTrue);
        expect(entry.storage.config.lastFetch, isNull);

        /// Create elements when offline.
        final newElement1 = const TestElement(10);
        final newElement2 = const TestElement(11);
        await entry.createElement(newElement1);
        await entry.createElement(newElement2);

        /// Elements should not be synced when offline
        verifyNever(networkCallbacks.onFetch()).called(0);
        verifyNever(networkCallbacks.onCreate(any)).called(0);

        cells = await storage.readAllCells();
        var elements = cells.map((e) => e.element).toList();
        expect(elements, hasLength(2));
        expect(elements[0].value, equals(newElement1.value));
        expect(elements[1].value, equals(newElement2.value));

        /// Go online
        await networkAvailabilityService.goOnline();

        /// Elements are synced with network.
        verify(networkCallbacks.onCreate(newElement1)).called(1);
        verify(networkCallbacks.onCreate(newElement2)).called(1);
        verify(networkCallbacks.onFetch()).called(1);

        /// Storage data is fetched from the network
        cells = await storage.readAllCells();
        elements = cells.map((e) => e.element).toList();
        expect(elements, hasLength(2));
        expect(elements[0].value, equals(elementsToFetch[0].value));
        expect(elements[1].value, equals(elementsToFetch[1].value));
      });
    });
  });
}
