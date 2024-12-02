import 'dart:math';

import 'package:async_benchmark/async_benchmark.dart';

void main() async {
  final profile =
      BenchmarkProfile('custom', warmup: 10, interactions: 100, rounds: 3);

  await BenchmarkPrime(seed: 12345).run(profile: profile);
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

/////////////
// OUTPUT: //
/////////////
/*
╔═══════════════════════════╗
║ PrimeCounter(seed: 12345) ║
╠═══════════════════════════╝
║ BenchmarkProfile[custom]{warmup: 10, interactions: 100, rounds: 3}
╠────────────────────────────
║ Setup...
║ ─ (service: Prime{}, setup: 155253)
║ Warmup (10)...
╠────────────────────────────
║ ROUND: 1/3
║
║ ─ Running (100)...
║ ─ Teardown...
║
║ »» Duration: 0:00:01.327276
║ »» Speed: 75.3423 Hz
║ »» Interaction Time: 13.273 ms
╠────────────────────────────
║ ROUND: 2/3
║
║ ─ Running (100)...
║ ─ Teardown...
║
║ »» Duration: 0:00:01.349250
║ »» Speed: 74.1152 Hz
║ »» Interaction Time: 13.492 ms
╠────────────────────────────
║ ROUND: 3/3
║
║ ─ Running (100)...
║ ─ Teardown...
║
║ »» Duration: 0:00:01.335322
║ »» Speed: 74.8883 Hz
║ »» Interaction Time: 13.353 ms
╠────────────────────────────
║ BEST ROUND: 1
║
║ »» Duration: 0:00:01.327276
║ »» Speed: 75.3423 Hz
║ »» Interaction Time: 13.273 ms
╠────────────────────────────
║ Shutdown...
╚════════════════════════════
 */
