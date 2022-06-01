import 'dart:async';

abstract class NetworkAvailabilityService {
  Stream<bool> get onConnectivityChanged;
  bool get isConnected;

  /// Check network connection and publish changes
  /// via [onConnectivityChanged] stream.
  Future<bool> checkConnection();

  void dispose();
}
