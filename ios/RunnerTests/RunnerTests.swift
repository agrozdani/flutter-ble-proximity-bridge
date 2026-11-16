import Flutter
import Herald
import UIKit
import XCTest

@testable import Runner

/// Pins the 16-byte wire format. StatusPayloadSupplierTest.kt on Android
/// holds the same four byte arrays: each platform's encoder must produce its
/// own pair exactly, and its decoder is run on the other platform's pair, so
/// the two codecs are checked against each other.
class StatusPayloadSupplierTests: XCTestCase {

  // Peer id 0x51C0FFEE (three of its bytes are >= 0x80, so a decoder that
  // sign-extends bytes fails), status 2, color 5, protocol version 3.
  // Flags 0x04: revision 2, online. 0x07: revision 3, offline.
  private let iosOnline: [UInt8] = [
    0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0,  // peer id, little-endian
    2,  // status
    5,  // color
    0,  // device kind: iOS
    0x04,  // flags: revision << 1 | offline
    3, 0, 0, 0,  // protocol version
  ]
  private let iosOffline: [UInt8] = [
    0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0, 2, 5, 0, 0x07, 3, 0, 0, 0,
  ]
  private let androidOnline: [UInt8] = [
    0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0, 2, 5, 1, 0x04, 3, 0, 0, 0,
  ]
  private let androidOffline: [UInt8] = [
    0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0, 2, 5, 1, 0x07, 3, 0, 0, 0,
  ]

  func testEncodesTheDocumentedLayout() throws {
    // A fresh counter: the supplier takes revision 1, the update 2, and
    // going offline 3.
    let supplier = StatusPayloadSupplier(peerId: 0x51C0_FFEE, revisions: RevisionCounter())
    supplier.update(status: 2, color: 5)

    XCTAssertEqual([UInt8](try XCTUnwrap(supplier.currentFrame())), iosOnline)

    supplier.setOffline(true)
    XCTAssertEqual([UInt8](try XCTUnwrap(supplier.currentFrame())), iosOffline)
  }

  func testDecodesTheBytesTheAndroidEncoderProduces() {
    let online = Data(androidOnline)
    XCTAssertEqual(StatusPayloadSupplier.peerId(from: online), 0x51C0_FFEE)
    XCTAssertEqual(StatusPayloadSupplier.status(from: online), 2)
    XCTAssertEqual(StatusPayloadSupplier.color(from: online), 5)
    XCTAssertEqual(StatusPayloadSupplier.deviceKind(from: online), 1)
    XCTAssertEqual(StatusPayloadSupplier.isOffline(from: online), false)
    XCTAssertEqual(StatusPayloadSupplier.revision(from: online), 2)
    XCTAssertEqual(StatusPayloadSupplier.version(from: online), 3)

    let offline = Data(androidOffline)
    XCTAssertEqual(StatusPayloadSupplier.peerId(from: offline), 0x51C0_FFEE)
    XCTAssertEqual(StatusPayloadSupplier.isOffline(from: offline), true)
    XCTAssertEqual(StatusPayloadSupplier.revision(from: offline), 3)
  }

  func testAVersion2PayloadHasNoRevision() {
    // Version 2 left flags bits 1-7 at 0, so they must not read as one.
    let data = Data([0xEE, 0xFF, 0xC0, 0x51, 0, 0, 0, 0, 2, 5, 1, 1, 2, 0, 0, 0])

    XCTAssertNil(StatusPayloadSupplier.revision(from: data))
    XCTAssertEqual(StatusPayloadSupplier.isOffline(from: data), true)
  }

  func testOnlyAChangeTakesANewRevision() throws {
    let supplier = StatusPayloadSupplier(peerId: 1, revisions: RevisionCounter())
    func revision() throws -> Int? {
      StatusPayloadSupplier.revision(from: try XCTUnwrap(supplier.currentFrame()))
    }

    XCTAssertEqual(try revision(), 1)
    supplier.update(status: 0, color: 0)
    supplier.setOffline(false)
    supplier.updatePeerId(1)
    XCTAssertEqual(try revision(), 1)

    supplier.update(status: 1, color: 0)
    XCTAssertEqual(try revision(), 2)
    supplier.setOffline(true)
    XCTAssertEqual(try revision(), 3)
    supplier.updatePeerId(2)
    XCTAssertEqual(try revision(), 4)
  }

