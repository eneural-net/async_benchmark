@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:async_benchmark/async_benchmark.dart';
import 'package:test/test.dart';

import 'fixtures/isolate_benchmark.dart';

const _profile = BenchmarkProfile(
  'test',
  warmup: 2,
  interactions: 3,
  rounds: 2,
);

void main() {
  group('setupOnIsolate', () {
    test('runs setup and shutdown on a spawned isolate', () async {
      final events = ReceivePort();
      addTearDown(events.close);
      final received = events.cast<String>().take(3).toList();

      var bench = IsolateBenchmark('iso', events: events.sendPort);

      var result = await bench.run(profile: _profile, setupOnIsolate: true);

      // The setup isolate is not the one running the test.
      expect(bench.isolateName, isNot(equals(Isolate.current.debugName)));

      // Jobs and teardowns run on the calling isolate, with the setup value
      // but without the service, which is never sent between isolates.
      expect(bench.jobs, equals(2 + 2 * 3));
      expect(bench.teardowns, equals(2));

      expect(result.benchmark, same(bench));
      expect(result.rounds.map((r) => r.round), equals([1, 2]));
      expect(result.rounds.every((r) => r.interactions == 3), isTrue);

      expect(
        await received.timeout(Duration(seconds: 10)),
        unorderedEquals([
          'setup@isolate',
          // On the isolate, `shutdown` gets the service created by `setup`.
          'shutdown@isolate:service',
          'shutdown@caller:null',
        ]),
      );
    });

    test('jobs receive the setup value produced on the isolate', () async {
      var seen = <String>[];
      var bench = _CapturingBenchmark('capture', seen);

      await bench.run(profile: BenchmarkProfile.instant, setupOnIsolate: true);

      expect(seen, isNotEmpty);
      expect(seen.toSet(), equals({bench.isolateName}));
    });

    test('runAll with shutdownIsolateDelay', () async {
      var list = [IsolateBenchmark('x'), IsolateBenchmark('y')];

      var results = await list.runAll(
        profile: BenchmarkProfile.instant,
        setupOnIsolate: true,
        shutdownIsolateDelay: Duration(milliseconds: 1),
      );

      expect(results.map((r) => r.benchmark), equals(list));
      for (var b in list) {
        expect(b.jobs, equals(2));
      }
    });

    test('an error in setup is reported instead of hanging', () async {
      var bench = IsolateBenchmark('bad-setup', failSetup: true);

      await expectLater(
        bench.run(profile: BenchmarkProfile.instant, setupOnIsolate: true),
        throwsA(
          isA<RemoteError>().having(
            (e) => e.toString(),
            'message',
            contains('setup failed'),
          ),
        ),
      );
      expect(bench.jobs, equals(0));
    }, timeout: Timeout(Duration(seconds: 20)));

    test('an error in shutdown on the isolate is reported', () async {
      var bench = IsolateBenchmark('bad-shutdown', failShutdownOnIsolate: true);

      await expectLater(
        bench.run(profile: BenchmarkProfile.instant, setupOnIsolate: true),
        throwsA(
          isA<RemoteError>().having(
            (e) => e.toString(),
            'message',
            contains('shutdown failed'),
          ),
        ),
      );
      expect(bench.jobs, equals(2));
    }, timeout: Timeout(Duration(seconds: 20)));

    test('the process exits once the benchmarks finish', () async {
      final process = await Process.start(Platform.resolvedExecutable, [
        'test/fixtures/isolate_benchmark.dart',
      ]);
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();

      final exitCode = await process.exitCode.timeout(
        Duration(seconds: 60),
        onTimeout: () {
          process.kill();
          fail('the process did not exit: a port was left open');
        },
      );

      expect(exitCode, equals(0), reason: await stderr);
      expect(await stdout, contains('done: 2'));
    }, timeout: Timeout(Duration(seconds: 90)));
  });
}

class _CapturingBenchmark extends IsolateBenchmark {
  final List<String> seen;

  _CapturingBenchmark(super.title, this.seen);

  @override
  void job(String setup, Object? service) {
    expect(service, isNull);
    seen.add(setup);
  }
}
