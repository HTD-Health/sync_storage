import 'package:sync_storage/sync_storage.dart';
import 'package:test/test.dart';

import 'data.dart';

void main() {
  group('StorageCell', () {
    test('Instantiate correctly with default constructor', () {
      final cell = StorageCell(element: const TestElement(1));
      expect(cell.actionNeeded, equals(SyncAction.create));
      expect(cell.createdAt, isA<DateTime>());
      expect(cell.updatedAt, isNull);
      expect(cell.deleted, isFalse);
      expect(cell.id, isA<ObjectId>());
      expect(cell.isDelayed, isFalse);
      expect(cell.lastSync, isNull);
      expect(cell.maxSyncAttemptsReached, isFalse);
      expect(cell.needsNetworkSync, isTrue);
      expect(cell.oldElement, isNull);
      expect(cell.syncDelayedTo, isNull);
      expect(cell.wasSynced, isFalse);
    });

    test('Instantiate correctly with synced constructor', () {
      final cell = StorageCell.synced(element: const TestElement(1));
      expect(cell.actionNeeded, equals(SyncAction.none));
      expect(cell.createdAt, isA<DateTime>());
      expect(cell.lastSync, equals(cell.createdAt));
      expect(cell.updatedAt, isNull);
      expect(cell.deleted, isFalse);
      expect(cell.id, isA<ObjectId>());
      expect(cell.isDelayed, isFalse);
      expect(cell.maxSyncAttemptsReached, isFalse);
      expect(cell.needsNetworkSync, isFalse);
      expect(cell.oldElement, isNull);
      expect(cell.syncDelayedTo, isNull);
      expect(cell.wasSynced, isTrue);
    });

    test('Copy method works correctly', () {
      final cell = StorageCell(element: const TestElement(1));
      final copiedCell = cell.copy();

      expect(cell.runtimeType, equals(copiedCell.runtimeType));
      expect(copiedCell.id, equals(cell.id));
      expect(copiedCell.isReadyForSync, equals(cell.isReadyForSync));
      expect(copiedCell.isDelayed, equals(cell.isDelayed));
      expect(copiedCell.createdAt, equals(cell.createdAt));
      expect(copiedCell.updatedAt, equals(cell.updatedAt));
      expect(copiedCell.lastSync, equals(cell.lastSync));
      expect(copiedCell.syncDelayedTo, equals(cell.syncDelayedTo));
      expect(copiedCell.deleted, equals(cell.deleted));
      expect(copiedCell.element.value, equals(cell.element.value));
      expect(copiedCell.oldElement, equals(cell.oldElement));
      expect(copiedCell.maxSyncAttemptsReached,
          equals(cell.maxSyncAttemptsReached));
      expect(copiedCell.needsNetworkSync, equals(cell.needsNetworkSync));
      expect(copiedCell.networkSyncAttemptsCount,
          equals(cell.networkSyncAttemptsCount));
      expect(copiedCell.wasSynced, equals(cell.wasSynced));
      expect(copiedCell.actionNeeded, equals(cell.actionNeeded));
    });

    group('Delay works correctly', () {
      test('with default delay function', () async {
        final cell = StorageCell(element: const TestElement(1));
        expect(cell.isDelayed, isFalse);
        expect(cell.syncDelayedTo, isNull);
        expect(cell.needsNetworkSync, isTrue);
        expect(cell.isReadyForSync, isTrue);

        cell.registerSyncAttempt(
          getDelayBeforeNextAttempt: defaultGetDelayBeforeNextAttempt,
        );

        expect(cell.isDelayed, isTrue);
        expect(cell.syncDelayedTo, isNotNull);
        expect(cell.needsNetworkSync, isTrue);
        expect(cell.isReadyForSync, isFalse);

        await Future<void>.delayed(const Duration(milliseconds: 1200));

        expect(cell.isDelayed, isFalse);
        expect(cell.syncDelayedTo, isNotNull);
        expect(cell.needsNetworkSync, isTrue);
        expect(cell.isReadyForSync, isTrue);
      });

      test('cannot delay already delayed cell', () async {
        final cell = StorageCell(element: const TestElement(1));
        cell.registerSyncAttempt(
            getDelayBeforeNextAttempt: defaultGetDelayBeforeNextAttempt);
        expect(
          () => cell.registerSyncAttempt(
              getDelayBeforeNextAttempt: defaultGetDelayBeforeNextAttempt),
          throwsA(
            isA<StateError>(),
          ),
        );
      });

      test('with custom delay function', () async {
        final cell = StorageCell(element: const TestElement(1));
        expect(cell.syncDelayedTo, isNull);

        while (
            cell.networkSyncAttemptsCount < cell.maxNetworkSyncAttempts - 1) {
          expect(cell.isDelayed, isFalse);
          expect(cell.needsNetworkSync, isTrue);
          expect(cell.isReadyForSync, isTrue);

          cell.registerSyncAttempt(
            getDelayBeforeNextAttempt: (_) => const Duration(milliseconds: 100),
          );

          expect(cell.isDelayed, isTrue);
          expect(cell.syncDelayedTo, isNotNull);
          expect(cell.needsNetworkSync, isTrue);
          expect(cell.isReadyForSync, isFalse);
          expect(cell.actionNeeded, SyncAction.create);

          await Future<void>.delayed(const Duration(milliseconds: 150));
        }

        cell.registerSyncAttempt(
          getDelayBeforeNextAttempt: (_) => const Duration(milliseconds: 100),
        );

        expect(cell.maxSyncAttemptsReached, isTrue);
        expect(cell.isDelayed, isTrue);
        expect(cell.syncDelayedTo, isNotNull);
        expect(cell.needsNetworkSync, isTrue);
        expect(cell.isReadyForSync, isFalse);
        expect(cell.actionNeeded, SyncAction.create);
      });
    });

    test('Serialization works correctly', () async {
      final cell = StorageCell.synced(element: const TestElement(1));

      final jsonEncodedCell = cell.toJson(const TestElementSerializer());
      final jsonDecodedCell =
          StorageCell.fromJson(jsonEncodedCell, const TestElementSerializer());

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

    test(
        'Updating cell that was not created on the network '
        'will still require create action.', () {
      const element1 = TestElement(1);
      final cell = StorageCell(element: element1);
      expect(cell.actionNeeded, equals(SyncAction.create));
      expect(cell.oldElement, isNull);

      const element2 = TestElement(2);
      cell.updateElement(element2);

      expect(cell.actionNeeded, equals(SyncAction.create));
      expect(cell.oldElement, equals(element1));
    });

    test(
        'Updating cell that was not created on the network '
        'will still require create action.', () {
      const element1 = TestElement(1);
      final cell = StorageCell(element: element1);
      expect(cell.actionNeeded, equals(SyncAction.create));
      expect(cell.oldElement, isNull);

      const element2 = TestElement(2);
      cell.updateElement(element2);

      expect(cell.actionNeeded, equals(SyncAction.create));
      expect(cell.oldElement, equals(element1));
    });

    test('markAsSynced method works correctly', () {
      final cell = StorageCell(element: const TestElement(1));
      expect(cell.actionNeeded, equals(SyncAction.create));
      expect(cell.needsNetworkSync, isTrue);
      expect(cell.wasSynced, isFalse);
      expect(cell.lastSync, isNull);

      cell.markAsSynced();
      expect(cell.actionNeeded, equals(SyncAction.none));
      expect(cell.needsNetworkSync, isFalse);
      expect(cell.wasSynced, isTrue);
      expect(cell.lastSync, isNotNull);
    });

    group('cell deletion', () {
      test('works correctly for a new cell', () {
        const element1 = TestElement(1);
        final cell = StorageCell(element: element1);
        expect(cell.actionNeeded, equals(SyncAction.create));
        expect(cell.deleted, isFalse);

        cell.markAsDeleted();

        expect(cell.deleted, isTrue);
        expect(cell.needsNetworkSync, isTrue);
        expect(cell.actionNeeded, equals(SyncAction.delete));
      });

      test('works correctly for updated cell', () {
        final cell = StorageCell(element: const TestElement(1));
        cell.markAsSynced();
        expect(cell.actionNeeded, equals(SyncAction.none));

        cell.updateElement(const TestElement(2));
        expect(cell.actionNeeded, equals(SyncAction.update));

        cell.markAsDeleted();

        expect(cell.deleted, isTrue);
        expect(cell.actionNeeded, equals(SyncAction.delete));
      });
    });

    group('cell update', () {
      test('Update method works correctly', () {
        const element1 = TestElement(1);
        final cell = StorageCell(element: element1);
        expect(cell.actionNeeded, equals(SyncAction.create));
        expect(cell.oldElement, isNull);

        cell.markAsSynced();

        expect(cell.actionNeeded, equals(SyncAction.none));

        const element2 = TestElement(2);
        cell.updateElement(element2);

        expect(cell.actionNeeded, equals(SyncAction.update));
        expect(cell.oldElement, equals(element1));
      });

      test('Cannot update deleted cell', () {
        final cell = StorageCell(element: const TestElement(1));
        cell.markAsDeleted();
        expect(cell.actionNeeded, equals(SyncAction.delete));
        expect(cell.needsNetworkSync, isTrue);

        expect(
          () => cell.updateElement(const TestElement(2)),
          throwsA(isA<StateError>()),
        );
        expect(cell.actionNeeded, equals(SyncAction.delete));
        expect(cell.needsNetworkSync, isTrue);
      });

      test('Cannot update element with itself.', () {
        const element = TestElement(1);
        final cell = StorageCell(element: element);
        expect(
          () => cell.updateElement(element),
          throwsA(isA<ArgumentError>()),
        );
      });
    });
  });
}
