import 'dart:async';

abstract class NetworkConnectionStatus {
  bool get isConnected;
}

abstract class NetworkAvailabilityService implements NetworkConnectionStatus {
  NetworkAvailabilityService();

  Stream<bool> get onConnectivityChanged;
  @override
  bool get isConnected;

  /// Check network connection and publish changes
  /// via [onConnectivityChanged] stream.
  Future<bool> checkConnection();

  void dispose();
}
