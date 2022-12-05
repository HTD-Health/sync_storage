import 'dart:convert';

import 'package:sync_storage/sync_storage.dart';

class StorageCellEncoder<T> extends Converter<StorageCell<T>, String> {
  final Serializer<T> serializer;

  const StorageCellEncoder({
    required this.serializer,
  });

  @override
  String convert(StorageCell input) {
    final jsonMap = <String, dynamic>{
      'id': input.id.hexString,
      'deleted': input.deleted,
      'syncDelayedTo': input.syncDelayedTo?.toIso8601String(),
      'createdAt': input.createdAt.toIso8601String(),
      'updatedAt': input.updatedAt?.toIso8601String(),
      'lastSync': input.lastSync?.toIso8601String(),
      'networkSyncAttemptsCount': input.networkSyncAttemptsCount,
      'element':
          input.element == null ? null : serializer.toJson(input.element),
      if (input.oldElement != null)
        'oldElement': serializer.toJson(input.oldElement),
    };

    return json.encode(jsonMap);
  }
}

class StorageCellDecoder<T> extends Converter<String, StorageCell<T>> {
  final Serializer<T> serializer;

  const StorageCellDecoder({
    required this.serializer,
  });

  @override
  StorageCell<T> convert(String input) {
    final dynamic decodedJson = json.decode(input);
    if (decodedJson is! Map) {
      throw ArgumentError.value(input, 'input');
    }

    final dynamic id = decodedJson['id'];
    final dynamic element = decodedJson['element'];
    final dynamic oldElement = decodedJson['oldElement'];
    final dynamic createdAt = decodedJson['createdAt'];
    final dynamic updatedAt = decodedJson['updatedAt'];
    final dynamic lastSync = decodedJson['lastSync'];
    final dynamic syncDelayedTo = decodedJson['syncDelayedTo'];

    return StorageCell(
      id: id == null

          /// If current cell does not contain id, generate a new one.
          /// (silent data migration)
          ? null
          : ObjectId.fromHexString(id),
      deleted: decodedJson['deleted'],
      networkSyncAttemptsCount: decodedJson['networkSyncAttemptsCount'],
      element: serializer.fromJson(element),
      oldElement: oldElement == null ? null : serializer.fromJson(oldElement),
      createdAt: createdAt == null ? null : DateTime.tryParse(createdAt),
      updatedAt: updatedAt == null ? null : DateTime.tryParse(updatedAt),
      lastSync: lastSync == null ? null : DateTime.tryParse(lastSync),
      syncDelayedTo:
          syncDelayedTo == null ? null : DateTime.tryParse(syncDelayedTo),
    );
  }
}
