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
/// - to os_log (subsystem: the bundle id, category `BPB`). `flutter run`
///   shows it: with Xcode 26 or later it launches the app through devicectl
///   with `OS_ACTIVITY_DT_MODE`, which mirrors os_log to the console. Lines
///   are logged at `.default` (`.error` for errors), because that mirror
///   leaves out `.debug` messages; the line carries its own level letter.
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

  /// Whether Dart should print the native lines it receives. On a simulator
  /// `flutter run` does not show them: it filters the simulator's os_log to
  /// messages from the app's main executable, and debug builds (Xcode 15+)
  /// put the app's code in Runner.debug.dylib. On a device it shows them
  /// (devicectl console with OS_ACTIVITY_DT_MODE), so Dart must not.
  static var dartShouldEcho: Bool {
    #if targetEnvironment(simulator)
      return true
    #else
      return false
    #endif
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
    osLog.log(level: level == .error ? .error : .default, "\(line, privacy: .public)")

    lock.lock()
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