  func testASupplierForARebuiltHostAdoptsTheStatusAndContinuesTheRevisions() throws {
    let revisions = RevisionCounter()
    let previous = StatusPayloadSupplier(peerId: 1, revisions: revisions)
    previous.update(status: 3, color: 4)
    previous.setOffline(true)
    let previousRevision = try XCTUnwrap(
      StatusPayloadSupplier.revision(from: try XCTUnwrap(previous.currentFrame())))

    let rebuilt = StatusPayloadSupplier.forRebuiltHost(
      peerId: 2, previous: previous, revisions: revisions)

    let payload = try XCTUnwrap(rebuilt.currentFrame())
    XCTAssertEqual(StatusPayloadSupplier.peerId(from: payload), 2)
    XCTAssertEqual(StatusPayloadSupplier.status(from: payload), 3)
    XCTAssertEqual(StatusPayloadSupplier.color(from: payload), 4)
    // Only the status carries over: the new supplier starts online.
    XCTAssertEqual(StatusPayloadSupplier.isOffline(from: payload), false)
    // Newer than anything the old supplier sent, as a receiver sees it.
    let rebuiltRevision = try XCTUnwrap(StatusPayloadSupplier.revision(from: payload))
    XCTAssertTrue((1...63).contains((rebuiltRevision - previousRevision) & 0x7F))
  }

  func testASupplierForAFirstHostStartsBlank() throws {
    let supplier = StatusPayloadSupplier.forRebuiltHost(
      peerId: 5, previous: nil, revisions: RevisionCounter())

    let payload = try XCTUnwrap(supplier.currentFrame())
    XCTAssertEqual(StatusPayloadSupplier.peerId(from: payload), 5)
    XCTAssertEqual(StatusPayloadSupplier.status(from: payload), 0)
    XCTAssertEqual(StatusPayloadSupplier.color(from: payload), 0)
  }

  func testRevisionsWrapAt7Bits() {
    let revisions = RevisionCounter()
    let issued = (0..<129).map { _ in revisions.next() }

    XCTAssertEqual(issued, Array(1...127) + [0, 1])
  }

  func testANegativeIdIsWrittenAsItsBitPattern() throws {
    let supplier = StatusPayloadSupplier(peerId: -1, revisions: RevisionCounter())

    let payload = try XCTUnwrap(supplier.currentFrame())
    XCTAssertEqual([UInt8](payload.prefix(8)), [UInt8](repeating: 0xFF, count: 8))
    XCTAssertEqual(StatusPayloadSupplier.peerId(from: payload), -1)
  }

  func testAnIdWithTheTopBitSetDecodesToTheSameValueAsOnAndroid() {
    let data = Data([1, 0, 0, 0, 0, 0, 0, 0x80, 0, 0, 0, 0, 3, 0, 0, 0])

    // Kotlin: Long.MIN_VALUE + 1.
    XCTAssertEqual(StatusPayloadSupplier.peerId(from: data), Int.min + 1)
  }

  func testAShortPayloadIsDroppedNotPartiallyParsed() {
    let data = Data(count: 15)

    XCTAssertNil(StatusPayloadSupplier.peerId(from: data))
    XCTAssertNil(StatusPayloadSupplier.status(from: data))
    XCTAssertNil(StatusPayloadSupplier.isOffline(from: data))
    XCTAssertNil(StatusPayloadSupplier.revision(from: data))
  }
}

/// Same cases as FrameOverridesTest.kt on Android.
class FrameOverridesTests: XCTestCase {

  private var clock = 0.0
  private var overrides: FrameOverrides!

  // Sent by an Android device, so its frames get the full lifetime. These
  // carry no revision (a sender before protocol version 3): the tests up to
  // the revision section pin the frame rule on its own.
  private let online = FrameOverrides.Payload(status: 1, color: 2, deviceKind: 1, offline: false)
  private let offline = FrameOverrides.Payload(status: 1, color: 2, deviceKind: 1, offline: true)
  private let onlineNewStatus = FrameOverrides.Payload(
    status: 3, color: 2, deviceKind: 1, offline: false)

  private let iphoneOnline = FrameOverrides.Payload(
    status: 1, color: 2, deviceKind: 0, offline: false)
  private let iphoneOffline = FrameOverrides.Payload(
    status: 1, color: 2, deviceKind: 0, offline: true)

