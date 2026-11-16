import CoreBluetooth
import Flutter
import Foundation
import Herald
import os

/// The native half of the app's logging, used by every iOS class. See
/// docs/logging.md; the line format is the one in
/// lib/src/logging/log_line.dart, so Dart, iOS and Android lines read and
/// merge the same way.
///
/// Each line goes:
/// - to the console, which is one of two (see `Console`, decided once per
///   launch): stderr when the app was launched with `OS_ACTIVITY_DT_MODE`
///   set, as `flutter run` on a device and Xcode's test runner do; otherwise
///   os_log (subsystem: the bundle id, category `BPB`), at `.default`
///   (`.error` for errors), the line carrying its own level letter.
///   With a stderr console, Dart's lines go out here too (Dart then does
///   not print them), and no caller ever waits for the console: see
///   `ConsoleWriter`.
/// - to the log file (Documents/logs/bridge.log), which also receives Dart's
///   lines, so it holds the whole run. The previous `keptFiles - 1` files are
///   kept (bridge.1.log is the previous launch, or the first part of this one
///   if it outgrew `maxFileBytes`);
/// - to Dart over the logs event channel, for the in-app log viewer. Lines
///   logged while Dart is not listening are held (up to `maxPending`) and
///   delivered once it subscribes.
///
/// Writes are synchronous, so the lines that lead up to a crash are on disk
/// when the process dies.
final class BridgeLog {

  enum Level: Int, Comparable {
    case debug, info, warn, error

    var letter: String {
      switch self {
      case .debug: return "D"
      case .info: return "I"
      case .warn: return "W"
      case .error: return "E"
      }
    }

    init?(name: String?) {
      switch name?.lowercased() {
      case "debug": self = .debug
      case "info": self = .info
      case "warn", "warning": self = .warn
      case "error": self = .error
      default: return nil
      }
    }

    static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  /// Where a line is written for a console to show (besides the file and
  /// Dart). Checked on an iPad (iPad8,11, iOS 27.2.1, Xcode 27.2, Flutter
  /// 3.47.9) and an iOS 26.4 simulator, 2026-11-16; docs/logging.md:
  ///
  /// - `flutter run` on a device launches the app with `devicectl
  ///   --console` and `OS_ACTIVITY_DT_MODE=enable`. That mirrors every
  ///   os_log message, `.debug` included, to the app's stderr, but as
  ///   `<time> Runner[pid:tid] [BPB] <line>`, and flutter_tools does not
  ///   print console lines with that prefix (only as `-v` trace) unless the
  ///   message starts with `flutter:` or an engine tag. A line written to
  ///   stderr as it is shows, once.
  /// - Xcode's test runner (tool/ios_ui_test.sh) sets
  ///   `OS_ACTIVITY_DT_MODE=YES`; 1 MB written to stderr there took 51 ms,
  ///   so it is read, and writing did not stall the app.
  /// - The simulator under `flutter run` (`simctl launch`), a device launch
  ///   without a console (`devicectl device process launch`, as
  ///   `flutter run --release` does) and a run from Xcode (its Run button,
  ///   or its scripting `debug` command, which flutter_tools falls back to
  ///   when LLDB is off or its launch fails) get no `OS_ACTIVITY_DT_MODE`.
  ///   Xcode's console showed each os_log line once.
  ///
  /// With the variable set, os_log is skipped rather than written as well:
  /// its mirror copy would otherwise sit next to ours in any console that
  /// shows both (`flutter run -v` does). The cost is that Console.app and
  /// `log stream` do not see our lines during such a launch; the log file
  /// has them all. Lines go out through a `ConsoleWriter`, Dart's included
  /// (`printsDartLines`).
  enum Console: Equatable {
    case osLog
    case standardError

    static let modeVariable = "OS_ACTIVITY_DT_MODE"

    /// Any non-empty value counts. Only `enable` (flutter_tools) and `YES`
    /// (Xcode's test runner) were seen.
    init(environment: [String: String]) {
      let mode = environment[Self.modeVariable] ?? ""
      self = mode.isEmpty ? .osLog : .standardError
    }
  }

  /// Whether Dart should print the native lines it receives: only when they
  /// go to os_log on a simulator. `flutter run` does not show them there: it
  /// filters the simulator's os_log to messages from the app's main
  /// executable, and debug builds put the app's code in Runner.debug.dylib
  /// (`ENABLE_DEBUG_DYLIB`). With `.standardError` the console already has each
  /// line, so an echo would print it twice; on a device without
  /// `OS_ACTIVITY_DT_MODE` no console of flutter_tools reads the app's
  /// output, so an echo would only add a second copy to os_log.
  static func dartShouldEcho(console: Console, simulator: Bool) -> Bool {
    console == .osLog && simulator
  }

