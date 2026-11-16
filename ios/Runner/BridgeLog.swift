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
  /// - The simulator under `flutter run` (`simctl launch`) and a device
  ///   launch without a console (`devicectl device process launch`, as
  ///   `flutter run --release` does) get no `OS_ACTIVITY_DT_MODE`.
  ///
  /// With the variable set, os_log is skipped rather than written as well:
  /// its mirror copy would otherwise sit next to ours in any console that
  /// shows both (`flutter run -v` does). The cost is that Console.app and `log stream` do not see
  /// our lines during such a launch; the log file has them all.
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
  /// executable, and debug builds (Xcode 15+) put the app's code in
  /// Runner.debug.dylib. With `.standardError` the console already has each
  /// line, so an echo would print it twice; on a device without
  /// `OS_ACTIVITY_DT_MODE` no console of flutter_tools reads the app's
  /// output, so an echo would only add a second copy to os_log.
  static func dartShouldEcho(console: Console, simulator: Bool) -> Bool {
    console == .osLog && simulator
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

  /// For the log header, e.g. `stderr (OS_ACTIVITY_DT_MODE=enable)`.
  private var consoleDescription: String {
    switch console {
    case .osLog: return "os_log"
    case .standardError:
      let mode = ProcessInfo.processInfo.environment[Console.modeVariable] ?? ""
      return "stderr (\(Console.modeVariable)=\(mode))"
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
    // Under the lock, so lines from different threads do not interleave.
    if console == .standardError { Self.writeStandardError(line) }
    write(line)
    pending.append(line)
    if pending.count > Self.maxPending {
      pending.removeFirst(pending.count - Self.maxPending)
      pendingDropped += 1
    }
    let drain = scheduleDrainLocked()
    lock.unlock()
    if drain { DispatchQueue.main.async { self.drain() } }
  }

  private func log(_ level: Level, _ component: String, _ message: String) {
    log(level, component, { message })
  }

  /// Appends lines Dart already formatted to the file. They are not sent to
  /// os_log (Dart printed them) or back to Dart.
  static func writeFromDart(_ lines: [String]) {
    let logger = shared
    logger.lock.lock()
    lines.forEach(logger.write)
    logger.lock.unlock()
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
      osLog.error("Log file write failed; file logging stops: \(error.localizedDescription, privacy: .public)")
      try? handle.close()
      self.handle = nil
    }
  }

  /// One unbuffered write(2) per line (more only if the kernel takes part
  /// of it). Errors are ignored: the line is in the file anyway.
  private static func writeStandardError(_ line: String) {
    let bytes = Array((line + "\n").utf8)
    bytes.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var offset = 0
      while offset < buffer.count {
        let written = Darwin.write(STDERR_FILENO, base + offset, buffer.count - offset)
        if written > 0 {
          offset += written
        } else if written < 0 && errno == EINTR {
          continue
        } else {
          return
        }
      }
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
    if handle == nil { osLog.error("Cannot open the log file; logging to os_log only") }
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
