import 'dart:math';

import 'package:async_benchmark/async_benchmark.dart';
import 'package:test/test.dart';

void main() {
  group('BenchmarkPrime', () {
    test('fast', () async {
      var bench = BenchmarkPrime();

      var results =
          await bench.run(profile: BenchmarkProfile.fast, verbose: true);

      var rounds = results.rounds;

      expect(rounds.length, equals(1));

      var bestRound = rounds.best;

      expect(bestRound.round, equals(1));
      expect(bestRound.duration.inMilliseconds, greaterThan(1));
    });
  });
}

class BenchmarkPrime extends Benchmark<int, Prime> {
  BenchmarkPrime() : super('PrimeCounter');

  @override
  BenchmarkSetupResult<int, Prime> setup() {
    var prime = Prime();

    var rand = Random(123);
    var limit = rand.nextInt(99999);

    return (setup: limit, service: prime);
  }

  @override
  void job(int setup, Prime? prime) {
    prime ??= Prime();
    prime.countPrimes(setup);
  }

  @override
  void teardown(int setup, Prime? prime) async {}

  @override
  void shutdown(int setup, Prime? prime) async {
    prime?.clearCache();
  }
}

class Prime {
  int countPrimes(int limit) {
    var count = 0;
    for (var n = 2; n <= limit; ++n) {
      if (isPrime(n)) {
        ++count;
      }
    }
    return count;
  }

  final Set<int> _primesCache = {};

  void clearCache() => _primesCache.clear();

  bool isPrime(int n) {
    if (n <= 1) return false;
    if (n == 2) return true;

    if (n % 2 == 0) return false;

    if (_primesCache.contains(n)) {
      return true;
    }

    var sqr = sqrt(n);

    for (var b = 3; b <= sqr; b += 2) {
      if (n % b == 0) return false;
    }

    _primesCache.add(n);
    return true;
  }
}
