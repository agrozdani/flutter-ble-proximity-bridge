import Flutter
import UIKit
import XCTest

@testable import Runner

/// Pins the 16-byte wire format. The byte arrays are the same ones the
/// Android tests (StatusPayloadSupplierTest.kt) use, so the two codecs are
/// checked against one set of golden bytes.
class StatusPayloadSupplierTests: XCTestCase {

  func testEncodesTheDocumentedLayout() throws {
    let supplier = StatusPayloadSupplier(peerId: 0x1A2B_3C4D)
    supplier.update(status: 2, color: 5)

    let payload = try XCTUnwrap(supplier.currentFrame())
    XCTAssertEqual(
      [UInt8](payload),
      [
        0x4D, 0x3C, 0x2B, 0x1A, 0, 0, 0, 0,  // peer id, little-endian
        2,  // status
        5,  // color
        0,  // device kind: iOS
        0,  // flags
        2, 0, 0, 0,  // protocol version
      ])

    supplier.setOffline(true)
    XCTAssertEqual(try XCTUnwrap(supplier.currentFrame())[11], 1)
  }

  func testDecodesAPayloadWrittenByAndroid() {
    let data = Data([
      0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0,
      3, 4, 1, 1,
      2, 0, 0, 0,
    ])

    XCTAssertEqual(StatusPayloadSupplier.peerId(from: data), 0x51C0_FFEE)
    XCTAssertEqual(StatusPayloadSupplier.status(from: data), 3)
    XCTAssertEqual(StatusPayloadSupplier.color(from: data), 4)
    XCTAssertEqual(StatusPayloadSupplier.deviceKind(from: data), 1)
    XCTAssertEqual(StatusPayloadSupplier.isOffline(from: data), true)
    XCTAssertEqual(StatusPayloadSupplier.version(from: data), 2)
  }

  func testAnIdWithTheTopBitSetDecodesToTheSameValueAsOnAndroid() {
    let data = Data([1, 0, 0, 0, 0, 0, 0, 0x80, 0, 0, 0, 0, 2, 0, 0, 0])

    // Kotlin: Long.MIN_VALUE + 1.
    XCTAssertEqual(StatusPayloadSupplier.peerId(from: data), Int.min + 1)
  }

  func testAShortPayloadIsDroppedNotPartiallyParsed() {
    let data = Data(count: 15)

    XCTAssertNil(StatusPayloadSupplier.peerId(from: data))
    XCTAssertNil(StatusPayloadSupplier.status(from: data))
    XCTAssertNil(StatusPayloadSupplier.isOffline(from: data))
  }

  func testARebuiltSupplierAdoptsTheStatusOfTheOneItReplaces() throws {
    let previous = StatusPayloadSupplier(peerId: 1)
    previous.update(status: 3, color: 4)
    previous.setOffline(true)

    let rebuilt = StatusPayloadSupplier(peerId: 2)
    rebuilt.adoptStatus(from: previous)

    let payload = try XCTUnwrap(rebuilt.currentFrame())
    XCTAssertEqual(StatusPayloadSupplier.peerId(from: payload), 2)
    XCTAssertEqual(StatusPayloadSupplier.status(from: payload), 3)
    XCTAssertEqual(StatusPayloadSupplier.color(from: payload), 4)
    // Only the status carries over: the new supplier starts online.
    XCTAssertEqual(StatusPayloadSupplier.isOffline(from: payload), false)
  }
}

/// Same cases as FrameOverridesTest.kt on Android.
class FrameOverridesTests: XCTestCase {

  private var clock = 0.0
  private var overrides: FrameOverrides!

  private let online = FrameOverrides.Payload(status: 1, color: 2, deviceKind: 0, offline: false)
  private let offline = FrameOverrides.Payload(status: 1, color: 2, deviceKind: 0, offline: true)
  private let onlineNewStatus = FrameOverrides.Payload(
    status: 3, color: 2, deviceKind: 0, offline: false)

