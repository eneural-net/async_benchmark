import 'dart:isolate';

import 'package:async_benchmark/async_benchmark.dart';

/// A benchmark whose [setup] runs wherever it is called and reports where.
///
/// Every lifecycle call is sent to [events] (when set) as `<call>@<isolate>`,
/// so a test can observe calls made on a spawned [Isolate].
class IsolateBenchmark extends Benchmark<String, Object> {
  final SendPort? events;

  /// Makes [setup] throw.
  final bool failSetup;

  /// Makes [shutdown] throw, but only on a spawned [Isolate].
  final bool failShutdownOnIsolate;

  int jobs = 0;
  int teardowns = 0;

  IsolateBenchmark(
    super.title, {
    this.events,
    this.failSetup = false,
    this.failShutdownOnIsolate = false,
  });

  /// The `debugName` this package gives the setup [Isolate].
  String get isolateName => '$runtimeType[$title]';

  bool get _onSetupIsolate => Isolate.current.debugName == isolateName;

  String get _where => _onSetupIsolate ? 'isolate' : 'caller';

  @override
  Future<BenchmarkSetupResult<String, Object>> setup() async {
    events?.send('setup@$_where');
    if (failSetup) throw StateError('setup failed');
    return (setup: Isolate.current.debugName ?? '', service: Object());
  }

  @override
  void job(String setup, Object? service) {
    ++jobs;
  }

  @override
  void teardown(String setup, Object? service) {
    ++teardowns;
  }

  @override
  void shutdown(String setup, Object? service) {
    events?.send('shutdown@$_where:${service == null ? 'null' : 'service'}');
    if (failShutdownOnIsolate && _onSetupIsolate) {
      throw StateError('shutdown failed');
    }
  }
}

/// Run as a separate process by the tests: it must exit on its own once the
/// benchmarks finish (an open `ReceivePort` would keep it alive).
void main() async {
  var results = await [IsolateBenchmark('a'), IsolateBenchmark('b')].runAll(
    profile: BenchmarkProfile.instant,
    setupOnIsolate: true,
    shutdownIsolateDelay: Duration(milliseconds: 1),
  );
  print('done: ${results.length}');
}
