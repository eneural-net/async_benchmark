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