  /// Writes lines to a file descriptor (stderr in the app) from its own
  /// serial queue, so no caller ever waits for whoever reads the console.
  ///
  /// A write to stderr waits while nobody reads it. Seen on an iPad
  /// (iPad8,11, iOS 27.2.1, Flutter 3.47.9), 2026-11-16: under
  /// `flutter run`, with the Mac's devicectl console process paused, the
  /// app took about 1.2 MB of log lines and then stood still, Dart
  /// included, for the 3 min 16 s until the process was resumed, when the
  /// logger wrote to stderr on the calling thread. So a line is only
  /// queued here. Up to `maxPendingBytes` wait for the reader; lines
  /// beyond that are left out of the console (the log file has every
  /// line) and counted, until the queue is down to half of that. The next
  /// line is then preceded by a note saying how many are missing. A burst
  /// that outruns a reader does the same: on the iPad, 2.4 MB logged within
  /// a second left lines out although `flutter run` was reading.
  final class ConsoleWriter {
    /// About 1500 lines. A reader that keeps up never gets near it.
    static let defaultMaxPendingBytes = 256 * 1024

    private let fd: Int32
    private let maxPendingBytes: Int
    private let queue = DispatchQueue(label: "bridge-log.console", qos: .utility)
    // Guards the three below.
    private let lock = NSLock()
    private var pendingBytes = 0
    private var skipping = false
    private var skipped = 0

    /// Whether SIGPIPE is off for `fd`: a write after the reader closed a
    /// pipe then fails with EPIPE instead of raising SIGPIPE. The app
    /// already ignores SIGPIPE in every launch checked (SIG_IGN before
    /// BridgeLog starts; who sets it was not found), so this is a guard in
    /// case that changes.
    let sigpipeOff: Bool

    init(fd: Int32, maxPendingBytes: Int = ConsoleWriter.defaultMaxPendingBytes) {
      self.fd = fd
      self.maxPendingBytes = maxPendingBytes
      sigpipeOff = fcntl(fd, F_SETNOSIGPIPE, 1) != -1
    }

    /// Queues one line; returns at once. False when the line was left out
    /// because too much is already waiting for the reader.
    @discardableResult
    func write(_ line: String, now: @autoclosure () -> String = "") -> Bool {
      var bytes = Array((line + "\n").utf8)
      lock.lock()
      // A line always fits an empty queue, whatever its size. Once lines
      // are being left out, that goes on until half the queue is free, so
      // the notes do not alternate with single lines.
      if skipping && pendingBytes <= maxPendingBytes / 2 { skipping = false }
      if !skipping && pendingBytes > 0 && pendingBytes + bytes.count > maxPendingBytes {
        skipping = true
      }
      if skipping {
        skipped += 1
        lock.unlock()
        return false
      }
      if skipped > 0 {
        bytes.insert(contentsOf: Array(Self.skippedNote(skipped, time: now()).utf8), at: 0)
        skipped = 0
      }
      pendingBytes += bytes.count
      lock.unlock()
      queue.async {
        self.writeNow(bytes)
        self.lock.lock()
        self.pendingBytes -= bytes.count
        self.lock.unlock()
      }
      return true
    }

    /// Waits until everything queued so far is written, for at most
    /// `timeout` seconds. False when the reader did not take it in time.
    @discardableResult
    func flush(timeout: TimeInterval) -> Bool {
      let done = DispatchSemaphore(value: 0)
      queue.async { done.signal() }
      return done.wait(timeout: .now() + timeout) == .success
    }

    /// The line that stands in for lines left out, in the log line format
    /// so that tool/devlogs.dart keeps it when it merges a capture.
    static func skippedNote(_ count: Int, time: String) -> String {
      "\(time) W native.log [console] \(count) line(s) left out of this console, which was not "
        + "taking them as fast as they were logged. The log file has them.\n"
    }

    /// One unbuffered write(2), more only if the kernel takes part of the
    /// bytes. True when all of them went out. Errors end the write: the
    /// line is in the log file anyway. Waits for the reader; only the
    /// queue calls it (and the tests).
    @discardableResult
    func writeNow(_ bytes: [UInt8]) -> Bool {
      bytes.withUnsafeBytes { buffer -> Bool in
        guard let base = buffer.baseAddress else { return false }
        var offset = 0
        while offset < buffer.count {
          let written = Darwin.write(fd, base + offset, buffer.count - offset)
          if written > 0 {
            offset += written
          } else if written < 0 && errno == EINTR {
            continue
          } else {
            return false
          }
        }
        return true
      }
    }
  }