  override func setUp() {
    super.setUp()
    clock = 0
    overrides = FrameOverrides(
      ttlSeconds: 30, iphoneGoodbyeTtlSeconds: 5, revisionMemorySeconds: 60,
      now: { [unowned self] in self.clock })
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

  func testAGoodbyeFromAnIphoneExpiresAfterItsShorterLifetime() {
    _ = overrides.resolve(peerId: 7, source: .frame, payload: iphoneOffline)

    clock = 5
    XCTAssertNil(overrides.resolve(peerId: 7, source: .cached, payload: iphoneOnline))

    // A restart the hello never announced shows up again.
    clock = 5.001
    XCTAssertEqual(
      overrides.resolve(peerId: 7, source: .cached, payload: iphoneOnline), iphoneOnline)
  }

  func testAHelloFromAnIphoneKeepsTheFullLifetime() {
    _ = overrides.resolve(peerId: 7, source: .frame, payload: iphoneOffline)
    clock = 1
    _ = overrides.resolve(peerId: 7, source: .frame, payload: iphoneOnline)

    clock = 31
    XCTAssertEqual(
      overrides.resolve(peerId: 7, source: .cached, payload: iphoneOffline), iphoneOnline)

    clock = 31.001
    XCTAssertEqual(
      overrides.resolve(peerId: 7, source: .cached, payload: iphoneOffline), iphoneOffline)
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

  // MARK: - Revisions (protocol version 3)

  private func rev(_ revision: Int, offline: Bool = false) -> FrameOverrides.Payload {
    var payload = online
    payload.offline = offline
    payload.revision = revision
    return payload
  }

  private func iphoneRev(_ revision: Int, offline: Bool = false) -> FrameOverrides.Payload {
    var payload = iphoneOnline
    payload.offline = offline
    payload.revision = revision
    return payload
  }

  func testAFrameOlderThanAPayloadAlreadySeenIsDropped() {
    // A goodbye that was stuck in the sender's queue arrives after a read of
    // its newer, online payload.
    XCTAssertEqual(overrides.resolve(peerId: 7, source: .read, payload: rev(5)), rev(5))

    XCTAssertNil(overrides.resolve(peerId: 7, source: .frame, payload: rev(4, offline: true)))
    XCTAssertEqual(overrides.resolve(peerId: 7, source: .cached, payload: rev(5)), rev(5))
  }

  func testAReadOlderThanTheFrameDoesNotEndIt() {
    _ = overrides.resolve(peerId: 7, source: .frame, payload: rev(5, offline: true))

    // Read just before the goodbye, delivered just after it.
    XCTAssertNil(overrides.resolve(peerId: 7, source: .read, payload: rev(4)))
    XCTAssertNil(overrides.resolve(peerId: 7, source: .cached, payload: rev(4)))
  }

  func testAStaleRelayedCopyIsIgnoredAfterAFreshOfflineRead() {
    XCTAssertEqual(
      overrides.resolve(peerId: 7, source: .read, payload: rev(6, offline: true)),
      rev(6, offline: true))

    // A relay still holds the online payload from before the stop.
    XCTAssertNil(overrides.resolve(peerId: 7, source: .read, payload: rev(5)))
    XCTAssertNil(overrides.resolve(peerId: 7, source: .cached, payload: rev(5)))
  }

  func testAStaleOfflineCopyDoesNotRemoveALivePeer() {
    _ = overrides.resolve(peerId: 7, source: .read, payload: rev(7))

    // A relay still holds the offline payload from before a restart.
    XCTAssertNil(overrides.resolve(peerId: 7, source: .read, payload: rev(6, offline: true)))
    XCTAssertEqual(
      overrides.resolve(peerId: 7, source: .cached, payload: rev(6, offline: true)), rev(7))
  }

  func testAfterAnIphoneGoodbyeRunsOutAnOlderCachedPayloadIsBelieved() {
    _ = overrides.resolve(peerId: 7, source: .frame, payload: iphoneRev(9, offline: true))

    clock = 5
    XCTAssertNil(overrides.resolve(peerId: 7, source: .cached, payload: iphoneRev(8)))

    // Readings again: most likely a restart whose hello never arrived.
    clock = 5.001
    XCTAssertEqual(
      overrides.resolve(peerId: 7, source: .cached, payload: iphoneRev(8)), iphoneRev(8))
  }

  func testACachedPayloadNewerThanTheFrameEndsIt() {
    _ = overrides.resolve(peerId: 7, source: .frame, payload: rev(3, offline: true))

    XCTAssertEqual(overrides.resolve(peerId: 7, source: .cached, payload: rev(4)), rev(4))
    XCTAssertEqual(overrides.resolve(peerId: 7, source: .cached, payload: rev(4)), rev(4))
  }

  func testRevisionsWrapAround() {
    _ = overrides.resolve(peerId: 7, source: .read, payload: rev(127))

    // 0 follows 127.
    XCTAssertEqual(
      overrides.resolve(peerId: 7, source: .frame, payload: rev(0, offline: true)),
      rev(0, offline: true))
    XCTAssertNil(overrides.resolve(peerId: 7, source: .read, payload: rev(127)))
  }

  func testRevisionsHalfTheRangeApartAreNotOrdered() {
    _ = overrides.resolve(peerId: 7, source: .read, payload: rev(0))

    // Neither newer nor older, so not dropped.
    XCTAssertEqual(
      overrides.resolve(peerId: 7, source: .frame, payload: rev(64, offline: true)),
      rev(64, offline: true))
  }

  func testAPayloadWithoutARevisionIsNeverStale() {
    _ = overrides.resolve(peerId: 7, source: .read, payload: rev(10))

    XCTAssertEqual(overrides.resolve(peerId: 7, source: .frame, payload: offline), offline)
  }

  func testTheNewestRevisionIsRememberedWhileItKeepsBeingConfirmed() {
    _ = overrides.resolve(peerId: 7, source: .read, payload: rev(10))

    clock = 50
    _ = overrides.resolve(peerId: 7, source: .cached, payload: rev(10))

    clock = 110
    XCTAssertNil(overrides.resolve(peerId: 7, source: .frame, payload: rev(9, offline: true)))

    // Not confirmed for longer than the memory: forgotten.
    clock = 170.001
    XCTAssertEqual(
      overrides.resolve(peerId: 7, source: .frame, payload: rev(9, offline: true)),
      rev(9, offline: true))
  }

  func testARevisionNotConfirmedWithinTheMemoryIsForgottenBetweenSweeps() {
    clock = 50
    _ = overrides.resolve(peerId: 7, source: .read, payload: rev(10))
    // Another peer's payload at 100 s runs the periodic sweep, which keeps
    // peer 7's 50 s old entry.
    clock = 100
    _ = overrides.resolve(peerId: 8, source: .read, payload: rev(1))

    // At 120 s peer 7's entry is 70 s old; the next sweep is not due, so the
    // lookup itself must notice it has expired.
    clock = 120
    XCTAssertEqual(
      overrides.resolve(peerId: 7, source: .frame, payload: rev(9, offline: true)),
      rev(9, offline: true))
  }

  func testClearAllAlsoForgetsRevisions() {
    _ = overrides.resolve(peerId: 7, source: .read, payload: rev(10))

    overrides.clearAll()
    XCTAssertEqual(
      overrides.resolve(peerId: 7, source: .frame, payload: rev(9, offline: true)),
      rev(9, offline: true))
  }
}

/// Drives the pipeline through Herald's own delegate callbacks, so how each
/// callback is classified is under test, not just FrameOverrides. Same cases
/// as PayloadPipelineTest.kt on Android.
///
/// The classification tests use payloads without a revision (protocol
/// version 2): with one, a misclassified read could be dropped as stale and
/// hide the mistake.
class PayloadPipelineTests: XCTestCase {

  private static let localId = 99

  private var active = true
  private var events: [String] = []
  private var malformed: [Int] = []
  private var pipeline: PayloadPipeline!

  override func setUp() {
    super.setUp()
    active = true
    events = []
    malformed = []
    pipeline = PayloadPipeline(
      frameOverrides: FrameOverrides(
        ttlSeconds: 30, iphoneGoodbyeTtlSeconds: 5, revisionMemorySeconds: 60, now: { 0 }),
      isActive: { [unowned self] in self.active },
      localPeerId: { PayloadPipelineTests.localId },
      onSighting: { [unowned self] peerId, status, _, _, rssi in
        self.events.append("peer \(peerId) status \(status) rssi \(rssi.map { "\($0)" } ?? "nil")")
      },
      onGone: { [unowned self] peerId in self.events.append("gone \(peerId)") },
      onMalformed: { [unowned self] size in self.malformed.append(size) })
  }

  private let target: TargetIdentifier = "target"

  private func payload(_ peerId: Int, offline: Bool = false, status: UInt8 = 1) -> PayloadData {
    var bytes = [UInt8](repeating: 0, count: 16)
    let id = UInt64(bitPattern: Int64(peerId))
    for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: id >> (8 * UInt64(i))) }
    bytes[8] = status
    bytes[10] = 1  // device kind: Android
    bytes[11] = offline ? 1 : 0
    bytes[12] = 2  // protocol version 2: no revision
    return PayloadData(Data(bytes))
  }

