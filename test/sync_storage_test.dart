import 'dart:async';

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

    SyncStorage syncStorage;
    HiveStorageMock<TestElement> storage;
    StorageEntry<TestElement> entry;
    final networkAvailabilityService =
        MockedNetworkAvailabilityService(initialIsConnected: false);
    final networkCallbacks = StorageNetworkCallbacksMock<TestElement>();

    /// remove box if already exists
    setUpAll(() async {
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
        initialNetworkAvailable: true,
      );
      storage = HiveStorageMock(boxName, const TestElementSerializer());

      entry = await syncStorage.registerEntry<TestElement>(
        name: 'test_elements',
        storage: storage,
        networkCallbacks: networkCallbacks,
      );

      networkAvailabilityService.goOnline();

      await Future<void>.delayed(const Duration());

      await entry.setElements([
        for (int i = 0; i < 5; i++) TestElement(i),
      ]);
    });

    tearDown(() async {
      syncStorage.dispose();
      reset(networkCallbacks);
    });

    test(
        'Succesfully feel storage without notyfing '
        'network about changes.', () async {
      expect(entry.cells, hasLength(5));
      await entry.setElements([
        for (int i = 0; i < 10; i++) TestElement(i),
      ]);
      expect(entry.cells, hasLength(10));
      expect(entry.needsNetworkSync, isFalse);
      verifyNever(networkCallbacks.onCreate(any)).called(0);
      verifyNever(networkCallbacks.onUpdate(any, any)).called(0);
      verifyNever(networkCallbacks.onDelete(any)).called(0);
    });

    test('needsNetworkSync getters works correctly.', () async {
      expect(
        entry.needsNetworkSync,
        isFalse,
      );

      final firstEntry = entry.cells.first;

      expect(firstEntry.deleted, isFalse);
      expect(firstEntry.needsNetworkSync, isFalse);
      entry.cells.first.deleted = true;
      expect(firstEntry.deleted, isTrue);
      expect(firstEntry.needsNetworkSync, isTrue);

      expect(
        entry.needsNetworkSync,
        isTrue,
      );
    });

    test('Deleting works correctly', () async {
      verifyNever(networkCallbacks.onDelete(any)).called(0);

      final cell = await entry.deleteElementWhere((cell) => cell.value == 2);
      final cell2 = await entry.deleteElementWhere((cell) => cell.value == 3);
      verify(networkCallbacks.onDelete(cell.element)).called(1);
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

      final oldCell = entry.cells.last;
      final currentElement = oldCell.element;

      expect(oldCell.element, isNot(equals(updatedTestElement)));
      final updated = await entry.updateElementWhere(
        (element) => element.value == oldCell.element.value,
        updatedTestElement,
      );

      expect(oldCell, equals(updated));
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
        await entry.updateElementWhere(
            (element) => element.value == newElement.value, updatedElement);
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
          'Remove elements from storage after [maxNetworkSyncAttempts] reached.',
          () async {
        when(networkCallbacks.onCreate(any))
            .thenAnswer((_) => throw Exception());

        /// 5 elements in storage
        expect(entry.cells, hasLength(5));

        final cellFuture = entry.createElement(const TestElement(100));

        /// element is added to storage
        expect(entry.cells, hasLength(6));

        final cell = await cellFuture;

        /// after [StorageCell.maxNetworkSyncAttempts] element is removed
        /// from storage.
        expect(entry.cells, hasLength(5));

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

      setUpAll(() async {
        entry1 = await syncStorage.registerEntry<TestElement>(
          name: 'box1',
          storage: HiveStorageMock('box1', const TestElementSerializer()),
          networkCallbacks: networkCallbacks,
        );
        entry2 = await syncStorage.registerEntry<TestElement>(
          name: 'box2',
          storage: HiveStorageMock('box2', const TestElementSerializer()),
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

        expect(entry1.needsElementsSync, isFalse);
        expect(entry2.needsElementsSync, isFalse);
        expect(entry1.cells, hasLength(0));
        expect(entry2.cells, hasLength(0));

        final newElement = const TestElement(999);
        entry1.createElement(newElement);

        expect(entry1.needsElementsSync, isTrue);
        expect(entry2.needsElementsSync, isFalse);
        expect(entry1.cells, hasLength(1));
        expect(entry2.cells, hasLength(0));

        final removedCell =
            entry1.removeCellWhere((element) => element.value == 999);

        expect(removedCell.element, equals(newElement));
        expect(entry1.needsElementsSync, isFalse);
        expect(entry2.needsElementsSync, isFalse);
        expect(entry1.cells, hasLength(0));
        expect(entry2.cells, hasLength(0));

        await entry2.putCell(removedCell);
        expect(entry1.needsElementsSync, isFalse);
        expect(entry2.needsElementsSync, isTrue);
        expect(entry1.cells, hasLength(0));
        expect(entry2.cells, hasLength(1));

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
          initialNetworkAvailable: true,
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

        entry = await syncStorage.registerEntry<TestElement>(
          name: boxName,
          storage: HiveStorageMock(boxName, const TestElementSerializer()),
          networkCallbacks: networkCallbacks,
        );

        expect(entry.elements, equals(elementsToFetch));
        expect(entry.storage.config.needsFetch, isFalse);
        expect(entry.storage.config.lastFetch, isA<DateTime>());

        verify(networkCallbacks.onFetch()).called(1);
      });

      test('Do not fetch data when already fetched.', () async {
        /// Go online
        await networkAvailabilityService.goOnline();

        /// Create entry
        /// Entry will be automatically synced with the network
        entry = await syncStorage.registerEntry<TestElement>(
          name: boxName,
          storage: HiveStorageMock(boxName, const TestElementSerializer()),
          networkCallbacks: networkCallbacks,
        );

        /// check whether entry is synced correctly
        verify(networkCallbacks.onFetch()).called(1);
        final elements = entry.elements.toList();
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
        entry = await syncStorage.registerEntry<TestElement>(
          name: boxName,
          storage: HiveStorageMock(boxName, const TestElementSerializer()),
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

        /// Create entry
        entry = await syncStorage.registerEntry<TestElement>(
          name: 'onFetch_offline_test',
          storage: HiveStorageMock(
              'onFetch_offline_test', const TestElementSerializer()),
          networkCallbacks: networkCallbacks,
        );

        verifyNever(networkCallbacks.onFetch()).called(0);
        expect(entry.cells, hasLength(0));
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

        /// Elements are saved to storage
        var elements = entry.elements.toList();
        expect(elements, hasLength(2));
        expect(elements[0], equals(newElement1));
        expect(elements[1], equals(newElement2));

        /// Go online
        await networkAvailabilityService.goOnline();

        /// Elements are synced with network.
        verify(networkCallbacks.onCreate(newElement1)).called(1);
        verify(networkCallbacks.onCreate(newElement2)).called(1);
        verify(networkCallbacks.onFetch()).called(1);

        /// Storage data is fetched from the network
        elements = entry.elements.toList();
        expect(elements, hasLength(2));
        expect(elements[0], equals(elementsToFetch[0]));
        expect(elements[1], equals(elementsToFetch[1]));
      });
    });
  });
}
