import 'dart:convert';

class StorageConfig {
  final DateTime? lastFetch;
  final DateTime? lastSync;
  final bool? needsFetch;

  const StorageConfig({
    required this.lastSync,
    required this.lastFetch,
    required this.needsFetch,
  });

  factory StorageConfig.fromJson(String? json) {
    if (json == null) {
      return const StorageConfig(
        needsFetch: true,
        lastFetch: null,
        lastSync: null,
      );
    }
    final dynamic jsonMap = jsonDecode(json);

    final DateTime? lastFetch = jsonMap['lastFetch'] != null
        ? DateTime.tryParse(jsonMap['lastFetch'])
        : null;
    final DateTime? lastSync = jsonMap['lastSync'] != null
        ? DateTime.tryParse(jsonMap['lastSync'])
        : null;

    return StorageConfig(
      needsFetch: jsonMap['needsFetch'] is bool && jsonMap['needsFetch'] != null
          ? jsonMap['needsFetch']
          : true,
      lastFetch: lastFetch,
      lastSync: lastSync,
    );
  }

  String toJson() {
    final jsonMap = <String, dynamic>{
      'lastFetch': lastFetch?.toIso8601String(),
      'lastSync': lastSync?.toIso8601String(),
      'needsFetch': needsFetch,
    };

    return jsonEncode(jsonMap);
  }

  StorageConfig copyWith({
    DateTime? lastFetch,
    DateTime? lastSync,
    bool? needsFetch,
  }) {
    return StorageConfig(
      lastFetch: lastFetch ?? this.lastFetch,
      lastSync: lastSync ?? this.lastSync,
      needsFetch: needsFetch ?? this.needsFetch,
    );
  }
}
