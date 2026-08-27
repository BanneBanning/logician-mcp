import XCTest
@testable import Logician
@testable import LogicMCUBridge

/// Slicing one MCU LCD row into strips. Pure: no Logic, no bridge.
///
/// Every row here was captured off the running surface on 2026-08-28, banked
/// at bank 2 of the reference project, with the CS volume view showing and a
/// vpot turned eight ticks down on one channel at a time. The rightmost cell
/// is the whole point: its value is painted one column left of its cell, and
/// reading it literally drops the sign — which sent the in-bridge convergence
/// the wrong way and parked `Stereo Out` on the +6.0 dB end stop.
final class LCDRowTests: XCTestCase {

    // Captured live. Note the banner's format ("+0,0 dB", a space before the
    // unit) versus the multi-channel row's ("+0,0dB", none) — the extra
    // character is exactly what makes the last cell overflow.
    private let multiChannel =
        "-19,5  +0,0dB +0,0dB +0,0dB +0,0dB +0,0dB +0,0dB +0,0dB "
    private let bannerChannel1 =
        "-19,5  -1,7 dB                            +0,0dB +0,0dB "
    private let bannerChannel3 =
        "-19,5  +0,0 dB       -1,7 dB                            "
    private let bannerChannel5 =
        "-19,5  +0,0 dB                     -1,7 dB              "
    private let bannerChannel7 =
        "-19,5  +0,0 dB                                  -1,7 dB "

    func testEveryCapturedRowIsFiftySixCharacters() {
        for row in [multiChannel, bannerChannel1, bannerChannel3,
                    bannerChannel5, bannerChannel7] {
            XCTAssertEqual(row.count, MCULCDRow.length, "row: |\(row)|")
        }
    }

    // MARK: - The literal slicing is unchanged

    func testMultiChannelRowSlicesIntoEightCells() {
        XCTAssertEqual(MCULCDRow.cells(multiChannel),
                       ["-19,5", "+0,0dB", "+0,0dB", "+0,0dB",
                        "+0,0dB", "+0,0dB", "+0,0dB", "+0,0dB"])
    }

    func testAShortRowIsPaddedRatherThanTruncatingTheCellList() {
        XCTAssertEqual(MCULCDRow.cells("Bas").count, MCULCDRow.cellCount)
        XCTAssertEqual(MCULCDRow.cells("Bas")[0], "Bas")
        XCTAssertEqual(MCULCDRow.cells("Bas")[7], "")
    }

    func testOutOfRangeCellsAreEmptyRatherThanATrap() {
        XCTAssertEqual(MCULCDRow.cell(multiChannel, -1), "")
        XCTAssertEqual(MCULCDRow.cell(multiChannel, 8), "")
        XCTAssertEqual(MCULCDRow.valueCell(multiChannel, 99), "")
    }

    // MARK: - The shift, cell by cell, on the captured rows

    func testChannelsBelowTheLastAreNotShifted() {
        // The banner fits inside its own cell everywhere but the right edge,
        // so the literal reading and the value reading agree.
        for (row, channel) in [(bannerChannel1, 1), (bannerChannel3, 3), (bannerChannel5, 5)] {
            XCTAssertEqual(MCULCDRow.cell(row, channel), "-1,7 dB")
            XCTAssertEqual(MCULCDRow.valueCell(row, channel), "-1,7 dB")
            XCTAssertEqual(MCUController.parseDb(MCULCDRow.valueCell(row, channel)), -1.7)
        }
    }

    func testTheRightmostCellLosesItsSignWhenReadLiterally() {
        // This is the bug, stated as a test: cell 6 gets the minus, cell 7
        // gets the magnitude, and the magnitude alone parses to +1.7.
        XCTAssertEqual(MCULCDRow.cell(bannerChannel7, 6), "-")
        XCTAssertEqual(MCULCDRow.cell(bannerChannel7, 7), "1,7 dB")
        XCTAssertEqual(MCUController.parseDb(MCULCDRow.cell(bannerChannel7, 7)), 1.7)
    }

    func testTheRightmostValueCellRecoversTheShiftedSign() {
        XCTAssertEqual(MCULCDRow.valueCell(bannerChannel7, 7), "-1,7 dB")
        XCTAssertEqual(MCUController.parseDb(MCULCDRow.valueCell(bannerChannel7, 7)), -1.7)
    }

    func testAPositiveRightmostValueRecoversItsPlusToo() {
        // "+6,0 dB" is what the runaway landed on; the plus is dropped by the
        // literal slice as surely as the minus, it just parses the same.
        let row = "-19,5  +0,0dB +0,0dB                            +6,0 dB "
        XCTAssertEqual(row.count, MCULCDRow.length)
        XCTAssertEqual(MCULCDRow.cell(row, 7), "6,0 dB")
        XCTAssertEqual(MCULCDRow.valueCell(row, 7), "+6,0 dB")
        XCTAssertEqual(MCUController.parseDb(MCULCDRow.valueCell(row, 7)), 6.0)
    }

    // MARK: - The rule fires on positive evidence only

    func testAnUnshiftedRightmostCellIsLeftAlone() {
        // The multi-channel row's last cell carries its own sign at its own
        // first column; nothing to recover, and cell 6 must not be raided.
        XCTAssertEqual(MCULCDRow.valueCell(multiChannel, 7), "+0,0dB")
        XCTAssertEqual(MCULCDRow.cells(multiChannel), MCULCDRow.valueCells(multiChannel))
    }

    func testADashPlaceholderInCellSixCannotNegateCellSeven() {
        // The pan single-channel view paints "-" placeholders, and they sit at
        // the cell's FIRST column — six columns away from the sign column, so
        // they can never be mistaken for a shifted sign.
        let row = "Pan    -      -      -      -      -      -      12     "
        XCTAssertEqual(row.count, MCULCDRow.length)
        XCTAssertEqual(MCULCDRow.cell(row, 6), "-")
        XCTAssertEqual(MCULCDRow.valueCell(row, 7), "12")
    }

    func testAnEmptyRightmostCellStaysEmptyEvenBesideASign() {
        let row = String(repeating: " ", count: 42) + "-1,7 d " // sign column blank
        XCTAssertEqual(MCULCDRow.valueCell(row, 7), "")
    }

    func testTheWholeRowOfValueCellsMatchesTheCapturedBanner() {
        XCTAssertEqual(MCULCDRow.valueCells(bannerChannel7),
                       ["-19,5", "+0,0 dB", "", "", "", "", "-", "-1,7 dB"])
    }

    // MARK: - Both planes read the same way

    func testTheServersValueFieldsAgreeWithTheSharedSlicer() {
        for row in [multiChannel, bannerChannel1, bannerChannel7] {
            XCTAssertEqual(MCUController.lcdValueFields(row), MCULCDRow.valueCells(row))
            XCTAssertEqual(MCUController.lcdFields(row), MCULCDRow.cells(row))
        }
    }
}
