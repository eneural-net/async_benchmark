import 'dart:async';
import 'dart:math' as math;

import 'package:async_benchmark/async_benchmark.dart';
import 'package:test/test.dart';

/// A round with a fixed duration, so every derived value is deterministic.
BenchmarkRoundResult roundOf(int round, Duration duration, int interactions) {
  final init = DateTime.utc(2024, 1, 1);
  return BenchmarkRoundResult(round, init, init.add(duration), interactions);
}

/// Runs [body] capturing everything it prints.
Future<(T, List<String>)> capturePrints<T>(Future<T> Function() body) async {
  final lines = <String>[];
  final result = await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => lines.add(line),
    ),
  );
  return (result, lines);
}

/// Logs every lifecycle call; [job] throws on job number [failAtJob] (1-based),
/// [teardown] on round [failAtTeardown], and [shutdown] when [failShutdown].
class LifecycleBenchmark extends Benchmark<int, String> {
  final List<String> log;

  final int? failAtJob;
  final int? failAtTeardown;
  final bool failShutdown;

  int jobs = 0;
  int teardowns = 0;

  LifecycleBenchmark(
    super.title, {
    List<String>? log,
    this.failAtJob,
    this.failAtTeardown,
    this.failShutdown = false,
  }) : log = log ?? [];

  @override
  BenchmarkSetupResult<int, String> setup() {
    log.add('$title:setup');
    return (setup: 7, service: 'svc');
  }

  @override
  Future<void> job(int setup, String? service) async {
    expect((setup, service), equals((7, 'svc')));
    ++jobs;
    if (jobs == failAtJob) throw StateError('job $jobs failed');
  }

  @override
  void teardown(int setup, String? service) {
    ++teardowns;
    log.add('$title:teardown');
    if (teardowns == failAtTeardown) throw StateError('teardown failed');
  }

  @override
  void shutdown(int setup, String? service) {
    log.add('$title:shutdown');
    if (failShutdown) throw StateError('shutdown failed');
  }

  @override
  String toString() => 'LifecycleBenchmark[$title]';
}

/// Runs a benchmark in some way (see the profile boundary tests).
typedef RunWith = Future<Object?> Function(LifecycleBenchmark bench);

/// Runs a list of benchmarks in some way (see the profile boundary tests).
typedef RunAllWith = Future<Object?> Function(List<LifecycleBenchmark> list);

const _profile = BenchmarkProfile(
  'test',
  warmup: 2,
  interactions: 3,
  rounds: 2,
);

/// The lines a verbose run of [result] (made with [profile]) prints, built
/// from the measured rounds themselves: the report is checked exactly without
/// depending on how long anything took.
List<String> expectedRunReport(
  BenchmarkResult result,
  BenchmarkProfile profile,
  String setupRecord,
) {
  final title = result.benchmark.title;
  final w = title.length;
  final line = '╠─${'─' * w}──';

  List<String> metrics(BenchmarkRoundResult r) => [
    '║ »» Duration: ${r.duration}',
    '║ »» Speed: ${r.hertzFormatted}',
    '║ »» Interaction Time: ${r.interactionTimeFormatted}',
  ];

  return [
    '╔═${'═' * w}═╗',
    '║ $title ║',
    '╠═${'═' * w}═╝',
    '║ $profile',
    line,
    '║ Setup...',
    '║ ─ $setupRecord',
    '║ Warmup (${profile.warmup})...',
    for (var r in result.rounds) ...[
      line,
      '║ ROUND: ${r.round}/${profile.rounds}',
      '║',
      '║ ─ Running (${profile.interactions})...',
      '║ ─ Teardown...',
      '║',
      ...metrics(r),
    ],
    if (profile.rounds > 1) ...[
      line,
      '║ BEST ROUND: ${result.rounds.best.round}',
      '║',
      ...metrics(result.rounds.best),
    ],
    line,
    '║ Shutdown...',
    '╚═${'═' * w}══',
    '',
  ];
}

