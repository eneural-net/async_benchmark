import 'dart:isolate';

import 'package:async_benchmark/async_benchmark.dart';

import 'isolate_benchmark.dart';

/// A benchmark whose [job] throws once [failAfter] jobs ran.
class FailingJobBenchmark extends IsolateBenchmark {
  final int failAfter;

  FailingJobBenchmark(super.title, {this.failAfter = 0, super.events});

  @override
  void job(String setup, Object? service) {
    if (jobs >= failAfter) throw StateError('job failed');
    super.job(setup, service);
  }
}

/// A benchmark whose [shutdown] throws on the calling isolate only.
class FailingCallerShutdownBenchmark extends IsolateBenchmark {
  FailingCallerShutdownBenchmark(super.title, {super.events});

  @override
  void shutdown(String setup, Object? service) {
    super.shutdown(setup, service);
    if (service == null) throw StateError('caller shutdown failed');
  }
}

/// A benchmark that can't be sent to an [Isolate]: it holds a [ReceivePort].
class UnsendableBenchmark extends Benchmark<int, Object> {
  final ReceivePort port = ReceivePort();

  UnsendableBenchmark() : super('unsendable');

  @override
  void job(int setup, Object? service) {}
}

/// Run as a separate process by the tests, with the scenario as the first
/// argument. Each scenario ends with an error that is caught and printed:
/// the process must still exit on its own (no `ReceivePort` left open).
void main(List<String> args) async {
  final scenario = args.single;

  final Benchmark<dynamic, dynamic> bench = switch (scenario) {
    'job-error' => FailingJobBenchmark('job-error', failAfter: 1),
    'caller-shutdown-error' => FailingCallerShutdownBenchmark('shutdown'),
    'spawn-error' => UnsendableBenchmark(),
    _ => throw ArgumentError.value(scenario, 'scenario'),
  };

  try {
    await bench.run(profile: BenchmarkProfile.instant, setupOnIsolate: true);
    print('no error');
  } catch (e) {
    print('caught: ${e.runtimeType}');
  } finally {
    // The benchmark's own port must not be what keeps the process alive.
    if (bench is UnsendableBenchmark) bench.port.close();
  }
}
