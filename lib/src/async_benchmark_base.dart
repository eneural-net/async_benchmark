import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

/// Type for setup value and shutting down benchmarks service on an [Isolate].
typedef BenchmarkOnIsolateSetup<S> = ({
  S setup,
  Future<void> Function() shutdown
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
    await benchmark.shutdown(setup.setup, service);
    await setup.shutdown();

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
      Benchmark<S, O> benchmark) async {
    final receivePort = ReceivePort();

    var isolate = await Isolate.spawn(
      _isolateRunSetup,
      (receivePort.sendPort, benchmark),
      debugName: '${benchmark.runtimeType}[${benchmark.title}]',
    );

    final startCompleter = Completer<S>();
    final stopCompleter = Completer<void>();

    SendPort? isolateSendPort;

    receivePort.listen((message) {
      if (message == '<stopped>') {
        stopCompleter.complete();
        isolate.kill();
      } else if (message is SendPort) {
        isolateSendPort = message;
      } else if (message is S) {
        startCompleter.complete(message);
      }
    });

    var setup = await startCompleter.future;

    Future<void> shutdown() async {
      if (isolateSendPort != null) {
        isolateSendPort!.send('shutdown');
        await stopCompleter.future;
      }
    }

    return (setup: setup, shutdown: shutdown);
  }

  /// Runs the benchmark setup in an [Isolate].
  static void _isolateRunSetup((SendPort, Benchmark) args) async {
    final sendPort = args.$1;
    final benchmark = args.$2;

    final receivePort = ReceivePort();

    sendPort.send(receivePort.sendPort);

    var s = await benchmark.setup();
    sendPort.send(s.setup);

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
  static final instant =
      const BenchmarkProfile('instant', warmup: 1, interactions: 1, rounds: 1);

  /// A pre-defined benchmarking profile for fast performance tests.
  static final fast =
      const BenchmarkProfile('fast', warmup: 10, interactions: 100, rounds: 1);

  /// A pre-defined benchmarking profile for normal performance tests.
  static final normal = const BenchmarkProfile('normal',
      warmup: 100, interactions: 1000, rounds: 3);

  /// A pre-defined benchmarking profile for heavy performance tests.
  static final heavy = const BenchmarkProfile('heavy',
      warmup: 1000, interactions: 10000, rounds: 10);

  /// The name of the benchmark profile.
  final String name;

  /// The number of warmup iterations for the benchmark.
  final int warmup;

  /// The number of interactions per benchmark round.
  final int interactions;

  /// The number of rounds for the benchmark.
  final int rounds;

  /// Constructs a custom [BenchmarkProfile].
  const BenchmarkProfile(this.name,
      {required this.warmup, required this.interactions, required this.rounds});

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
    verbose = false,
  }) =>
      benchmark(this,
          profile: profile,
          warmup: warmup,
          interactions: interactions,
          setupOnIsolate: setupOnIsolate,
          verbose: verbose);
}

