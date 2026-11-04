import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

/// Type for setup value and shutting down benchmarks service on an [Isolate].
typedef BenchmarkOnIsolateSetup<S> = ({
  S setup,
  Future<void> Function() shutdown,
});

/// A class that runs benchmarks on an [Isolate], extending the [Benchmark] class.
/// This class encapsulates setup, job execution, teardown, and shutdown
/// of benchmarks executed on a separate [Isolate].
class _BenchmarkOnIsolate<S, O, B extends Benchmark<S, O>>
    extends Benchmark<BenchmarkOnIsolateSetup<S>, O> {
  /// The benchmark instance that this class is managing.
  final B benchmark;

  /// An optional additional delay to wait after [Isolate] shutdown.
  /// Useful if system resources require time to synchronize with
  /// Dart's shutdown operations.
  final Duration? shutdownIsolateDelay;

  _BenchmarkOnIsolate(this.benchmark, {this.shutdownIsolateDelay})
    : super(benchmark.title);

  /// Sets up the benchmark on the [Isolate], returning a [BenchmarkSetupResult]
  /// containing setup data and service information.
  @override
  Future<BenchmarkSetupResult<BenchmarkOnIsolateSetup<S>, O>> setup() async {
    var r = await _runSetupOnIsolate(benchmark);
    return (setup: r, service: null);
  }

  /// Shuts down the benchmark by calling the [shutdown] method on both the
  /// [Isolate] and the benchmark itself.
  @override
  Future<void> shutdown(BenchmarkOnIsolateSetup<S> setup, O? service) async {
    try {
      await benchmark.shutdown(setup.setup, service);
    } finally {
      // Stop the isolate even if the caller's `shutdown` throws: a running
      // isolate keeps the process alive.
      await setup.shutdown();
    }

    var shutdownIsolateDelay = this.shutdownIsolateDelay;
    if (shutdownIsolateDelay != null) {
      await Future.delayed(shutdownIsolateDelay);
    }
  }

  /// Executes the benchmark job.
  @override
  FutureOr<void> job(BenchmarkOnIsolateSetup<S> setup, O? service) =>
      benchmark.job(setup.setup, service);

  /// Teardown after running the job, by invoking the [teardown] method of the
  /// benchmark.
  @override
  FutureOr<void> teardown(BenchmarkOnIsolateSetup<S> setup, O? service) =>
      benchmark.teardown(setup.setup, service);

  /// Runs the setup of the benchmark on a separate [Isolate].
  /// Returns a [BenchmarkOnIsolateSetup] containing setup data and shutdown function.
  static Future<BenchmarkOnIsolateSetup<S>> _runSetupOnIsolate<S, O>(
    Benchmark<S, O> benchmark,
  ) async {
    final receivePort = ReceivePort();
    final errorPort = ReceivePort();

    // Both ports must be closed once the isolate is done: an open
    // `ReceivePort` keeps the calling isolate (and the process) alive.
    void closePorts() {
      receivePort.close();
      errorPort.close();
    }

    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _isolateRunSetup,
        (receivePort.sendPort, benchmark),
        onError: errorPort.sendPort,
        debugName: '${benchmark.runtimeType}[${benchmark.title}]',
      );
    } catch (_) {
      // E.g. the benchmark can't be sent to an isolate.
      closePorts();
      rethrow;
    }

    // The isolate's `SendPort` and the setup value, sent together so that a
    // setup value of any type (even a `SendPort`) is recognized.
    final startCompleter = Completer<(SendPort, S)>();
    final stopCompleter = Completer<void>();
    // An error after setup is only rethrown if `shutdown` is awaited;
    // don't report it as unhandled before that.
    stopCompleter.future.ignore();

    receivePort.listen((message) {
      if (message == '<stopped>') {
        closePorts();
        stopCompleter.complete();
        isolate.kill();
      } else if (message is (SendPort, Object?)) {
        startCompleter.complete((message.$1, message.$2 as S));
      }
    });

    // Errors thrown by `setup`/`shutdown` on the isolate terminate it: forward
    // them instead of waiting forever for a message that won't come.
    // `onError` messages are `[error, stackTrace]`, both as strings.
    errorPort.listen((message) {
      final [description, stackTrace] = message as List;
      final error = RemoteError('$description', '$stackTrace');

      closePorts();
      isolate.kill(priority: Isolate.immediate);

      if (!startCompleter.isCompleted) {
        startCompleter.completeError(error, error.stackTrace);
      } else if (!stopCompleter.isCompleted) {
        stopCompleter.completeError(error, error.stackTrace);
      }
    });

    var (isolateSendPort, setup) = await startCompleter.future;

    Future<void> shutdown() async {
      isolateSendPort.send('shutdown');
      await stopCompleter.future;
    }

    return (setup: setup, shutdown: shutdown);
  }

  /// Runs the benchmark setup in an [Isolate].
  static void _isolateRunSetup((SendPort, Benchmark) args) async {
    final sendPort = args.$1;
    final benchmark = args.$2;

    var s = await benchmark.setup();

    final receivePort = ReceivePort();
    sendPort.send((receivePort.sendPort, s.setup));

    final shutdownCompleter = Completer<void>();

    receivePort.listen((message) async {
      if (message == 'shutdown') {
        await benchmark.shutdown(s.setup, s.service);
        sendPort.send('<stopped>');
        shutdownCompleter.complete();
      }
    });

    await shutdownCompleter.future;
    receivePort.close();
  }
}

