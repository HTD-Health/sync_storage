String getOptimizedRuntimeType(Object? object, String optimizedValue) {
  String value = optimizedValue;
  // ignore: prefer_asserts_with_message
  assert(() {
    value = object.runtimeType.toString();
    return true;
  }());
  return value;
}