  override func setUp() {
    super.setUp()
    clock = 0
    overrides = FrameOverrides(ttlSeconds: 30, now: { [unowned self] in self.clock })
  }

  func testWithoutAFrameEveryPayloadIsTakenAtFaceValue() {
    XCTAssertEqual(overrides.resolve(peerId: 7, source: .cached, payload: online), online)
    XCTAssertEqual(overrides.resolve(peerId: 7, source: .cached, payload: offline), offline)
    XCTAssertEqual(overrides.resolve(peerId: 7, source: .read, payload: online), online)
  }

  func testAFrameIsReportedAsItArrived() {
    XCTAssertEqual(overrides.resolve(peerId: 7, source: .frame, payload: offline), offline)
    XCTAssertEqual(overrides.resolve(peerId: 7, source: .frame, payload: online), online)
  }

  func testAfterAGoodbyeTheCachedOnlinePayloadIsIgnored() {
    _ = overrides.resolve(peerId: 7, source: .frame, payload: offline)

    XCTAssertNil(overrides.resolve(peerId: 7, source: .cached, payload: online))
    // Still ignored on later readings, and without reporting gone again.
    XCTAssertNil(overrides.resolve(peerId: 7, source: .cached, payload: online))
    XCTAssertNil(overrides.resolve(peerId: 7, source: .cached, payload: offline))
  }

  func testAfterAHelloTheCachedOfflinePayloadDoesNotRemoveThePeer() {
    _ = overrides.resolve(peerId: 7, source: .frame, payload: onlineNewStatus)

    // The reading is kept, described by the frame rather than the cache.
    XCTAssertEqual(
      overrides.resolve(peerId: 7, source: .cached, payload: offline), onlineNewStatus)
    XCTAssertEqual(
      overrides.resolve(peerId: 7, source: .cached, payload: online), onlineNewStatus)
  }

  func testAFreshReadEndsTheOverride() {
    _ = overrides.resolve(peerId: 7, source: .frame, payload: offline)

    XCTAssertEqual(overrides.resolve(peerId: 7, source: .read, payload: online), online)
    XCTAssertEqual(overrides.resolve(peerId: 7, source: .cached, payload: online), online)
  }

  func testAFreshOfflineReadIsReportedAndEndsAHelloOverride() {
    _ = overrides.resolve(peerId: 7, source: .frame, payload: online)

    XCTAssertEqual(overrides.resolve(peerId: 7, source: .read, payload: offline), offline)
    XCTAssertEqual(overrides.resolve(peerId: 7, source: .cached, payload: offline), offline)
  }

  func testAnOverrideExpiresIfNoFreshReadReplacesIt() {
    _ = overrides.resolve(peerId: 7, source: .frame, payload: offline)

    clock = 30
    XCTAssertNil(overrides.resolve(peerId: 7, source: .cached, payload: online))

    clock = 30.001
    XCTAssertEqual(overrides.resolve(peerId: 7, source: .cached, payload: online), online)
    // Expiry removed the entry rather than just hiding it.
    clock = 0
    XCTAssertEqual(overrides.resolve(peerId: 7, source: .cached, payload: online), online)
  }

  func testANewerFrameReplacesTheOlderOneAndRestartsItsLifetime() {
    _ = overrides.resolve(peerId: 7, source: .frame, payload: offline)
    clock = 20
    _ = overrides.resolve(peerId: 7, source: .frame, payload: online)

    clock = 45
    XCTAssertEqual(overrides.resolve(peerId: 7, source: .cached, payload: offline), online)
  }

  func testOverridesAreKeptPerPeerAndDroppedByClearAll() {
    _ = overrides.resolve(peerId: 7, source: .frame, payload: offline)

    XCTAssertEqual(overrides.resolve(peerId: 8, source: .cached, payload: online), online)
    XCTAssertNil(overrides.resolve(peerId: 7, source: .cached, payload: online))

    overrides.clearAll()
    XCTAssertEqual(overrides.resolve(peerId: 7, source: .cached, payload: online), online)
  }
}