/// Represents a profile configuration for benchmarking.
class BenchmarkProfile {
  /// A pre-defined benchmarking profile for instant/quick performance tests
  /// to ensure the benchmark runs successfully.
  static final instant = const BenchmarkProfile(
    'instant',
    warmup: 1,
    interactions: 1,
    rounds: 1,
  );

  /// A pre-defined benchmarking profile for fast performance tests.
  static final fast = const BenchmarkProfile(
    'fast',
    warmup: 10,
    interactions: 100,
    rounds: 1,
  );

  /// A pre-defined benchmarking profile for normal performance tests.
  static final normal = const BenchmarkProfile(
    'normal',
    warmup: 100,
    interactions: 1000,
    rounds: 3,
  );

  /// A pre-defined benchmarking profile for heavy performance tests.
  static final heavy = const BenchmarkProfile(
    'heavy',
    warmup: 1000,
    interactions: 10000,
    rounds: 10,
  );

  /// The name of the benchmark profile.
  final String name;

  /// The number of warmup iterations for the benchmark.
  final int warmup;

  /// The number of interactions per benchmark round.
  final int interactions;

  /// The number of rounds for the benchmark.
  final int rounds;

  /// Constructs a custom [BenchmarkProfile].
  ///
  /// The values are not checked here (this constructor is `const`): they are
  /// checked by [validate], which every run calls before running anything.
  const BenchmarkProfile(
    this.name, {
    required this.warmup,
    required this.interactions,
    required this.rounds,
  });

  /// Creates a copy of the current `BenchmarkProfile` instance with updated values.
  BenchmarkProfile copyWith({
    String? name,
    int? warmup,
    int? interactions,
    int? rounds,
  }) => BenchmarkProfile(
    name ?? this.name,
    warmup: warmup ?? this.warmup,
    interactions: interactions ?? this.interactions,
    rounds: rounds ?? this.rounds,
  );

  /// Checks that this profile can be run, throwing an [ArgumentError] naming
  /// the first invalid field:
  /// - [warmup] must be `>= 0` (`0` runs no warmup);
  /// - [interactions] must be `>= 1` (a round without interactions measures
  ///   nothing);
  /// - [rounds] must be `>= 1` (a run without rounds has no result).
  ///
  /// There is no upper limit: a large count only makes the run longer.
  ///
  /// [benchmark], [BenchmarkExtension.run] and
  /// [IterableBenchmarkExtension.runAll] call it (with their `warmup` and
  /// `interactions` overrides applied) before running anything.
  void validate() {
    if (warmup < 0) {
      throw ArgumentError.value(warmup, 'warmup', 'Must not be negative');
    }
    if (interactions < 1) {
      throw ArgumentError.value(
        interactions,
        'interactions',
        'Must be at least 1',
      );
    }
    if (rounds < 1) {
      throw ArgumentError.value(rounds, 'rounds', 'Must be at least 1');
    }
  }

