import Foundation

/// Seconds on a clock that only moves forward and keeps counting while the
/// device sleeps, like Android's `SystemClock.elapsedRealtime`.
///
/// `ProcessInfo.systemUptime` would not do: it is "the amount of time the
/// system has been awake", so a window measured with it stretches whenever
/// a backgrounded iPhone sleeps between Bluetooth events. Darwin documents
/// `CLOCK_MONOTONIC` as continuing to increment while the system is asleep
/// (`man clock_gettime`).
enum MonotonicClock {
  static func seconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
  }
}
