import Foundation

// MARK: - Rows Logic publishes and has not drawn, and the one count that survives them

/// The undrawn-row rule, in one place, for every List Editors reader and writer.
///
/// MEASURED 2026-09-01 and again 2026-09-02 (the `logic_edit_event` and
/// `logic_list_events` profiles, reproduced 2/2 and 3/3). When a List Editors
/// table GROWS, Logic publishes the new size in `Number of Items` and the new
/// row in `AXRows` at once — and leaves one row's cells undrawn: every cell
/// empty but the Status one, `["", "", "", "Note", "", "", "", ""]`. It is a
/// real event (the delete that followed proved it), it simply has no text yet,
/// and it stays that way until the list is scrolled.
///
/// And it is not only the newest row. Measured live on 2026-09-02 while
/// verifying this fix: a 54-event region publishes all 54 rows and draws only
/// the 26 IN VIEW — rows 27–52, a contiguous window that moves with the scroll
/// position — so the reader that mapped every published row was answering that
/// region with 26 events and 28 blanks, and calling the result 54. The window,
/// not the growth, is the general case; the newest row is one instance of it.
///
/// So the row is COUNTED and not READ, and the two things that must never
/// happen are: reporting the blank row as an event, and reporting a count that
/// silently swapped a real event for it. `EventCensus` applied this on the
/// WRITE side; `ListEditorCensus` applies the same rule to every read.
enum UndrawnListRows {

    /// What a warning or a refusal calls the rows it could not read. One
    /// wording, shared, so an agent meets the same sentence whichever tool
    /// hands it back.
    static func note(_ unread: Int) -> String {
        "Logic published \(unread) row(s) it had not drawn yet. A List Editors table draws only"
            + " the rows in VIEW — everything scrolled out of the pane, and the newest row of a"
            + " list that has just grown, publishes empty cells — so those rows are counted here"
            + " and cannot be read or addressed. Scroll the list in Logic (or make the pane"
            + " taller) and read again to see them."
    }