  static let shared = BridgeLog()

  private static let fileName = "bridge.log"
  private static let maxFileBytes: UInt64 = 4 * 1024 * 1024
  private static let keptFiles = 3
  private static let maxPending = 5_000

  // Guards everything below.
  private let lock = NSLock()
  private var minLevel: Level = .debug
  private var heraldLevel: SensorLoggerLevel = .off
  private var directory: URL?
  private var handle: FileHandle?
  private var fileBytes: UInt64 = 0
  private var pending: [String] = []
  private var pendingDropped = 0
  private var dartSink: FlutterEventSink?
  private var drainScheduled = false
  /// Problems with the log file itself, reported once the lock is released.
  private var problems: [String] = []
  /// Set when `console` is `.standardError`; tests swap it.
  private var consoleWriter: ConsoleWriter?

  /// Fixed for the process: the environment does not change after launch.
  let console = Console(environment: ProcessInfo.processInfo.environment)
  private let osLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ble_proximity_bridge", category: "BPB")
  private let formatter: DateFormatter = {
    // DateFormatter is thread-safe for formatting on iOS 7 and later.
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter
  }()

  private init() {
    if console == .standardError { consoleWriter = ConsoleWriter(fd: STDERR_FILENO) }
    openFile()
    installCrashHandler()
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    let process = ProcessInfo.processInfo
    log(.info, "log", "==== native log start pid=\(process.processIdentifier) app=\(version)+\(build)")
    // ProcessInfo rather than UIDevice: this can run off the main thread.
    log(
      .info, "log",
      "device \(Self.modelIdentifier()) iOS \(process.operatingSystemVersionString) "
        + "lowPower=\(process.isLowPowerModeEnabled)")
    log(.info, "log", "file \(currentFile?.path ?? "none")")
    log(.info, "log", "console \(consoleDescription)")
    log(.info, "ble", "authorization \(Self.bluetoothAuthorization())")
  }

  // MARK: - Logging

  static func d(_ component: String, _ message: @autoclosure () -> String) {
    shared.log(.debug, component, message)
  }

  static func i(_ component: String, _ message: @autoclosure () -> String) {
    shared.log(.info, component, message)
  }

  static func w(_ component: String, _ message: @autoclosure () -> String) {
    shared.log(.warn, component, message)
  }

  static func e(_ component: String, _ message: @autoclosure () -> String) {
    shared.log(.error, component, message)
  }

  static func isEnabled(_ level: Level) -> Bool {
    shared.lock.lock()
    defer { shared.lock.unlock() }
    return level >= shared.minLevel
  }

  /// The file being written.
  var currentFile: URL? { directory?.appendingPathComponent(Self.fileName) }

  /// For this process; see `dartShouldEcho(console:simulator:)`.
  static var dartShouldEcho: Bool {
    #if targetEnvironment(simulator)
      let simulator = true
    #else
      let simulator = false
    #endif
    return dartShouldEcho(console: shared.console, simulator: simulator)
  }

  /// For the log header, e.g.
  /// `stderr (OS_ACTIVITY_DT_MODE=enable, SIGPIPE off)`.
  private var consoleDescription: String {
    switch console {
    case .osLog: return "os_log"
    case .standardError:
      let mode = ProcessInfo.processInfo.environment[Console.modeVariable] ?? ""
      let sigpipe = consoleWriter?.sigpipeOff == true ? "off" : "ON"
      return "stderr (\(Console.modeVariable)=\(mode), SIGPIPE \(sigpipe))"
    }
  }

  /// Herald's own log level, applied to every Herald host we build.
  static var heraldLevel: SensorLoggerLevel {
    shared.lock.lock()
    defer { shared.lock.unlock() }
    return shared.heraldLevel
  }

  /// Applies the levels Dart asked for (see LoggingSetup in Dart).
  static func configure(level: Level?, herald: SensorLoggerLevel?) {
    let logger = shared
    logger.lock.lock()
    if let level = level { logger.minLevel = level }
    if let herald = herald {
      logger.heraldLevel = herald
      // Herald reads it on every log call, so this applies at once.
      BLESensorConfiguration.logLevel = herald
    }
    let summary = "configured level=\(logger.minLevel) herald=\(logger.heraldLevel.rawValue)"
    logger.lock.unlock()
    i("log", summary)
  }

