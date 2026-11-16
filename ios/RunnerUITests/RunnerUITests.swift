import XCTest

// UI tests that drive the real app on a device or simulator. Run them with
// tool/ios_ui_test.sh; see docs/device-testing.md.
//
// They run in the Profile configuration: a Flutter debug build can't start
// on a physical iOS device unless a debugger is attached, and XCUITest
// launches without one. Profile builds start with mock peers off, so the
// tests switch them on.
final class RunnerUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launch()
    XCTAssertTrue(element("idle").waitForExistence(timeout: 20), "app did not reach idle")
  }

  override func tearDownWithError() throws {
    attachScreenshot("final")
    app.terminate()
  }

  func testStartAndStopWithMockPeers() throws {
    setMockPeers(true)
    element("Start").tap()
    XCTAssertTrue(element("running").waitForExistence(timeout: 10))

    let peers = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH 'Nearby peers (' AND NOT (label == 'Nearby peers (0)')"))
      .firstMatch
    XCTAssertTrue(peers.waitForExistence(timeout: 15), "no mock peers appeared")
    attachScreenshot("running")

    element("Stop").tap()
    XCTAssertTrue(element("idle").waitForExistence(timeout: 10))
  }

  func testOpenLogScreen() throws {
    element("Logs").tap()
    attachScreenshot("logs")
    // Flutter draws its own app bar; its back button is labelled "Back".
    let back = element("Back")
    XCTAssertTrue(back.waitForExistence(timeout: 5), "log screen did not open")
    back.tap()
    XCTAssertTrue(element("Start").waitForExistence(timeout: 5))
  }

  // MARK: Scripted scenario

  /// Runs the steps in the SCENARIO environment variable against the real
  /// app, for exercising Bluetooth on hardware while another device and
  /// the logs are watched. Skipped unless SCENARIO is set; xcodebuild passes
  /// it on as TEST_RUNNER_SCENARIO, which tool/ios_ui_test.sh sets from
  /// SCENARIO.
  ///
  /// Steps, comma-separated:
  ///   start           Start with real Bluetooth (mock peers off), allowing
  ///                   the Bluetooth prompt if iOS shows it.
  ///   start-mock      Start with mock peers.
  ///   stop            Stop.
  ///   status:TEXT     Tap the status chip whose label contains TEXT.
  ///   hold:SECONDS    Wait, leaving the app as it is.
  ///   logs            Open the Logs screen.
  ///   tap:LABEL       Tap the element labelled exactly LABEL.
  ///   back            Leave the Logs screen.
  ///   shot:NAME       Attach a screenshot.
  ///
  /// Each step is an activity named "SCENARIO <time> <step>", which shows in
  /// xcodebuild's output as the step begins, so other devices can be driven
  /// in step with it.
  func testScenario() throws {
    let script = ProcessInfo.processInfo.environment["SCENARIO"] ?? ""
    try XCTSkipIf(script.isEmpty, "SCENARIO not set")

    for step in script.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
      let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
      let argument = parts.count > 1 ? parts[1] : ""
      // An activity, unlike print, shows in xcodebuild's output on devices.
      let name = "SCENARIO \(ISO8601DateFormatter().string(from: Date())) \(step)"
      XCTContext.runActivity(named: name) { _ in run(step: parts[0], argument: argument) }
    }
    XCTContext.runActivity(named: "SCENARIO \(ISO8601DateFormatter().string(from: Date())) done") { _ in }
  }

  private func run(step: String, argument: String) {
    switch step {
    case "start":
      setMockPeers(false)
      element("Start").tap()
      allowSystemAlertIfShown()
      XCTAssertTrue(element("running").waitForExistence(timeout: 30), "bridge did not start")
    case "start-mock":
      setMockPeers(true)
      element("Start").tap()
      XCTAssertTrue(element("running").waitForExistence(timeout: 10), "bridge did not start")
    case "stop":
      element("Stop").tap()
      XCTAssertTrue(element("idle").waitForExistence(timeout: 15), "bridge did not stop")
    case "status":
      let chip = app.descendants(matching: .any)
        .matching(NSPredicate(format: "label CONTAINS %@", argument)).firstMatch
      XCTAssertTrue(chip.waitForExistence(timeout: 5), "no status \(argument)")
      chip.tap()
    case "hold":
      Thread.sleep(forTimeInterval: TimeInterval(argument) ?? 0)
    case "logs":
      element("Logs").tap()
      XCTAssertTrue(element("Back").waitForExistence(timeout: 5), "log screen did not open")
    case "tap":
      let target = element(argument)
      XCTAssertTrue(target.waitForExistence(timeout: 5), "nothing labelled \(argument)")
      target.tap()
    case "back":
      element("Back").tap()
    case "shot":
      attachScreenshot(argument)
    default:
      XCTFail("unknown scenario step \(step)")
    }
  }

  // MARK: Helpers

  /// The first element whose accessibility label is exactly `label`.
  private func element(_ label: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
  }

  private func setMockPeers(_ on: Bool) {
    let toggle = app.switches.firstMatch
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    let want = on ? "1" : "0"
    if (toggle.value as? String) != want { toggle.tap() }
    XCTAssertEqual(toggle.value as? String, want, "mock peers did not switch \(on ? "on" : "off")")
  }

  /// Allows a system prompt (iOS asks for Bluetooth on the first real start).
  private func allowSystemAlertIfShown() {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let allow = springboard.alerts.buttons.matching(
      NSPredicate(format: "label IN {'Allow', 'OK', 'Allow While Using App'}")
    ).firstMatch
    if allow.waitForExistence(timeout: 5) {
      XCTContext.runActivity(named: "SCENARIO allowing \(springboard.alerts.firstMatch.label)") { _ in
        allow.tap()
      }
    }
  }

  private func attachScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
