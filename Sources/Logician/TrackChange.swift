import Foundation

// MARK: - What a create or a delete actually did, read out of two listings

/// The pure half of `logic_create_track`, `logic_duplicate_track` and
/// `logic_delete_track`: given the track rows before the key command and the
/// rows read back after it, what may the result honestly claim?
///
/// It lives away from the AX reads for two reasons. The first is testability —
/// the whole path had no unit test, and the interesting cases (a project
/// scrolled away from the insertion point, two rows sharing a name) are the
/// ones a live run is least likely to produce on demand. The second is that
/// the counting rule is genuinely subtle: `listTracks()` sees only the rows
/// Logic has RENDERED (`partial: true` on the reference project, 19 of 29),
/// so "the count went up" is not the same question as "a track was created",
/// and the difference is exactly the case where a wrong answer is worst.
enum TrackChange {

    /// One rendered track header, reduced to what a create/delete verdict
    /// depends on.
    struct Row: Equatable {
        let number: Int
        let name: String
        let selected: Bool

        init(number: Int, name: String, selected: Bool) {
            self.number = number
            self.name = name
            self.selected = selected
        }
    }

    /// The rows of a `listTracks()` payload's `tracks` array. Anything that
    /// cannot be read as a row is dropped rather than defaulted: a row with no
    /// name would otherwise become a `""` that matches another unreadable row
    /// and hides a real difference.
    static func rows(_ tracks: [[String: Any]]) -> [Row] {
        tracks.compactMap { entry in
            guard let name = entry["track_name"] as? String, !name.isEmpty else { return nil }
            return Row(
                number: entry["track_number"] as? Int ?? 0,
                name: name,
                selected: entry["selected"] as? Bool == true
            )
        }
    }

    /// The same reduction, for rows that have already been parsed off the AX
    /// tree. `selectTrack` walks the track headers to resolve its target and
    /// then throws the walk away; `logic_duplicate_track` needs exactly that
    /// listing as its "before" and used to pay a second walk for it (53–88 ms
    /// of an 807 ms call, measured 2026-09-01). The drop-rule for an unusable
    /// name stays here rather than being written out a second time at the AX
    /// call site.
    static func rows(headers: [(number: Int, name: String, selected: Bool)]) -> [Row] {
        headers.compactMap { header in
            guard !header.name.isEmpty else { return nil }
            return Row(number: header.number, name: header.name, selected: header.selected)
        }
    }

    // MARK: Creating

    /// The names `after` carries that `before` did not, counting OCCURRENCES:
    /// two rows may legitimately share a name (a rename, a duplicate), so a
    /// set difference would report "nothing new" about a second `Audio 9`.
    static func addedNames(before: [Row], after: [Row]) -> [String] {
        var unmatched: [String: Int] = [:]
        for row in before {
            unmatched[row.name.lowercased(), default: 0] += 1
        }
        var added: [String] = []
        for row in after {
            let key = row.name.lowercased()
            if let count = unmatched[key], count > 0 {
                unmatched[key] = count - 1
            } else {
                added.append(row.name)
            }
        }
        return added
    }

    /// Positive evidence that a row appeared — the ONLY thing the create poll
    /// is allowed to exit early on.
    ///
    /// The count rising is the obvious signal. The named comparison is the one
    /// that matters on a partial listing: Logic renders a window onto the
    /// track list, so inserting a row can push another out of the viewport and
    /// leave the visible COUNT unchanged while the set of names plainly moved.
    /// `handleDeleteTrack` has always compared names on its side; this is the
    /// same test on the other.
    static func trackAppeared(before: [Row], after: [Row]) -> Bool {
        after.count > before.count || !addedNames(before: before, after: after).isEmpty
    }

    /// Which row is the new one, for the result's `created_track` /
    /// `duplicate`.
    ///
    /// A duplicate is the case this has to get right and a create is the easy
    /// one: Logic hands a copy either the source's own name — so the added
    /// name is carried by TWO rows and only the selection tells them apart —
    /// or an auto-incremented successor of it (`Audio 9` → `Audio 10`,
    /// measured 2026-09-01). Neither is derivable by the caller, which is why
    /// this answer is returned rather than left to a follow-up listing.
    ///
    /// Logic SELECTS a track it just created, and the verifying read already
    /// carries `selected`, so the selection is the primary answer — but only
    /// when it agrees with the named difference, because a selection can also
    /// have been moved by something else between the two reads. Otherwise a
    /// single unambiguous added name answers instead. When neither holds
    /// (several rows appeared, or the added name is carried by more than one
    /// row and none of them is selected) this returns nil and the result omits
    /// `created_track`: the caller re-reads `logic_list_tracks` rather than
    /// being handed a guess it would feed straight into `logic_load_instrument`.
    static func createdRow(before: [Row], after: [Row]) -> Row? {
        let added = addedNames(before: before, after: after)
        guard !added.isEmpty else { return nil }
        if let selected = after.first(where: \.selected),
           added.contains(where: { $0.caseInsensitiveCompare(selected.name) == .orderedSame }) {
            return selected
        }
        guard added.count == 1, let name = added.first else { return nil }
        let matches = after.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return matches.count == 1 ? matches[0] : nil
    }

