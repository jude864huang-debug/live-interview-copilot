import Foundation

enum InterviewHotwordSource: String, Codable, Sendable {
    case manual
    case knowledgePackage
}

struct InterviewHotword: Codable, Equatable, Sendable, Identifiable {
    var id: String { phrase.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current) }

    let phrase: String
    let weight: Int
    let source: InterviewHotwordSource

    init(phrase: String, weight: Int, source: InterviewHotwordSource) {
        self.phrase = phrase
        self.weight = min(11, max(1, weight))
        self.source = source
    }
}

enum InterviewHotwordExtractor {
    /// Builds the ephemeral Tencent hotword list. Manual terms always win a
    /// case-insensitive duplicate and are emitted before package-derived terms.
    static func extract(
        manualTerms: [String],
        snapshot: KnowledgePackageSnapshot?,
        maximumCount: Int = 128
    ) -> [InterviewHotword] {
        let limit = min(128, max(0, maximumCount))
        guard limit > 0 else { return [] }

        var output: [InterviewHotword] = []
        var seen: Set<String> = []

        func append(_ raw: String, defaultWeight: Int, source: InterviewHotwordSource) {
            guard output.count < limit,
                  let parsed = parse(raw, defaultWeight: defaultWeight) else { return }
            let key = parsed.phrase.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(key).inserted else { return }
            output.append(InterviewHotword(phrase: parsed.phrase, weight: parsed.weight, source: source))
        }

        for rawEntry in manualTerms {
            for term in splitManualEntry(rawEntry) {
                append(term, defaultWeight: 10, source: .manual)
            }
        }

        guard let snapshot, output.count < limit else { return output }

        for source in snapshot.sources {
            append(source.title, defaultWeight: 5, source: .knowledgePackage)
            appendEnglishTechnicalTerms(
                from: source.title,
                limit: limit - output.count
            ) { append($0, defaultWeight: 5, source: .knowledgePackage) }
            if output.count == limit { return output }
        }

        for block in snapshot.blocks {
            if let heading = block.heading {
                append(heading, defaultWeight: 5, source: .knowledgePackage)
                appendEnglishTechnicalTerms(
                    from: heading,
                    limit: limit - output.count
                ) { append($0, defaultWeight: 5, source: .knowledgePackage) }
            }
            if output.count == limit { return output }

            appendEnglishTechnicalTerms(
                from: block.text,
                limit: limit - output.count
            ) { append($0, defaultWeight: 5, source: .knowledgePackage) }
            if output.count == limit { return output }
        }

        return output
    }

    static func tencentParameterValue(_ hotwords: [InterviewHotword]) -> String? {
        let valid = hotwords.prefix(128).compactMap { hotword -> String? in
            guard let parsed = parse(hotword.phrase, defaultWeight: hotword.weight) else { return nil }
            return "\(parsed.phrase)|\(min(11, max(1, hotword.weight)))"
        }
        return valid.isEmpty ? nil : valid.joined(separator: ",")
    }

    private static func splitManualEntry(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: ",，;；\n\r"))
    }

    private static func parse(_ raw: String, defaultWeight: Int) -> (phrase: String, weight: Int)? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        var weight = defaultWeight
        if let separator = value.lastIndex(of: "|") {
            let suffix = value[value.index(after: separator)...]
            if let explicit = Int(suffix), (1...11).contains(explicit) {
                weight = explicit
                value = String(value[..<separator])
            }
        }

        // Tencent rejects the whole websocket request when any temporary
        // hotword contains punctuation or a special character. Knowledge
        // headings commonly contain parentheses, slashes and dashes, so using
        // trim-only cleanup is insufficient: punctuation in the middle remains.
        // Keep Unicode letters (including Han characters) and decimal digits;
        // remove everything else before the hotword is signed into the URL.
        value = String(
            value.unicodeScalars.filter { scalar in
                CharacterSet.letters.contains(scalar)
                    || CharacterSet.decimalDigits.contains(scalar)
            }
        )

        guard value.count >= 2, value.count <= 30 else { return nil }
        let hanCount = value.unicodeScalars.reduce(into: 0) { count, scalar in
            if (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value) {
                count += 1
            }
        }
        guard hanCount <= 10 else { return nil }
        return (value, min(11, max(1, weight)))
    }

    private static func appendEnglishTechnicalTerms(
        from text: String,
        limit: Int,
        append: (String) -> Void
    ) {
        guard limit > 0, !text.isEmpty else { return }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var emitted = 0
        englishTokenRegex.enumerateMatches(in: text, range: range) { match, _, stop in
            guard let match, let tokenRange = Range(match.range, in: text) else { return }
            let token = String(text[tokenRange])
            guard isLikelyTechnicalTerm(token) else { return }
            append(token)
            emitted += 1
            if emitted >= limit { stop.pointee = true }
        }
    }

    private static func isLikelyTechnicalTerm(_ token: String) -> Bool {
        let lower = token.lowercased()
        guard !englishStopwords.contains(lower), token.count >= 2 else { return false }
        let uppercaseCount = token.unicodeScalars.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        let hasDigit = token.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        let hasTechnicalPunctuation = token.contains { ".+#_/-".contains($0) }
        let hasInternalCapital = token.dropFirst().contains { $0.isUppercase }
        return uppercaseCount >= 2 || hasDigit || hasTechnicalPunctuation || hasInternalCapital
    }

    private static let englishTokenRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])[A-Za-z][A-Za-z0-9.+#_/-]{1,29}(?![A-Za-z0-9])"#
    )

    private static let englishStopwords: Set<String> = [
        "about", "after", "before", "candidate", "company", "document", "experience",
        "interview", "manager", "project", "resume", "role", "story", "team", "with",
    ]
}