  private func log(_ level: Level, _ component: String, _ message: () -> String) {
    lock.lock()
    let enabled = level >= minLevel
    lock.unlock()
    guard enabled else { return }

    let line =
      "\(formatter.string(from: Date())) \(level.letter) native.\(component) "
      + "[\(Self.queueLabel())] \(message())"
    if console == .osLog {
      osLog.log(level: level == .error ? .error : .default, "\(line, privacy: .public)")
    }

    lock.lock()
    write(line)
    pending.append(line)
    if pending.count > Self.maxPending {
      pending.removeFirst(pending.count - Self.maxPending)
      pendingDropped += 1
    }
    let drain = scheduleDrainLocked()
    // Under the lock, so the console has the lines in the file's order.
    // This only queues the line (see ConsoleWriter); nothing waits here.
    consoleWriter?.write(line, now: self.formatter.string(from: Date()))
    lock.unlock()
    if drain { DispatchQueue.main.async { self.drain() } }
    reportProblems()
  }

  private func log(_ level: Level, _ component: String, _ message: String) {
    log(level, component, { message })
  }

  /// Appends lines Dart already formatted to the file. They are not sent
  /// back to Dart. `printed` says whether Dart printed them itself; when it
  /// did not (see `printsDartLines`), they go to the console from here.
  static func writeFromDart(_ lines: [String], printed: Bool = true) {
    let logger = shared
    logger.lock.lock()
    for line in lines {
      logger.write(line)
      if !printed {
        logger.consoleWriter?.write(line, now: logger.formatter.string(from: Date()))
      }
    }
    logger.lock.unlock()
    logger.reportProblems()
  }

  /// Whether Dart should leave printing its lines to this logger: when the
  /// console is the app's stderr. Dart's `print` waited there like our own
  /// writes while nobody read the console (on the iPad, with the console
  /// paused, the app stood still after 1500 printed lines of 1 KB); from
  /// here the line is only queued.
  static var printsDartLines: Bool { shared.console == .standardError }

  /// Gives the console up to `timeout` seconds to take what is queued.
  /// For the moments before the process ends.
  static func flushConsole(timeout: TimeInterval) {
    let logger = shared
    logger.lock.lock()
    let writer = logger.consoleWriter
    logger.lock.unlock()
    writer?.flush(timeout: timeout)
  }

  /// Logs (as errors, so they reach the console and Dart) the problems
  /// `write` and `openHandle` recorded. Call without the lock. Logging one
  /// cannot record another: the failed file handle is gone by then.
  private func reportProblems() {
    lock.lock()
    let found = problems
    problems.removeAll()
    lock.unlock()
    for problem in found { log(.error, "log", problem) }
  }

  // MARK: - Dart

  /// The logs event channel's sink; main thread only.
  static func attachDart(_ sink: FlutterEventSink?) {
    let logger = shared
    logger.lock.lock()
    logger.dartSink = sink
    let drain = logger.scheduleDrainLocked()
    logger.lock.unlock()
    if drain { DispatchQueue.main.async { logger.drain() } }
  }

  /// Call with the lock held; true when the caller must schedule `drain`.
  private func scheduleDrainLocked() -> Bool {
    guard dartSink != nil, !drainScheduled, !pending.isEmpty else { return false }
    drainScheduled = true
    return true
  }

  /// Sends everything pending in one batch. Main thread.
  private func drain() {
    lock.lock()
    drainScheduled = false
    guard let sink = dartSink, !pending.isEmpty else {
      lock.unlock()
      return
    }
    var batch = pending
    pending.removeAll()
    if pendingDropped > 0 {
      batch.insert(
        "\(formatter.string(from: Date())) W native.log [main] \(pendingDropped) earlier "
          + "lines did not fit while Dart was not listening", at: 0)
      pendingDropped = 0
    }
    lock.unlock()
    // A FlutterEventSink is a block and cannot throw.
    sink(batch)
  }

  // MARK: - File

  /// Call with the lock held.
  private func write(_ line: String) {
    guard let handle = handle, let data = (line + "\n").data(using: .utf8) else { return }
    do {
      try handle.write(contentsOf: data)
      fileBytes += UInt64(data.count)
      if fileBytes > Self.maxFileBytes {
        try? handle.close()
        self.handle = nil
        rotate()
        openHandle()
        if let note = "\(formatter.string(from: Date())) I native.log [log] continued from bridge.1.log\n"
          .data(using: .utf8)
        {
          try? self.handle?.write(contentsOf: note)
        }
      }
    } catch {
      problems.append("log file write failed; file logging stops: \(error.localizedDescription)")
      try? handle.close()
      self.handle = nil
    }
  }

