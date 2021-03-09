import 'package:sync_storage/sync_storage.dart';
import 'package:test/test.dart';
import 'package:hive/hive.dart';

import 'data.dart';

void main() {
  group('HiveStorageController', () {
    final storageKey = 'CONFIG';
    final box1Name = 'box1';
    final box2Name = 'box2';

    HiveStorageControllerMock<TestElement> controller;
    HiveStorage<TestElement> hiveStorage1;

    setUpAll(() async {
      /// Delete config storag if exist.
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

    test('Successfully initilize controller', () async {
      await controller.initialize();
      expect(controller.initialized, isTrue);
      expect(controller.registeredStorages, hasLength(0));
    });

    test('Sucessfully creates storages', () async {
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
      await controller.deleteAllRegistredStorages();
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
  });
}
