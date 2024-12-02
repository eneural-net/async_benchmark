import 'dart:async';
import 'dart:isolate';

typedef BenchmarkOnIsolateSetup<S> = ({
  S setup,
  Future<void> Function() shutdown
});

class BenchmarkOnIsolate<S, O, B extends Benchmark<S, O>>
class _BenchmarkOnIsolate<S, O, B extends Benchmark<S, O>>
    extends Benchmark<BenchmarkOnIsolateSetup<S>, O> {
  final B benchmark;

  _BenchmarkOnIsolate(this.benchmark) : super(benchmark.title);

  @override
  Future<BenchmarkSetupResult<BenchmarkOnIsolateSetup<S>, O>> setup() async {
    var r = await _runSetupOnIsolate(benchmark);
    return (setup: r, service: null);
  }

  @override
  Future<void> shutdown(BenchmarkOnIsolateSetup<S> setup, O? service) async {
    await benchmark.shutdown(setup.setup, service);
    await setup.shutdown();
  }

  @override
  FutureOr<void> job(BenchmarkOnIsolateSetup<S> setup, O? service) =>
      benchmark.job(setup.setup, service);

  @override
  FutureOr<void> teardown(BenchmarkOnIsolateSetup<S> setup, O? service) =>
      benchmark.teardown(setup.setup, service);

  static Future<BenchmarkOnIsolateSetup<S>> runSetupOnIsolate<S, O>(
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

  static void isolateSetup((SendPort, Benchmark) args) async {
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
  }
}

class BenchmarkProfile {
  static final instant =
      const BenchmarkProfile('instant', warmup: 1, interactions: 1, rounds: 1);

  static final fast =
      const BenchmarkProfile('fast', warmup: 10, interactions: 100, rounds: 1);

  static final normal = const BenchmarkProfile('normal',
      warmup: 100, interactions: 1000, rounds: 3);

  static final heavy = const BenchmarkProfile('heavy',
      warmup: 1000, interactions: 10000, rounds: 10);

  final String name;
  final int warmup;
  final int interactions;
  final int rounds;

  const BenchmarkProfile(this.name,
      {required this.warmup, required this.interactions, required this.rounds});

  @override
  String toString() =>
      'BenchmarkProfile[$name]{warmup: $warmup, interactions: $interactions, rounds: $rounds}';
}

typedef BenchmarkSetupResult<S, O> = ({S setup, O? service});

abstract class Benchmark<S, O> {
  final String title;

  const Benchmark(this.title);

  FutureOr<BenchmarkSetupResult<S, O>> setup() async {
    return (setup: null as S, service: null);
  }

  FutureOr<void> job(S setup, O? service);

  FutureOr<void> teardown(S setup, O? service) async {}

  FutureOr<void> shutdown(S setup, O? service) async {}
}

extension BenchmarkExtension<S, O, B extends Benchmark<S, O>> on B {
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
  Future<List<BenchmarkResult<S, O, B>>> runAll({
    BenchmarkProfile? profile,
    int? warmup,
    int? interactions,
    bool setupOnIsolate = false,
    bool verbose = false,
  }) async {
    var results = <BenchmarkResult<S, O, B>>[];

    for (var b in this) {
      var r = await benchmark<S, O, B>(b,
          profile: profile,
          warmup: warmup,
          interactions: interactions,
          setupOnIsolate: setupOnIsolate,
          verbose: verbose);

      results.add(r);
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

class BenchmarkResult<S, O, B extends Benchmark<S, O>>
    implements Comparable<BenchmarkResult<S, O, B>> {
  final B benchmark;
  final List<BenchmarkRoundResult> rounds;

  BenchmarkResult(this.benchmark, this.rounds);

  @override
  int compareTo(BenchmarkResult<S, O, B> other) {
    var b1 = rounds.best;
    var b2 = other.rounds.best;
    return b1.compareTo(b2);
  }

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

class BenchmarkRoundResult implements Comparable<BenchmarkRoundResult> {
  final int round;
  final DateTime initTime;
  final DateTime endTime;

  final int interactions;

  late final Duration duration = endTime.difference(initTime);

  late final double hertz =
      (interactions / duration.inMicroseconds) * (1000 * 1000);

  late final double interactionTimeMs =
      (duration.inMicroseconds / interactions) / 1000;

  BenchmarkRoundResult(
      this.round, this.initTime, this.endTime, this.interactions);

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

  BenchmarkRoundResult best(BenchmarkRoundResult other) =>
      compareTo(other) <= 0 ? this : other;

  @override
  String toString() =>
      'BenchmarkRoundResult{round: $round, interactions: $interactions, hertz: $hertzFormatted, interactionTime: $interactionTimeFormatted}';
}

extension BenchmarkRoundResultExtension on Iterable<BenchmarkRoundResult> {
  BenchmarkRoundResult get best => reduce((a, b) => a.best(b));
}

Future<BenchmarkResult<S, O, B>> benchmark<S, O, B extends Benchmark<S, O>>(
  B benchmark, {
  BenchmarkProfile? profile,
  int? warmup,
  int? interactions,
  bool setupOnIsolate = false,
  bool verbose = false,
}) async {
  if (setupOnIsolate) {
    var result = await _benchmarkImpl(
      BenchmarkOnIsolate<S, O, B>(benchmark),
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
