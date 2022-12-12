import 'package:sync_storage/src/utils/utils.dart';
import 'package:test/expect.dart';
import 'package:test/scaffolding.dart';

const duration = Duration(milliseconds: 100);
const defaultMaxConcurrentActions = 5;
const operationDelay = Duration(milliseconds: 50);

final durations = [
  for (int i = 0; i < defaultMaxConcurrentActions; i++) duration,
];

void main() {
  group('parallel -', () {
    int called = 0;
    Future<void> callback(Duration duration) {
      called++;
      return Future<void>.delayed(duration);
    }

    setUp(() {
      called = 0;
    });

    test('Works correctly with default maxConcurrentActions', () async {
      final watch = Stopwatch()..start();
      await parallel(callback, durations);
      watch.stop();
      expect(
        watch.elapsed,
        greaterThan(const Duration(milliseconds: 100)),
      );
      expect(
        watch.elapsed,
        lessThan(const Duration(milliseconds: 150)),
      );
      expect(called, equals(durations.length));
    });

    test('Works correctly with more elements than maxConcurrentActions - 3',
        () async {
      final watch = Stopwatch()..start();
      await parallel(callback, durations, maxConcurrentActions: 3);
      watch.stop();
      expect(
        watch.elapsed,
        greaterThan(const Duration(milliseconds: 200)),
      );
      expect(
        watch.elapsed,
        lessThan(const Duration(milliseconds: 250)),
      );
      expect(called, equals(durations.length));
    });

    test('Works correctly with more elements than maxConcurrentActions - 1',
        () async {
      final watch = Stopwatch()..start();
      await parallel(callback, durations, maxConcurrentActions: 1);
      watch.stop();
      expect(
        watch.elapsed,
        greaterThan(const Duration(milliseconds: 500)),
      );
      expect(
        watch.elapsed,
        lessThan(const Duration(milliseconds: 550)),
      );
      expect(called, equals(durations.length));
    });

    test(
        'Skips elements when exceptions are thrown and correctly '
        'throws a ParallelException exception.', () async {
      final exception = Exception('error');
      int called = 0;
      Future<void> callback(Duration duration) {
        called++;
        if (called == 1) {
          throw exception;
        }
        return Future<void>.delayed(duration);
      }

      final watch = Stopwatch()..start();
      Exception? thrown;
      try {
        await parallel(callback, durations, maxConcurrentActions: 1);
      } on Exception catch (err) {
        thrown = err;
      }
      watch.stop();
      expect(thrown, isA<ParallelException>());
      expect((thrown as ParallelException).errors, hasLength(1));
      expect(thrown.errors.first.exception, equals(exception));
      expect(
        watch.elapsed,
        // It has a duration of more than 400 instead of 500,
        // because one element is skipped due to an exception.
        greaterThan(const Duration(milliseconds: 400)),
      );
      expect(
        watch.elapsed,
        lessThan(const Duration(milliseconds: 450)),
      );
      expect(called, equals(durations.length));
    });
  });
}
