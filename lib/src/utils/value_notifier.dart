import 'dart:async';

typedef ValueChanged<T> = void Function(T value);

class ValueController<T> {
  final ValueNotifier<T> notifier;

  T get value => notifier.value;
  void set value(T value) {
    notifier._value = value;
    notifier._notify();
  }

  ValueController(T initialValue) : notifier = ValueNotifier<T>(initialValue);

  void dispose() {
    notifier.dispose();
  }
}

class ValueNotifier<T> {
  T _value;
  T get value => _value;

  final _streamController = StreamController<T>.broadcast();

  ValueNotifier(this._value) {
    addListener(_streamController.add);
  }

  final List<ValueChanged<T>> _listeners = [];

  void addListener(ValueChanged<T> callback) {
    _listeners.add(callback);
  }

  void removeListener(ValueChanged<T> callback) {
    _listeners.remove(callback);
  }

  void _notify() {
    for (final listener in _listeners) {
      listener(value);
    }
  }

  Stream<T> get stream => _streamController.stream;

  void dispose() {
    _listeners.clear();
    _streamController.close();
  }
}
