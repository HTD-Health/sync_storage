import 'dart:async';

typedef ValueChanged<T> = void Function(T value);

/// Manages the [ListenableValue].
class ListenableValueController<T> {
  final ListenableValue<T> listenable;

  T get value => listenable.value;
  void set value(T value) {
    listenable._setValue(value);
  }

  ListenableValueController(T initialValue)
      : listenable = ListenableValue<T>._(initialValue);

  void dispose() {
    listenable.dispose();
  }
}

/// Unlike streams, [ListenableValue] provides values synchronously.
/// However, it also exposes a [stream] that can be
/// helpful in certain scenarious.
class ListenableValue<T> {
  T _value;
  T get value => _value;

  void _setValue(T newValue) {
    final bool hasValueChanged = newValue != value;
    if (hasValueChanged) {
      _value = newValue;
      _notify();
    }
  }

  final _streamController = StreamController<T>.broadcast();

  ListenableValue._(this._value) {
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