  @override
  String toString() =>
      'BenchmarkProfile[$name]{warmup: $warmup, interactions: $interactions, rounds: $rounds}';
}

/// Result type for benchmark setup, consisting of setup data and an optional service.
/// The [service], if defined, won't be shared between [Isolate]s.
typedef BenchmarkSetupResult<S, O> = ({S setup, O? service});

/// Abstract class that defines the core structure of a benchmark test.
abstract class Benchmark<S, O> {
  /// The title or name of the benchmark.
  final String title;

  /// Constructs a [Benchmark].
  const Benchmark(this.title);

  /// Sets up the benchmark, returning a result that includes setup data and an optional service.
  /// The [service], if defined, won't be shared between [Isolate]s.
  FutureOr<BenchmarkSetupResult<S, O>> setup() async {
    return (setup: null as S, service: null);
  }

  /// Executes the benchmark job with the provided setup and service.
  FutureOr<void> job(S setup, O? service);

  /// Performs any necessary teardown after the benchmark job iterations are executed.
  FutureOr<void> teardown(S setup, O? service) async {}

  /// Shuts down the benchmark by cleaning up any resources.
  /// When running in an [Isolate], the [service] should be finalized.
  FutureOr<void> shutdown(S setup, O? service) async {}
}

extension BenchmarkExtension<S, O, B extends Benchmark<S, O>> on B {
  /// Runs the benchmark with the specified profile and options.
  Future<BenchmarkResult<S, O, B>> run({
    BenchmarkProfile? profile,
    int? warmup,
    int? interactions,
    bool setupOnIsolate = false,
    Duration? shutdownIsolateDelay,
    bool verbose = false,
  }) => benchmark(
    this,
    profile: profile,
    warmup: warmup,
    interactions: interactions,
    setupOnIsolate: setupOnIsolate,
    shutdownIsolateDelay: shutdownIsolateDelay,
    verbose: verbose,
  );
}

extension IterableBenchmarkExtension<S, O, B extends Benchmark<S, O>>
    on Iterable<B> {
  /// Runs all benchmarks in the iterable collection with the specified options.
  ///
  /// The counts are validated (see [BenchmarkProfile.validate]) before any
  /// benchmark runs: invalid counts throw an [ArgumentError] and run nothing.
  Future<List<BenchmarkResult<S, O, B>>> runAll({
    BenchmarkProfile? profile,
    int? warmup,
    int? interactions,
    Duration? interactionDelay,
    bool setupOnIsolate = false,
    Duration? shutdownIsolateDelay,
    bool shuffle = false,
    int? shuffleSeed,
    bool verbose = false,
  }) async {
    _effectiveProfile(profile, warmup, interactions);

    var results = <BenchmarkResult<S, O, B>>[];

    var benchmarks = this;

    if (shuffle) {
      var rand = math.Random(shuffleSeed);
      var benchmarksShuffled = benchmarks.toList();
      benchmarksShuffled.shuffle(rand);

      benchmarks = benchmarksShuffled;
    }

    for (var b in benchmarks) {
      var r = await benchmark<S, O, B>(
        b,
        profile: profile,
        warmup: warmup,
        interactions: interactions,
        setupOnIsolate: setupOnIsolate,
        shutdownIsolateDelay: shutdownIsolateDelay,
        verbose: verbose,
      );

      results.add(r);

      if (interactionDelay != null) {
        await Future.delayed(interactionDelay);
      }
    }

    // Only results with rounds can be compared (all of them, for validated
    // counts).
    final measured = results.where((r) => r.rounds.isNotEmpty).toList();

    if (measured.isNotEmpty) {
      var bestResult = measured.best;

      var bestBench = bestResult.benchmark;
      var bestRound = bestResult.rounds.best;

      if (verbose) {
        print('╔═${'═' * bestBench.title.length}══');
        print(
          '║ BEST BENCHMARK: ${bestBench.title} (round: ${bestRound.round})',
        );
        print('║');
        print('║ »» Duration: ${bestRound.duration}');
        print('║ »» Speed: ${bestRound.hertzFormatted}');
        print('║ »» Interaction Time: ${bestRound.interactionTimeFormatted}');
      }

      if (measured.length > 1) {
        var resultsSorted = measured.toList();
        resultsSorted.sort();

        final line = '╠─${'─' * bestBench.title.length}──';

        for (var r in resultsSorted) {
          if (r == bestResult) continue;

          var bench = r.benchmark;
          var rounds = r.rounds;
          var best = rounds.best;

          if (verbose) {
            print(line);
            print('║ BENCHMARK: ${bench.title} (round: ${best.round})');
            print('║ »» Duration: ${best.duration}');
            print('║ »» Speed: ${best.hertzFormatted}');
            print('║ »» Interaction Time: ${best.interactionTimeFormatted}');
            print('║ »» Speed ratio: ${best.speedRatioFormatted(bestRound)}');
          }
        }
      }

      if (verbose) {
        print('╚═${'═' * bestBench.title.length}══');
        print('');
      }
    }

    return results;
  }
}

