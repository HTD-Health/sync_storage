import 'dart:async';
import 'dart:convert';

import 'package:hive/hive.dart';
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
  void dispose() {
    networkAvailabilityController.close();
  }
}

class HiveStorageControllerMock<T> extends HiveStorageController<T> {
  HiveStorageControllerMock(String boxName, Serializer<T> serializer)
      : super(boxName, serializer);

  @override
  bool initialized = false;

  /// override initialize to skip flutter hive initialization.
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

  /// override initialize to skip flutter hive initialization.
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

class TestElement {
  final int? value;

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
