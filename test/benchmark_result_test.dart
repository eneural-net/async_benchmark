import 'package:async_benchmark/async_benchmark.dart';
import 'package:test/test.dart';

/// A round with a fixed duration, so every derived value is deterministic.
BenchmarkRoundResult roundOf(int round, Duration duration, int interactions) {
  final init = DateTime.utc(2024, 1, 1);
  return BenchmarkRoundResult(round, init, init.add(duration), interactions);
}

class _NoopBenchmark extends Benchmark<void, void> {
  const _NoopBenchmark(super.title);

  @override
  void job(void setup, void service) {}
}

void main() {
  group('BenchmarkProfile', () {
    test('pre-defined profiles', () {
      expect(
        [
          BenchmarkProfile.instant,
          BenchmarkProfile.fast,
          BenchmarkProfile.normal,
          BenchmarkProfile.heavy,
        ].map((p) => (p.name, p.warmup, p.interactions, p.rounds)),
        equals([
          ('instant', 1, 1, 1),
          ('fast', 10, 100, 1),
          ('normal', 100, 1000, 3),
          ('heavy', 1000, 10000, 10),
        ]),
      );
    });

    test('copyWith', () {
      const p = BenchmarkProfile('a', warmup: 1, interactions: 2, rounds: 3);

      var same = p.copyWith();
      expect((
        same.name,
        same.warmup,
        same.interactions,
        same.rounds,
      ), equals(('a', 1, 2, 3)));

      var changed = p.copyWith(
        name: 'b',
        warmup: 4,
        interactions: 5,
        rounds: 6,
      );
      expect((
        changed.name,
        changed.warmup,
        changed.interactions,
        changed.rounds,
      ), equals(('b', 4, 5, 6)));

      var onlyRounds = p.copyWith(rounds: 9);
      expect((
        onlyRounds.name,
        onlyRounds.warmup,
        onlyRounds.interactions,
        onlyRounds.rounds,
      ), equals(('a', 1, 2, 9)));
    });

    test('toString', () {
      expect(
        BenchmarkProfile.fast.toString(),
        equals(
          'BenchmarkProfile[fast]{warmup: 10, interactions: 100, rounds: 1}',
        ),
      );
    });
  });

  group('BenchmarkRoundResult', () {
    test('duration, hertz and interactionTimeMs', () {
      var r = roundOf(1, Duration(milliseconds: 500), 1000);

      expect(r.duration, equals(Duration(milliseconds: 500)));
      expect(r.hertz, equals(2000));
      expect(r.interactionTimeMs, equals(0.5));
    });

    test('hertzFormatted', () {
      expect(
        roundOf(1, Duration(seconds: 1), 10).hertzFormatted,
        equals('10.0000 Hz'),
      );
      expect(
        roundOf(1, Duration(seconds: 2), 1).hertzFormatted,
        equals('0.50000000 Hz'),
      );
      // Below 0.00001 Hz the raw value is printed.
      var slow = roundOf(1, Duration(seconds: 200000), 1);
      expect(slow.hertz, lessThan(0.00001));
      expect(slow.hertzFormatted, equals('${slow.hertz} Hz'));
    });

    test('interactionTimeFormatted', () {
      expect(
        roundOf(1, Duration(seconds: 3), 1).interactionTimeFormatted,
        equals('3.000 sec'),
      );
      expect(
        roundOf(1, Duration(milliseconds: 1500), 1).interactionTimeFormatted,
        equals('1.500000 sec'),
      );
      expect(
        roundOf(1, Duration(milliseconds: 5), 1).interactionTimeFormatted,
        equals('5.000 ms'),
      );
      expect(
        roundOf(1, Duration(microseconds: 250), 1).interactionTimeFormatted,
        equals('250.000 µs'),
      );
      expect(
        roundOf(1, Duration(microseconds: 5), 10).interactionTimeFormatted,
        equals('0.500000 µs'),
      );
    });

    test('compareTo and best: higher hertz is better', () {
      var fast = roundOf(1, Duration(milliseconds: 100), 100);
      var slow = roundOf(2, Duration(milliseconds: 200), 100);

      expect(fast.compareTo(slow), lessThan(0));
      expect(slow.compareTo(fast), greaterThan(0));
      expect(fast.compareTo(fast), equals(0));

      expect(fast.best(slow), same(fast));
      expect(slow.best(fast), same(fast));
      // Ties keep the receiver.
      var tie = roundOf(3, Duration(milliseconds: 100), 100);
      expect(fast.best(tie), same(fast));

      var sorted = [slow, fast]..sort();
      expect(sorted, equals([fast, slow]));
    });

    test('Iterable.best', () {
      var rounds = [
        roundOf(1, Duration(milliseconds: 300), 100),
        roundOf(2, Duration(milliseconds: 100), 100),
        roundOf(3, Duration(milliseconds: 200), 100),
      ];
      expect(rounds.best.round, equals(2));
      expect(() => <BenchmarkRoundResult>[].best, throwsStateError);
    });

    test('toString', () {
      expect(
        roundOf(4, Duration(seconds: 1), 10).toString(),
        equals(
          'BenchmarkRoundResult{round: 4, interactions: 10, '
          'hertz: 10.0000 Hz, interactionTime: 100.000 ms}',
        ),
      );
    });
  });

  group('BenchmarkResult', () {
    var benchA = _NoopBenchmark('A');
    var benchB = _NoopBenchmark('B');

    // A's best round (round 2) is faster than any of B's rounds.
    var resultA = BenchmarkResult<void, void, _NoopBenchmark>(benchA, [
      roundOf(1, Duration(milliseconds: 400), 100),
      roundOf(2, Duration(milliseconds: 100), 100),
    ]);
    var resultB = BenchmarkResult<void, void, _NoopBenchmark>(benchB, [
      roundOf(1, Duration(milliseconds: 200), 100),
    ]);

    test('compareTo and best use the best round', () {
      expect(resultA.compareTo(resultB), lessThan(0));
      expect(resultB.compareTo(resultA), greaterThan(0));
      expect(resultA.best(resultB), same(resultA));
      expect(resultB.best(resultA), same(resultA));

      var sorted = [resultB, resultA]..sort();
      expect(sorted, equals([resultA, resultB]));
    });

    test('Iterable.best', () {
      expect([resultB, resultA].best, same(resultA));
    });

    test('MapEntry.best', () {
      var a = MapEntry(benchA, resultA.rounds);
      var b = MapEntry(benchB, resultB.rounds);

      expect(a.best(b), same(a));
      expect(b.best(a), same(a));
    });

    test('toString', () {
      expect(
        resultA.toString(),
        equals('BenchmarkResult{benchmark: $benchA, rounds: 2}'),
      );
    });
  });
}