    /// What the result may claim when the poll ran out without seeing a row
    /// appear.
    ///
    /// This is the D2 fix. The old verification was `after.count > before` over
    /// VISIBLE rows, so a project whose Tracks area is scrolled away from the
    /// insertion point answered `success: false, "No new track appeared"` about
    /// a track that Logic had created and nothing cleaned up — the agent's next
    /// move is to fire the command again, and now there are two. When the
    /// listing itself says it is partial, "I did not see it" is the honest
    /// statement and "nothing happened" is not one this plane can make.
    enum Unseen: Equatable {
        /// The listing proved itself incomplete: the track may exist off-screen.
        case notVisible
        /// Nothing proved the listing incomplete, and it did not move.
        case nothing
    }

    static func unseenVerdict(partial: Bool) -> Unseen {
        partial ? .notVisible : .nothing
    }

    // MARK: Deleting

    /// Is the named row gone? Occurrence count, not absence: duplicates share
    /// the name, so "no row called X" would be false for the deletion of one
    /// of two, and the total has to have dropped by exactly one so that a
    /// listing which simply scrolled is not read as a deletion.
    static func rowRemoved(before: [Row], after: [Row], name: String) -> Bool {
        after.count == before.count - 1
            && occurrences(of: name, in: after) == occurrences(of: name, in: before) - 1
    }

    static func occurrences(of name: String, in rows: [Row]) -> Int {
        rows.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.count
    }

    // MARK: Renaming

    /// What a rename may claim, read off the row it addressed.
    enum RenameOutcome: Equatable {
        /// The addressed row carries the new name, character for character.
        case renamed
        /// The addressed row is not among the rendered ones and the listing
        /// says it is incomplete, so the rename may well have landed
        /// off-screen. `verified: false` and a warning, never a failure claim.
        case notVisible
        /// The addressed row is right there and does not carry the new name.
        case unchanged
    }

    /// Did the row this call addressed take the new name?
    ///
    /// This replaces a case-INSENSITIVE presence check over the whole listing
    /// (*"does some visible row carry `new_name`"*), which the profile of
    /// 2026-09-02 showed could be satisfied without any evidence of a rename:
    /// `{Inst 2 → Inst 2}` and `{Inst 2 → INST 2}` both came back
    /// `verified: true` off a test that was already true BEFORE the write
    /// (`confirm_zerowait new=yes old_gone=no`). The case-only rename is the
    /// sharp end of it — `resolveTrack` compares names case-SENSITIVELY, so
    /// changing only the case is exactly the rename whose result the caller
    /// then has to address by the new case, and it was the one operation whose
    /// success could not be told from a silent no-op.
    ///
    /// The row NUMBER is what makes the test identify a row rather than a
    /// name: a rename renumbers nothing, so the row that was addressed is the
    /// row that must have changed. That is strictly stronger than "one `from`
    /// gone, one `to` appeared" — it also holds when two rows share a name,
    /// which is precisely the state `logic_duplicate_track` manufactures.
    static func renameLanded(after: [Row], number: Int, to: String) -> Bool {
        after.contains { $0.number == number && $0.name == to }
    }

    /// The OTHER row a rename would collide with, if any.
    ///
    /// Case-sensitive, because that is what makes a pair unaddressable:
    /// `TrackRowAddressing.resolve` compares names case-sensitively, so
    /// `Crash` and `CRASH` are two distinguishable rows while two `Crash`
    /// rows are refused as ambiguous by every name-addressed track tool.
    static func nameCollision(rows: [Row], renaming number: Int, to newName: String) -> Row? {
        rows.first { $0.number != number && $0.name == newName }
    }

    static func renameVerdict(
        after: [Row],
        number: Int,
        to: String,
        partial: Bool
    ) -> RenameOutcome {
        if renameLanded(after: after, number: number, to: to) { return .renamed }
        // The row is rendered and still reads something else: that is a
        // provable non-event, whatever the rest of the listing is missing.
        if after.contains(where: { $0.number == number }) { return .unchanged }
        return unseenVerdict(partial: partial) == .notVisible ? .notVisible : .unchanged
    }

