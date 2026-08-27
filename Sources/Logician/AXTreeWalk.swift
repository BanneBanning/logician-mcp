import AppKit
import ApplicationServices
import Foundation

// MARK: - The one tree-walk primitive

/// What a walk does after visiting a node.
enum AXWalkStep {
    /// Descend into this node's children (the normal case).
    case descend
    /// Do not descend into this node's children, but keep walking the rest of
    /// the tree. For subtrees that are known to hold nothing of interest, or
    /// that would double-count if entered (a region row's own items, a menu
    /// nested inside a menu).
    case skipChildren
    /// Abandon the walk entirely: nothing else is visited.
    case stop
}

/// Depth-first, PRE-ORDER walk of an arbitrary tree: a node is visited before
/// any of its children, and children are visited in the order `children`
/// returns them. Accessibility trees are ordered and nearly every caller here
/// takes "the first match", so that order is load-bearing.
///
/// The root is visited, at depth 0, and `maximumDepth` is INCLUSIVE: a
/// `maximumDepth` of 3 visits the root and three levels below it. A node
/// deeper than the cap is never visited, so its `visit` never runs.
///
/// Generic over the node type purely so the traversal itself is testable
/// without an AXUIElement (see AXTreeWalkTests); production code always calls
/// it through `LogicAccessibility.walk(from:maximumDepth:visit:)` below.
func walkTree<Node>(
    from root: Node,
    maximumDepth: Int,
    children: (Node) -> [Node],
    visit: (Node) -> AXWalkStep
) {
    /// Returns false once the walk has been stopped, which unwinds the whole
    /// recursion the way the hand-rolled `guard result == nil` walkers did.
    func step(_ node: Node, _ depth: Int) -> Bool {
        guard depth <= maximumDepth else { return true }
        switch visit(node) {
        case .stop:
            return false
        case .skipChildren:
            return true
        case .descend:
            for child in children(node) {
                if !step(child, depth + 1) { return false }
            }
            return true
        }
    }
    _ = step(root, 0)
}

/// First node in pre-order that satisfies `predicate`, root included.
/// Generic for the same testability reason as `walkTree`.
func firstNode<Node>(
    from root: Node,
    maximumDepth: Int,
    children: (Node) -> [Node],
    where predicate: (Node) -> Bool
) -> Node? {
    var match: Node?
    walkTree(from: root, maximumDepth: maximumDepth, children: children) { node in
        guard predicate(node) else { return .descend }
        match = node
        return .stop
    }
    return match
}

// MARK: - Depth caps

/// Every depth cap used by the Accessibility walks, in one place.
///
/// These are experimentally-tuned distances through Logic's real layout —
/// measured from each walk's own root down to the element it looks for, plus
/// a little headroom. They are not safety limits; they are the reason a walk
/// terminates in reasonable time on a window with tens of thousands of
/// elements. A Logic update that inserts one more wrapper group makes a walk
/// return nil ("not found") rather than fail loudly, so when a formerly
/// working lookup starts reporting "not found", RAISE the constant here
/// first — that is a one-line fix.
///
/// All values are inclusive and count the walk's root as depth 0, matching
/// `walkTree`. The one exception is `wholeWindow`, which is used with
/// `descendants(of:maximumDepth:)`; see the note there.
enum AXDepth {

    // MARK: Tracks area (main project window)

    /// Project window -> "Tracks header" group. The track header column sits
    /// under several scroll/split/layout wrappers.
    static let trackHeaderGroup = 12
    /// Project window -> an "inspector channel strip" layout item (left and
    /// right inspector). Same wrapper stack as the track header column.
    static let inspectorStrip = 12
    /// A single track header item -> its Freeze checkbox. The header's own
    /// controls are shallow; the cap keeps the walk off neighbouring rows.
    static let trackHeaderControl = 3
    /// Project window -> the per-track "Track N “Name”" region rows.
    static let trackRegionRow = 9
    /// Project window -> the "Tracks time ruler" layout area.
    static let timeRuler = 10
    /// Project window -> the "Control Bar" group (transport buttons, LCD).
    static let controlBar = 6

    // MARK: List Editors (Event / Marker / Tempo / Signature)

    /// Project window -> the List Editors pane's tab strip (the `AXRadioButton`s
    /// described `Event`/`Marker`/`Tempo`/`Signature`) and the tab group each
    /// one reveals. MEASURED live 2026-08-27: both sit at window depth 2 — the
    /// pane is a direct child of the project window, not buried under the
    /// arrange area's wrappers — so 8 is pure headroom. See `readTempoMap`.
    static let listEditorTab = 8
    /// The Tempo tab's own group -> its `AXTable` (measured at 3, under one
    /// scroll area) and its "Number of Items" text (measured at 1).
    static let listEditorTable = 6

    // MARK: Modal dialogs and alerts

    /// Any Logic window -> the static text and buttons of a modal alert
    /// (freeze confirm, "Create New Track", recovery prompt, save changes).
    /// Alert content is shallow; 7 covers the sheet wrappers around it.
    static let alertDialog = 7
    /// Bounce dialog / save panel -> a named button (Cancel, Bounce, Replace).
    /// The save panel is the deepest of these, hence more headroom than
    /// `alertDialog`.
    static let bounceDialogControl = 9
    /// Bounce dialog's destination scroll area -> the destination checkboxes.
    static let bounceDestinationList = 5

    // MARK: Menus

    /// Logic's menu bar -> a menu item, tracking the menu title path.
    static let menuBarItem = 5
    /// Application element -> a free-standing (non-menu-bar) popup menu, e.g.
    /// the insert slot's plugin chooser.
    static let popupMenu = 7
    /// A popup menu -> an item in it or in one of its submenus. The plugin
    /// chooser nests manufacturer > format > plugin.
    static let popupMenuItem = 5

    // MARK: Key Commands window

    /// Key Commands window -> the command list (AXOutline / AXTable).
    static let keyCommandsOutline = 4
    /// One command row -> the static texts that make up its columns.
    static let keyCommandsRowText = 3
    /// Key Commands window -> a control outside the command list (the walk
    /// prunes at the outline itself so it never descends thousands of rows).
    static let keyCommandsControl = 7
    /// Any Logic window -> the "already assigned" conflict alert's texts and
    /// Cancel button.
    static let keyCommandsConflictAlert = 6

    // MARK: Plugin windows

    /// A plugin window -> the header's preset popup buttons.
    static let pluginWindowHeader = 5
    /// A plugin window -> everything in it. Used with
    /// `descendants(of:maximumDepth:)`, whose cap is measured from each CHILD
    /// of the root rather than from the root, so this reaches one level
    /// deeper than the same number would in `collect`/`firstDescendant`.
    /// Plugin UIs are deep and irregular, so this is deliberately generous.
    static let wholeWindow = 20
}

// MARK: - Accessibility-tree convenience

extension LogicAccessibility {

    /// Pre-order walk of the Accessibility tree under `root`. See `walkTree`
    /// for the depth semantics (root is depth 0, `maximumDepth` inclusive).
    func walk(
        from root: AXUIElement,
        maximumDepth: Int,
        visit: (AXUIElement) -> AXWalkStep
    ) {
        walkTree(from: root, maximumDepth: maximumDepth, children: { children(of: $0) }, visit: visit)
    }

    /// First element in pre-order under `root` (root itself included) that
    /// satisfies `predicate`. The walk stops at the match.
    func firstDescendant(
        of root: AXUIElement,
        maximumDepth: Int,
        where predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        firstNode(from: root, maximumDepth: maximumDepth, children: { children(of: $0) }, where: predicate)
    }
}
