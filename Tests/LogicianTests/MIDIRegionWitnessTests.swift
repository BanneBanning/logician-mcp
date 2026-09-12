import XCTest
@testable import Logician

final class MIDIRegionWitnessTests: XCTestCase {
    private let meter = MeterMap(events: [MeterEvent(bar: 1, numerator: 4, denominator: 4),
        MeterEvent(bar: 41, numerator: 5, denominator: 4)], source: .signatureList)!
    private func entry(position: String = "40 4 4 223", end: String = "45 1 1 1", pitch: String = "A♯2") -> ListEditorEntry {
        var fields = Dictionary(uniqueKeysWithValues: MIDIRegionWitness.columns.map { ($0, "") })
        fields["Position"] = position; fields["Off Position/Info"] = end
        fields["Status"] = "Note"; fields["Ch"] = "1"; fields["Num"] = pitch
        fields["Val"] = "9864"
        return ListEditorEntry(index: 0, fields: fields, cells: MIDIRegionWitness.columns.map { fields[$0]! })
    }
    private func witness(_ entries: [ListEditorEntry], anchor: Int = 41,
        velocities: [[Int]]? = nil, declared: Int? = nil,
        parameters: Data = Data("parameters".utf8)) throws -> MIDIRegionWitness {
        try MIDIRegionWitness(entries: entries,
            velocities: velocities ?? entries.map { _ in [98,64] },
            columns: MIDIRegionWitness.columns, declared: declared ?? entries.count,
            anchor: .init(bar: anchor, beat: 1, division: 1, tick: 1),
            meter: meter, parameters: parameters)
    }
    func testAbsoluteNoteEndsPreserveDurationAcrossChangingMeterAndPickup() throws {
        let source = try witness([entry()])
        let copied = try witness([entry(position: "47 5 4 223", end: "52 1 1 1")], anchor: 48)
        XCTAssertEqual(source, copied)
        let shortened = try witness([entry(position: "47 5 4 223", end: "51 5 1 1")], anchor: 48)
        XCTAssertNotEqual(source, shortened)
    }
    func testStaleClipboardWithIdenticalRegionMetadataCannotPassDifferentNotes() throws {
        XCTAssertNotEqual(try witness([entry()]), try witness([entry(pitch: "C3")]))
        XCTAssertNotEqual(try witness([entry()]), try witness([entry()], velocities: [[98,65]]))
        XCTAssertNotEqual(try witness([entry()], velocities: [[11,22]]),
            try witness([entry()], velocities: [[112,2]]))
        XCTAssertNotEqual(try witness([entry()]),
            try witness([entry()], parameters: Data("changed transpose".utf8)))
    }
    func testOrderDoesNotMatterButDuplicateNotesDo() throws {
        let a = entry(), b = entry(pitch: "C3")
        XCTAssertEqual(try witness([a,b]), try witness([b,a]))
        XCTAssertNotEqual(try witness([a,b]), try witness([a,a,b]))
    }
    func testUnreadAndUnsupportedEventsRefuseInsteadOfDisappearing() throws {
        XCTAssertThrowsError(try witness([entry()], declared: 2))
        var fields = entry().fields
        fields["Status"] = "SysEx"
        XCTAssertThrowsError(try witness([.init(index: 0, fields: fields, cells: [])]))
        XCTAssertThrowsError(try witness([entry()], velocities: [[98]]))
        XCTAssertThrowsError(try witness([entry(position: "-1 1 1 1")]))
        XCTAssertThrowsError(try witness([entry(end: "40 4 4 200")]))
    }
    func testMissingColumnsAndFractionalAnchorAreNotGuessed() throws {
        XCTAssertThrowsError(try MIDIRegionWitness(entries: [entry()], velocities: [[98,64]],
            columns: Array(MIDIRegionWitness.columns.dropLast()), declared: 1,
            anchor: .init(bar: 41, beat: 1, division: 1, tick: 1), meter: meter, parameters: Data()))
        XCTAssertThrowsError(try MIDIRegionWitness(entries: [entry()], velocities: [[98,64]],
            columns: MIDIRegionWitness.columns, declared: 1,
            anchor: .init(bar: 41, beat: 1, division: 2, tick: 1), meter: meter, parameters: Data()))
    }
}
