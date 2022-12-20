import 'package:meta/meta.dart';
import 'package:objectid/objectid.dart';
import 'package:sync_storage/src/storage/storage_config.dart';
import 'package:sync_storage/src/storage_entry.dart';

/// Callbacks are called when storage want to save data to database.
abstract class Storage<T> {
  const Storage();

  StorageConfig get config;

  /// This method is called together with [Entry.initialize]
  /// method.
  ///
  /// This is the best place to initialize memory, open files, etc.
  @mustCallSuper
  Future<void> initialize();

  /// Set current config.
  ///
  /// Entries uses [config] to store additonal inforations like
  /// last fetch date or whether the fetch was requested.
  Future<void> writeConfig(StorageConfig config);

  /// Read all cells from the storage.
  Future<List<StorageCell<T>>> readAll();

  /// Write all cells to the storage.
  ///
  /// The entry must be cleared before inserting new [cells],
  /// but it is not cleared via the [clear] method,
  /// as this method allows the data to be merged with the current
  /// data in the storage.
  Future<void> writeAll(List<StorageCell<T>> cells);

  /// Writes a single [cell] to the storage.
  Future<void> write(StorageCell<T> cell);

  /// Removes a single [cell] from the storage.
  Future<void> delete(StorageCell<T> cell);

  /// Reads a single cell by [id] from the storage.
  Future<StorageCell<T>?> read(ObjectId id);

  /// Read all cells from the storage.
  Future<List<StorageCell<T>>> readNotSynced();

  /// Clear all storage data
  Future<void> clear();

  /// Called together with the [Entry.dispose] method.
  Future<void> dispose();
}
