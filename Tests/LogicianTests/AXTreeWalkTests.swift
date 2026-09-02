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

    // MARK: - Nearest (breadth-first)

    /// The whole point of `nearestNode`: the save panel's Bounce button is
    /// shallow and the file browser next to it is enormous, so "nearest the
    /// root" has to beat "first in pre-order" (993 ms vs single-digit ms,
    /// measured 2026-09-01).
    func testNearestNodeReturnsTheShallowestMatchNotThePreOrderFirst() {
        let match = nearestNode(from: tree, maximumDepth: 10, children: { $0.children }) {
            $0.name == "a1x" || $0.name == "b"
        }
        XCTAssertEqual(match?.name, "b", "depth 1 beats depth 3")
        XCTAssertEqual(
            firstNode(from: tree, maximumDepth: 10, children: { $0.children }) {
                $0.name == "a1x" || $0.name == "b"
            }?.name,
            "a1x",
            "and pre-order still answers the other way, for the callers that need it"
        )
    }

    func testNearestNodeBreaksTiesInChildOrder() {
        let match = nearestNode(from: tree, maximumDepth: 10, children: { $0.children }) {
            $0.name == "a" || $0.name == "b"
        }
        XCTAssertEqual(match?.name, "a")
    }

    func testNearestNodeHonoursTheDepthCapExactlyAsPreOrderDoes() {
        for cap in 0...3 {
            let reachable = Set(visited(maximumDepth: cap))
            for name in ["root", "a", "a1", "a1x", "a2", "b", "b1"] {
                let found = nearestNode(from: tree, maximumDepth: cap, children: { $0.children }) {
                    $0.name == name
                }
                XCTAssertEqual(
                    found != nil, reachable.contains(name),
                    "'\(name)' at cap \(cap): the two walks must see the same set of nodes"
                )
            }
        }
    }

    func testNearestNodeCanMatchTheRootAndReturnsNilWhenNothingMatches() {
        XCTAssertEqual(
            nearestNode(from: tree, maximumDepth: 0, children: { $0.children }) { $0.name == "root" }?.name,
            "root"
        )
        XCTAssertNil(nearestNode(from: tree, maximumDepth: 10, children: { $0.children }) {
            $0.name == "nope"
        })
    }

    /// A cycle in the tree would hang a breadth-first walk that trusted its
    /// frontier; the depth cap is what bounds it, and this pins that.
    func testNearestNodeTerminatesOnAWideTree() {
        let wide = Node(name: "root", children: (0..<500).map { index in
            Node(name: "w\(index)", children: (0..<50).map { Node(name: "deep\($0)") })
        })
        XCTAssertEqual(
            nearestNode(from: wide, maximumDepth: 2, children: { $0.children }) { $0.name == "deep7" }?.name,
            "deep7"
        )
        XCTAssertNil(nearestNode(from: wide, maximumDepth: 1, children: { $0.children }) { $0.name == "deep7" })
    }

    // MARK: - The import panel's shape, which is why the rule matters

    /// Logic's MIDI import panel, as the live tree has it: the window's FIRST
    /// child is the file browser's outline (thousands of rows, and it is the
    /// user's own filesystem, so its depth is not this server's to predict),
    /// and every control this tool presses — the Go-to-Folder sheet, Import,
    /// Cancel — is a shallow sibling BEHIND it.
    ///
    /// Pre-order pays for the whole browser before it reaches the button
    /// (measured 2026-09-02: 1 266-2 000 ms a lookup, four lookups an import,
    /// 65% of the tool). Breadth-first finds the same button without
    /// descending it. This pins the decision that produced that fix.
    /// Both copies of the button answer to the identifier the code searches
    /// for; only the suffix — which the production predicate cannot see —
    /// says which one a walk came back with.
    private func importPanel(browserDepth: Int) -> Node {
        func browserRow(_ depth: Int) -> Node {
            depth == 0
                ? Node(name: "browser-row", children: [Node(name: "OKButton@browser")])
                : Node(name: "browser-\(depth)", children: [browserRow(depth - 1)])
        }
        return Node(name: "open-panel", children: [
            Node(name: "browser", children: [browserRow(browserDepth)]),
            Node(name: "split-group", children: [
                Node(name: "OKButton@panel"), Node(name: "CancelButton@panel")
            ])
        ])
    }

    private func isOKButton(_ node: Node) -> Bool { node.name.hasPrefix("OKButton") }

    func testThePanelsButtonIsFoundNearestTheRootAndNotDownTheFileBrowser() {
        let panel = importPanel(browserDepth: 3)
        var breadthFirstLooks = 0
        let nearest = nearestNode(
            from: panel, maximumDepth: AXDepth.importPanelControl, children: { $0.children }
        ) { breadthFirstLooks += 1; return self.isOKButton($0) }
        var preOrderLooks = 0
        let preOrder = firstNode(
            from: panel, maximumDepth: AXDepth.importPanelControl, children: { $0.children }
        ) { preOrderLooks += 1; return self.isOKButton($0) }
        XCTAssertEqual(nearest?.name, "OKButton@panel")
        XCTAssertEqual(
            preOrder?.name, "OKButton@browser",
            "pre-order finds the browser's copy first — it is down the first sibling, which is"
                + " the user's filesystem, and that walk is what cost 1.3-2.0 s a lookup"
        )
        XCTAssertLessThan(breadthFirstLooks, preOrderLooks)
    }

    /// The risk this fix had to close: a same-identifier element inside the
    /// browser must not outrank the panel's own. It cannot — the panel's
    /// button is strictly shallower — and that holds however deep the user's
    /// filesystem happens to be.
    func testTheShallowControlWinsAtEveryBrowserDepth() {
        for depth in 0...3 {
            let panel = importPanel(browserDepth: depth)
            let match = nearestNode(
                from: panel, maximumDepth: AXDepth.importPanelControl, children: { $0.children }
            ) { self.isOKButton($0) }
            XCTAssertEqual(
                match?.name, "OKButton@panel",
                "browser depth \(depth): the panel's own button, every time"
            )
        }
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
