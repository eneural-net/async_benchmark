import 'dart:async';

import 'package:async_benchmark/async_benchmark.dart';

void main() async {
  var benchmarks = [
    BenchmarkAsync1(),
    BenchmarkAsync2(),
    BenchmarkFutureOr(),
  ];

  var profile = BenchmarkProfile('custom',
      warmup: 1000000, interactions: 20000000, rounds: 3);

  await benchmarks.runAll(profile: profile, shuffle: true, verbose: true);
}

class BenchmarkAsync1 extends Benchmark {
  BenchmarkAsync1() : super('Async1');

  int accumulator = 0;

  @override
  Future<void> job(setup, service) async {
    var valueAsync = Future.microtask(() => 123);

    return valueAsync.then((v) {
      var c = v * 10;
      accumulator += c;
    });
  }
}

class BenchmarkAsync2 extends Benchmark {
  BenchmarkAsync2() : super('Async2');

  int accumulator = 0;

  @override
  Future<void> job(setup, service) async {
    var valueAsync = Future.microtask(() => 123);

    var v = await valueAsync;

    var c = v * 10;
    accumulator += c;
  }
}

class BenchmarkFutureOr extends Benchmark {
  BenchmarkFutureOr() : super('FutureOr');

  int accumulator = 0;

  @override
  FutureOr<void> job(setup, service) {
    var valueAsync = Future.microtask(() => 123);

    return valueAsync.then((v) {
      var c = v * 10;
      accumulator += c;
    });
  }
}
