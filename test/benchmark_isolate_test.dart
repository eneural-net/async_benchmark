@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:async_benchmark/async_benchmark.dart';
import 'package:test/test.dart';

import 'fixtures/isolate_benchmark.dart';
import 'fixtures/isolate_scenarios.dart';

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

    test('a service holding a port on the isolate, reached through '
        'a SendPort setup value', () async {
      final events = ReceivePort();
      addTearDown(events.close);
      final received = events.take(1).toList();

      var bench = _PortServiceBenchmark(events.sendPort);

      var result = await bench
          .run(profile: _profile, setupOnIsolate: true)
          .timeout(Duration(seconds: 10));

      expect(result.rounds, hasLength(2));
      // Every job, run on the caller, reached the service on the isolate,
      // which counted them before being shut down.
      expect(
        await received.timeout(Duration(seconds: 10)),
        equals(['service closed after ${2 + 2 * 3} jobs']),
      );
    });

    test('a failing job still shuts the isolate down', () async {
      final events = ReceivePort();
      addTearDown(events.close);
      final received = events.cast<String>().take(3).toList();

      var bench = FailingJobBenchmark(
        'iso-job-error',
        failAfter: 1,
        events: events.sendPort,
      );

      await expectLater(
        bench.run(profile: _profile, setupOnIsolate: true),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'job failed'),
        ),
      );
      expect(bench.jobs, equals(1));
      expect(
        await received.timeout(Duration(seconds: 10)),
        unorderedEquals([
          'setup@isolate',
          'shutdown@isolate:service',
          'shutdown@caller:null',
        ]),
      );
    });

    test('a failing shutdown on the caller still stops the isolate', () async {
      final events = ReceivePort();
      addTearDown(events.close);
      final received = events.cast<String>().take(3).toList();

      var bench = FailingCallerShutdownBenchmark(
        'iso-caller-shutdown',
        events: events.sendPort,
      );

      await expectLater(
        bench.run(profile: BenchmarkProfile.instant, setupOnIsolate: true),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'caller shutdown failed',
          ),
        ),
      );
      expect(
        await received.timeout(Duration(seconds: 10)),
        unorderedEquals([
          'setup@isolate',
          'shutdown@caller:null',
          'shutdown@isolate:service',
        ]),
      );
    });

    test('a setup value that cannot leave the isolate is reported', () async {
      await expectLater(
        _UnsendableSetupBenchmark().run(
          profile: BenchmarkProfile.instant,
          setupOnIsolate: true,
        ),
        throwsA(isA<RemoteError>()),
      );
    }, timeout: Timeout(Duration(seconds: 20)));

    test('a benchmark that cannot be sent to an isolate fails', () async {
      var bench = UnsendableBenchmark();
      addTearDown(bench.port.close);

      await expectLater(
        bench.run(profile: BenchmarkProfile.instant, setupOnIsolate: true),
        throwsArgumentError,
      );
    });

    test('concurrent runs use one isolate each', () async {
      var seenA = <String>[];
      var seenB = <String>[];
      var a = _CapturingBenchmark('conc-a', seenA);
      var b = _CapturingBenchmark('conc-b', seenB);

      await Future.wait([
        a.run(profile: _profile, setupOnIsolate: true),
        b.run(profile: _profile, setupOnIsolate: true),
      ]);

      expect(seenA, hasLength(2 + 2 * 3));
      expect(seenB, hasLength(2 + 2 * 3));
      expect(seenA.toSet(), equals({a.isolateName}));
      expect(seenB.toSet(), equals({b.isolateName}));
    });

    test('verbose says the setup runs on an isolate', () async {
      final lines = <String>[];
      await runZoned(
        () => IsolateBenchmark('iso-verbose').run(
          profile: BenchmarkProfile.instant,
          setupOnIsolate: true,
          verbose: true,
        ),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => lines.add(line),
        ),
      );
      expect(lines, contains('║ Setup (on Isolate)...'));
      expect(lines, isNot(contains('║ Setup...')));
      // The setup record printed is the one built on the caller: the setup
      // value from the isolate and its `shutdown` function, without service.
      expect(
        lines.where((l) => l.startsWith('║ ─ (service: null, setup: ')),
        hasLength(1),
      );
    });

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

/// The service is a [ReceivePort] living on the setup isolate; the jobs, on
/// the caller, reach it through its [SendPort] (the setup value).
class _PortServiceBenchmark extends Benchmark<SendPort, ReceivePort> {
  final SendPort events;

  /// Messages received by the service (only meaningful on the isolate).
  int _received = 0;

  _PortServiceBenchmark(this.events) : super('port-service');

  @override
  BenchmarkSetupResult<SendPort, ReceivePort> setup() {
    final port = ReceivePort();
    port.listen((_) => ++_received);
    return (setup: port.sendPort, service: port);
  }

  @override
  void job(SendPort setup, ReceivePort? service) {
    expect(service, isNull);
    setup.send('job');
  }

  @override
  void shutdown(SendPort setup, ReceivePort? service) {
    if (service != null) {
      service.close();
      events.send('service closed after $_received jobs');
    }
  }
}

/// Its setup value, a [ReceivePort], can't be sent back from the isolate.
class _UnsendableSetupBenchmark extends Benchmark<Object, Object> {
  _UnsendableSetupBenchmark() : super('unsendable-setup');

  @override
  BenchmarkSetupResult<Object, Object> setup() =>
      (setup: ReceivePort(), service: null);

  @override
  void job(Object setup, Object? service) {}
}
