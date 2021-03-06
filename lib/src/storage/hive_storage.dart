import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:meta/meta.dart';
import 'package:objectid/objectid.dart';
import 'package:sync_storage/src/storage/storage_config.dart';
import 'package:sync_storage/src/storage/storage.dart';

import '../../sync_storage.dart';

class HiveStorageController<T> {
  @visibleForTesting
  Box<String> box;
  final String boxName;
  final Serializer<T> serializer;

  bool _initialized = false;
  bool get initialized => _initialized;

  bool _disposed = false;
  bool get disposed => _disposed;

  void _assertInitialized() {
    if (!initialized) throw StateError('Controller is not initialized.');
  }

  void _assertNotDisposed() {
    if (_disposed) throw StateError('Controller is disposed.');
  }

  void _assertInitializedNotDisposed() {
    _assertInitialized();
    _assertNotDisposed();
  }

  HiveStorageController(this.boxName, this.serializer)
      : assert(
          boxName != null && serializer != null,
          'boxName and serializer cannot be null',
        );

  Future<void> initialize() async {
    if (initialized) throw StateError('Controller is already initialized.');
    if (_disposed) throw StateError('Controller is disposed.');

    await Hive.initFlutter();
    box = await Hive.openBox<String>(boxName);
    _initialized = true;
  }

  @visibleForTesting
  bool hasRegisteredStorageWithName(String boxName) {
    _assertInitializedNotDisposed();

    return box.values.contains(boxName);
  }

  @visibleForTesting
  void registerBoxWithName(String boxName) {
    _assertInitializedNotDisposed();

    if (!hasRegisteredStorageWithName(boxName)) {
      box.add(boxName);
    }
  }

  HiveStorage<T> getStorage(
    final String boxName,
  ) {
    _assertInitializedNotDisposed();

    registerBoxWithName(boxName);
    return HiveStorage<T>(boxName, serializer);
  }

  List<String> get registeredStorages {
    _assertInitializedNotDisposed();

    return box.values.toList();
  }

  /// Delete all registred Boxes
  Future<void> deleteAllRegistredStorages() async {
    _assertInitializedNotDisposed();

    for (final boxNameEntry in box.toMap().entries) {
      final boxName = boxNameEntry.value;
      final boxExist = await Hive.boxExists(boxName);
      if (boxExist) {
        await Hive.deleteBoxFromDisk(boxName);
      }
      await box.delete(boxNameEntry.key);
    }
  }

  Future<void> deleteStorageWithName(String boxName) async {
    _assertInitializedNotDisposed();

    MapEntry<dynamic, String> onBoxDoesNotExist() {
      throw StateError('Box with provided name is not registred.');
    }

    final boxNameEntry = box.toMap().entries.firstWhere(
          (boxNameEntry) => boxNameEntry.value == boxName,
          orElse: onBoxDoesNotExist,
        );

    await Hive.deleteBoxFromDisk(boxNameEntry.value);
    await box.delete(boxNameEntry.key);
  }

  Future<void> dispose() async {
    if (!initialized) {
      throw StateError('Only initialized controllers should be disposed.');
    }
    if (_disposed) throw StateError('Controller is already disposed.');

    await box.close();
    _disposed = true;
  }
}

class HiveStorage<T> extends Storage<T> {
  static const _configKey = '__config';
  StorageConfig _config;
  @override
  StorageConfig get config => _config;

  final String boxName;
  final Serializer<T> serializer;

  HiveStorage(this.boxName, this.serializer);

  @visibleForTesting
  LazyBox<String> box;

  @override
  Future<void> initialize() async {
    await Hive.initFlutter();

    final storageExists = await exist();
    if (!storageExists) {
      await create();
    }

    await open();
  }

  Future<bool> exist() => Hive.boxExists(boxName);

  Future<void> create() async {
    /// Nothing to do here as HIVE storage automatically creates databes
    /// during open operation.
  }

  Future<void> open() async {
    box = await Hive.openLazyBox<String>(boxName);
    await _loadConfig();
  }

  @override
  Future<List<StorageCell<T>>> readAllCells() async {
    final values = await Future.wait(box.keys
        .where((dynamic key) => key != _configKey)
        .map((dynamic key) => box.get(key)));

    return values
        .map((value) => StorageCell<T>.fromJson(value, serializer))
        .toList();
  }

  Future<void> _loadConfig() async {
    final configData = await box.get(_configKey);

    _config = StorageConfig.fromJson(configData);
  }

  @override
  Future<void> writeConfig(StorageConfig config) async {
    ArgumentError.checkNotNull(config, 'config');

    _config = config;
    await box.put(_configKey, _config?.toJson());
  }

  @override
  Future<void> writeAllCells(Iterable<StorageCell<T>> cells) async {
    await box.clear();

    await Future.wait(cells.map(writeCell));

    await writeConfig(config);
  }

  @override
  Future<void> dispose() async {
    await box?.close();
  }

  @override
  Future<void> clear() async {
    await box.clear();
    await _loadConfig();
  }

  @override
  Future<void> delete() async {
    await box.deleteFromDisk();
  }

  @override
  Future<void> deleteCell(StorageCell<T> cell) {
    return box.delete(cell.id.hexString);
  }

  @override
  Future<StorageCell<T>> readCell(ObjectId id) async {
    final jsonEncodedCell = await box.get(id.hexString);

    return jsonEncodedCell == null
        ? null
        : StorageCell<T>.fromJson(jsonEncodedCell, serializer);
  }

  @override
  Future<void> writeCell(StorageCell<T> cell) {
    return box.put(cell.id.hexString, cell.toJson(serializer));
  }

  @override
  Future<List<StorageCell<T>>> readNotSyncedCells() async {
    final cells = await readAllCells();
    return cells.where((cell) => cell.needsNetworkSync).toList();
  }
}
