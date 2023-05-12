import 'package:sync_storage/sync_storage.dart';
import 'package:test/test.dart';

import '../data.dart';

class TestElementValueEquals extends CustomMatcher {
  TestElementValueEquals(dynamic matcher)
      : super('TestElement with value that is', 'value', matcher);
  @override
  int? featureValueOf(dynamic actual) {
    if (actual is StorageCell<TestElement>) {
      return actual.element.value;
    } else if (actual is TestElement) {
      return actual.value;
    } else {
      throw UnsupportedError('Unsupported matcher value: $actual.');
    }
  }
}

Matcher testElementValueEquals(Object? expected) =>
    TestElementValueEquals(equals(expected));
