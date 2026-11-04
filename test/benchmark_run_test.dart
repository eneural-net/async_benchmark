import 'dart:async';
import 'dart:math' as math;

import 'package:async_benchmark/async_benchmark.dart';
import 'package:test/test.dart';

/// Records every lifecycle call, so tests can assert on what ran and with
/// which arguments rather than on timing.
class RecordingBenchmark extends Benchmark<String, List<String>> {
  final List<String> log = [];

  int jobs = 0;
  int teardowns = 0;
  int shutdowns = 0;

  /// When set, `job` awaits before counting, to prove it is awaited.
  final bool asyncJob;

  RecordingBenchmark(super.title, {this.asyncJob = false});

  @override
  Future<BenchmarkSetupResult<String, List<String>>> setup() async {
    log.add('setup');
    return (setup: 'setup:$title', service: log);
  }

  @override
  FutureOr<void> job(String setup, List<String>? service) async {
    expect(setup, equals('setup:$title'));
    expect(service, same(log));
    if (asyncJob) await Future<void>.delayed(Duration.zero);
    ++jobs;
  }

  @override
  void teardown(String setup, List<String>? service) {
    log.add('teardown@$jobs');
    ++teardowns;
  }

  @override
  void shutdown(String setup, List<String>? service) {
    log.add('shutdown');
    ++shutdowns;
  }

  @override
  String toString() => 'RecordingBenchmark[$title]';
}

/// Uses the default [Benchmark.setup], [Benchmark.teardown] and
/// [Benchmark.shutdown].
class DefaultsBenchmark extends Benchmark<int?, Object> {
  final List<(int?, Object?)> calls = [];

  DefaultsBenchmark() : super('defaults');

  @override
  void job(int? setup, Object? service) => calls.add((setup, service));
}

const _profile = BenchmarkProfile(
  'test',
  warmup: 2,
  interactions: 3,
  rounds: 2,
);

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