  private func reading(_ rssi: Double) -> Proximity {
    Proximity(unit: .RSSI, value: rssi)
  }

  private func goodbye(_ peerId: Int) {
    pipeline.sensor(.BLE, didReceive: payload(peerId, offline: true).data, fromTarget: target)
  }

  func testAReadingWithAPayloadIsASightingWithItsRSSI() {
    pipeline.sensor(.BLE, didMeasure: reading(-60), fromTarget: target, withPayload: payload(7))

    XCTAssertEqual(events, ["peer 7 status 1 rssi -60.0"])
  }

  func testAReadIsASightingWithoutRSSI() {
    pipeline.sensor(.BLE, didRead: payload(7), fromTarget: target)

    XCTAssertEqual(events, ["peer 7 status 1 rssi nil"])
  }

  func testAFrameIsReportedAsItArrived() {
    goodbye(7)

    XCTAssertEqual(events, ["gone 7"])
  }

  func testAReadingIsCachedSoItCannotUndoAGoodbye() {
    goodbye(7)
    pipeline.sensor(.BLE, didMeasure: reading(-60), fromTarget: target, withPayload: payload(7))

    XCTAssertEqual(events, ["gone 7"])
  }

  func testAReadIsFreshSoItEndsAGoodbye() {
    goodbye(7)
    pipeline.sensor(.BLE, didRead: payload(7), fromTarget: target)

    XCTAssertEqual(events, ["gone 7", "peer 7 status 1 rssi nil"])
  }

