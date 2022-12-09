import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:hive_storage/hive_storage.dart';

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
