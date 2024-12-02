import 'dart:collection';
import 'dart:math';

import 'package:async_benchmark/async_benchmark.dart';

void main() async {
  final profile =
      BenchmarkProfile('custom', warmup: 10, interactions: 100, rounds: 3);

  final seed = 123;

  var benchmarks = <Benchmark<int, Prime>>[
    BenchmarkPrimeCached(seed: seed),
    BenchmarkPrime(seed: seed),
  ];

  await benchmarks.runAll(profile: profile);
}

class BenchmarkPrimeCached extends Benchmark<int, PrimeCached> {
  final int? seed;

  BenchmarkPrimeCached({this.seed})
      : super('PrimeCounterCached(seed: ${seed ?? '*'})');

  static final Pool<PrimeCached> _primePool = Pool(() => PrimeCached());

  @override
  BenchmarkSetupResult<int, PrimeCached> setup() {
    var prime = _primePool.catchElement();

    var rand = Random(seed);
    var limit = rand.nextInt(999999);

    return (setup: limit, service: prime);
  }

  @override
  void job(int setup, Prime? service) {
    var prime = service ?? _primePool.catchElement();
    prime.countPrimes(setup);
  }

  @override
  void teardown(int setup, PrimeCached? service) async {
    if (service != null) {
      service.clearCache();
    }
  }

  @override
  void shutdown(int setup, PrimeCached? service) async {
    if (service != null) {
      _primePool.releaseElement(service);
    }
  }
}

class BenchmarkPrime extends Benchmark<int, Prime> {
  final int? seed;

  BenchmarkPrime({this.seed}) : super('PrimeCounter(seed: ${seed ?? '*'})');

  @override
  BenchmarkSetupResult<int, Prime> setup() {
    var prime = Prime();

    var rand = Random(seed);
    var limit = rand.nextInt(999999);

    return (setup: limit, service: prime);
  }

  @override
  void job(int setup, Prime? service) {
    var prime = service ?? Prime();
    prime.countPrimes(setup);
  }
}

class PrimeCached extends Prime {
  final Set<int> _primesCache = {};

  int get cacheLength => _primesCache.length;

  void clearCache() {
    _primesCache.clear();
    _isPrimeCached = 0;
    _isPrimeComputed = 0;
  }

  int _isPrimeCached = 0;
  int _isPrimeComputed = 0;

  ({int cached, int computed}) get isPrimeStats =>
      (cached: _isPrimeCached, computed: _isPrimeComputed);

  @override
  bool isPrime(int n) {
    if (n <= 1) return false;
    if (n == 2) return true;

    if (n % 2 == 0) return false;

    if (_primesCache.contains(n)) {
      ++_isPrimeCached;
      return true;
    }

    var sqr = sqrt(n);

    for (var b = 3; b <= sqr; b += 2) {
      if (n % b == 0) return false;
    }

    ++_isPrimeComputed;
    _primesCache.add(n);

    return true;
  }

  @override
  String toString() => 'PrimeCached{cache: ${_primesCache.length}}';
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

  bool isPrime(int n) {
    if (n <= 1) return false;
    if (n == 2) return true;

    if (n % 2 == 0) return false;

    var sqr = sqrt(n);

    for (var b = 3; b <= sqr; b += 2) {
      if (n % b == 0) return false;
    }

    return true;
  }

  @override
  String toString() => 'Prime{}';
}

class Pool<E extends Object> {
  final E Function() instantiator;

  Pool(this.instantiator);

  final Queue<E> _pool = Queue();

  E catchElement() {
    if (_pool.isEmpty) {
      return instantiator();
    } else {
      return _pool.removeLast();
    }
  }

  bool releaseElement(E? element) {
    if (element != null && _pool.length < 10) {
      _pool.add(element);
      return true;
    } else {
      return false;
    }
  }
}

/////////////
// OUTPUT: //
/////////////
/*
╔═══════════════════════════════╗
║ PrimeCounterCached(seed: 123) ║
╠═══════════════════════════════╝
║ BenchmarkProfile[custom]{warmup: 10, interactions: 100, rounds: 3}
╠────────────────────────────────
║ Setup...
║ ─ (service: PrimeCached{cache: 0}, setup: 999502)
║ Warmup (10)...
╠────────────────────────────────
║ ROUND: 1/3
║
║ ─ Running (100)...
║ ─ Teardown...
║
║ »» Duration: 0:00:06.366585
║ »» Speed: 15.7070 Hz
║ »» Interaction Time: 63.666 ms
╠────────────────────────────────
║ ROUND: 2/3
║
║ ─ Running (100)...
║ ─ Teardown...
║
║ »» Duration: 0:00:06.548992
║ »» Speed: 15.2695 Hz
║ »» Interaction Time: 65.490 ms
╠────────────────────────────────
║ ROUND: 3/3
║
║ ─ Running (100)...
║ ─ Teardown...
║
║ »» Duration: 0:00:06.541619
║ »» Speed: 15.2867 Hz
║ »» Interaction Time: 65.416 ms
╠────────────────────────────────
║ BEST ROUND: 1
║
║ »» Duration: 0:00:06.366585
║ »» Speed: 15.7070 Hz
║ »» Interaction Time: 63.666 ms
╠────────────────────────────────
║ Shutdown...
╚════════════════════════════════

╔═════════════════════════╗
║ PrimeCounter(seed: 123) ║
╠═════════════════════════╝
║ BenchmarkProfile[custom]{warmup: 10, interactions: 100, rounds: 3}
╠──────────────────────────
║ Setup...
║ ─ (service: Prime{}, setup: 999502)
║ Warmup (10)...
╠──────────────────────────
║ ROUND: 1/3
║
║ ─ Running (100)...
║ ─ Teardown...
║
║ »» Duration: 0:00:17.028856
║ »» Speed: 5.8724 Hz
║ »» Interaction Time: 170.289 ms
╠──────────────────────────
║ ROUND: 2/3
║
║ ─ Running (100)...
║ ─ Teardown...
║
║ »» Duration: 0:00:16.985658
║ »» Speed: 5.8873 Hz
║ »» Interaction Time: 169.857 ms
╠──────────────────────────
║ ROUND: 3/3
║
║ ─ Running (100)...
║ ─ Teardown...
║
║ »» Duration: 0:00:17.001885
║ »» Speed: 5.8817 Hz
║ »» Interaction Time: 170.019 ms
╠──────────────────────────
║ BEST ROUND: 2
║
║ »» Duration: 0:00:16.985658
║ »» Speed: 5.8873 Hz
║ »» Interaction Time: 169.857 ms
╠──────────────────────────
║ Shutdown...
╚══════════════════════════

╔════════════════════════════════
║ BEST BENCHMARK: PrimeCounterCached(seed: 123) (round: 1)
║
║ »» Duration: 0:00:06.366585
║ »» Speed: 15.7070 Hz
║ »» Interaction Time: 63.666 ms
╠────────────────────────────────
║ BENCHMARK: PrimeCounter(seed: 123) (round: 2)
║ »» Duration: 0:00:16.985658
║ »» Speed: 5.8873 Hz
║ »» Interaction Time: 169.857 ms
║ »» Speed ratio: 0.3748 (2.6679 x)
╚════════════════════════════════
 */