extension IterableBenchmarkExtension<S, O, B extends Benchmark<S, O>>
    on Iterable<B> {
  /// Runs all benchmarks in the iterable collection with the specified options.
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
    var results = <BenchmarkResult<S, O, B>>[];

    var benchmarks = this;

    if (shuffle) {
      var rand = math.Random(shuffleSeed);
      var benchmarksShuffled = benchmarks.toList();
      benchmarksShuffled.shuffle(rand);

      benchmarks = benchmarksShuffled;
    }

    for (var b in benchmarks) {
      var r = await benchmark<S, O, B>(b,
          profile: profile,
          warmup: warmup,
          interactions: interactions,
          setupOnIsolate: setupOnIsolate,
          shutdownIsolateDelay: shutdownIsolateDelay,
          verbose: verbose);

      results.add(r);

      if (interactionDelay != null) {
        await Future.delayed(interactionDelay);
      }
    }

    if (results.isNotEmpty) {
      var bestResult = results.best;

      var bestBench = bestResult.benchmark;
      var bestRound = bestResult.rounds.best;

      if (verbose) {
        print('╔═${'═' * bestBench.title.length}══');
        print(
            '║ BEST BENCHMARK: ${bestBench.title} (round: ${bestRound.round})');
        print('║');
        print('║ »» Duration: ${bestRound.duration}');
        print('║ »» Speed: ${bestRound.hertzFormatted}');
        print('║ »» Interaction Time: ${bestRound.interactionTimeFormatted}');
      }

      if (results.length > 1) {
        var resultsSorted = results.toList();
        resultsSorted.sort();

        final line = '╠─${'─' * bestBench.title.length}──';

        for (var r in resultsSorted) {
          if (r == bestResult) continue;

          var bench = r.benchmark;
          var rounds = r.rounds;
          var best = rounds.best;

          var ratio = best.hertz / bestRound.hertz;

          if (verbose) {
            print(line);
            print('║ BENCHMARK: ${bench.title} (round: ${best.round})');
            print('║ »» Duration: ${best.duration}');
            print('║ »» Speed: ${best.hertzFormatted}');
            print('║ »» Interaction Time: ${best.interactionTimeFormatted}');
            print(
                '║ »» Speed ratio: ${ratio.toStringAsFixed(4)} (${(1 / ratio).toStringAsFixed(4)} x)');
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
  MapEntry<B, List<BenchmarkRoundResult>> best(
      MapEntry<B, List<BenchmarkRoundResult>> other) {
    var b1 = value.best;
    var b2 = other.value.best;

    var best = b1.best(b2);

    if (identical(best, b1)) {
      return this;
    } else {
      return other;
    }
  }
}

/// A structure that contains the results of a benchmark execution.
class BenchmarkResult<S, O, B extends Benchmark<S, O>>
    implements Comparable<BenchmarkResult<S, O, B>> {
  /// The [Benchmark] that was executed.
  final B benchmark;

  /// The results of the execution rounds ([BenchmarkRoundResult]).
  final List<BenchmarkRoundResult> rounds;

  BenchmarkResult(this.benchmark, this.rounds);

  @override
  int compareTo(BenchmarkResult<S, O, B> other) {
    var b1 = rounds.best;
    var b2 = other.rounds.best;
    return b1.compareTo(b2);
  }

  /// Returns the [BenchmarkResult] with the best performance (higher Hertz value).
  BenchmarkResult<S, O, B> best(BenchmarkResult<S, O, B> other) =>
      compareTo(other) <= 0 ? this : other;

  @override
  String toString() =>
      'BenchmarkResult{benchmark: $benchmark, rounds: ${rounds.length}}';
}

extension IterableBenchmarkResultExtension<S, O, B extends Benchmark<S, O>,
    R extends BenchmarkResult<S, O, B>> on Iterable<R> {
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

  /// The Hertz value representing the performance ([interactions] per second).
  late final double hertz =
      (interactions / duration.inMicroseconds) * (1000 * 1000);

  /// The average time per job interaction in milliseconds.
  late final double interactionTimeMs =
      (duration.inMicroseconds / interactions) / 1000;

  BenchmarkRoundResult(
      this.round, this.initTime, this.endTime, this.interactions);

  /// A formatted string representing the [hertz] value.
  String get hertzFormatted {
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

  /// A formatted string representing the [interactionTimeMs].
  String get interactionTimeFormatted {
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
  BenchmarkRoundResult get best => reduce((a, b) => a.best(b));
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
Future<BenchmarkResult<S, O, B>> benchmark<S, O, B extends Benchmark<S, O>>(
  B benchmark, {
  BenchmarkProfile? profile,
  int? warmup,
  int? interactions,
  bool setupOnIsolate = false,
  Duration? shutdownIsolateDelay,
  bool verbose = false,
}) async {
  if (setupOnIsolate) {
    var result = await _benchmarkImpl(
      _BenchmarkOnIsolate<S, O, B>(benchmark,
          shutdownIsolateDelay: shutdownIsolateDelay),
      profile: profile,
      warmup: warmup,
      interactions: interactions,
      setupOnIsolate: true,
      verbose: verbose,
    );
    return BenchmarkResult<S, O, B>(benchmark, result.rounds);
  } else {
    return _benchmarkImpl(
      benchmark,
      profile: profile,
      warmup: warmup,
      interactions: interactions,
      verbose: verbose,
    );
  }
}

Future<BenchmarkResult<S, O, B>>
    _benchmarkImpl<S, O, B extends Benchmark<S, O>>(
  B benchmark, {
  BenchmarkProfile? profile,
  int? warmup,
  int? interactions,
  int? rounds,
  bool setupOnIsolate = false,
  bool verbose = false,
}) async {
  final title = benchmark.title;

  if (verbose) {
    print('╔═${'═' * title.length}═╗');
    print('║ $title ║');
    print('╠═${'═' * title.length}═╝');
  }

  if (profile != null) {
    warmup ??= profile.warmup;
    interactions ??= profile.interactions;
    rounds ??= profile.rounds;

    if (verbose) {
      print('║ $profile');
    }
  } else {
    warmup ??= BenchmarkProfile.normal.warmup;
    interactions ??= BenchmarkProfile.normal.interactions;
    rounds ??= BenchmarkProfile.normal.rounds;

    if (verbose) {
      print('║ warmup: $warmup');
      print('║ interactions: $interactions');
      print('║ rounds: $rounds');
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
