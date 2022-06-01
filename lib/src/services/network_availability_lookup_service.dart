import 'dart:async';
import 'dart:io';

import 'package:rxdart/subjects.dart';
import 'package:sync_storage/src/services/network_availability_service.dart';

class NetworkAvailabilityLookupService extends NetworkAvailabilityService {
  final _streamController = BehaviorSubject<bool>.seeded(false);

  final Duration lookupInterval;
  final List<String> lookupAddresses;

  late final Timer _periodicLookup;

  @override
  Stream<bool> get onConnectivityChanged => _streamController.stream;
  @override
  bool get isConnected => _streamController.value;

  NetworkAvailabilityLookupService({
    required this.lookupAddresses,
    this.lookupInterval = const Duration(seconds: 2),
  }) {
    _setPeriodicPolling();
  }

  void _setPeriodicPolling() {
    _periodicLookup = Timer.periodic(
      lookupInterval,
      (_) => checkConnection(),
    );
  }

  Future<bool> _isAccessible(String address) async {
    try {
      final result = await InternetAddress.lookup(address);
      final success = result.isNotEmpty && result.first.rawAddress.isNotEmpty;
      return success;
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {
      return false;
    }
  }

  Future<bool> _lookupAddresses() async {
    final successfulTries = await Future.wait<bool>(
      lookupAddresses.map(_isAccessible),
    );
    return successfulTries.any((isAccesible) => isAccesible);
  }

  @override
  Future<bool> checkConnection() async {
    final bool isConnected = await _lookupAddresses();
    if (_streamController.value != isConnected) {
      _streamController.sink.add(isConnected);
    }
    return isConnected;
  }

  @override
  @override
  void dispose() {
    _periodicLookup.cancel();
    _streamController.close();
  }
}