    /// Has Logic drawn this row's cells?
    ///
    /// Decided on the POSITION cell, which is where the writer has always
    /// decided it too (`EventListWrite.row` refuses a row whose position is not
    /// four integers) — lifted here so the readers stop mapping every published
    /// row into an entry. The reader's parse is the LENIENT one, the same
    /// `parseTempoListPosition` its payload takes `bar`/`beat` from: the
    /// question a reader has to answer is "can this row be named at all", not
    /// "can it be addressed by a stepper write", and a row that yields a bar is
    /// an event worth reporting.
    ///
    /// `emptyPositionIsTheFirstRow` is the Signature tab and only it: the
    /// project's own initial time and key signatures publish NO position at all
    /// (measured 2026-08-28), so there an empty position is a real row as long
    /// as some other cell carries text — and a row with an empty position and
    /// nothing else is the undrawn one.
    ///
    /// A table that publishes no Position column at all cannot be judged this
    /// way, so every row counts as drawn: the reader keeps the behaviour it had
    /// rather than inventing a refusal out of a missing column.
    static func isDrawn(
        cells: [String], positionIndex: Int?, emptyPositionIsTheFirstRow: Bool = false
    ) -> Bool {
        guard let positionIndex, cells.indices.contains(positionIndex) else { return true }
        let raw = cells[positionIndex].trimmingCharacters(in: .whitespaces)
        guard raw.isEmpty else { return TempoMap.parseTempoListPosition(raw) != nil }
        guard emptyPositionIsTheFirstRow else { return false }
        return cells.enumerated().contains { index, cell in
            index != positionIndex && !cell.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Where the Position column sits in a List Editors table, by NAME. It is
    /// column 0 on the Signature tab and column 2 on the Event tab, and all
    /// four tabs are read by the same code — so it is never assumed.
    static func positionIndex(in columns: [String]) -> Int? {
        columns.firstIndex { $0.lowercased().contains(LogicUIStrings.Element.positionColumn) }
    }
}

/// What one List Editors tab holds, and how much of it a read could read.
///
/// The reader's counterpart to `EventCensus`, and deliberately the same shape:
/// the count an agent is told is the LIST'S OWN, never the parsed array's
/// length — that one is short by however many rows Logic has not drawn, and
/// before this existed `logic_list_events` answered a 26-event region with 26
/// entries of which one was blank and one real note was missing, with no
/// warning at all.
struct ListEditorCensus: Equatable {
    /// Every row that carried readable text, in table order. `index` is the
    /// row's index in the TABLE, so an undrawn row leaves a gap.
    let entries: [ListEditorEntry]
    /// How many rows Logic published.
    let published: Int
    /// What the list's own `Number of Items` says it holds, when it says.
    let declared: Int?

    /// THE count of rows in the list: its own, falling back to what it
    /// published. Never `entries.count`.
    var count: Int { declared ?? published }
    /// Rows that exist and could not be read.
    var unread: Int { max(0, published - entries.count) }
    var isComplete: Bool { unread == 0 }
    /// Which rows those are, numbered the way the payload numbers them (1-based),
    /// so a warning can name them instead of only counting them.
    var unreadRowNumbers: [Int] {
        let drawn = Set(entries.map(\.index))
        return (0..<published).filter { !drawn.contains($0) }.map { $0 + 1 }
    }
    /// What a warning calls them.
    var unreadNote: String { UndrawnListRows.note(unread) }

    /// The census of a table that published these cells under these columns.
    ///
    /// Pure, and separate from the Accessibility read, for the same reason
    /// `ListEditorPayload` is: this rule was wrong on the read side for days
    /// while every live session agreed with itself, and a rule that decides
    /// whether an event is reported at all should be pinned by a test rather
    /// than by a session log.
    static func of(
        cells: [[String]], columns: [String], declaredCount: Int?,
        emptyPositionIsTheFirstRow: Bool = false
    ) -> ListEditorCensus {
        let positionIndex = UndrawnListRows.positionIndex(in: columns)
        let entries = cells.enumerated().compactMap { index, row -> ListEditorEntry? in
            guard UndrawnListRows.isDrawn(
                cells: row, positionIndex: positionIndex,
                emptyPositionIsTheFirstRow: emptyPositionIsTheFirstRow
            ) else { return nil }
            var fields: [String: String] = [:]
            for (position, column) in columns.enumerated() where !column.isEmpty {
                fields[column] = position < row.count ? row[position] : ""
            }
            return ListEditorEntry(index: index, fields: fields, cells: row)
        }
        return ListEditorCensus(entries: entries, published: cells.count, declared: declaredCount)
    }
}

/// The pruning both List Editors tree walks want.
///
/// MEASURED 2026-09-02 (`logic_list_events` profile §6 candidate 5, a
/// `.skipChildren` twin run beside the real walk in the same call): neither
/// walk wants anything INSIDE the table — the tab strip is four
/// `AXRadioButton`s above it and `Number of Items` is a SIBLING of the table,
/// never a descendant — and descending into the rows was the whole superlinear
/// term. The tab-strip walk went 108–131 ms (25 rows) / 265–290 ms (54 rows) →
/// 56–62 ms at any size, and the table walk 68–75 / 308–368 → 4.4–5.4 ms.
///
/// NOT for the tab-GROUP walk (`listEditorTabGroup`): that one already `.stop`s
/// at the group before it ever reaches the table, and the same probe measured
/// no difference there.
enum ListEditorWalk {
    static func step(role: String) -> AXWalkStep {
        role == "AXTable" ? .skipChildren : .descend
    }
}

/// What the settle after the pane-OPEN press is allowed to wait for.
///
/// Split out and made pure because the old answer was wrong in a way no live
/// session could show: the settle waited for the TARGET tab's table, Logic
/// opens the pane on the tab it was last on, and a readiness check that can
/// never be true simply looks like a slow pane. Measured 2026-09-02
/// (`logic_markers` profile §5): `settle DEADLINE` 15/15, 610–1 094 ms, with
/// `previousTab == "Event"` 15/15.
enum ListEditorSettleGoal: Equatable {
    /// The tab strip is not published yet. Nothing else can be asked, and
    /// nothing else is worth asking — the strip is what the caller needs.
    case tabStrip
    /// The strip is there and the target tab is NOT selected, so a press
    /// follows and ITS settle waits for the table. This one is done.
    case ready
    /// The strip is there and the target tab is ALREADY selected, so no press
    /// follows: this settle is the only one, and it has to wait for the table.
    case targetTabDrawn
}

enum ListEditorSettle {
    /// A tab the strip does not carry keeps the settle waiting rather than
    /// letting it return early: the caller's refusal (`tabNotFound`) is worth
    /// more after the deadline than before the pane finished painting.
    static func goal(target: String, tabs: [(name: String, selected: Bool)]) -> ListEditorSettleGoal {
        guard let tab = tabs.first(where: { $0.name == target }) else { return .tabStrip }
        return tab.selected ? .targetTabDrawn : .ready
    }
}
