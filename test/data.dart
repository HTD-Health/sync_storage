import 'dart:async';

import 'package:sync_storage/sync_storage.dart';

class MockedNetworkAvailabilityService extends NetworkAvailabilityService {
  @override
  bool get isConnected => _isConnected;
  bool _isConnected;

  @override
  Stream<bool> get onConnectivityChanged =>
      networkAvailabilityController.stream;
  final networkAvailabilityController = StreamController<bool>.broadcast();

  MockedNetworkAvailabilityService({
    bool initialIsConnected = false,
  }) : _isConnected = initialIsConnected;

  Future<void> goOnline() async {
    networkAvailabilityController.add(true);
    _isConnected = true;

    /// wait for network changes to take effect
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  Future<void> goOffline() async {
    networkAvailabilityController.add(false);
    _isConnected = false;

    /// wait for network changes to take effect
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  @override
  Future<bool> checkConnection() async => isConnected;

  @override
  void dispose() {
    networkAvailabilityController.close();
  }
}

class InMemoryStorage<T> extends Storage<T> {
  final String name;

  final _elements = <ObjectId, StorageCell<T>>{};

  InMemoryStorage(this.name);

  @override
  StorageConfig get config => _config;
  StorageConfig _config = const StorageConfig(
    needsFetch: true,
    lastFetch: null,
    lastSync: null,
  );

  @override
  Future<void> clear() async {
    _elements.clear();
  }

  @override
  Future<void> delete() async {
    _elements.clear();
  }

  @override
  Future<void> deleteCell(StorageCell<T> cell) async {
    _elements.removeWhere((id, _) => id == cell.id);
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<void> initialize() async {}

  @override
  Future<List<StorageCell<T>>> readAllCells() {
    return Future.value(_elements.values.toList());
  }

  @override
  Future<StorageCell<T>?> readCell(ObjectId id) {
    return Future.value(_elements[id]);
  }

  @override
  Future<List<StorageCell<T>>> readNotSyncedCells() {
    final notSynced =
        _elements.values.where((c) => c.needsNetworkSync).toList();
    return Future.value(notSynced);
  }

  @override
  Future<void> writeAllCells(List<StorageCell<T>> cells) {
    _elements.addEntries(cells.map((c) => MapEntry(c.id, c)));

    return Future<void>.value();
  }

  @override
  Future<void> writeCell(StorageCell<T> cell) {
    _elements[cell.id] = cell;
    return Future<void>.value();
  }

  @override
  Future<void> writeConfig(StorageConfig config) {
    _config = config;
    return Future<void>.value();
  }
}

class TestElement {
  final int? value;

  const TestElement(this.value);
}