void main() {
  group('benchmark', () {
    test(
      'runs setup, warmup, rounds, teardown and shutdown in order',
      () async {
        var bench = RecordingBenchmark('order');

        var result = await benchmark<String, List<String>, RecordingBenchmark>(
          bench,
          profile: _profile,
        );

        expect(result.benchmark, same(bench));
        // warmup (2) + rounds (2) * interactions (3)
        expect(bench.jobs, equals(8));
        expect(
          bench.log,
          equals(['setup', 'teardown@5', 'teardown@8', 'shutdown']),
        );

        expect(result.rounds.map((r) => r.round), equals([1, 2]));
        for (var r in result.rounds) {
          expect(r.interactions, equals(3));
          expect(r.endTime.isBefore(r.initTime), isFalse);
        }
      },
    );

    test('awaits asynchronous jobs', () async {
      var bench = RecordingBenchmark('async', asyncJob: true);
      await bench.run(profile: _profile);
      expect(bench.jobs, equals(8));
    });

    test('warmup and interactions override the profile', () async {
      var bench = RecordingBenchmark('override');

      var result = await bench.run(
        profile: _profile,
        warmup: 0,
        interactions: 5,
      );

      expect(bench.jobs, equals(10));
      expect(result.rounds.length, equals(2));
      expect(result.rounds.every((r) => r.interactions == 5), isTrue);
    });

    test('defaults to the normal profile', () async {
      var bench = RecordingBenchmark('normal');

      var result = await bench.run();

      final normal = BenchmarkProfile.normal;
      expect(result.rounds.length, equals(normal.rounds));
      expect(
        bench.jobs,
        equals(normal.warmup + normal.rounds * normal.interactions),
      );
    });

    test('default setup, teardown and shutdown', () async {
      var bench = DefaultsBenchmark();

      var result = await bench.run(profile: BenchmarkProfile.instant);

      expect(result.rounds.length, equals(1));
      expect(bench.calls, equals([(null, null), (null, null)]));
    });

    test('propagates errors thrown by the job', () async {
      var bench = _ThrowingJobBenchmark();
      await expectLater(
        bench.run(profile: BenchmarkProfile.instant),
        throwsA(isA<StateError>()),
      );
    });

    test('verbose prints a report; quiet prints nothing', () async {
      var (_, quiet) = await capturePrints(
        () => RecordingBenchmark('quiet').run(profile: _profile),
      );
      expect(quiet, isEmpty);

      var (_, withProfile) = await capturePrints(
        () => RecordingBenchmark('loud').run(profile: _profile, verbose: true),
      );
      expect(withProfile, contains('║ loud ║'));
      expect(withProfile, contains('║ $_profile'));
      expect(withProfile, contains('║ ROUND: 2/2'));
      expect(withProfile.any((l) => l.startsWith('║ BEST ROUND: ')), isTrue);
      expect(withProfile, contains('║ Setup...'));
      expect(withProfile, contains('║ Shutdown...'));

      var (_, noProfile) = await capturePrints(
        () => RecordingBenchmark('loud').run(warmup: 0, verbose: true),
      );
      expect(noProfile, contains('║ warmup: 0'));
      expect(noProfile, contains('║ interactions: 1000'));
      expect(noProfile, contains('║ rounds: 3'));
    });
  });

  group('runAll', () {
    List<RecordingBenchmark> benchmarks() => [
      for (var t in ['a', 'b', 'c', 'd', 'e']) RecordingBenchmark(t),
    ];

    test('runs every benchmark in order', () async {
      var list = benchmarks();

      var results = await list.runAll(profile: _profile);

      expect(results.map((r) => r.benchmark), equals(list));
      for (var b in list) {
        expect(b.jobs, equals(8));
        expect(b.shutdowns, equals(1));
      }
    });

    test('an empty iterable returns no results', () async {
      var (results, lines) = await capturePrints(
        () => <RecordingBenchmark>[].runAll(profile: _profile, verbose: true),
      );
      expect(results, isEmpty);
      expect(lines, isEmpty);
    });

    test('shuffle with a seed is deterministic', () async {
      var list = benchmarks();

      var results = await list.runAll(
        profile: BenchmarkProfile.instant,
        shuffle: true,
        shuffleSeed: 42,
        interactionDelay: Duration(milliseconds: 1),
      );

      var expected = list.toList()..shuffle(math.Random(42));
      expect(results.map((r) => r.benchmark), equals(expected));
      // The receiver is not shuffled in place.
      expect(list.map((b) => b.title), equals(['a', 'b', 'c', 'd', 'e']));
    });

    test('verbose prints a summary comparing every benchmark', () async {
      var list = benchmarks().take(3).toList();

      var (results, lines) = await capturePrints(
        () => list.runAll(profile: _profile, verbose: true),
      );

      var best = results.best.benchmark.title;
      expect(
        lines.where((l) => l.startsWith('║ BEST BENCHMARK: $best ')),
        hasLength(1),
      );
      // Every other benchmark is compared against the best one.
      expect(lines.where((l) => l.startsWith('║ BENCHMARK: ')), hasLength(2));
      expect(
        lines.where((l) => l.startsWith('║ »» Speed ratio: ')),
        hasLength(2),
      );
    });

    test('a single benchmark has no comparison lines', () async {
      var (_, lines) = await capturePrints(
        () =>
            [RecordingBenchmark('solo')]
                .runAll(profile: BenchmarkProfile.instant, verbose: true),
      );
      expect(lines.any((l) => l.startsWith('║ BEST BENCHMARK: solo ')), isTrue);
      expect(lines.any((l) => l.startsWith('║ BENCHMARK: ')), isFalse);
    });
  });
}

class _ThrowingJobBenchmark extends Benchmark<void, void> {
  _ThrowingJobBenchmark() : super('throwing-job');

  @override
  void job(void setup, void service) => throw StateError('job failed');
}
