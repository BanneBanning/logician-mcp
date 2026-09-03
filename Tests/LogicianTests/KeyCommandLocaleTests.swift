import XCTest
@testable import Logician

/// `KeyCommandLocalePlan` — whether a learn may address Logic's Key Commands
/// window at all, and in which words.
///
/// The gap this closes was measured, not imagined: with Logic's UI in French
/// (R4, 2026-08-30) triggering an already-learned command still worked (note
/// 119 opened the inline rename editor) while learning a new one by name was
/// dead, because the driver types English row names into Logic's filter field.
/// With Logic 12.2+ refusing plist Key Commands import, a non-English install
/// had no route to the bindings at all — and the way it FAILED was the worst
/// part: nineteen separate `not_found`s, several seconds apart, each with a
/// candidate list in a language nobody asked about.
///
/// No translation is invented here or in the source. What is pinned is the
/// degradation: an honest refusal that names the language, and a captured
/// table (supplied by the test) actually being used when one exists.
final class KeyCommandLocaleTests: XCTestCase {

    private let ownNames = Set(KeyCommandRegistry.Name.all)

    private func targets(_ names: [String]) -> [KeyCommandLocalePlan.Target] {
        names.enumerated().map { index, name in
            KeyCommandLocalePlan.Target(
                search: String(name.prefix(4)).lowercased(), name: name, preferredNote: 60 + index
            )
        }
    }

    // MARK: - English, and "cannot tell"

    func testAnEnglishLogicProceedsUntouchedAndSaysNothing() {
        let asked = targets([KeyCommandRegistry.Name.save, KeyCommandRegistry.Name.cut])
        XCTAssertEqual(
            KeyCommandLocalePlan.plan(
                targets: asked, language: "en", isEnglish: true, ownNames: ownNames
            ),
            .proceed(targets: asked, warning: nil)
        )
    }

    func testAnEnglishDialectIsStillEnglish() {
        let asked = targets([KeyCommandRegistry.Name.save])
        XCTAssertEqual(
            KeyCommandLocalePlan.plan(
                targets: asked, language: "en-GB", isEnglish: true, ownNames: ownNames
            ),
            .proceed(targets: asked, warning: nil)
        )
    }

    func testAnUndeterminedLanguageProceedsInEnglishAndWarnsRatherThanRefusing() {
        // "Could not tell" is not "not English" — the standing rule. Refusing
        // here would break every English Mac whose Logic bundle is unreadable.
        let asked = targets([KeyCommandRegistry.Name.save])
        let outcome = KeyCommandLocalePlan.plan(
            targets: asked, language: nil, isEnglish: nil, ownNames: ownNames
        )
        XCTAssertEqual(
            outcome, .proceed(targets: asked, warning: KeyCommandLocalePlan.unknownLanguageWarning)
        )
    }

    // MARK: - A language nobody has captured

    func testATranslatedLogicWithNoTableRefusesBeforeAnythingIsOpened() {
        let asked = targets([KeyCommandRegistry.Name.save, KeyCommandRegistry.Name.cut])
        guard case .refuse(let reason) = KeyCommandLocalePlan.plan(
            targets: asked, language: "fr", isEnglish: false, ownNames: ownNames, translations: [:]
        ) else { return XCTFail("a language with no captured row names must refuse") }
        XCTAssertTrue(reason.contains("'fr'"), "the refusal must name the language: \(reason)")
        XCTAssertTrue(reason.contains("NOTHING WAS BOUND"))
        XCTAssertTrue(reason.contains("NOTHING WAS OPENED"))
        // It has to name the way forward, not just the problem.
        XCTAssertTrue(reason.contains("logic_learn_key_command"))
        XCTAssertTrue(reason.contains("logic_trigger_key_command"))
    }

    func testTheRefusalNamesTheCommandsItCannotSpell() {
        let reason = KeyCommandLocalePlan.refusal(
            language: "sv", missing: [KeyCommandRegistry.Name.save], asked: 1, translations: [:]
        )
        XCTAssertTrue(reason.contains(KeyCommandRegistry.Name.save))
        XCTAssertTrue(reason.contains("en"), "it must say which languages DO work")
    }

    func testANameThisServerDoesNotSpellIsNeverRefused() {
        // The caller is reading their own Logic in their own language. That
        // call worked before this gate existed and must keep working.
        let asked = targets(["Diviser les régions"])
        XCTAssertEqual(
            KeyCommandLocalePlan.plan(
                targets: asked, language: "fr", isEnglish: false,
                ownNames: ownNames, translations: [:]
            ),
            .proceed(targets: asked, warning: nil)
        )
    }

    func testOneUnspellableCommandRefusesTheWholeRoundRatherThanHalfBindingIt() {
        // A partial table is the silent-mismatch case this exists to prevent.
        let table = ["fr": [KeyCommandRegistry.Name.save: "Enregistrer"]]
        let asked = targets([KeyCommandRegistry.Name.save, KeyCommandRegistry.Name.cut])
        guard case .refuse(let reason) = KeyCommandLocalePlan.plan(
            targets: asked, language: "fr", isEnglish: false,
            ownNames: ownNames, translations: table
        ) else { return XCTFail("a half-filled table must refuse, not bind half the set") }
        XCTAssertTrue(reason.contains(KeyCommandRegistry.Name.cut))
        XCTAssertFalse(reason.contains("Enregistrer"))
    }

    // MARK: - A language somebody HAS captured

    func testACapturedLanguageIsTypedInThatLanguageNameAndSearchTermAlike() {
        let table = ["fr": [KeyCommandRegistry.Name.save: "Enregistrer"]]
        guard case .proceed(let planned, let warning) = KeyCommandLocalePlan.plan(
            targets: targets([KeyCommandRegistry.Name.save]),
            language: "fr", isEnglish: false, ownNames: ownNames, translations: table
        ) else { return XCTFail("a captured language must proceed") }
        XCTAssertEqual(planned.count, 1)
        XCTAssertEqual(planned[0].name, "Enregistrer")
        // The English search terms are substrings of ENGLISH names; a
        // substring of "Save" filters nothing in French, so the row's own text
        // is the term.
        XCTAssertEqual(planned[0].search, "Enregistrer")
        XCTAssertEqual(planned[0].preferredNote, 60)
        XCTAssertNotNil(warning, "the caller should be told the names came from a locale table")
    }

    func testADialectFallsBackToItsBaseLanguageTable() {
        XCTAssertEqual(
            LogicUIStrings.KeyCommandRow.spelling(
                of: KeyCommandRegistry.Name.save, language: "fr-CA",
                in: ["fr": [KeyCommandRegistry.Name.save: "Enregistrer"]]
            ),
            "Enregistrer"
        )
    }

    func testNoTranslationIsShippedYetAndTheTableSaysSoHonestly() {
        // If this ever fails because a language was captured, the capture is
        // welcome — update the assertion and the refusal's language list.
        XCTAssertTrue(LogicUIStrings.KeyCommandRow.translations.isEmpty)
        XCTAssertEqual(LogicUIStrings.KeyCommandRow.supportedLanguages(), ["en"])
    }
}
