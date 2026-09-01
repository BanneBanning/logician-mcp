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

    /// Which row is the new one, for the result's `created_track`.
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
