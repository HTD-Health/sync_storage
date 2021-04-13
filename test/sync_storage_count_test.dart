import 'package:hive/hive.dart';
import 'package:mockito/mockito.dart';
import 'package:sync_storage/src/sync_storage.dart';
import 'package:sync_storage/src/storage_entry.dart';
import 'package:sync_storage/sync_storage.dart';
import 'package:test/test.dart';

import 'data.dart';

final delaysBeforeNextAttempt = <Duration>[
  Duration(microseconds: 0),
  Duration(microseconds: 0),
  Duration(microseconds: 0),
  Duration(microseconds: 0),
  Duration(microseconds: 0),
  Duration(microseconds: 0),
];

Duration getDelayBeforeNextAttempt(int attempt) =>
    delaysBeforeNextAttempt[attempt];

class HasElementValue extends CustomMatcher {
  HasElementValue(matcher) : super("Storage with id that is", "id", matcher);
  int featureValueOf(actual) => (actual as TestElement).value;
}

void main() {
  final boxNames = [for (int i = 0; i < 5; i++) 'SYNC_TEST_$i'];
  SyncStorage syncStorage;
  final List<HiveStorageMock<TestElement>> storages = [];
  final List<StorageEntry<TestElement>> entries = [];
  final networkAvailabilityService =
      MockedNetworkAvailabilityService(initialIsConnected: false);
  final networkCallbacks = StorageNetworkCallbacksMock<TestElement>();

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

    for (final name in boxNames) {
      if (await Hive.boxExists(name)) {
        await Hive.deleteBoxFromDisk(name);
      }
    }

    syncStorage = SyncStorage(
      networkAvailabilityService: networkAvailabilityService,
    );

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
          await syncStorage.registerEntry<TestElement>(
            name: boxNames[i],
            storage: storages[i],
            networkCallbacks: networkCallbacks,
            getDelayBeforeNextAttempt: getDelayBeforeNextAttempt,
          )
      ]);

    await networkAvailabilityService.goOffline();

    await syncStorage.syncEntriesWithNetwork();
  });

  tearDown(() async {
    await syncStorage.dispose();
    reset(networkCallbacks);
  });

  test("Correctly counts elements for single entry", () async {
    expect(syncStorage.elementsToSyncCount, equals(0));
    await entries[0].createElement(TestElement(0));
    expect(syncStorage.elementsToSyncCount, equals(1));
    final cell = await entries[0].createElement(TestElement(1));
    expect(syncStorage.elementsToSyncCount, equals(2));
    await entries[0].removeCell(cell);
    expect(syncStorage.elementsToSyncCount, equals(1));
  });

  test("Correctly counts elements for multiple entries", () async {
    expect(syncStorage.elementsToSyncCount, equals(0));

    for (final entry in entries) {
      await entry.createElement(TestElement(0));
    }
    expect(syncStorage.elementsToSyncCount, equals(entries.length));

    for (final entry in entries) {
      await entry.createElement(TestElement(0));
    }
    expect(syncStorage.elementsToSyncCount, equals(entries.length * 2));
  });
}
