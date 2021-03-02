import 'dart:async';
import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:mockito/mockito.dart';
import 'package:sync_storage/src/callbacks/storage_network_callbacks.dart';
import 'package:sync_storage/src/services/network_availability_service.dart';
import 'package:sync_storage/src/serializer.dart';
import 'package:sync_storage/src/storage/hive_storage.dart';
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

  @override
  void dispose() {
    networkAvailabilityController.close();
  }

  Future<void> goOnline() async {
    networkAvailabilityController.add(true);
    _isConnected = true;

    /// wait for network changes to take effect
    await Future.delayed(Duration(milliseconds: 10));
  }

  Future<void> goOffline() async {
    networkAvailabilityController.add(false);
    _isConnected = false;

    /// wait for network changes to take effect
    await Future.delayed(Duration(milliseconds: 10));
  }
}

class HiveStorageControllerMock<T> extends HiveStorageController<T> {
  HiveStorageControllerMock(String boxName, Serializer<T> serializer)
      : super(boxName, serializer);

  @override
  bool initialized = false;

  /// override initialize to ommit flutter hive initialization.
  @override
  Future<void> initialize() async {
    Hive.init('./');
    box = await Hive.openBox<String>(boxName);
    initialized = true;
  }
}

class HiveStorageMock<T> extends HiveStorage<T> {
  HiveStorageMock(String boxName, Serializer<T> serializer)
      : super(boxName, serializer);

  /// override initialize to ommit flutter hive initialization.
  @override
  // ignore: must_call_super
  Future<void> initialize() async {
    Hive.init('./');

    final storageExists = await exist();
    if (!storageExists) {
      await create();
    }

    await open();
  }
}

class StorageNetworkCallbacksMock<T> extends Mock
    implements StorageNetworkCallbacks<T> {}

class TestElement {
  final int value;

  const TestElement(this.value);
}

class TestElementSerializer extends Serializer<TestElement> {
  const TestElementSerializer();
  @override
  TestElement fromJson(String json) {
    final dynamic jsonMap = jsonDecode(json);
    return TestElement(jsonMap['value']);
  }

  @override
  String toJson(TestElement data) {
    final jsonMap = {
      'value': data.value,
    };

    return jsonEncode(jsonMap);
  }
}