    /// MEASURED 2026-09-02 (`logic_rename_track` profile §3–§3.4). The rename
    /// path spent **1 108 ms of a 1 455 ms call — 76% — in three blind
    /// `Thread.sleep`s**, and probes taken at 0 ms proved all three dead:
    ///
    /// * the inline editor is an `AXTextField`, focused, settable and
    ///   pre-filled with the OLD name within ~1 ms of the key command's socket
    ///   round-trip returning (6 of 6 runs, `probe_ms` 0.4–7.1) — and the loop
    ///   slept 0.2 s BEFORE its first look, then exited on that look on 6 of 6;
    /// * the header column already carries the new name and has already
    ///   dropped the old one when the 0.6 s post-confirm sleep begins (6 of 6),
    ///   and unlike the create and duplicate paths the first post-effect read
    ///   is NOT the expensive one here (56–82 ms against 52–58 ms in steady
    ///   state — nothing is being built), so these are a plain deletion rather
    ///   than a haircut;
    /// * the "lingering rename popover" the 0.3 s sleep guarded does not
    ///   exist on Logic 12.3.1 — no window with subrole `AXDialog` at all at
    ///   that moment (6/6), `dialogs_closed=0` on 9/9 renames across four name
    ///   shapes. The scan is cheap (4.3 ms), so it is kept and folded onto the
    ///   poll's MISS path, where a Logic version that does prompt is still
    ///   answered and a version that does not pays nothing.
    ///
    /// Prototype of exactly this shape, same session: **1 455 ms → 263–279 ms
    /// (mean 271, −81%)**, `looks=1` on 3 of 3 for both polls, with a verdict
    /// strictly stronger than the one it replaced.
    static let renameEditorDeadline: TimeInterval = 3.0
    static let renameEditorInterval: TimeInterval = 0.02
    static let renamePollDeadline: TimeInterval = 4.0
    static let renamePollInterval: TimeInterval = 0.02

    // MARK: How long the polls look, and how often

    /// MEASURED 2026-09-01 (`logic_create_track` profile §3.1–§3.2). The
    /// create path used to spend 8.9 s of a 9.3 s call in a 50-iteration loop
    /// that slept 0.12 s and then looked for a *Create New Track* dialog — a
    /// dialog Logic 12.3.1 never raises for the *New Software Instrument
    /// Track* / *New Audio Track* key commands, which create the track
    /// directly. It returned false on 200 looks out of 200 while the track was
    /// created anyway. The dialog belongs to *New Tracks…*, a command this
    /// tool does not use.
    ///
    /// So there is one poll now, over the thing the tool actually verifies,
    /// and it looks BEFORE it sleeps: the first post-command read found the
    /// new row 3 times out of 3 (that read costs 139–236 ms against 67–98 ms
    /// in steady state — Logic blocks it while it builds the track, and that
    /// read IS the verification, so it is the part that is never cut). The
    /// dialog look is folded into the same loop, on the miss path, so a Logic
    /// version that DOES prompt is still answered while a version that does
    /// not pays nothing for the question. Prototype: 9.1–9.4 s → 253–356 ms.
    static let createPollDeadline: TimeInterval = 4.0
    static let createPollInterval: TimeInterval = 0.02

    /// MEASURED 2026-09-01 (`logic_duplicate_track` profile §3.1–§3.2). The
    /// duplicate path slept 0.3 s and THEN looked, up to fifteen times over —
    /// and exited on the first look on 10 runs out of 10, so every call paid
    /// 300 ms for nothing. A probe read fired at 0 ms after the key command
    /// already saw the new row (2 of 2): the copy is in the header column
    /// before the first post-command AX read returns. Looking first buys the
    /// identical verification for less. A/B'd live the same day, same machine
    /// and same track, old shape against new: call **1 036–1 187 ms → 703–816
    /// ms** (mean 1 088 → 753), verify loop 445–458 ms → 253–270 ms, still
    /// `iterations = 1` on 6 runs out of 6. That first post-command read is the
    /// expensive one (253–270 ms here, against 136–148 ms for the same read
    /// taken after the old shape's sleep, because Logic blocks it while it
    /// builds the track) and it IS the verification, so it is the part that is
    /// never cut — paying it immediately still beats sleeping through the wait
    /// and then paying a cheap one.
    static let duplicatePollDeadline: TimeInterval = 4.0
    static let duplicatePollInterval: TimeInterval = 0.02

    /// MEASURED 2026-09-01 (same profile, restore path, 7 runs). Deleting a
    /// track cost 3.2–3.4 s, of which 2.57–2.64 s was `trackDeletionAlert()`
    /// waiting out its whole 2.5 s timeout for the "Delete Track and Regions?"
    /// confirmation — an alert that only appears when the track still holds
    /// regions (`present: false` on 7 of 7 empty-track deletes). It is a
    /// NEGATIVE proof, and it was priced at the full timeout on the common
    /// path. The alert look is folded into the deletion poll instead, so the
    /// wait ends when the row is gone; the full deadline is still paid, and
    /// only paid, while the row is still listed — which is exactly the state
    /// in which a modal might be the reason.
    static let deletePollDeadline: TimeInterval = 2.5
    static let deletePollInterval: TimeInterval = 0.025
}