  private func openFile() {
    guard
      let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    else { return }
    let dir = documents.appendingPathComponent("logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    directory = dir
    rotate()
    openHandle()
  }

  private func openHandle() {
    guard let url = currentFile else { return }
    FileManager.default.createFile(atPath: url.path, contents: nil)
    handle = try? FileHandle(forWritingTo: url)
    fileBytes = 0
    if handle == nil { problems.append("cannot open the log file; logging to the console only") }
  }

  /// bridge.log → bridge.1.log → bridge.2.log; the oldest is dropped.
  private func rotate() {
    guard let dir = directory else { return }
    func url(_ index: Int) -> URL {
      dir.appendingPathComponent(index == 0 ? Self.fileName : "bridge.\(index).log")
    }
    let files = FileManager.default
    try? files.removeItem(at: url(Self.keptFiles - 1))
    for index in stride(from: Self.keptFiles - 2, through: 0, by: -1)
    where files.fileExists(atPath: url(index).path) {
      try? files.moveItem(at: url(index), to: url(index + 1))
    }
  }

  // MARK: - Tests

  /// Swaps the console writer (nil: none); returns the previous one.
  func replaceConsoleWriterForTesting(_ writer: ConsoleWriter?) -> ConsoleWriter? {
    lock.lock()
    defer { lock.unlock() }
    let previous = consoleWriter
    consoleWriter = writer
    return previous
  }

  /// Closes the file handle behind the logger's back, so the next write
  /// fails as a real I/O error would.
  func breakLogFileForTesting() {
    lock.lock()
    try? handle?.close()
    lock.unlock()
  }

  /// Opens bridge.log again (truncated) after `breakLogFileForTesting`.
  func reopenLogFileForTesting() {
    lock.lock()
    openHandle()
    lock.unlock()
    reportProblems()
  }

  // MARK: - Helpers

  /// The dispatch queue we are on, shortened: `main`, or e.g.
  /// `BLE.BLESensor.DelegateQueue` for Herald's delegate queue.
  private static func queueLabel() -> String {
    let label = String(cString: __dispatch_queue_get_label(nil))
    if label == "com.apple.main-thread" { return "main" }
    var short = label
    for prefix in ["Sensor.", "com.apple."] where short.hasPrefix(prefix) {
      short.removeFirst(prefix.count)
    }
    short = short.replacingOccurrences(of: "Concrete", with: "")
    if short.isEmpty { return Thread.isMainThread ? "main" : "bg" }
    return String(short.suffix(32))
  }

  /// E.g. `iPhone17,2`, or `iPhone19,2 (simulator)`.
  private static func modelIdentifier() -> String {
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
      return "\(simulated) (simulator)"
    }
    var systemInfo = utsname()
    uname(&systemInfo)
    return withUnsafePointer(to: &systemInfo.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
  }

  /// The app's Bluetooth permission; reading it does not prompt.
  static func bluetoothAuthorization() -> String {
    switch CBManager.authorization {
    case .allowedAlways: return "allowedAlways"
    case .denied: return "DENIED"
    case .restricted: return "RESTRICTED"
    case .notDetermined: return "notDetermined (iOS asks when Herald starts)"
    @unknown default: return "unknown"
    }
  }

  /// Logs an uncaught Objective-C exception (CBUUID with a bad string, for
  /// one) before the previous handler runs. Swift runtime traps are signals
  /// and are not caught here; their crash reports are on the device
  /// (tool/devlogs.dart pull fetches them).
  private func installCrashHandler() {
    previousExceptionHandler = NSGetUncaughtExceptionHandler()
    NSSetUncaughtExceptionHandler { exception in
      let stack = exception.callStackSymbols.joined(separator: "\n    ")
      BridgeLog.e(
        "crash",
        "uncaught exception \(exception.name.rawValue): \(exception.reason ?? "")\n    \(stack)")
      // The process is about to end; let the console have the line too.
      BridgeLog.flushConsole(timeout: 0.5)
      previousExceptionHandler?(exception)
    }
  }
}

/// The handler that was installed before ours; a C function pointer, so it
/// has to live outside the closure.
private var previousExceptionHandler: (@convention(c) (NSException) -> Void)?

/// A device kind from the payload, for the log: `ios`, `android` or the code.
func deviceKindName(_ kind: Int) -> String {
  switch kind {
  case 0: return "ios"
  case 1: return "android"
  default: return "dev=\(kind)"
  }
}

/// A peer id as every log line writes it: upper-case hex, at least 8 digits,
/// negative ids as their 64-bit two's complement (same as Dart's peerHex).
func peerHex(_ id: Int) -> String {
  let hex = String(UInt64(bitPattern: Int64(id)), radix: 16, uppercase: true)
  return hex.count >= 8 ? hex : String(repeating: "0", count: 8 - hex.count) + hex
}
