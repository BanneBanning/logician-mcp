import AppKit
import ApplicationServices
import Foundation

// MARK: - The one tree-walk primitive

/// What a walk does after visiting a node.
enum AXWalkStep: Equatable {
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

/// First node in BREADTH-FIRST order that satisfies `predicate`, root
/// included — the match NEAREST the root rather than the first one pre-order
/// happens to reach.
///
/// Why this exists (measured live 2026-09-01, the bounce save panel). The
/// panel's Bounce button is a shallow child of the panel window, but the
/// window's FIRST child is the file browser, whose subtree is thousands of
/// elements deep. A pre-order walk descends all of that before it ever looks
/// at the button's level: `firstDescendant` at `bounceDialogControl` (9) took
/// **993 ms**, the same search capped at depth 3 took **4 ms**, and the same
/// walk ran twice per bounce. Breadth-first pays the shallow price without
/// lowering the cap, so a Logic update that adds one wrapper level still
/// finds the button (which is what the depth caps exist to survive).
///
/// Use this ONLY where "nearest to the root" is the right rule — a named
/// button on a dialog, of which there is one. Where pre-order is
/// load-bearing (the region rows, the strip's insert slots, anything ordered
/// top-to-bottom on screen), keep `firstNode`.
func nearestNode<Node>(
    from root: Node,
    maximumDepth: Int,
    children: (Node) -> [Node],
    where predicate: (Node) -> Bool
) -> Node? {
    var frontier = [root]
    var depth = 0
    while !frontier.isEmpty, depth <= maximumDepth {
        var next: [Node] = []
        for node in frontier {
            if predicate(node) { return node }
            if depth < maximumDepth { next.append(contentsOf: children(node)) }
        }
        frontier = next
        depth += 1
    }
    return nil
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

    // MARK: Region inspector (the "Region:" panel above the channel strip)

    /// Project window -> the `Inspector` group. MEASURED live 2026-08-28: it
    /// is a direct child of the project window (depth 1), and its first
    /// `AXList` holds the Region panel, the Track panel and the Mixer panel
    /// in that order.
    static let inspectorPanel = 8
    /// The Region panel's own group -> its `AXOutline` of parameter rows,
    /// measured at 2 (group -> scroll area -> outline).
    static let regionInspectorOutline = 6
    /// Application element -> the menu one of the panel's pop-ups opens.
    /// DEEPER than `popupMenu` on purpose: the Region inspector's menus are
    /// parented under the project window's own tree, and the depth-7 walk
    /// `popupMenus()` uses does not reach them (measured 2026-08-28 — the
    /// press worked and the menu was invisible until the cap was raised).
    static let regionInspectorMenu = 14

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

    // MARK: Project Settings

    /// The Project Settings window -> one of its controls. MEASURED live
    /// 2026-08-28: the Smart Tempo pane's pop-ups and the toolbar's pane
    /// buttons are direct children of the window (depth 1) and the toolbar's
    /// buttons depth 2, so 6 is pure headroom.
    static let projectSettingsControl = 6

    // MARK: Modal dialogs and alerts

    /// Any Logic window -> the static text and buttons of a modal alert
    /// (freeze confirm, "Create New Track", recovery prompt, save changes).
    /// Alert content is shallow; 7 covers the sheet wrappers around it.
    static let alertDialog = 7
    /// The "Create New Track" sheet -> its track-type radio buttons (the
    /// chooser `initial_track` reads and, when asked, presses).
    ///
    /// DEEPER than `alertDialog` on purpose. The sheet's static text and
    /// buttons are what `visibleDialogs()` reads at 7, and the dump that
    /// caught this sheet standing over a new project
    /// (`Logician-archive/profiles/logic_new_project.md`, D-NP1) showed those
    /// and no type control at all — the chooser sits inside the sheet's own
    /// layout groups. Reading it costs one walk of an already-open sheet, so
    /// the cap is set for headroom rather than trimmed to a measurement.
    static let createTrackTypeChooser = 12
    /// One category group of that chooser -> its own variant radio buttons.
    /// MEASURED live 2026-09-03: group -> AXRadioGroup -> AXRadioButton, so 2
    /// is the walk and 4 is headroom that cannot reach a neighbouring group.
    static let createTrackTypeVariant = 4
    /// Bounce dialog / save panel -> a named button (Cancel, Bounce, Replace).
    /// The save panel is the deepest of these, hence more headroom than
    /// `alertDialog`.
    static let bounceDialogControl = 9
    /// Bounce dialog's destination scroll area -> the destination checkboxes.
    static let bounceDestinationList = 5
    /// Logic's `open-panel` import window -> a named control. MEASURED live
    /// 2026-08-30: `OKButton` and `CancelButton` are children of the panel's
    /// `AXSplitGroup` (depth 2) and the Go-to-Folder sheet is a direct child of
    /// the window (depth 1) with its `PathTextField` one below that, so 6 is
    /// headroom over a panel whose insides are drawn by another process.
    static let importPanelControl = 6

    // MARK: Menus

    /// Logic's menu bar -> a menu item, tracking the menu title path.
    static let menuBarItem = 5
    /// Application element -> a free-standing (non-menu-bar) popup menu, e.g.
    /// the insert slot's plugin chooser.
    static let popupMenu = 7
    /// A popup menu -> an item in it or in one of its submenus. The plugin
    /// chooser nests manufacturer > format > plugin.
    static let popupMenuItem = 5
    /// Application element -> a channel strip slot's pop-up menu. DEEPER than
    /// `popupMenu` for the same reason `regionInspectorMenu` is: Logic parents
    /// these under the project window's own tree, and a depth-7 walk finds
    /// them only sometimes (measured 2026-08-28 as presses that "did not open
    /// a menu" while the menu was in fact up).
    static let stripSlotMenu = 14
    /// A hit-tested element -> the AXMenu it belongs to, walking UP. MEASURED
    /// live 2026-09-03 on the `No Output` output slot: the chain is
    /// `AXMenuItem <- AXMenu`, two steps, and a submenu's item adds two more.
    /// Six is headroom over both, and it is a walk of PARENTS, so it visits
    /// six elements, not a subtree.
    static let slotMenuAncestors = 6
    /// A channel strip routing slot's menu -> a destination. MEASURED
    /// 2026-08-28: the output menu nests root -> `Bus` -> the 32 bus items,
    /// and the `33 - 64` … `225 - 256` ranges one level deeper again, so a
    /// depth-5 walk reaches every named bus.
    static let routingMenuItem = 6

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

    /// The element NEAREST `root` (root itself included) that satisfies
    /// `predicate` — breadth-first, so a shallow match is found without
    /// descending a deep first sibling. See `nearestNode` for why, and for
    /// when NOT to use it.
    func nearestDescendant(
        of root: AXUIElement,
        maximumDepth: Int,
        where predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        nearestNode(from: root, maximumDepth: maximumDepth, children: { children(of: $0) }, where: predicate)
    }
}
