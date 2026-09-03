import Foundation
import XCTest
@testable import Logician

/// Every menu-bar press in this server answers `.success` and does NOTHING
/// while Logic is in the background — measured live 2026-09-03 on `View >
/// Inspector` (3/3, including a System Events click as a control) and on
/// `Mix > Delete Automation` the same day. Two callers were fixed by putting
/// `ensureLogicFrontmost` in front of their own press
/// (`InspectorVisibility.pressInspectorMenuItem`, the automation-menu path in
/// `ToolHandlersSurface.swift`). A THIRD, `AXListEditors.withListEditorsTab`
/// pressing `View > List Editors`, had skipped it — which is what a guard
/// sprinkled at each call site costs: it is optional at every new one.
///
/// The fix moves the guard INTO `pressMenuItem` itself, the one function every
/// title-path menu press in this codebase goes through, so no future caller
/// can leave it out. These tests pin that decision down two ways: that the
/// choke point still guards (source-level, since exercising it live needs
/// Logic running and backgrounded — the live proof for that is in the fix's
/// report, not in CI), and that nothing has grown a second, unguarded route to
/// a menu-bar press.
final class MenuPressFrontmostGuardTests: XCTestCase {

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LogicianTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Sources/Logician")
    }

    private func contents(_ file: String) throws -> String {
        try String(contentsOf: sourcesRoot.appendingPathComponent(file), encoding: .utf8)
    }

    // MARK: - The choke point itself

    /// `pressMenuItem`'s guard has to run BEFORE it ever asks Logic's menu bar
    /// for anything — a guard bolted on after the walk still lets the walk
    /// itself run against a backgrounded app. This pins the ORDER, not just
    /// the presence, by requiring the frontmost call to precede the app
    /// lookup that starts the walk.
    func testPressMenuItemGuardsFrontmostBeforeItTouchesTheMenuBar() throws {
        let source = try contents("AXBounce.swift")
        guard let signature = source.range(of: "func pressMenuItem(") else {
            return XCTFail("pressMenuItem has moved or been renamed")
        }
        let body = source[signature.lowerBound...]
        guard let guardCall = body.range(of: "ensureLogicFrontmost(for:") else {
            return XCTFail("pressMenuItem no longer guards ensureLogicFrontmost")
        }
        guard let menuBarLookup = body.range(of: "kAXMenuBarAttribute") else {
            return XCTFail("could not find the menu bar lookup to order against")
        }
        XCTAssertTrue(
            guardCall.lowerBound < menuBarLookup.lowerBound,
            "ensureLogicFrontmost must run before pressMenuItem reads the menu bar, not after"
        )
    }

    // MARK: - The list of callers: nothing bypasses the guarded helpers

    /// Every menu title this server presses by title path goes through
    /// `pressMenuItem`. If a future call site walked the menu bar itself
    /// instead (its own `AXUIElementPerformAction` on something found under
    /// `kAXMenuBarAttribute`), it would inherit none of this fix.
    func testEveryTitlePathMenuPressGoesThroughPressMenuItem() throws {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
        )
        var callSites = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let file = url.lastPathComponent
            let code = try String(contentsOf: url, encoding: .utf8)
            // `LogicUIStrings.Menu.` marks a reference to a named menu bar
            // item or path segment. Every source file that mentions one is
            // allowed to do so only as an ARGUMENT to `pressMenuItem`/
            // `automationMenuItem`, as a route-string label, or as a literal
            // inside `LogicUIStrings.swift`/this test itself — never as the
            // target of a raw `kAXMenuBarAttribute` walk of its own.
            guard code.contains("LogicUIStrings.Menu.") else { continue }
            guard !["LogicUIStrings.swift", "AXRemoveAutomation.swift", "AXBounce.swift"]
                .contains(file) else {
                // AXRemoveAutomation.swift owns the one OTHER menu-bar walk in
                // the server (`Mix > Delete Automation`), and it is guarded at
                // its own call site in ToolHandlersSurface.swift — see the
                // test below. AXBounce.swift IS `pressMenuItem`'s own
                // declaration, the one place `kAXMenuBarAttribute` is allowed
                // to appear alongside a `Menu.` reference.
                continue
            }
            callSites += 1
            XCTAssertFalse(
                code.contains("kAXMenuBarAttribute"),
                "\(file) references a Menu title AND walks kAXMenuBarAttribute directly — "
                    + "route it through pressMenuItem() instead, which is the only place the "
                    + "frontmost guard lives"
            )
        }
        XCTAssertGreaterThan(callSites, 5, "the scan found almost no menu callers — wrong root?")
    }

    /// The one other menu-bar walk in the server (`Mix > Delete Automation`,
    /// `AXRemoveAutomation.swift`'s `automationMenuItem`) does not go through
    /// `pressMenuItem`, by design (see that file's header comment on why a
    /// local walk was chosen). It has to carry its own guard, immediately
    /// before EACH of its two presses — the lane read between them can run
    /// long enough for something else to take the front back.
    func testTheAutomationMenuPressPathGuardsFrontmostBeforeEachOfItsTwoPresses() throws {
        let source = try contents("ToolHandlersSurface.swift")
        let guardCount = source.components(separatedBy: "logic.ensureLogicFrontmost(for: \"the '\\(item)'").count - 1
        XCTAssertEqual(
            guardCount, 2,
            "expected exactly two ensureLogicFrontmost guards around the Delete Automation menu "
                + "item (one before reading its enabled state, one before the destructive press) — "
                + "found \(guardCount)"
        )
    }

    /// `pressOpeningTrackingMenu` deliberately discards the press's own status
    /// code (see its doc comment: Logic's tracking-menu runloop never answers
    /// it), which means it can never fall back the way `pressMenuItem(settled:)`
    /// does. Every one of its callers has to guard frontmost itself, before
    /// the press — this enumerates them so a future caller cannot add a fifth
    /// one that skips it.
    func testEveryPressOpeningTrackingMenuCallIsPrecededByAFrontmostGuard() throws {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
        )
        var callSites = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let file = url.lastPathComponent
            guard file != "AXHelpers.swift" else { continue }  // the declaration itself
            let lines = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where line.contains("pressOpeningTrackingMenu(") {
                callSites += 1
                let precedingWindow = lines[max(0, index - 40)..<index].joined(separator: "\n")
                XCTAssertTrue(
                    precedingWindow.contains("ensureLogicFrontmost("),
                    "\(file):\(index + 1) calls pressOpeningTrackingMenu with no "
                        + "ensureLogicFrontmost guard in the 40 lines before it"
                )
            }
        }
        XCTAssertEqual(callSites, 4, "the known pressOpeningTrackingMenu call sites moved — update this test's expectations")
    }
}