  func testRelayedPayloadsAreCached() {
    goodbye(7)
    pipeline.sensor(.BLE, didShare: [payload(7), payload(8)], fromTarget: target)

    XCTAssertEqual(events, ["gone 7", "peer 8 status 1 rssi nil"])
  }

  func testOurOwnPayloadIsDroppedWithoutBeingRecorded() {
    goodbye(Self.localId)
    pipeline.sensor(
      .BLE, didMeasure: reading(-60), fromTarget: target, withPayload: payload(Self.localId))
    pipeline.sensor(.BLE, didRead: payload(Self.localId), fromTarget: target)

    XCTAssertEqual(events, [])
  }

  func testWhileInactiveNothingIsReportedButFramesAreStillRecorded() {
    active = false
    goodbye(7)
    pipeline.sensor(.BLE, didMeasure: reading(-60), fromTarget: target, withPayload: payload(8))
    XCTAssertEqual(events, [])

    // After the next start, Herald's cached online copy of peer 7 must still
    // lose to the goodbye that arrived while we were stopped.
    active = true
    pipeline.sensor(.BLE, didMeasure: reading(-60), fromTarget: target, withPayload: payload(7))
    pipeline.sensor(.BLE, didMeasure: reading(-61), fromTarget: target, withPayload: payload(8))
    XCTAssertEqual(events, ["peer 8 status 1 rssi -61.0"])
  }

  func testAMalformedPayloadIsDroppedAndLogged() {
    pipeline.sensor(.BLE, didRead: PayloadData(Data(count: 15)), fromTarget: target)

    XCTAssertEqual(events, [])
    XCTAssertEqual(malformed, [15])
  }

  func testCallbacksWithoutAPayloadAreIgnored() {
    pipeline.sensor(.BLE, didDetect: target)
    pipeline.sensor(.BLE, available: true, didDeleteOrDetect: target)
    pipeline.sensor(.BLE, didMeasure: reading(-60), fromTarget: target)
    pipeline.sensor(.BLE, didUpdateState: .on)

    XCTAssertEqual(events, [])
  }
}
