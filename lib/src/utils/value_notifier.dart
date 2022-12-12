typedef ValueChanged<T> = void Function(T value);

class ValueController<T> {
  final ValueNotifier<T> notifier;

  T get value => notifier.value;
  void set value(T value) {
    notifier._value = value;
    notifier._notify();
  }

  ValueController(T initialValue) : notifier = ValueNotifier<T>(initialValue);

  void clear() {
    notifier.clear();
  }
}

class ValueNotifier<T> {
  T _value;
  T get value => _value;

  ValueNotifier(this._value);

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

  Stream<T> toStream() {
    throw UnimplementedError();
  }

  void clear() {
    _listeners.clear();
  }
}