void main() {
  group('BenchmarkRoundResult edge values', () {
    // Printed values are never `Infinity` or `NaN`.
    Matcher readable = isNot(anyOf(contains('Infinity'), contains('NaN')));

    test('zero interactions in a measured round', () {
      var r = roundOf(1, Duration(milliseconds: 1), 0);
      expect(r.isMeasurable, isFalse);
      expect(r.hertz, equals(0));
      expect(r.hertzFormatted, equals('n/a (no interactions)'));
      expect(r.interactionTimeMs.isNaN, isTrue);
      expect(r.interactionTimeFormatted, equals('n/a (no interactions)'));
      expect(r.toString(), readable);

      // It compares as the slowest round.
      var measured = roundOf(2, Duration(seconds: 100), 1);
      expect(r.best(measured), same(measured));
      expect(measured.best(r), same(measured));
    });

    test('a round too fast to measure (zero duration)', () {
      var r = roundOf(1, Duration.zero, 10);
      expect(r.duration, equals(Duration.zero));
      expect(r.isMeasurable, isFalse);
      expect(r.hertz, equals(double.infinity));
      expect(r.hertzFormatted, equals('n/a (too fast to measure)'));
      expect(r.interactionTimeMs, equals(0));
      expect(r.interactionTimeFormatted, equals('n/a (too fast to measure)'));
      expect(r.toString(), readable);

      // It still compares as the fastest round.
      var measured = roundOf(2, Duration(microseconds: 1), 10);
      expect(r.best(measured), same(r));
      expect(measured.best(r), same(r));
    });

    test('a negative duration (the clock moved back) is not measurable', () {
      var r = roundOf(1, Duration(microseconds: -5), 10);
      expect(r.isMeasurable, isFalse);
      expect(r.hertz, equals(double.infinity));
      expect(r.interactionTimeMs, equals(0));
      expect(r.hertzFormatted, equals('n/a (too fast to measure)'));
      expect(r.interactionTimeFormatted, equals('n/a (too fast to measure)'));
    });

    test('zero interactions and zero duration', () {
      var r = roundOf(1, Duration.zero, 0);
      expect(r.isMeasurable, isFalse);
      expect(r.hertz, equals(0));
      expect(r.hertzFormatted, equals('n/a (no interactions)'));
      expect(r.interactionTimeMs.isNaN, isTrue);
      expect(r.interactionTimeFormatted, equals('n/a (no interactions)'));
      expect(r.toString(), readable);
    });

    test('speedRatioFormatted', () {
      var best = roundOf(1, Duration(milliseconds: 100), 100);
      var half = roundOf(2, Duration(milliseconds: 200), 100);
      expect(half.speedRatioFormatted(best), equals('0.5000 (2.0000 x)'));
      expect(best.speedRatioFormatted(best), equals('1.0000 (1.0000 x)'));

      var tooFast = roundOf(3, Duration.zero, 100);
      var empty = roundOf(4, Duration(milliseconds: 1), 0);
      // Either side unmeasurable: `n/a`, not `0.0000 (Infinity x)` or NaN.
      expect(half.speedRatioFormatted(tooFast), 'n/a (too fast to measure)');
      expect(tooFast.speedRatioFormatted(best), 'n/a (too fast to measure)');
      expect(tooFast.speedRatioFormatted(tooFast), 'n/a (too fast to measure)');
      expect(empty.speedRatioFormatted(best), 'n/a (no interactions)');
      expect(best.speedRatioFormatted(empty), 'n/a (no interactions)');
    });

    test('hertzFormatted at its thresholds', () {
      // Exactly 1 Hz is not "> 1": printed with 8 decimals.
      var oneHz = roundOf(1, Duration(seconds: 4), 4);
      expect(oneHz.hertz, equals(1));
      expect(oneHz.hertzFormatted, equals('1.00000000 Hz'));

      var justAbove = roundOf(1, Duration(seconds: 1), 2);
      expect(justAbove.hertzFormatted, equals('2.0000 Hz'));

      // 1 interaction in 50000 s: 0.00002 Hz, still above 0.00001.
      var slow = roundOf(1, Duration(seconds: 50000), 1);
      expect(slow.hertzFormatted, equals('0.00002000 Hz'));

      // At or below 0.00001 Hz: the plain `double` text.
      var slower = roundOf(1, Duration(seconds: 200000), 1);
      expect(slower.hertz, closeTo(0.000005, 1e-12));
      expect(slower.hertzFormatted, equals('${slower.hertz} Hz'));
    });

    test('interactionTimeFormatted at its thresholds', () {
      String format(Duration d) => roundOf(1, d, 1).interactionTimeFormatted;

      expect(format(Duration(seconds: 2)), equals('2.000 sec'));
      expect(format(Duration(microseconds: 1999999)), equals('1.999999 sec'));
      // Exactly 1000 ms is not "> 1000": printed in ms.
      expect(format(Duration(seconds: 1)), equals('1000.000 ms'));
      expect(format(Duration(microseconds: 1000001)), equals('1.000001 sec'));
      expect(format(Duration(milliseconds: 1)), equals('1.000 ms'));
      expect(format(Duration(microseconds: 999)), equals('999.000 µs'));
      expect(format(Duration(microseconds: 100)), equals('100.000 µs'));
      expect(format(Duration(microseconds: 99)), equals('99.000000 µs'));
    });

    test('hertz and interaction time are hand-calculated inverses', () {
      // 3 interactions in 1.5 ms: 2000 Hz and 0.5 ms each.
      var r = roundOf(1, Duration(microseconds: 1500), 3);
      expect(r.hertz, equals(2000));
      expect(r.interactionTimeMs, equals(0.5));
      expect(r.hertzFormatted, equals('2000.0000 Hz'));
      expect(r.interactionTimeFormatted, equals('500.000 µs'));
    });

    test('best keeps the first of equally fast rounds', () {
      var rounds = [
        roundOf(1, Duration(milliseconds: 200), 100),
        roundOf(2, Duration(milliseconds: 100), 100),
        roundOf(3, Duration(milliseconds: 100), 100),
        // Twice the interactions in twice the time: the same speed.
        roundOf(4, Duration(milliseconds: 200), 200),
      ];
      expect(rounds.best.round, equals(2));
    });
  });

  group('profile boundaries', () {
    Matcher invalid(String name, Object value) => throwsA(
      isA<ArgumentError>()
          .having((e) => e.name, 'name', name)
          .having((e) => e.invalidValue, 'invalidValue', value),
    );

    test('validate: the valid minimum and the invalid values', () {
      // Zero warmup is valid: no warmup.
      BenchmarkProfile('min', warmup: 0, interactions: 1, rounds: 1).validate();
      // No upper limit.
      BenchmarkProfile(
        'max',
        warmup: 1 << 62,
        interactions: 1 << 62,
        rounds: 1 << 62,
      ).validate();
      for (var p in [
        BenchmarkProfile.instant,
        BenchmarkProfile.fast,
        BenchmarkProfile.normal,
        BenchmarkProfile.heavy,
      ]) {
        p.validate();
      }

      expect(
        () => _profile.copyWith(warmup: -1).validate(),
        invalid('warmup', -1),
      );
      expect(
        () => _profile.copyWith(interactions: 0).validate(),
        invalid('interactions', 0),
      );
      expect(
        () => _profile.copyWith(interactions: -3).validate(),
        invalid('interactions', -3),
      );
      expect(
        () => _profile.copyWith(rounds: 0).validate(),
        invalid('rounds', 0),
      );
      expect(
        () => _profile.copyWith(rounds: -2).validate(),
        invalid('rounds', -2),
      );
    });

    test('zero warmup runs only the rounds', () async {
      var bench = LifecycleBenchmark('no-warmup');

      var result = await bench.run(profile: _profile, warmup: 0);

      expect(bench.jobs, equals(2 * 3));
      expect(result.rounds.map((r) => r.round), equals([1, 2]));
    });

    for (var (name, value, run) in <(String, int, RunWith)>[
      ('warmup', -5, (b) => b.run(profile: _profile, warmup: -5)),
      ('interactions', 0, (b) => b.run(profile: _profile, interactions: 0)),
      ('interactions', -1, (b) => b.run(profile: _profile, interactions: -1)),
      ('rounds', 0, (b) => b.run(profile: _profile.copyWith(rounds: 0))),
      ('rounds', -1, (b) => b.run(profile: _profile.copyWith(rounds: -1))),
      // Invalid values in the profile itself, not only in the overrides.
      ('warmup', -1, (b) => b.run(profile: _profile.copyWith(warmup: -1))),
      (
        'interactions',
        0,
        (b) => b.run(profile: _profile.copyWith(interactions: 0)),
      ),
      // The default (normal) profile with an invalid override.
      ('interactions', 0, (b) => b.run(interactions: 0)),
    ]) {
      test('run rejects $name: $value before setup', () async {
        var bench = LifecycleBenchmark('invalid');

        await expectLater(run(bench), invalid(name, value));

        expect(bench.log, isEmpty);
        expect(bench.jobs, equals(0));
      });
    }

    test('a verbose run with setupOnIsolate rejects invalid counts '
        'before printing or spawning anything', () async {
      var (_, lines) = await capturePrints(
        () => expectLater(
          LifecycleBenchmark('isolate').run(
            profile: _profile.copyWith(rounds: 0),
            setupOnIsolate: true,
            verbose: true,
          ),
          invalid('rounds', 0),
        ),
      );
      expect(lines, isEmpty);
    });

    test('a valid override fixes an invalid profile value', () async {
      var bench = LifecycleBenchmark('fixed');

      var result = await bench.run(
        profile: _profile.copyWith(interactions: 0),
        interactions: 1,
      );

      expect(result.rounds.every((r) => r.interactions == 1), isTrue);
    });

    test('runAll rejects invalid counts before any benchmark runs', () async {
      for (var (name, value, runAll) in <(String, int, RunAllWith)>[
        ('rounds', 0, (l) => l.runAll(profile: _profile.copyWith(rounds: 0))),
        ('warmup', -1, (l) => l.runAll(profile: _profile, warmup: -1)),
        (
          'interactions',
          0,
          (l) => l.runAll(profile: _profile, interactions: 0),
        ),
        ('interactions', -1, (l) => l.runAll(interactions: -1)),
      ]) {
        var list = [LifecycleBenchmark('a'), LifecycleBenchmark('b')];

        await expectLater(runAll(list), invalid(name, value));
        for (var b in list) {
          expect(b.log, isEmpty, reason: '$name: $value');
        }
      }

      // Even with nothing to run.
      await expectLater(
        <LifecycleBenchmark>[].runAll(profile: _profile.copyWith(rounds: 0)),
        invalid('rounds', 0),
      );
    });

    test('results without rounds compare after the others', () {
      var a = LifecycleBenchmark('a');
      var b = LifecycleBenchmark('b');

      // Runs always measure at least one round: a result without rounds can
      // only be built by hand. It still compares, without throwing.
      var empty = BenchmarkResult<int, String, LifecycleBenchmark>(a, []);
      var measured = BenchmarkResult<int, String, LifecycleBenchmark>(b, [
        roundOf(1, Duration(milliseconds: 1), 1),
      ]);
      expect(empty.compareTo(measured), greaterThan(0));
      expect(measured.compareTo(empty), lessThan(0));
      expect(empty.compareTo(empty), equals(0));
      expect([empty, measured].best, same(measured));
      expect([measured, empty].best, same(measured));
      expect(([empty, measured]..sort()).first, same(measured));

      var emptyEntry = MapEntry(a, <BenchmarkRoundResult>[]);
      var measuredEntry = MapEntry(b, measured.rounds);
      expect(emptyEntry.best(measuredEntry), same(measuredEntry));
      expect(measuredEntry.best(emptyEntry), same(measuredEntry));

      expect(<BenchmarkRoundResult>[].bestOrNull, isNull);
      expect(measured.rounds.bestOrNull, same(measured.rounds.single));
    });

    test('a single round prints no BEST ROUND section', () async {
      var (result, lines) = await capturePrints(
        () =>
            LifecycleBenchmark('single')
                .run(profile: _profile.copyWith(rounds: 1), verbose: true),
      );
      expect(result.rounds, hasLength(1));
      expect(lines.where((l) => l.startsWith('║ BEST ROUND')), isEmpty);
    });
  });

  group('verbose report', () {
    test('benchmark prints exactly the expected lines', () async {
      var bench = LifecycleBenchmark('report');

      var (result, lines) = await capturePrints(
        () => bench.run(profile: _profile, verbose: true),
      );

      expect(
        lines,
        equals(
          expectedRunReport(result, _profile, '${(setup: 7, service: 'svc')}'),
        ),
      );
    });

    test('runAll prints each run and an exact comparison summary', () async {
      // Titles of different lengths: the summary box is sized to the best.
      var list = [
        LifecycleBenchmark('a'),
        LifecycleBenchmark('bbbbbb'),
        LifecycleBenchmark('ccc'),
      ];

      var (results, lines) = await capturePrints(
        () => list.runAll(profile: _profile, verbose: true),
      );

      final setupRecord = '${(setup: 7, service: 'svc')}';
      final expected = <String>[
        for (var r in results) ...expectedRunReport(r, _profile, setupRecord),
      ];
      expect(lines.sublist(0, expected.length), equals(expected));

      final best = results.best;
      final bestRound = best.rounds.best;
      final w = best.benchmark.title.length;
      final others = (results.toList()..sort()).where((r) => r != best);

      expect(
        lines.sublist(expected.length),
        equals([
          '╔═${'═' * w}══',
          '║ BEST BENCHMARK: ${best.benchmark.title} '
              '(round: ${bestRound.round})',
          '║',
          '║ »» Duration: ${bestRound.duration}',
          '║ »» Speed: ${bestRound.hertzFormatted}',
          '║ »» Interaction Time: ${bestRound.interactionTimeFormatted}',
          for (var r in others) ...[
            '╠─${'─' * w}──',
            '║ BENCHMARK: ${r.benchmark.title} (round: ${r.rounds.best.round})',
            '║ »» Duration: ${r.rounds.best.duration}',
            '║ »» Speed: ${r.rounds.best.hertzFormatted}',
            '║ »» Interaction Time: ${r.rounds.best.interactionTimeFormatted}',
            '║ »» Speed ratio: ${r.rounds.best.speedRatioFormatted(bestRound)}',
          ],
          '╚═${'═' * w}══',
          '',
        ]),
      );
      expect(others, hasLength(2));
    });
  });

  group('runAll ordering', () {
    List<LifecycleBenchmark> many(int n) => [
      for (var i = 0; i < n; ++i) LifecycleBenchmark('b$i'),
    ];

    Future<List<String>> order(
      List<LifecycleBenchmark> list, {
      required bool shuffle,
      int? seed,
    }) async {
      var results = await list.runAll(
        profile: BenchmarkProfile.instant,
        shuffle: shuffle,
        shuffleSeed: seed,
      );
      return [for (var r in results) r.benchmark.title];
    }

    test('the same seed gives the same order, run after run', () async {
      var titles = [for (var b in many(20)) b.title];

      var first = await order(many(20), shuffle: true, seed: 2024);
      var second = await order(many(20), shuffle: true, seed: 2024);

      expect(second, equals(first));
      expect(first, equals(titles.toList()..shuffle(math.Random(2024))));
      // With 20 benchmarks, a seeded shuffle that keeps the input order
      // would be a 1 in 20! coincidence.
      expect(first, isNot(equals(titles)));
    });

    test('different seeds give the orders those seeds produce', () async {
      var titles = [for (var b in many(12)) b.title];

      for (var seed in [1, 2, 3]) {
        expect(
          await order(many(12), shuffle: true, seed: seed),
          equals(titles.toList()..shuffle(math.Random(seed))),
        );
      }
    });

    test('an unseeded shuffle still runs every benchmark once', () async {
      var list = many(15);

      var titles = await order(list, shuffle: true);

      expect(titles, unorderedEquals([for (var b in list) b.title]));
      for (var b in list) {
        expect(
          b.log,
          equals([
            '${b.title}:setup',
            '${b.title}:teardown',
            '${b.title}:shutdown',
          ]),
        );
      }
    });

    test('shuffleSeed is ignored without shuffle', () async {
      var list = many(10);
      expect(
        await order(list, shuffle: false, seed: 99),
        equals([for (var b in list) b.title]),
      );
    });

    test('runs a lazy iterable once, in order', () async {
      var created = 0;
      var lazy = Iterable.generate(4, (i) {
        ++created;
        return LifecycleBenchmark('lazy$i');
      });

      var results = await lazy.runAll(profile: BenchmarkProfile.instant);

      expect(
        results.map((r) => r.benchmark.title),
        equals(['lazy0', 'lazy1', 'lazy2', 'lazy3']),
      );
      // The receiver is iterated once: the summary uses the results.
      expect(created, equals(4));
    });
  });

  group('errors in the middle of a run', () {
    test(
      'a failing job stops runAll, after shutting down that benchmark',
      () async {
        var log = <String>[];
        var list = [
          LifecycleBenchmark('ok', log: log),
          // Fails in round 1 (after the 2 warmup jobs).
          LifecycleBenchmark('bad', log: log, failAtJob: 4),
          LifecycleBenchmark('never', log: log),
        ];

        await expectLater(
          list.runAll(profile: _profile),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'job 4 failed',
            ),
          ),
        );

        expect(
          log,
          equals([
            'ok:setup',
            'ok:teardown',
            'ok:teardown',
            'ok:shutdown',
            'bad:setup',
            // No teardown for the interrupted round, but its resources are
            // still released.
            'bad:shutdown',
          ]),
        );
        expect(list[2].jobs, equals(0));
      },
    );

    test('a failing warmup job shuts the benchmark down', () async {
      var bench = LifecycleBenchmark('warmup', failAtJob: 1);

      await expectLater(bench.run(profile: _profile), throwsStateError);
      expect(bench.log, equals(['warmup:setup', 'warmup:shutdown']));
    });

    test('a failing teardown shuts the benchmark down', () async {
      var bench = LifecycleBenchmark('teardown', failAtTeardown: 1);

      await expectLater(
        bench.run(profile: _profile),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'teardown failed',
          ),
        ),
      );
      // Round 2 never starts.
      expect(bench.jobs, equals(2 + 3));
      expect(
        bench.log,
        equals(['teardown:setup', 'teardown:teardown', 'teardown:shutdown']),
      );
    });

    test('the job error is reported even if shutdown also fails', () async {
      var bench = LifecycleBenchmark('both', failAtJob: 3, failShutdown: true);

      await expectLater(
        bench.run(profile: _profile),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'job 3 failed'),
        ),
      );
      expect(bench.log, equals(['both:setup', 'both:shutdown']));
    });

    test(
      'a failing shutdown after a successful run is reported once',
      () async {
        var bench = LifecycleBenchmark('shutdown', failShutdown: true);

        await expectLater(
          bench.run(profile: _profile),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'shutdown failed',
            ),
          ),
        );
        expect(bench.log.where((l) => l == 'shutdown:shutdown'), hasLength(1));
      },
    );

    test('a failing setup runs nothing else', () async {
      var bench = _FailingSetupBenchmark();

      await expectLater(bench.run(profile: _profile), throwsStateError);
      expect(bench.calls, equals(['setup']));
    });
  });

  group('concurrent runs', () {
    test('benchmarks run concurrently keep their own state', () async {
      var a = LifecycleBenchmark('a');
      var b = LifecycleBenchmark('b');

      var [ra, rb] = await Future.wait([
        a.run(profile: _profile),
        b.run(profile: _profile.copyWith(interactions: 5)),
      ]);

      expect(ra.benchmark, same(a));
      expect(rb.benchmark, same(b));
      expect(a.jobs, equals(2 + 2 * 3));
      expect(b.jobs, equals(2 + 2 * 5));
      expect(ra.rounds.every((r) => r.interactions == 3), isTrue);
      expect(rb.rounds.every((r) => r.interactions == 5), isTrue);
      expect(
        a.log,
        equals(['a:setup', 'a:teardown', 'a:teardown', 'a:shutdown']),
      );
      expect(
        b.log,
        equals(['b:setup', 'b:teardown', 'b:teardown', 'b:shutdown']),
      );
    });

    test('the same benchmark run twice at once', () async {
      var bench = LifecycleBenchmark('twice');

      var results = await Future.wait([
        bench.run(profile: _profile),
        bench.run(profile: _profile),
      ]);

      expect(results.map((r) => r.benchmark), everyElement(same(bench)));
      expect(bench.jobs, equals(2 * (2 + 2 * 3)));
      expect(bench.log.where((l) => l == 'twice:setup'), hasLength(2));
      expect(bench.log.where((l) => l == 'twice:shutdown'), hasLength(2));
    });
  });
}

class _FailingSetupBenchmark extends Benchmark<void, void> {
  final List<String> calls = [];

  _FailingSetupBenchmark() : super('failing-setup');

  @override
  BenchmarkSetupResult<void, void> setup() {
    calls.add('setup');
    throw StateError('setup failed');
  }

  @override
  void job(void setup, void service) => calls.add('job');

  @override
  void teardown(void setup, void service) => calls.add('teardown');

  @override
  void shutdown(void setup, void service) => calls.add('shutdown');
}