extension MapEntryBenchmarkResultsExtension<S, O, B extends Benchmark<S, O>>
    on MapEntry<B, List<BenchmarkRoundResult>> {
  /// Returns the entry with the best performance (higher Hertz value).
  /// An entry without rounds loses to one with rounds.
  MapEntry<B, List<BenchmarkRoundResult>> best(
    MapEntry<B, List<BenchmarkRoundResult>> other,
  ) => _compareBestRounds(value, other.value) <= 0 ? this : other;
}

/// Compares the best rounds of [a] and [b] (as [BenchmarkRoundResult.compareTo]
/// does): negative if [a]'s is faster. A list without rounds sorts after one
/// with rounds.
int _compareBestRounds(
  Iterable<BenchmarkRoundResult> a,
  Iterable<BenchmarkRoundResult> b,
) {
  final bestA = a.bestOrNull;
  final bestB = b.bestOrNull;
  if (bestA == null) return bestB == null ? 0 : 1;
  if (bestB == null) return -1;
  return bestA.compareTo(bestB);
}

/// A structure that contains the results of a benchmark execution.
class BenchmarkResult<S, O, B extends Benchmark<S, O>>
    implements Comparable<BenchmarkResult<S, O, B>> {
  /// The [Benchmark] that was executed.
  final B benchmark;

  /// The results of the execution rounds ([BenchmarkRoundResult]).
  final List<BenchmarkRoundResult> rounds;

  BenchmarkResult(this.benchmark, this.rounds);

  /// Compares the best rounds: negative if this result is faster. A result
  /// without rounds sorts after one with rounds.
  @override
  int compareTo(BenchmarkResult<S, O, B> other) =>
      _compareBestRounds(rounds, other.rounds);

  /// Returns the [BenchmarkResult] with the best performance (higher Hertz value).
  /// A result without rounds loses to one with rounds.
  BenchmarkResult<S, O, B> best(BenchmarkResult<S, O, B> other) =>
      compareTo(other) <= 0 ? this : other;

  @override
  String toString() =>
      'BenchmarkResult{benchmark: $benchmark, rounds: ${rounds.length}}';
}

extension IterableBenchmarkResultExtension<
  S,
  O,
  B extends Benchmark<S, O>,
  R extends BenchmarkResult<S, O, B>
>
    on Iterable<R> {
  /// Returns the [BenchmarkResult] with the best performance (higher Hertz
  /// value). Throws a [StateError] if there are no results.
  R get best => reduce((a, b) => a.best(b) as R);
}

