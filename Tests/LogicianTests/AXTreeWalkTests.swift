import XCTest
@testable import Logician

/// The Accessibility tree walks all funnel through `walkTree`/`firstNode`.
/// Real AXUIElements cannot be constructed in a test, but the traversal is
/// generic over the node type, so the part that actually matters — pre-order
/// visit ORDER, where the depth cap falls, and what `.stop` / `.skipChildren`
/// do — is checked here on a plain tree. Every one of these properties is
/// load-bearing: the callers take "the first match", and an off-by-one in the
/// depth cap makes a lookup silently return nil ("not found") rather than
/// fail.
final class AXTreeWalkTests: XCTestCase {

    private struct Node {
        let name: String
        var children: [Node] = []
    }

    /// root
    /// ├── a          (depth 1)
    /// │   ├── a1     (depth 2)
    /// │   │   └── a1x (depth 3)
    /// │   └── a2     (depth 2)
    /// └── b          (depth 1)
    ///     └── b1     (depth 2)
    private let tree = Node(name: "root", children: [
        Node(name: "a", children: [
            Node(name: "a1", children: [Node(name: "a1x")]),
            Node(name: "a2")
        ]),
        Node(name: "b", children: [Node(name: "b1")])
    ])

    private func visited(maximumDepth: Int, step: @escaping (Node) -> AXWalkStep = { _ in .descend }) -> [String] {
        var seen: [String] = []
        walkTree(from: tree, maximumDepth: maximumDepth, children: { $0.children }) { node in
            seen.append(node.name)
            return step(node)
        }
        return seen
    }

    // MARK: - Order

    func testWalkIsDepthFirstPreOrder() {
        XCTAssertEqual(
            visited(maximumDepth: 10),
            ["root", "a", "a1", "a1x", "a2", "b", "b1"],
            "parents before children, siblings in child order"
        )
    }

    func testFirstNodeReturnsTheFirstMatchInPreOrderNotTheShallowest() {
        // "a1x" (depth 3) is visited before "b" (depth 1); a breadth-first
        // walk would return the other one.
        let match = firstNode(from: tree, maximumDepth: 10, children: { $0.children }) {
            $0.name == "a1x" || $0.name == "b"
        }
        XCTAssertEqual(match?.name, "a1x")
    }

    // MARK: - Depth semantics (root is 0, cap is inclusive)

    func testMaximumDepthZeroVisitsOnlyTheRoot() {
        XCTAssertEqual(visited(maximumDepth: 0), ["root"])
    }

    func testMaximumDepthIsInclusiveOfThatLevel() {
        XCTAssertEqual(visited(maximumDepth: 1), ["root", "a", "b"])
        XCTAssertEqual(visited(maximumDepth: 2), ["root", "a", "a1", "a2", "b", "b1"])
        XCTAssertEqual(visited(maximumDepth: 3), ["root", "a", "a1", "a1x", "a2", "b", "b1"])
    }

    func testNodesBelowTheCapAreNeverVisited() {
        XCTAssertFalse(visited(maximumDepth: 2).contains("a1x"))
        XCTAssertNil(firstNode(from: tree, maximumDepth: 2, children: { $0.children }) {
            $0.name == "a1x"
        })
    }

    /// `descendants(of:maximumDepth:)` is root-exclusive and measures its cap
    /// from each CHILD of the root, so it reaches one level deeper than
    /// `collect`/`firstDescendant` with the same number. That asymmetry is
    /// inherited from the original hand-rolled walk and is deliberate; this
    /// pins it so a future tidy-up cannot quietly shorten every plugin walk.
    func testChildRootedWalkReachesOneLevelDeeper() {
        var seen: [String] = []
        for child in tree.children {
            walkTree(from: child, maximumDepth: 2, children: { $0.children }) { node in
                seen.append(node.name)
                return .descend
            }
        }
        XCTAssertEqual(seen, ["a", "a1", "a1x", "a2", "b", "b1"])
        XCTAssertFalse(visited(maximumDepth: 2).contains("a1x"), "same number, one level shallower")
    }

    // MARK: - Steps

    func testStopEndsTheWholeWalkImmediately() {
        XCTAssertEqual(
            visited(maximumDepth: 10, step: { $0.name == "a1" ? .stop : .descend }),
            ["root", "a", "a1"],
            "no siblings, no uncles, nothing after the stop"
        )
    }

    func testSkipChildrenPrunesTheSubtreeButKeepsWalkingSiblings() {
        XCTAssertEqual(
            visited(maximumDepth: 10, step: { $0.name == "a1" ? .skipChildren : .descend }),
            ["root", "a", "a1", "a2", "b", "b1"],
            "a1x is pruned; a2 and the b branch still run"
        )
    }

    func testSkipChildrenOnTheRootVisitsNothingElse() {
        XCTAssertEqual(visited(maximumDepth: 10, step: { _ in .skipChildren }), ["root"])
    }

    func testFirstNodeCanMatchTheRootItself() {
        let match = firstNode(from: tree, maximumDepth: 0, children: { $0.children }) {
            $0.name == "root"
        }
        XCTAssertEqual(match?.name, "root")
    }

    func testFirstNodeReturnsNilWhenNothingMatches() {
        XCTAssertNil(firstNode(from: tree, maximumDepth: 10, children: { $0.children }) {
            $0.name == "nope"
        })
    }

    func testWalkVisitsEachNodeExactlyOnce() {
        var counts: [String: Int] = [:]
        walkTree(from: tree, maximumDepth: 10, children: { $0.children }) { node in
            counts[node.name, default: 0] += 1
            return .descend
        }
        XCTAssertEqual(counts.values.filter { $0 != 1 }.count, 0)
        XCTAssertEqual(counts.count, 7)
    }

    // MARK: - Depth table

    /// The depth caps are the only thing standing between a Logic layout
    /// change and a silent "not found", so they must stay positive and stay
    /// deep enough to leave the walk's root behind.
    func testEveryDepthCapIsUsable() {
        let caps: [(String, Int)] = [
            ("trackHeaderGroup", AXDepth.trackHeaderGroup),
            ("inspectorStrip", AXDepth.inspectorStrip),
            ("trackHeaderControl", AXDepth.trackHeaderControl),
            ("trackRegionRow", AXDepth.trackRegionRow),
            ("timeRuler", AXDepth.timeRuler),
            ("controlBar", AXDepth.controlBar),
            ("alertDialog", AXDepth.alertDialog),
            ("bounceDialogControl", AXDepth.bounceDialogControl),
            ("bounceDestinationList", AXDepth.bounceDestinationList),
            ("menuBarItem", AXDepth.menuBarItem),
            ("popupMenu", AXDepth.popupMenu),
            ("popupMenuItem", AXDepth.popupMenuItem),
            ("keyCommandsOutline", AXDepth.keyCommandsOutline),
            ("keyCommandsRowText", AXDepth.keyCommandsRowText),
            ("keyCommandsControl", AXDepth.keyCommandsControl),
            ("keyCommandsConflictAlert", AXDepth.keyCommandsConflictAlert),
            ("pluginWindowHeader", AXDepth.pluginWindowHeader),
            ("wholeWindow", AXDepth.wholeWindow)
        ]
        for (name, value) in caps {
            XCTAssertGreaterThanOrEqual(value, 3, "\(name) would not reach past the root's grandchildren")
        }
    }
}
