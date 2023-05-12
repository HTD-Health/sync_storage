import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:sync_storage/sync_storage.dart';
import 'package:test/test.dart';

import 'data.dart';
import 'sync_storage_test.mocks.dart';
import 'utils/matchers.dart';

List<StorageCell<TestElement>> createCells() =>
    List.generate(5, TestElement.new)
        .map((e) => StorageCell<TestElement>(element: e))
        .toList();

@GenerateMocks([StorageNetworkCallbacks])
void main() {
  group('SyncStorage - initialize -', () {
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

      await networkAvailabilityService.goOnline();
    });

    tearDown(() async {
      reset(networkCallbacks);
    });

    test('Initializes correctly when there are no errors.', () async {
      final storage1 = InMemoryStorage<TestElement>('storage_1');
      final storage2 = InMemoryStorage<TestElement>('storage_2');

      final entry2 = StorageEntry<TestElement, InMemoryStorage<TestElement>>(
        name: 'test_elements',
        storage: storage2,
        callbacks: networkCallbacks,
      );
      final entry1 = StorageEntry<TestElement, InMemoryStorage<TestElement>>(
        name: 'test_elements',
        storage: storage1,
        callbacks: networkCallbacks,
        children: [entry2],
      );
      final syncStorage = SyncStorage(
        networkAvailabilityService: networkAvailabilityService,
        children: [entry1],
      );

      await entry1.setElements([
        for (int i = 0; i < 5; i++) TestElement(i),
      ]);
      await entry2.setElements([
        for (int i = 0; i < 5; i++) TestElement(i),
      ]);
      await syncStorage.initialize();
      await syncStorage.syncEntriesWithNetwork();
    });

    test(
        'Throws error during initialization when clearOnError is set to false.',
        () async {
      final storage1 = InMemoryStorage<TestElement>(
        'storage_1',
        throwDuringInit: true,
      );
      final storage2 = InMemoryStorage<TestElement>('storage_2');

      final entry2 = StorageEntry<TestElement, InMemoryStorage<TestElement>>(
        name: 'test_elements',
        storage: storage2,
        callbacks: networkCallbacks,
        clearOnError: false,
      );
      final entry1 = StorageEntry<TestElement, InMemoryStorage<TestElement>>(
        name: 'test_elements',
        storage: storage1,
        callbacks: networkCallbacks,
        children: [entry2],
        clearOnError: false,
      );
      final syncStorage = SyncStorage(
        networkAvailabilityService: networkAvailabilityService,
        children: [entry1],
      );

      storage1.writeAll(createCells());
      storage2.writeAll(createCells());

      expect(
        () async => syncStorage.initialize(),
        throwsA(isA<FakeException>()),
      );
    });

    /// Make sure that database read and initialization errors are handled
    for (final storage1 in [
      InMemoryStorage<TestElement>('storage_1', throwDuringInit: true),
      InMemoryStorage<TestElement>('storage_1', throwDuringRead: true),
    ]) {
      test(
          'Clears storage when error is throw during initialization '
          '(throwDuringInit: ${storage1.throwDuringInit}, '
          'throwDuringRead: ${storage1.throwDuringRead}) '
          'and clearOnError is set to true.', () async {
        final storage2 = InMemoryStorage<TestElement>('storage_2');

        final entry2 = StorageEntry<TestElement, InMemoryStorage<TestElement>>(
          name: 'test_elements',
          storage: storage2,
          callbacks: networkCallbacks,
          clearOnError: false,
        );
        final entry1 = StorageEntry<TestElement, InMemoryStorage<TestElement>>(
          name: 'test_elements',
          storage: storage1,
          callbacks: networkCallbacks,
          children: [entry2],
          clearOnError: true,
        );
        final syncStorage = SyncStorage(
          networkAvailabilityService: networkAvailabilityService,
          children: [entry1],
        );

        storage1.writeAll(createCells());
        storage2.writeAll(createCells());

        when(networkCallbacks.onFetch())
            .thenAnswer((_) async => [const TestElement(100)]);

        await syncStorage.initialize();

        /// Disable fake errors
        storage1.throwDuringRead = false;

        var storage1Cells = await storage1.readAll();
        // data deleted during init
        expect(storage1Cells, hasLength(0));

        var storage2Cells = await storage2.readAll();
        // data not deleted
        expect(storage2Cells, hasLength(5));
        expect(
          storage2Cells,
          equals([
            for (int i = 0; i < 5; i++) testElementValueEquals(i),
          ]),
        );

        await syncStorage.syncEntriesWithNetwork();

        storage1Cells = await storage1.readAll();
        // new data fetched
        expect(storage1Cells, hasLength(1));
        expect(storage1Cells.first, testElementValueEquals(100));

        storage2Cells = await storage2.readAll();
        // data not deleted
        expect(storage2Cells, hasLength(1));
        expect(storage2Cells.first, testElementValueEquals(100));
      });
    }
  });
}
