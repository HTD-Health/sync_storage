import 'package:hive/hive.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:sync_storage/sync_storage.dart';
import 'package:test/test.dart';

import 'data.dart';
import 'sync_storage_count_test.mocks.dart';

final delaysBeforeNextAttempt = <Duration>[
  const Duration(microseconds: 0),
  const Duration(microseconds: 0),
  const Duration(microseconds: 0),
  const Duration(microseconds: 0),
  const Duration(microseconds: 0),
  const Duration(microseconds: 0),
];

Duration getDelayBeforeNextAttempt(int attempt) =>
    delaysBeforeNextAttempt[attempt];

class HasElementValue extends CustomMatcher {
  HasElementValue(dynamic matcher)
      : super('Storage with id that is', 'id', matcher);
  @override
  int? featureValueOf(dynamic actual) => (actual as TestElement).value;
}

@GenerateMocks([StorageNetworkCallbacks])
void main() {
  final boxNames = [for (int i = 0; i < 5; i++) 'SYNC_TEST_$i'];
  late SyncStorage syncStorage;
  final List<HiveStorageMock<TestElement>> storages = [];
  final List<StorageEntry<TestElement, HiveStorageMock<TestElement>>> entries =
      [];
  final networkAvailabilityService =
      MockedNetworkAvailabilityService(initialIsConnected: false);
  final networkCallbacks = MockStorageNetworkCallbacks<TestElement>();

  /// remove box if already exists
  setUpAll(() async {
    Hive.init('./');
  });

  tearDownAll(() async {
    for (final name in boxNames) {
      if (await Hive.boxExists(name)) {
        await Hive.deleteBoxFromDisk(name);
      }
    }
    networkAvailabilityService.dispose();
  });

  setUp(() async {
    when(networkCallbacks.onFetch()).thenAnswer((_) async => []);
    when(networkCallbacks.onCreate(any)).thenAnswer((_) async => null);

    for (final name in boxNames) {
      if (await Hive.boxExists(name)) {
        await Hive.deleteBoxFromDisk(name);
      }
    }

    storages
      ..clear()
      ..addAll([
        for (final name in boxNames)
          HiveStorageMock(name, const TestElementSerializer()),
      ]);

    entries
      ..clear()
      ..addAll([
        for (int i = 0; i < boxNames.length; i++)
          StorageEntry<TestElement, HiveStorageMock<TestElement>>(
            name: boxNames[i],
            storage: storages[i],
            callbacks: networkCallbacks,
            getDelayBeforeNextAttempt: getDelayBeforeNextAttempt,
          )
      ]);

    syncStorage = SyncStorage(
      children: entries,
      networkAvailabilityService: networkAvailabilityService,
    );

    await syncStorage.initialize();

    await networkAvailabilityService.goOffline();
  });

  tearDown(() async {
    await syncStorage.dispose();
    reset(networkCallbacks);
  });

  test('Correctly counts elements for single entry', () async {
    expect(syncStorage.elementsToSyncCount, equals(0));
    await entries[0].createElement(const TestElement(0));
    expect(syncStorage.elementsToSyncCount, equals(1));
    final cell = await entries[0].createElement(const TestElement(1));
    expect(syncStorage.elementsToSyncCount, equals(2));
    await entries[0].removeCell(cell);
    expect(syncStorage.elementsToSyncCount, equals(1));
  });

  test('Correctly counts elements for multiple entries', () async {
    expect(syncStorage.elementsToSyncCount, equals(0));

    for (final entry in entries) {
      await entry.createElement(const TestElement(0));
    }
    expect(syncStorage.elementsToSyncCount, equals(entries.length));

    for (final entry in entries) {
      await entry.createElement(const TestElement(0));
    }
    expect(syncStorage.elementsToSyncCount, equals(entries.length * 2));
  });

  test('lastSync field works correctly', () async {
    expect(syncStorage.lastSync, isNull);
    await networkAvailabilityService.goOnline();
    await Future<void>.delayed(const Duration(seconds: 1));
    final lastSync = syncStorage.lastSync!;
    expect(lastSync, isA<DateTime>());

    await entries.first.createElement(const TestElement(0));
    expect(syncStorage.lastSync, isA<DateTime>());

    expect(syncStorage.lastSync!.isAfter(lastSync), isTrue);
    expect(entries.last.lastSync!.isBefore(syncStorage.lastSync!), isTrue);
  });
}
