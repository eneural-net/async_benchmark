## 1.1.1

- `benchmark` / `BenchmarkExtension.run` / `IterableBenchmarkExtension.runAll`:
  - Fixed: when a `job` or `teardown` throws, the benchmark's `shutdown` is
    now called before the error is rethrown, so its resources are released.
    With `setupOnIsolate: true` the setup `Isolate` was left running and the
    program never exited. The original error is the one reported, even if
    `shutdown` also throws.

- `_BenchmarkOnIsolate`:
  - Fixed: the setup `Isolate` is stopped even if the caller's `shutdown`
    throws (the program never exited).
  - Fixed: a benchmark that can't be sent to an `Isolate` now fails with the
    `Isolate.spawn` error without leaving its `ReceivePort`s open (the
    program never exited).
  - Fixed: a setup value that is a `SendPort` (e.g. to reach a service living
    on the setup `Isolate`) was mistaken for the isolate's own port, and the
    benchmark hung forever. The port and the setup value are now sent
    together.

- Tests:
  - Edge values of `BenchmarkRoundResult` (zero interactions, zero duration,
    formatting thresholds) and of profiles (zero/negative counts, zero rounds).
  - The verbose reports of `run` and `runAll` asserted line by line.
  - Seeded shuffles, errors in the middle of a run, concurrent runs, and
    `setupOnIsolate` with a service holding a port on the `Isolate`.
  - Integration: an end-to-end verbose `runAll` and the error paths of
    `setupOnIsolate` run as separate processes, which must exit on their own.

## 1.1.0

- `_BenchmarkOnIsolate`:
  - Fixed: close the caller's `ReceivePort` when the setup `Isolate` stops.
    A program that ran a benchmark with `setupOnIsolate: true` never exited.
  - Fixed: an error thrown by `setup` or `shutdown` on the `Isolate` is now
    reported as a `RemoteError` instead of hanging forever.

- `BenchmarkExtension.run`:
  - Added parameter `shutdownIsolateDelay` (as in `runAll`).
  - Parameter `verbose` is now typed as `bool` (was `dynamic`).

- Tests: cover the whole public API and the `setupOnIsolate` path.

- Dart CI: `actions/checkout@v7`, `codecov/codecov-action@v7`; run the tests
  on the minimum SDK (3.13.0) and on stable.

- sdk: ^3.13.0
- lints: ^6.1.0
- test: ^1.33.0
- dependency_validator: ^5.1.0

## 1.0.3

- `BenchmarkProfile`:
  - Added `copyWith`.

- test: ^1.25.12
- dependency_validator: ^4.1.2

## 1.0.2

- `IterableBenchmarkExtension`:
  - `runAll`: added parameters `interactionDelay`, `shuffle`, `shuffleSeed`. 

## 1.0.1

- `_BenchmarkOnIsolate`:
  - Added optional field `shutdownIsolateDelay`.
  - Ensure that the `Isolate` closes its `receivePort`.

## 1.0.0

- Initial version.