/// Represents a single round of a [Benchmark], including performance details.
class BenchmarkRoundResult implements Comparable<BenchmarkRoundResult> {
  /// The round number for the [Benchmark].
  final int round;

  /// The initial time of the [Benchmark] round.
  final DateTime initTime;

  /// The end time of the [Benchmark] round.
  final DateTime endTime;

  /// The number of job interactions executed.
  final int interactions;

  /// The total duration of the round execution.
  late final Duration duration = endTime.difference(initTime);

  /// Whether the round measured something: it has [interactions] and a
  /// positive [duration]. Otherwise [hertzFormatted],
  /// [interactionTimeFormatted] and [speedRatioFormatted] print `n/a`.
  bool get isMeasurable => interactions > 0 && duration > Duration.zero;

  /// The Hertz value representing the performance ([interactions] per second).
  ///
  /// - `0` if there are no [interactions].
  /// - [double.infinity] if the [duration] is zero (or negative): the round
  ///   was faster than the clock resolution. It compares as the fastest.
  late final double hertz = interactions <= 0
      ? 0
      : duration <= Duration.zero
      ? double.infinity
      : (interactions / duration.inMicroseconds) * (1000 * 1000);

  /// The average time per job interaction in milliseconds.
  ///
  /// - [double.nan] if there are no [interactions].
  /// - `0` if the [duration] is zero (or negative).
  late final double interactionTimeMs = interactions <= 0
      ? double.nan
      : duration <= Duration.zero
      ? 0
      : (duration.inMicroseconds / interactions) / 1000;

  /// Why this round is not [isMeasurable], as printed in place of a value;
  /// `null` if it is.
  String? get _notMeasurable => interactions <= 0
      ? 'n/a (no interactions)'
      : duration <= Duration.zero
      ? 'n/a (too fast to measure)'
      : null;

  BenchmarkRoundResult(
    this.round,
    this.initTime,
    this.endTime,
    this.interactions,
  );

  /// A formatted string representing the [hertz] value, or
  /// `n/a (no interactions)` / `n/a (too fast to measure)` if the round is
  /// not [isMeasurable]. It never prints `Infinity` or `NaN`.
  String get hertzFormatted {
    final notMeasurable = _notMeasurable;
    if (notMeasurable != null) return notMeasurable;

    var hz = hertz;

    if (hz > 1) {
      var f = hz.toStringAsFixed(4);
      return '$f Hz';
    } else if (hz > 0.00001) {
      var f = hz.toStringAsFixed(8);
      return '$f Hz';
    } else {
      return '$hz Hz';
    }
  }

  /// A formatted string representing the [interactionTimeMs], or `n/a (...)`
  /// as in [hertzFormatted].
  String get interactionTimeFormatted {
    final notMeasurable = _notMeasurable;
    if (notMeasurable != null) return notMeasurable;

    var ms = interactionTimeMs;

    if (ms >= 2000) {
      var sec = ms / 1000;
      var f = sec.toStringAsFixed(3);
      return '$f sec';
    } else if (ms > 1000) {
      var sec = ms / 1000;
      var f = sec.toStringAsFixed(6);
      return '$f sec';
    } else if (ms >= 1) {
      var f = ms.toStringAsFixed(3);
      return '$f ms';
    } else {
      var mic = ms * 1000;
      if (mic >= 100) {
        var f = mic.toStringAsFixed(3);
        return '$f µs';
      } else {
        var f = mic.toStringAsFixed(6);
        return '$f µs';
      }
    }
  }

  /// The speed of this round relative to [best]'s, as printed by
  /// [IterableBenchmarkResultExtension.runAll]: `ratio (inverse x)`, both with
  /// 4 decimals, e.g. `0.5000 (2.0000 x)` for half the speed of [best].
  /// `n/a (...)` (as in [hertzFormatted]) if either round is not
  /// [isMeasurable].
  String speedRatioFormatted(BenchmarkRoundResult best) {
    final notMeasurable = _notMeasurable ?? best._notMeasurable;
    if (notMeasurable != null) return notMeasurable;

    final ratio = hertz / best.hertz;
    return '${ratio.toStringAsFixed(4)} (${(1 / ratio).toStringAsFixed(4)} x)';
  }

