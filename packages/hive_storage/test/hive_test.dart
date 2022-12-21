import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:hive_storage/hive_storage.dart';
import 'package:sync_storage/sync_storage.dart';

import 'data.dart';

void main() {
  group('HiveStorageController', () {
    const storageKey = 'CONFIG';
    const box1Name = 'box1';
    const box2Name = 'box2';

    late HiveStorageControllerMock<TestElement> controller;
    HiveStorage<TestElement> hiveStorage1;

    setUpAll(() async {
      /// Delete config storage if exist.
      Hive.init('./');
      await Hive.deleteBoxFromDisk(storageKey);
    });

    test('Successfully creates controller', () async {
      controller = HiveStorageControllerMock<TestElement>(
        storageKey,
        const TestElementSerializer(),
      );

      expect(controller.initialized, isFalse);
      expect(
        () async => controller.registeredStorages,
        throwsA(isA<StateError>()),
      );
    });

    test('Successfully initialize controller', () async {
      await controller.initialize();
      expect(controller.initialized, isTrue);
      expect(controller.registeredStorages, hasLength(0));
    });

    test('Successfully creates storages', () async {
      hiveStorage1 = controller.getStorage(box1Name);
      controller.getStorage(box2Name);
      expect(hiveStorage1, isNotNull);
      expect(hiveStorage1, isA<HiveStorage<TestElement>>());
      expect(hiveStorage1.serializer, equals(controller.serializer));
      expect(controller.registeredStorages, equals([box1Name, box2Name]));
    });

    test('Deletes storage', () async {
      await controller.deleteStorageWithName(box1Name);
      expect(controller.registeredStorages, equals([box2Name]));
    });

    test('Deletes all storages', () async {
      controller.getStorage('box3');
      controller.getStorage('box4');
      controller.getStorage('box5');
      expect(
        controller.registeredStorages,
        equals([
          'box2',
          'box3',
          'box4',
          'box5',
        ]),
      );
      await controller.deleteAllRegisteredStorages();
      expect(controller.registeredStorages, hasLength(0));
    });

    test('Disposes correctly', () async {
      expect(controller.disposed, isFalse);

      await controller.dispose();

      expect(controller.disposed, isTrue);

      expect(controller.dispose, throwsA(isA<StateError>()));
      expect(
        () async => controller.getStorage('newBox'),
        throwsA(isA<StateError>()),
      );
    });

    test('Serialization works correctly', () async {
      final cell = StorageCell.synced(element: const TestElement(1));
      const encoder =
          StorageCellJsonEncoder(serializer: TestElementSerializer());
      const decoder =
          StorageCellJsonDecoder(serializer: TestElementSerializer());

      final jsonEncodedCell = encoder.convert(cell);
      final jsonDecodedCell = decoder.convert(jsonEncodedCell);

      expect(jsonDecodedCell.id, equals(cell.id));
      expect(jsonDecodedCell.createdAt, equals(cell.createdAt));
      expect(jsonDecodedCell.updatedAt, equals(cell.updatedAt));
      expect(jsonDecodedCell.lastSync, equals(cell.lastSync));
      expect(jsonDecodedCell.syncDelayedTo, equals(cell.syncDelayedTo));
      expect(jsonDecodedCell.deleted, equals(cell.deleted));
      expect(jsonDecodedCell.element.value, equals(cell.element.value));
      expect(jsonDecodedCell.oldElement, equals(cell.oldElement));
      expect(jsonDecodedCell.isReadyForSync, equals(cell.isReadyForSync));
      expect(jsonDecodedCell.isDelayed, equals(cell.isDelayed));
      expect(jsonDecodedCell.maxSyncAttemptsReached,
          equals(cell.maxSyncAttemptsReached));
      expect(jsonDecodedCell.needsNetworkSync, equals(cell.needsNetworkSync));
      expect(jsonDecodedCell.networkSyncAttemptsCount,
          equals(cell.networkSyncAttemptsCount));
      expect(jsonDecodedCell.wasSynced, equals(cell.wasSynced));
      expect(jsonDecodedCell.actionNeeded, equals(cell.actionNeeded));
    });
  });
}
