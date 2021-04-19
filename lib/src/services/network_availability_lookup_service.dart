import 'dart:async';
import 'dart:io';
import 'package:connectivity/connectivity.dart';
import 'package:meta/meta.dart';
import 'package:sync_storage/sync_storage.dart';

import '../sync_storage.dart';

class NetworkAvailabilityLookupService extends NetworkAvailabilityService {
  final Connectivity _connectivity = Connectivity();
  final StreamController _streamController = StreamController<bool>.broadcast();

  final Duration pollingDuration;
  final List<String> lookupAddresses;
  final bool debug;

  Timer _timer;
  bool _internetAvailable = false;

  @override
  Stream<bool> get onConnectivityChanged => _streamController.stream;
  @override
  bool get isConnected => _internetAvailable;

  NetworkAvailabilityLookupService({
    this.lookupAddresses,
    this.debug = false,
    this.pollingDuration = const Duration(seconds: 2),
  }) {
    _connectivity.onConnectivityChanged.listen(_handleConnectivityChange);
    _connectivity.checkConnectivity().then(_handleConnectivityChange);
  }

  Future<void> _handleConnectivityChange(ConnectivityResult event) async {
    debugModePrint('[$runtimeType] ConnectivityChange: $event', enabled: debug);
    switch (event) {
      case ConnectivityResult.mobile:
      case ConnectivityResult.wifi:
        _cancelTimer();
        _publishConnectionStatus();
        _setPeriodicPolling();
        break;
      case ConnectivityResult.none:
        _cancelTimer();
        _setConnectionStatus(isConnected: false);

        break;
      default:
        throw Exception('Connectivity unavailable');
    }
  }

  Future<bool> _ping(String address) async {
    try {
      final result = await InternetAddress.lookup(address);
      final success = result.isNotEmpty && result.first.rawAddress.isNotEmpty;
      debugModePrint('[$runtimeType] Ping: address=$address, success=$success.',
          enabled: debug);
      return success;
    } on SocketException catch (_) {
      debugModePrint('[$runtimeType] Ping: address=$address, success=${false}.',
          enabled: debug);
      return false;
    }
  }

  Future<bool> _checkConnection() async {
    final successfulTries = await Future.wait<bool>([
      for (final address in lookupAddresses) _ping(address),
    ]);
    return successfulTries.any((element) => element == true);
  }

  Future<void> _publishConnectionStatus() async {
    final bool isConnected = await _checkConnection();
    debugModePrint(
        '[$runtimeType] Publish connection status: isConnected=$isConnected.',
        enabled: debug);
    _internetAvailable = isConnected;
    _streamController.sink.add(isConnected);
  }

  void _setConnectionStatus({
    @required bool isConnected,
  }) {
    _internetAvailable = isConnected;
    _streamController.sink.add(isConnected);
  }

  void _setPeriodicPolling() {
    debugModePrint('[$runtimeType] Set periodic polling.', enabled: debug);
    _timer = Timer.periodic(pollingDuration, (_) => _publishConnectionStatus());
  }

  void _cancelTimer() {
    debugModePrint('[$runtimeType] Cancel timer.', enabled: debug);
    _timer?.cancel();
  }

  @override
  void dispose() {
    _cancelTimer();
    _streamController.close();
  }
}
