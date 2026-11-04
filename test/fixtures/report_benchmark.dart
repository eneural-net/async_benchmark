import 'package:async_benchmark/async_benchmark.dart';

/// Sums the first [n] integers, either with a loop or with the closed form:
/// two implementations of the same thing, as a real comparison would have.
class SumBenchmark extends Benchmark<int, List<int>> {
  final bool closedForm;

  SumBenchmark(super.title, {required this.closedForm});

  @override
  BenchmarkSetupResult<int, List<int>> setup() => (setup: 1000, service: []);

  @override
  void job(int setup, List<int>? service) {
    var sum = 0;
    if (closedForm) {
      sum = setup * (setup + 1) ~/ 2;
    } else {
      for (var i = 1; i <= setup; ++i) {
        sum += i;
      }
    }
    service!.add(sum);
  }

  @override
  void teardown(int setup, List<int>? service) {
    if (service!.any((s) => s != 500500)) throw StateError('wrong sum');
    service.clear();
  }
}

/// Run as a separate process by the tests: an end-to-end, verbose `runAll`
/// whose printed report is checked line by line.
void main() async {
  final results =
      await [
        SumBenchmark('loop', closedForm: false),
        SumBenchmark('closed-form', closedForm: true),
        SumBenchmark('loop-again', closedForm: false),
      ].runAll(
        profile: BenchmarkProfile(
          'e2e',
          warmup: 5,
          interactions: 50,
          rounds: 2,
        ),
        shuffle: true,
        shuffleSeed: 7,
        verbose: true,
      );

  print('order: ${results.map((r) => r.benchmark.title).join(',')}');
  print('best: ${results.best.benchmark.title}');
}
