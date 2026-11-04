@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';

/// Runs the Dart script [script] with [args] as a separate process and
/// returns its stdout lines, failing if it doesn't exit cleanly on its own.
Future<List<String>> runScript(
  String script, [
  List<String> args = const [],
]) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    script,
    ...args,
  ]);
  final stdout = process.stdout.transform(utf8.decoder).join();
  final stderr = process.stderr.transform(utf8.decoder).join();

  final exitCode = await process.exitCode.timeout(
    Duration(seconds: 60),
    onTimeout: () {
      process.kill();
      fail('`$script ${args.join(' ')}` did not exit: a port was left open');
    },
  );

  expect(exitCode, equals(0), reason: await stderr);
  return const LineSplitter().convert(await stdout);
}

final _duration = RegExp(r'^\d+:\d\d:\d\d\.\d{6}$');
// A round faster than the clock resolution prints `n/a (...)`, never
// `Infinity` or `NaN`.
const _notMeasurable = r'n/a \(too fast to measure\)';
final _speed = RegExp('^║ »» Speed: (\\d+\\.\\d+ Hz|$_notMeasurable)\$');
final _time = RegExp(
  '^║ »» Interaction Time: (\\d+\\.\\d+ (sec|ms|µs)|$_notMeasurable)\$',
);

/// Matches the three `»»` lines printed for a round.
void expectRoundMetrics(List<String> lines, int at) {
  expect(
    lines[at],
    startsWith('║ »» Duration: '),
    reason: 'line $at: ${lines[at]}',
  );
  expect(lines[at].substring('║ »» Duration: '.length), matches(_duration));
  expect(lines[at + 1], startsWith('║ »» Speed: '));
  expect(lines[at + 1], matches(_speed));
  expect(lines[at + 2], startsWith('║ »» Interaction Time: '));
  expect(lines[at + 2], matches(_time));
}

/// Checks the block printed by a verbose run of the benchmark [title] with
/// `warmup: 5, interactions: 50, rounds: 2`, starting at [at].
/// Returns the index of the line after the block.
int expectRunBlock(List<String> lines, int at, String title) {
  final w = title.length;
  final line = '╠─${'─' * w}──';

  expect(
    lines.sublist(at, at + 8),
    equals([
      '╔═${'═' * w}═╗',
      '║ $title ║',
      '╠═${'═' * w}═╝',
      '║ BenchmarkProfile[e2e]{warmup: 5, interactions: 50, rounds: 2}',
      line,
      '║ Setup...',
      '║ ─ (service: [], setup: 1000)',
      '║ Warmup (5)...',
    ]),
  );
  at += 8;

  for (var r = 1; r <= 2; ++r) {
    expect(
      lines.sublist(at, at + 6),
      equals([
        line,
        '║ ROUND: $r/2',
        '║',
        '║ ─ Running (50)...',
        '║ ─ Teardown...',
        '║',
      ]),
    );
    expectRoundMetrics(lines, at + 6);
    at += 9;
  }

  expect(lines[at], equals(line));
  expect(lines[at + 1], matches(RegExp(r'^║ BEST ROUND: [12]$')));
  expect(lines[at + 2], equals('║'));
  expectRoundMetrics(lines, at + 3);
  at += 6;

  expect(
    lines.sublist(at, at + 4),
    equals([line, '║ Shutdown...', '╚═${'═' * w}══', '']),
  );
  return at + 4;
}

void main() {
  group('integration', () {
    test('a verbose runAll prints the full report', () async {
      final lines = await runScript('test/fixtures/report_benchmark.dart');

      // The run order is the one given by the seed.
      final order = ['loop', 'closed-form', 'loop-again']
        ..shuffle(math.Random(7));
      expect(lines[lines.length - 2], equals('order: ${order.join(',')}'));

      final bestLine = lines.last;
      expect(bestLine, startsWith('best: '));
      final best = bestLine.substring('best: '.length);
      expect(order, contains(best));

      var at = 0;
      for (var title in order) {
        at = expectRunBlock(lines, at, title);
      }

      // The summary: the best benchmark, then each other one, compared.
      final w = best.length;
      expect(lines[at], equals('╔═${'═' * w}══'));
      expect(
        lines[at + 1],
        matches(RegExp('^║ BEST BENCHMARK: $best \\(round: [12]\\)\$')),
      );
      expect(lines[at + 2], equals('║'));
      expectRoundMetrics(lines, at + 3);
      at += 6;

      final others = <String>[];
      for (var i = 0; i < 2; ++i) {
        expect(lines[at], equals('╠─${'─' * w}──'));
        final m = RegExp(r'^║ BENCHMARK: (.+) \(round: [12]\)$')
            .firstMatch(lines[at + 1]);
        expect(m, isNotNull, reason: lines[at + 1]);
        others.add(m!.group(1)!);
        expectRoundMetrics(lines, at + 2);

        final ratioLine = lines[at + 5];
        final ratio = RegExp(
          r'^║ »» Speed ratio: (\d+\.\d{4}) \((\d+\.\d{4}) x\)$',
        ).firstMatch(ratioLine);
        if (ratio == null) {
          // The best round (or this one) was too fast to measure.
          expect(
            ratioLine,
            equals('║ »» Speed ratio: n/a (too fast to measure)'),
          );
        } else {
          // Compared against the best: at most as fast, and the inverse.
          final r = double.parse(ratio.group(1)!);
          final inverse = double.parse(ratio.group(2)!);
          expect(r, lessThanOrEqualTo(1));
          expect(inverse, greaterThanOrEqualTo(1));
          // Both are rounded to 4 decimals.
          expect(1 / inverse, closeTo(r, 0.0001));
        }
        at += 6;
      }
      expect(others.toSet(), equals(order.toSet()..remove(best)));

      expect(
        lines.sublist(at),
        equals(['╚═${'═' * w}══', '', 'order: ${order.join(',')}', bestLine]),
      );
    }, timeout: Timeout(Duration(seconds: 90)));

    // Each scenario fails part-way, catches the error and must still exit:
    // the setup isolate and its ports are released on every error path.
    for (var (scenario, error) in [
      ('job-error', 'StateError'),
      ('caller-shutdown-error', 'StateError'),
      ('spawn-error', 'ArgumentError'),
    ]) {
      test('setupOnIsolate: the process exits after a $scenario', () async {
        final lines = await runScript('test/fixtures/isolate_scenarios.dart', [
          scenario,
        ]);
        expect(lines, equals(['caught: $error']));
      }, timeout: Timeout(Duration(seconds: 90)));
    }
  });
}
