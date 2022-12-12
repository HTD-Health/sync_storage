import 'package:hive_flutter/hive_flutter.dart';
import 'package:hive_storage/hive_storage.dart';
import 'package:meta/meta.dart';
import 'package:sync_storage/sync_storage.dart' hide Serializer;

class HiveStorageController<T> {
  @visibleForTesting
  late Box<String> box;
  final String boxName;
  final Serializer<T> serializer;
  final StorageCellJsonEncoder<T> encoder;
  final StorageCellJsonDecoder<T> decoder;

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
      : encoder = StorageCellJsonEncoder<T>(serializer: serializer),
        decoder = StorageCellJsonDecoder<T>(serializer: serializer);

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

  /// Delete all registered Boxes
  Future<void> deleteAllRegisteredStorages() async {
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
      throw StateError('Box with provided name is not registered.');
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
  @override
  StorageConfig get config => _config;
  late StorageConfig _config;

  final String boxName;
  final Serializer<T> serializer;
  final StorageCellJsonEncoder<T> encoder;
  final StorageCellJsonDecoder<T> decoder;

  HiveStorage(this.boxName, this.serializer)
      : encoder = StorageCellJsonEncoder<T>(serializer: serializer),
        decoder = StorageCellJsonDecoder<T>(serializer: serializer);

  @visibleForTesting
  late LazyBox<String?> box;

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
    box = await Hive.openLazyBox<String?>(boxName);
    await _loadConfig();
  }

  @override
  Future<List<StorageCell<T>>> readAll() async {
    final values = await Future.wait(box.keys
        .where((dynamic key) => key != _configKey)
        .map((dynamic key) => box.get(key)));

    return values.map((value) => decoder.convert(value!)).toList();
  }

  Future<void> _loadConfig() async {
    final configData = await box.get(_configKey);

    _config = StorageConfig.fromJson(configData);
  }

  @override
  Future<void> writeConfig(StorageConfig config) async {
    ArgumentError.checkNotNull(config, 'config');

    _config = config;
    await box.put(_configKey, _config.toJson());
  }

  @override
  Future<void> writeAll(Iterable<StorageCell<T>> cells) async {
    await Future.wait(cells.map(write));

    await writeConfig(config);
  }

  @override
  Future<void> dispose() async {
    await box.close();
  }

  @override
  Future<void> clear() async {
    await box.clear();
    await _loadConfig();
  }

  Future<void> deleteFromDisk() async {
    await box.deleteFromDisk();
  }

  @override
  Future<void> delete(StorageCell<T> cell) {
    return box.delete(cell.id.hexString);
  }

  @override
  Future<StorageCell<T>?> read(ObjectId id) async {
    final jsonEncodedCell = await box.get(id.hexString);

    return jsonEncodedCell == null ? null : decoder.convert(jsonEncodedCell);
  }

  @override
  Future<void> write(StorageCell<T> cell) {
    return box.put(cell.id.hexString, encoder.convert(cell));
  }

  @override
  Future<List<StorageCell<T>>> readNotSynced() async {
    final cells = await readAll();
    return cells.where((cell) => cell.needsNetworkSync).toList();
  }
}