  @override
  int compareTo(BenchmarkRoundResult other) => other.hertz.compareTo(hertz);

  /// Returns the [BenchmarkRoundResult] with the best performance (higher Hertz value).
  BenchmarkRoundResult best(BenchmarkRoundResult other) =>
      compareTo(other) <= 0 ? this : other;

  @override
  String toString() =>
      'BenchmarkRoundResult{round: $round, interactions: $interactions, hertz: $hertzFormatted, interactionTime: $interactionTimeFormatted}';
}

extension BenchmarkRoundResultExtension on Iterable<BenchmarkRoundResult> {
  /// Returns the [BenchmarkRoundResult] with the best performance (higher Hertz value).
  ///
  /// Throws a [StateError] if there are no rounds: see [bestOrNull].
  BenchmarkRoundResult get best => reduce((a, b) => a.best(b));

  /// Like [best], but `null` if there are no rounds.
  BenchmarkRoundResult? get bestOrNull => isEmpty ? null : best;
}

/// Runs a benchmark with the specified configuration, executing the setup,
/// job, and teardown, and returns the [BenchmarkResult] including performance
/// details like round duration, Hertz and interaction time.
///
/// Parameters:
/// - [benchmark]: The benchmark instance to run. It must extend the [Benchmark] class.
/// - [profile]: An optional [BenchmarkProfile] to define the number of rounds, warmups,
///   and interactions (default: [BenchmarkProfile.normal]).
/// - [warmup]: An optional number of warmup iterations before the actual benchmark starts.
///   This overrides the [profile] warmup setting if provided.
/// - [interactions]: An optional number of interactions to perform in each benchmark round.
///   This overrides the [profile] interactions setting if provided.
/// - [setupOnIsolate]: A flag indicating whether to run the benchmark setup on a separate [Isolate].
///   Defaults to `false`, meaning the setup runs on the same [Isolate] as the job interactions.
/// - [verbose]: If `true`, prints detailed output during execution (default is `false`).
///
/// Returns a [BenchmarkResult] containing the benchmark performance metrics
/// (e.g., duration, interaction time) for each round.
///
/// If a [Benchmark.job] or [Benchmark.teardown] throws, [Benchmark.shutdown]
/// is still called (and any error it throws ignored) before the original
/// error is rethrown.
///
/// The counts are validated first (see [BenchmarkProfile.validate]): invalid
/// counts throw an [ArgumentError] before `setup` runs.
Future<BenchmarkResult<S, O, B>> benchmark<S, O, B extends Benchmark<S, O>>(
  B benchmark, {
  BenchmarkProfile? profile,
  int? warmup,
  int? interactions,
  bool setupOnIsolate = false,
  Duration? shutdownIsolateDelay,
  bool verbose = false,
}) async {
  final counts = _effectiveProfile(profile, warmup, interactions);

  if (setupOnIsolate) {
    var result = await _benchmarkImpl(
      _BenchmarkOnIsolate<S, O, B>(
        benchmark,
        shutdownIsolateDelay: shutdownIsolateDelay,
      ),
      profile: profile,
      counts: counts,
      setupOnIsolate: true,
      verbose: verbose,
    );
    return BenchmarkResult<S, O, B>(benchmark, result.rounds);
  } else {
    return _benchmarkImpl(
      benchmark,
      profile: profile,
      counts: counts,
      verbose: verbose,
    );
  }
}

/// The [profile] (default: [BenchmarkProfile.normal]) with the [warmup] and
/// [interactions] overrides applied, validated.
BenchmarkProfile _effectiveProfile(
  BenchmarkProfile? profile,
  int? warmup,
  int? interactions,
) => (profile ?? BenchmarkProfile.normal).copyWith(
  warmup: warmup,
  interactions: interactions,
)..validate();

