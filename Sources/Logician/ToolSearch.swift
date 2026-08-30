import Foundation

/// Okapi BM25 over the advertised tool surface: the retrieval half of a
/// client-side tool search, running inside the server for the clients that do
/// not have one.
///
/// WHY IT IS A PORT AND NOT AN IMPLEMENTATION. `scripts/retrieval_probe.py`
/// has scored this surface's descriptions against a fixed 55-query set since
/// the retrieval-quality pass, and that probe is the only measurement we have
/// of whether a description edit helps or hurts discovery. If the ranking a
/// caller of `logic_find_tool` gets were merely SIMILAR to the ranking the
/// probe reports, the probe would stop being evidence about the tool. So every
/// detail below is the probe's, deliberately and to the digit:
///
/// - the same tokenizer (lowercase, split on non-alphanumerics, then one crude
///   suffix strip so `stems` reaches `stem`),
/// - the same corpus — name, description, and every argument name, argument
///   description and enum value at every nesting depth, read off the SAME
///   `tools/list` wire shape the probe parses, with annotations excluded,
/// - the same constants (k1 = 1.2, b = 0.75) and the same IDF,
/// - repeated query terms scored repeatedly, because the probe iterates the
///   token list rather than a set,
/// - and ties broken by registry order, which is what Python's stable sort
///   does to `sorted(..., key=lambda pair: -pair[1])`.
///
/// `ToolSearchTests` runs the probe's 53 scored queries through this code and
/// asserts the same tool comes back in the top five, so the agreement is
/// pinned rather than asserted in a comment.
enum ToolSearch {
    /// Okapi's term-frequency saturation and length-normalisation constants.
    /// Textbook defaults, and the probe's.
    static let k1 = 1.2
    static let b = 0.75

    /// Lowercase, split on anything that is not a letter or a digit, then add
    /// the stem for the plural/participle endings that make `stems` miss
    /// `stem`. Crude on purpose: this models a keyword matcher, it does not
    /// try to out-linguist one — and the crudeness has to match the probe's.
    ///
    /// The stem is ADDED, not substituted, so a document keeps both forms and
    /// an exact query term still scores its full term frequency.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        func flush() {
            defer { word = "" }
            guard !word.isEmpty else { return }
            tokens.append(word)
            for suffix in ["ing", "ies", "es", "ed", "s"] where word.count > suffix.count + 2 {
                if word.hasSuffix(suffix) {
                    tokens.append(String(word.dropLast(suffix.count)))
                    break
                }
            }
        }
        for character in text.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                word.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// Everything a keyword matcher gets to see for one tool. Takes the
    /// `tools/list` DEFINITION rather than the `Tool` value so the field set
    /// cannot drift from the probe's: both read a name, a description (the
    /// advertised one, warning note included) and the input schema, and
    /// neither reads annotations — `title` is client display metadata, not
    /// part of the definition text a search ranks.
    static func corpusText(for definition: [String: Any]) -> String {
        var parts: [String] = []
        parts.append(definition["name"] as? String ?? "")
        parts.append(definition["description"] as? String ?? "")

        func walk(_ schema: [String: Any]) {
            guard let properties = schema["properties"] as? [String: Any] else { return }
            // Dictionary order is arbitrary in Swift and insertion-ordered in
            // Python; it does not matter, because BM25 reads a bag of words
            // and both sides produce the same multiset.
            for (key, value) in properties {
                parts.append(key)
                guard let value = value as? [String: Any] else { continue }
                parts.append(value["description"] as? String ?? "")
                for option in value["enum"] as? [Any] ?? [] {
                    if let option = option as? String { parts.append(option) }
                }
                walk(value)
                if let items = value["items"] as? [String: Any] { walk(items) }
            }
        }
        walk(definition["inputSchema"] as? [String: Any] ?? [:])
        return parts.joined(separator: " ")
    }

    /// A built index over one corpus. Cheap enough to rebuild per call (82
    /// documents, ~145 KB of text, no I/O), so there is no cache to invalidate
    /// and no way for the index to describe a registry that has moved on.
    struct Index {
        private let documents: [[String: Int]]
        private let lengths: [Double]
        private let averageLength: Double
        private let idf: [String: Double]

        init(documents texts: [String]) {
            documents = texts.map { text in
                var counts: [String: Int] = [:]
                for token in ToolSearch.tokenize(text) { counts[token, default: 0] += 1 }
                return counts
            }
            lengths = documents.map { Double($0.values.reduce(0, +)) }
            averageLength = lengths.reduce(0, +) / Double(max(1, documents.count))
            var frequencies: [String: Int] = [:]
            for document in documents {
                for term in document.keys { frequencies[term, default: 0] += 1 }
            }
            let total = Double(documents.count)
            idf = frequencies.mapValues { count in
                log(1 + (total - Double(count) + 0.5) / (Double(count) + 0.5))
            }
        }

        /// One BM25 score per document, in document order.
        func scores(for query: String) -> [Double] {
            let terms = ToolSearch.tokenize(query)
            return documents.indices.map { index in
                let document = documents[index]
                let length = lengths[index]
                var score = 0.0
                for term in terms {
                    guard let frequency = document[term], let weight = idf[term] else { continue }
                    let count = Double(frequency)
                    let denominator = count + ToolSearch.k1
                        * (1 - ToolSearch.b + ToolSearch.b * length / averageLength)
                    score += weight * count * (ToolSearch.k1 + 1) / denominator
                }
                return score
            }
        }

        /// Document indices in descending score order, ties broken by document
        /// order — the total order Python's stable sort produces, written out
        /// because Swift's `sorted` makes no stability promise.
        ///
        /// Zero-scoring documents are dropped: the probe prints them to fill a
        /// top-five, but a tool that shares not one word with the query is not
        /// a search result, it is padding an agent would have to read.
        func ranking(for query: String) -> [(document: Int, score: Double)] {
            let scored = scores(for: query)
            return scored.indices
                .filter { scored[$0] > 0 }
                .sorted { left, right in
                    scored[left] == scored[right] ? left < right : scored[left] > scored[right]
                }
                .map { (document: $0, score: scored[$0]) }
        }
    }

    /// The exact-name escape hatch, and the reason there is no separate
    /// `logic_tool_schema` tool.
    ///
    /// BM25 is measurably BAD at the one query an agent asks most often once
    /// it has a name — the name itself. Scored over the 82-tool corpus, a
    /// tool's own name ranks it first for only 59 of them: `logic_track_info`
    /// comes back fourth behind three `logic_set_track_*` tools, and
    /// `logic_list_inserts` ninth. The tools that lose are exactly the ones
    /// whose name-words are common across a family, which is to say the ones
    /// an agent is most likely to be disambiguating. A second tool could have
    /// answered that query; ten lines here answer it inside the first, and the
    /// miss degrades into search results instead of a not-found error.
    ///
    /// Two forms, both chosen so they cannot fire for a natural-language
    /// query: the WHOLE query being a tool name (with or without the
    /// `logic_` prefix, e.g. `bounce_range`), or any whitespace-separated
    /// token that starts with `logic_` and names a real tool, which is how a
    /// name arrives inside a sentence.
    static func exactNames(in query: String, registry: Set<String>) -> [String] {
        var found: [String] = []
        func consider(_ candidate: String) {
            let name = candidate.hasPrefix("logic_") ? candidate : "logic_" + candidate
            if registry.contains(name), !found.contains(name) { found.append(name) }
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count == 1 { consider(words[0]) }
        for word in words where word.hasPrefix("logic_") {
            consider(word.trimmingCharacters(in: CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "_")).inverted))
        }
        return found
    }
}
