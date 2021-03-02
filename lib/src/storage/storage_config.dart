import 'dart:convert';

import 'package:meta/meta.dart';

class StorageConfig {
  final DateTime lastFetch;
  final bool needsFetch;

  const StorageConfig({
    @required this.lastFetch,
    @required this.needsFetch,
  });

  factory StorageConfig.fromJson(String json) {
    if (json == null) {
      return const StorageConfig(lastFetch: null, needsFetch: true);
    }
    final dynamic jsonMap = jsonDecode(json);
    final DateTime lastFetch = jsonMap['lastFetch'] != null
        ? DateTime.tryParse(jsonMap['lastFetch'])
        : null;

    return StorageConfig(
      lastFetch: lastFetch,
      needsFetch: jsonMap['needsFetch'] is bool && jsonMap['needsFetch'] != null
          ? jsonMap['needsFetch']
          : true,
    );
  }

  String toJson() {
    final jsonMap = <String, dynamic>{
      'lastFetch': lastFetch?.toIso8601String(),
      'needsFetch': needsFetch,
    };

    return jsonEncode(jsonMap);
  }

  StorageConfig copyWith({
    DateTime lastFetch,
    bool needsFetch,
  }) {
    return StorageConfig(
      lastFetch: lastFetch ?? this.lastFetch,
      needsFetch: needsFetch ?? this.needsFetch,
    );
  }
}