Future<BenchmarkResult<S, O, B>>
_benchmarkImpl<S, O, B extends Benchmark<S, O>>(
  B benchmark, {
  required BenchmarkProfile? profile,
  required BenchmarkProfile counts,
  bool setupOnIsolate = false,
  bool verbose = false,
}) async {
  final title = benchmark.title;

  if (verbose) {
    print('╔═${'═' * title.length}═╗');
    print('║ $title ║');
    print('╠═${'═' * title.length}═╝');

    if (profile != null) {
      print('║ $profile');
    } else {
      print('║ warmup: ${counts.warmup}');
      print('║ interactions: ${counts.interactions}');
      print('║ rounds: ${counts.rounds}');
    }
  }

  final line = '╠─${'─' * title.length}──';

  if (verbose) {
    print(line);
    print(setupOnIsolate ? '║ Setup (on Isolate)...' : '║ Setup...');
  }

  var s = await benchmark.setup();

  if (verbose) {
    print('║ ─ $s');
  }

  final setup = s.setup;
  final service = s.service;

  final List<BenchmarkRoundResult> roundsResults;
  try {
    roundsResults = await _benchmarkRounds(
      benchmark,
      setup,
      service,
      warmup: counts.warmup,
      interactions: counts.interactions,
      rounds: counts.rounds,
      line: line,
      verbose: verbose,
    );
  } catch (_) {
    // A failing `job` or `teardown` still releases the benchmark's resources
    // (and stops the setup isolate, which would keep the process alive).
    // The original error is the one reported.
    try {
      await benchmark.shutdown(setup, service);
    } catch (_) {}
    rethrow;
  }

  if (verbose) {
    print(line);
    print('║ Shutdown...');
  }

  await benchmark.shutdown(setup, service);

  if (verbose) {
    print('╚═${'═' * title.length}══');
    print('');
  }

  return BenchmarkResult(benchmark, roundsResults);
}

/// Runs the warmup and the rounds of [_benchmarkImpl] (after `setup`, before
/// `shutdown`).
Future<List<BenchmarkRoundResult>> _benchmarkRounds<S, O>(
  Benchmark<S, O> benchmark,
  S setup,
  O? service, {
  required int warmup,
  required int interactions,
  required int rounds,
  required String line,
  required bool verbose,
}) async {
  await Future.delayed(Duration(milliseconds: 10));

  if (verbose) {
    print('║ Warmup ($warmup)...');
  }

  for (var i = 0; i < warmup; ++i) {
    await benchmark.job(setup, service);
  }

  var roundsResults = <BenchmarkRoundResult>[];

  for (var r = 1; r <= rounds; ++r) {
    if (verbose) {
      print(line);
      print('║ ROUND: $r/$rounds');
      print('║');
    }

    await Future.delayed(Duration(milliseconds: 10));

    if (verbose) {
      print('║ ─ Running ($interactions)...');
    }

    final initTime = DateTime.now();

    for (var i = 0; i < interactions; ++i) {
      await benchmark.job(setup, service);
    }

    final endTime = DateTime.now();

    if (verbose) {
      print('║ ─ Teardown...');
    }

    await benchmark.teardown(setup, service);

    if (verbose) {
      print('║');
    }

    var roundResult = BenchmarkRoundResult(r, initTime, endTime, interactions);

    roundsResults.add(roundResult);

    if (verbose) {
      print('║ »» Duration: ${roundResult.duration}');
      print('║ »» Speed: ${roundResult.hertzFormatted}');
      print('║ »» Interaction Time: ${roundResult.interactionTimeFormatted}');
    }
  }

  if (rounds > 1) {
    var bestRound = roundsResults.best;

    if (verbose) {
      print(line);
      print('║ BEST ROUND: ${bestRound.round}');
      print('║');
      print('║ »» Duration: ${bestRound.duration}');
      print('║ »» Speed: ${bestRound.hertzFormatted}');
      print('║ »» Interaction Time: ${bestRound.interactionTimeFormatted}');
    }
  }

  return roundsResults;
}
