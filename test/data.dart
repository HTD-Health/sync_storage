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
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  Future<void> goOffline() async {
    networkAvailabilityController.add(false);
    _isConnected = false;

    /// wait for network changes to take effect
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  @override
  Future<bool> checkConnection() async => isConnected;

  @override
  void dispose() {
    networkAvailabilityController.close();
  }
}

class FakeException implements Exception {
  final String message;

  FakeException(this.message);

  @override
  String toString() => 'FakeException: $message';
}

class InMemoryStorage<T> extends Storage<T> {
  final String name;

  bool throwDuringInit;
  bool throwDuringRead;

  final _elements = <ObjectId, StorageCell<T>>{};

  InMemoryStorage(
    this.name, {
    this.throwDuringInit = false,
    this.throwDuringRead = false,
  });

  @override
  StorageConfig get config => _config;
  StorageConfig _config = const StorageConfig(
    needsFetch: true,
    lastFetch: null,
    lastSync: null,
  );

  @override
  Future<void> clear() {
    _elements.clear();
    return Future<void>.value();
  }

  @override
  Future<void> delete(StorageCell<T> cell) {
    _elements.removeWhere((id, _) => id == cell.id);
    return Future<void>.value();
  }

  @override
  Future<void> dispose() {
    return Future<void>.value();
  }

  @override
  Future<void> initialize() {
    if (throwDuringInit) {
      throw FakeException('initialize()');
    }
    return Future<void>.value();
  }

  @override
  Future<List<StorageCell<T>>> readAll() {
    if (throwDuringRead) {
      throw FakeException('readAll()');
    }
    return Future.value(_elements.values.toList());
  }

  @override
  Future<StorageCell<T>?> read(ObjectId id) {
    if (throwDuringRead) {
      throw FakeException('read(${id})');
    }
    return Future.value(_elements[id]);
  }

  @override
  Future<List<StorageCell<T>>> readNotSynced() {
    if (throwDuringRead) {
      throw FakeException('readNotSynced()');
    }
    final notSynced =
        _elements.values.where((c) => c.needsNetworkSync).toList();
    return Future.value(notSynced);
  }

  @override
  Future<void> writeAll(List<StorageCell<T>> cells) {
    _elements
      ..clear()
      ..addEntries(cells.map((c) => MapEntry(c.id, c)));

    return Future<void>.value();
  }

  @override
  Future<void> write(StorageCell<T> cell) {
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

  @override
  String toString() => 'TestElement(${value})';
}
