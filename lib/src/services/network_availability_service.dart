import 'dart:async';

abstract class NetworkAvailabilityService {
  Stream<bool> get onConnectivityChanged;
  bool get isConnected;

  void dispose();
}
