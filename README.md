# async_benchmark

[![pub package](https://img.shields.io/pub/v/async_benchmark.svg?logo=dart&logoColor=00b9fc)](https://pub.dev/packages/async_benchmark)
[![Null Safety](https://img.shields.io/badge/null-safety-brightgreen)](https://dart.dev/null-safety)
[![Codecov](https://img.shields.io/codecov/c/github/eneural-net/async_benchmark)](https://app.codecov.io/gh/eneural-net/async_benchmark)
[![Dart CI](https://github.com/eneural-net/async_benchmark/actions/workflows/dart.yml/badge.svg?branch=master)](https://github.com/eneural-net/async_benchmark/actions/workflows/dart.yml)
[![GitHub Tag](https://img.shields.io/github/v/tag/eneural-net/async_benchmark?logo=git&logoColor=white)](https://github.com/eneural-net/async_benchmark/releases)
[![New Commits](https://img.shields.io/github/commits-since/eneural-net/async_benchmark/latest?logo=git&logoColor=white)](https://github.com/eneural-net/async_benchmark/network)
[![Last Commits](https://img.shields.io/github/last-commit/eneural-net/async_benchmark?logo=git&logoColor=white)](https://github.com/eneural-net/async_benchmark/commits/master)
[![Pull Requests](https://img.shields.io/github/issues-pr/eneural-net/async_benchmark?logo=github&logoColor=white)](https://github.com/eneural-net/async_benchmark/pulls)
[![Code size](https://img.shields.io/github/languages/code-size/eneural-net/async_benchmark?logo=github&logoColor=white)](https://github.com/eneural-net/async_benchmark)
[![License](https://img.shields.io/github/license/eneural-net/async_benchmark?logo=open-source-initiative&logoColor=green)](https://github.com/eneural-net/async_benchmark/blob/master/LICENSE)

`async_benchmark` is a Dart package for running and analyzing benchmarks with support for isolated environments and
performance tracking.

## Usage

```dart
import 'dart:math';

import 'package:async_benchmark/async_benchmark.dart';

void main() async {
  final profile =
  BenchmarkProfile('custom', warmup: 10, interactions: 100, rounds: 3);

  await BenchmarkPrime(seed: 12345).run(profile: profile, verbose: true);
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
```

OUTPUT:

```text
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
║ »» Duration: 0:00:01.356317
║ »» Speed: 73.7291 Hz
║ »» Interaction Time: 13.563 ms
╠────────────────────────────
║ ROUND: 2/3
║
║ ─ Running (100)...
║ ─ Teardown...
║
║ »» Duration: 0:00:01.352660
║ »» Speed: 73.9284 Hz
║ »» Interaction Time: 13.527 ms
╠────────────────────────────
║ ROUND: 3/3
║
║ ─ Running (100)...
║ ─ Teardown...
║
║ »» Duration: 0:00:01.359452
║ »» Speed: 73.5591 Hz
║ »» Interaction Time: 13.595 ms
╠────────────────────────────
║ BEST ROUND: 2
║
║ »» Duration: 0:00:01.352660
║ »» Speed: 73.9284 Hz
║ »» Interaction Time: 13.527 ms
╠────────────────────────────
║ Shutdown...
╚════════════════════════════
```

## Source

The official source code is [hosted @ GitHub][github_async_benchmark]:

- https://github.com/eneural-net/async_benchmark

[github_async_benchmark]: https://github.com/eneural-net/async_benchmark

# Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/eneural-net/async_benchmark/issues

# Contribution

Any help from the open-source community is always welcome and needed:

- Found an issue?
    - Please fill a bug report with details.
- Wish a feature?
    - Open a feature request with use cases.
- Are you using and liking the project?
    - Promote the project: create an article, do a post or make a donation.
- Are you a developer?
    - Fix a bug and send a pull request.
    - Implement a new feature.
    - Improve the Unit Tests.
- Have you already helped in any way?
    - **Many thanks from me, the contributors and everybody that uses this project!**

*If you donate 1 hour of your time, you can contribute a lot,
because others will do the same, just be part and start with your 1 hour.*

# Author

Graciliano M. Passos: [gmpassos@GitHub][github].

[github]: https://github.com/gmpassos

## Sponsor

Don't be shy, show some love, and become our [GitHub Sponsor][github_sponsors].
Your support means the world to us, and it keeps the code caffeinated! ☕✨

Thanks a million! 🚀😄

[github_sponsors]: https://github.com/sponsors/gmpassos

## License

[Apache License - Version 2.0][apache_license]

[apache_license]: https://www.apache.org/licenses/LICENSE-2.0.txt
