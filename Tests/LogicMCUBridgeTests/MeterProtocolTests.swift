import XCTest
@testable import LogicMCUBridge

/// The protocol-5 additions, seen from both sides of a version skew.
///
/// The daemon and the server are separate processes and are routinely at
/// different versions — during this very session the running daemon answered
/// `bridge_protocol: 3` while the build under test was 5. So "what happens
/// when the other end is older" is not a hypothetical here, it is the normal
/// case, and it is what these tests are about.
final class MeterProtocolTests: XCTestCase {

    /// A pre-protocol-5 daemon's status reply: no meter keys at all.
    private static let preMeterSnapshot = """
    {"assignment":"PN",\
    "faders_14bit":[8192,-1,-1,-1,-1,-1,-1,-1,12000],\
    "last_receive":1756200000.5,\
    "lcd_bottom":"  0.0    -3.5   -oo                                    ",\
    "lcd_top":"Kick   Snare  Bass                                       ",\
    "leds_lit":[86,94],\
    "online":true,\
    "received_events":4211,\
    "timecode":"001 01 01 000",\
    "transport_leds":{"cycle":true,"forward":false,"play":true,"record":false,"rewind":false,"stop":false},\
    "updated":1756200001.25,\
    "vpot_rings":[0,1,2,3,4,5,6,7]}
    """

    /// The regression this guards is severe and silent. `BridgeResponse`
    /// decodes the snapshot with `try?`, so if a newly-added REQUIRED field
    /// throws on an older daemon's JSON, the failure is not "no meters" — it
    /// is `snapshot == nil`, i.e. every LCD row, fader and LED in the server
    /// reads as absent while the bridge is perfectly healthy.
    func testAnOlderDaemonsSnapshotStillDecodesWhole() throws {
        let data = Data(Self.preMeterSnapshot.utf8)
        let snapshot = try bridgeJSONDecoder.decode(SurfaceSnapshot.self, from: data)
        XCTAssertEqual(snapshot.receivedEvents, 4211)
        XCTAssertEqual(snapshot.assignment, "PN")
        XCTAssertEqual(snapshot.faders14bit.first, 8192)
        // ...and the meter fields default rather than throwing.
        XCTAssertEqual(snapshot.meterLevels, [])
        XCTAssertEqual(snapshot.meterOverloads, [])
        XCTAssertEqual(snapshot.meterEvents, 0)
    }

    func testAnOlderDaemonsStatusReplyStillCarriesItsSnapshot() throws {
        let reply = Data(("{\"ok\":true,\"midi_streaming\":false,"
            + Self.preMeterSnapshot.dropFirst()).utf8)
        let response = try bridgeJSONDecoder.decode(BridgeResponse.self, from: reply)
        XCTAssertTrue(response.ok)
        XCTAssertNotNil(response.snapshot, "the whole snapshot must survive a version skew")
        XCTAssertEqual(response.snapshot?.receivedEvents, 4211)
        XCTAssertEqual(response.snapshot?.meterLevels, [])
    }

    /// An EMPTY meter array and an all-zero one are different answers:
    /// "this daemon cannot tell you" versus "Logic says silence".
    func testEmptyMetersAreDistinguishableFromSilentMeters() throws {
        let silent = SurfaceSnapshot(
            updated: 1, lastReceive: 1, receivedEvents: 1, online: true,
            lcdTop: "", lcdBottom: "", timecode: "", assignment: "",
            faders14bit: [], vpotRings: [], transportLEDs: [:], ledsLit: [],
            meterLevels: [Int](repeating: 0, count: 8),
            meterOverloads: [Bool](repeating: false, count: 8),
            meterEvents: 900
        )
        let data = try bridgeJSONEncoder.encode(silent)
        let back = try bridgeJSONDecoder.decode(SurfaceSnapshot.self, from: data)
        XCTAssertEqual(back.meterLevels.count, 8)
        XCTAssertEqual(back.meterEvents, 900)
        XCTAssertNotEqual(back.meterLevels, [])
    }

    func testMeterSnapshotRoundTrips() throws {
        let snapshot = SurfaceSnapshot(
            updated: 2, lastReceive: 2, receivedEvents: 7, online: true,
            lcdTop: "a", lcdBottom: "b", timecode: "c", assignment: "PN",
            faders14bit: [1, 2], vpotRings: [3], transportLEDs: ["play": true], ledsLit: [1],
            meterLevels: [0, 12, -1, 4, 5, 6, 7, 8],
            meterOverloads: [false, true, false, false, false, false, false, false],
            meterEvents: 42
        )
        let data = try bridgeJSONEncoder.encode(snapshot)
        XCTAssertEqual(try bridgeJSONDecoder.decode(SurfaceSnapshot.self, from: data), snapshot)
    }

    /// A genuinely malformed reply must still fail loudly — leniency is only
    /// for the fields that did not exist before protocol 5.
    func testAMissingPreExistingFieldStillThrows() {
        let broken = Data(#"{"assignment":"PN","meter_events":3}"#.utf8)
        XCTAssertThrowsError(try bridgeJSONDecoder.decode(SurfaceSnapshot.self, from: broken))
    }

    // MARK: - fader verify

    func testFaderCommandOmitsVerifyByDefault() throws {
        let command = BridgeCommand.fader(channel: 3, value: 9000)
        let object = try JSONSerialization.jsonObject(
            with: try bridgeJSONEncoder.encode(command)
        ) as? [String: Any]
        XCTAssertEqual(object?["channel"] as? Int, 3)
        XCTAssertEqual(object?["value"] as? Int, 9000)
        // Absent, not `false`: the automation recorder's timing depends on the
        // daemon taking the fast path, and an older daemon must see the exact
        // bytes it always saw.
        XCTAssertNil(object?["verify"])
    }

    func testFaderCommandCarriesVerifyWhenAsked() throws {
        let command = BridgeCommand.fader(channel: 0, value: 12443, verify: true)
        XCTAssertEqual(command.verify, true)
        let data = try bridgeJSONEncoder.encode(command)
        XCTAssertEqual(try bridgeJSONDecoder.decode(BridgeCommand.self, from: data), command)
    }

    func testVerifiedFaderReplyRoundTrips() throws {
        var response = BridgeResponse.success
        response.finalValue = 5628
        response.followed = true
        let data = try bridgeJSONEncoder.encode(response)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["final_value"] as? Double, 5628)
        XCTAssertEqual(object?["followed"] as? Bool, true)
        XCTAssertEqual(try bridgeJSONDecoder.decode(BridgeResponse.self, from: data), response)
    }

    /// An older daemon answers a verified fader write with a bare `ok`. The
    /// server must read that as "unverified", never as "did not follow".
    func testOlderDaemonsFaderReplyLeavesFollowedNil() throws {
        let data = Data(#"{"ok":true}"#.utf8)
        let response = try bridgeJSONDecoder.decode(BridgeResponse.self, from: data)
        XCTAssertTrue(response.ok)
        XCTAssertNil(response.followed)
        XCTAssertNil(response.finalValue)
    }
}
