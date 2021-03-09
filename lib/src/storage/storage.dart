import 'package:meta/meta.dart';
import 'package:objectid/objectid.dart';
import 'package:sync_storage/src/storage/storage_config.dart';
import 'package:sync_storage/src/storage_entry.dart';

/// Callbacks are called when storage want to save data to database.
abstract class Storage<T> {
  const Storage();

  StorageConfig get config;

  /// This method is called together with [SyncStorage] [initializeEntry] method.
  ///
  /// This is the best place to initialize memory, open files, etc.
  @mustCallSuper
  Future<void> initialize();

  /// Set current config.
  Future<void> writeConfig(StorageConfig config);

  /// Read all cells from the storage.
  Future<List<StorageCell<T>>> readAllCells();

  /// Write all cells from the storage.
  Future<void> writeAllCells(List<StorageCell<T>> cells);

  Future<void> writeCell(StorageCell<T> cell);

  Future<void> updateCell(ObjectId cellId, StorageCell<T> cell);

  Future<void> deleteCell(ObjectId cellId);

  /// Read all cells from the storage.
  // Future<List<StorageCell<T>>> readNotSyncedCells();

  /// Clear all storage data
  Future<void> clear();

  /// Delete storage.
  ///
  /// In opposite to [clear], this method will remove files/tables related
  /// with current storage. After this action [create] should be called before next use.
  Future<void> delete();

  /// Called together with [SyncStorage] [dispose] method.
  Future<void> dispose();
}
