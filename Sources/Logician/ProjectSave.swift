import Foundation

/// The pure half of `logic_save_project`: how long the save may take to prove
/// itself, and how often the proof is looked for. No Logic, no Accessibility,
/// unit-tested — the shape `ProjectClose`, `ProjectOpen` and `ProjectDuplicate`
/// established for the rest of the project family.
enum ProjectSave {

    /// How long the save has to prove itself before the call gives up.
    ///
    /// Unchanged in wall-clock terms from the `40 × 250 ms` loop it replaces —
    /// the budget was never the problem. What changed is that the loop now
    /// LOOKS BEFORE IT SLEEPS.
    static let pollBudgetSeconds: TimeInterval = 10

    /// How long the poll waits between looks, once the first look has already
    /// failed.
    ///
    /// MEASURED 2026-09-02, live, on a throwaway clone of the sandbox project:
    /// a zero-wait probe fired immediately after the Save key command found
    /// BOTH success signals already true — the AppleScript modified flag
    /// cleared AND the `Alternatives/000/ProjectData` mtime advanced — and the
    /// poll then finished on iteration 1. The old loop slept 250 ms before
    /// looking at all, which was ~34% of a ~725 ms call and bought nothing:
    /// the Save key command is synchronous with the write, the same shape as
    /// the bounce sheet's blocking OK and the AX close press.
    ///
    /// The interval is kept at 250 ms rather than shrunk, deliberately. Every
    /// look costs an Apple Event to Logic (208-353 ms in-process, measured the
    /// same day), so a tighter interval would spend more than it could save on
    /// the only path that reaches it — a save Logic has not finished yet.
    static let pollIntervalSeconds: TimeInterval = 0.25
}
