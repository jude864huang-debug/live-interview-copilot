import Foundation

enum QuestionHighlightReason: String, Codable, Sendable, Equatable {
    case entity
    case english
    case acronym
    case domain
    case lowConfidence
    case oov
}

struct QuestionRiskHighlight: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let range: Range<String.Index>
    let utf16Range: NSRange
    let reasons: [QuestionHighlightReason]
    let candidates: [String]
    let score: Int

    var idString: String { id.uuidString }
}

enum QuestionCorrectionMode: String, Equatable, Sendable {
    case idle
    case keyword
    case fullSentence
}

/// Local, explainable keyword risk detection for interviewer question correction.
/// Keeps the sentence readable and only marks a few high-impact spans.
enum QuestionRiskHighlighter {
    private static let maxHighlights = 4

    private static let domainTerms: [String] = [
        "优先级", "优先序", "复盘", "取舍", "权衡", "指标", "增长", "北极星",
        "转化", "留存", "转化率", "留存率", "路径", "方案", "验证", "基线",
        "排列", "排定", "重排", "ROI", "OKR", "KPI", "ARR", "CAC", "LTV", "PMF",
        "A/B", "AB测试", "A/B测试", "北极星指标", "成功指标",
        // Product / AI interview terms frequently mangled by ASR.
        "agent", "Agent", "agents", "JSB", "jsb", "LLM", "llm", "RAG", "rag",
        "SDK", "sdk", "API", "api", "SaaS", "B2B", "B2C", "GTM", "PMF",
    ]

    private static let englishStopwords: Set<String> = [
        "a", "an", "and", "or", "the", "to", "of", "in", "on", "for", "with",
        "is", "are", "was", "were", "be", "as", "at", "by", "from", "that", "this",
        "it", "you", "we", "i", "me", "my", "our", "your",
    ]

    private static let stopTerms: Set<String> = [
        "的", "了", "吗", "呢", "啊", "吧", "和", "与", "或", "及", "在", "是",
        "有", "会", "你", "我", "他", "她", "它", "我们", "你们", "他们",
        "如何", "怎样", "怎么", "什么", "哪些", "是否", "可以", "需要", "时候",
        "一下", "一个", "这个", "那个", "如果", "因为", "所以", "然后",
    ]

    private static let correctionPairs: [(String, [String])] = [
        ("排列", ["排定", "重排", "排出"]),
        ("优先序", ["优先级"]),
        ("复判", ["复盘"]),
        ("复盘", ["复盘"]),
        ("肉眼", ["ROI"]),
        ("若一", ["ROI"]),
        ("欧克尔", ["OKR"]),
        ("欧开尔", ["OKR"]),
        ("开皮埃", ["KPI"]),
        ("开皮埃爱", ["KPI"]),
    ]

    static func highlights(
        in question: String,
        knowledgeTerms: [String] = [],
        maxCount: Int = maxHighlights
    ) -> [QuestionRiskHighlight] {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var spans: [CandidateSpan] = []
        spans.append(contentsOf: matchTerms(text, terms: knowledgeTerms, reason: .entity, baseScore: 6))
        spans.append(contentsOf: matchTerms(text, terms: domainTerms, reason: .domain, baseScore: 4))
        spans.append(contentsOf: matchEnglishAndAcronyms(in: text))
        spans.append(contentsOf: matchCorrectionSources(in: text))

        let merged = mergeAndScore(spans, in: text)
        let limited = Array(merged.prefix(max(0, maxCount)))
        return limited.map { span in
            QuestionRiskHighlight(
                id: UUID(),
                text: span.text,
                range: span.range,
                utf16Range: NSRange(span.range, in: text),
                reasons: span.reasons.sorted { $0.rawValue < $1.rawValue },
                candidates: candidates(for: span.text, knowledgeTerms: knowledgeTerms),
                score: span.score
            )
        }
    }

    static func candidates(
        for token: String,
        knowledgeTerms: [String] = []
    ) -> [String] {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var result: [String] = []
        var seen: Set<String> = [normalized(trimmed)]

        func append(_ value: String) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { return }
            let key = normalized(v)
            guard seen.insert(key).inserted else { return }
            // Prefer canonical casing for pure acronyms.
            if v.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }),
               v.count <= 6,
               v == v.uppercased() || v == v.lowercased() {
                result.append(v.uppercased())
            } else {
                result.append(v)
            }
        }

        // Exact correction table.
        for (source, targets) in correctionPairs where normalized(source) == normalized(trimmed) {
            targets.forEach(append)
        }

        // Knowledge entity near-matches (edit distance / shared prefix).
        for term in knowledgeTerms {
            let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, normalized(t) != normalized(trimmed) else { continue }
            if isNearMatch(trimmed, t) {
                append(t)
            }
        }

        // Domain canonical forms.
        for term in domainTerms where isNearMatch(trimmed, term) {
            append(term)
        }

        // English/acronym normalization.
        if looksLikeAcronym(trimmed) || looksLikeAcronym(trimmed.uppercased()) {
            append(trimmed.uppercased())
        }
        if looksLikeEnglishWord(trimmed) {
            // Keep original specialist casing for mixed tokens; surface a
            // capitalized form for short product words when useful.
            if trimmed == trimmed.lowercased(), (2...6).contains(trimmed.count) {
                append(trimmed.uppercased())
            }
        }

        return Array(result.prefix(3))
    }

    // MARK: - Matching

    private struct CandidateSpan {
        let text: String
        let range: Range<String.Index>
        var reasons: Set<QuestionHighlightReason>
        var score: Int
    }

    private static func matchTerms(
        _ text: String,
        terms: [String],
        reason: QuestionHighlightReason,
        baseScore: Int
    ) -> [CandidateSpan] {
        let uniqueTerms = orderedUnique(terms)
            .filter { !stopTerms.contains($0) }
            .sorted { $0.count > $1.count }

        var spans: [CandidateSpan] = []
        for term in uniqueTerms {
            guard term.count >= 2 || looksLikeAcronym(term) || looksLikeEnglishWord(term) else { continue }
            var search = text.startIndex
            while search < text.endIndex,
                  let found = text.range(of: term, options: [.caseInsensitive], range: search..<text.endIndex) {
                spans.append(
                    CandidateSpan(
                        text: String(text[found]),
                        range: found,
                        reasons: [reason],
                        score: baseScore + min(3, term.count / 2)
                    )
                )
                search = found.upperBound
            }
        }
        return spans
    }

    private static func matchEnglishAndAcronyms(in text: String) -> [CandidateSpan] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        // Do not use \b here: in CJK-adjacent strings like "的agent和JSB", word
        // boundaries often fail and drop the only high-value keywords.
        let pattern = #"(?<![A-Za-z0-9])[A-Za-z][A-Za-z0-9]{0,15}(?:[/-][A-Za-z0-9]{1,8}){0,2}(?![A-Za-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        return regex.matches(in: text, range: full).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let value = String(text[range])
            let isAcronym = looksLikeAcronym(value)
            let isEnglish = looksLikeEnglishWord(value)
            guard isAcronym || isEnglish else { return nil }
            // Skip ultra-common English glue words when they appear alone.
            if englishStopwords.contains(normalized(value)) { return nil }
            var reasons: Set<QuestionHighlightReason> = []
            var score = 5
            if isAcronym {
                reasons.insert(.acronym)
                score += 2
            }
            if isEnglish {
                reasons.insert(.english)
            }
            // Prefer short product tokens (agent/JSB) over long generic words.
            if value.count <= 5 { score += 1 }
            return CandidateSpan(text: value, range: range, reasons: reasons, score: score)
        }
    }

    private static func matchCorrectionSources(in text: String) -> [CandidateSpan] {
        matchTerms(
            text,
            terms: correctionPairs.map(\.0),
            reason: .oov,
            baseScore: 5
        )
    }

    private static func mergeAndScore(_ spans: [CandidateSpan], in text: String) -> [CandidateSpan] {
        let sorted = spans.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return text.distance(from: text.startIndex, to: $0.range.lowerBound)
                < text.distance(from: text.startIndex, to: $1.range.lowerBound)
        }

        var accepted: [CandidateSpan] = []
        for span in sorted {
            if stopTerms.contains(span.text) { continue }
            if span.text.count == 1 && !looksLikeAcronym(span.text) { continue }
            let overlaps = accepted.contains { rangesOverlap($0.range, span.range) }
            if overlaps { continue }
            accepted.append(span)
        }

        return accepted.sorted {
            text.distance(from: text.startIndex, to: $0.range.lowerBound)
                < text.distance(from: text.startIndex, to: $1.range.lowerBound)
        }
    }

    private static func rangesOverlap(_ a: Range<String.Index>, _ b: Range<String.Index>) -> Bool {
        a.overlaps(b)
    }

    private static func isNearMatch(_ a: String, _ b: String) -> Bool {
        let left = normalized(a)
        let right = normalized(b)
        if left == right { return false }
        if left.isEmpty || right.isEmpty { return false }
        if left.contains(right) || right.contains(left) {
            return abs(left.count - right.count) <= 2
        }
        let distance = editDistance(left, right)
        let limit = max(left.count, right.count) <= 4 ? 1 : 2
        return distance > 0 && distance <= limit
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let aa = Array(a)
        let bb = Array(b)
        var dp = Array(repeating: Array(repeating: 0, count: bb.count + 1), count: aa.count + 1)
        for i in 0...aa.count { dp[i][0] = i }
        for j in 0...bb.count { dp[0][j] = j }
        for i in 1...aa.count {
            for j in 1...bb.count {
                if aa[i - 1] == bb[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1]) + 1
                }
            }
        }
        return dp[aa.count][bb.count]
    }

    private static func looksLikeAcronym(_ value: String) -> Bool {
        let letters = value.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard (2...6).contains(letters.count) else { return false }
        let upper = letters.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        return upper >= letters.count - 1
    }

    private static func looksLikeEnglishWord(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty else { return false }
        return scalars.allSatisfy {
            CharacterSet.letters.contains($0)
                || CharacterSet.decimalDigits.contains($0)
                || $0 == "/" || $0 == "-" || $0 == "&"
        } && scalars.contains(where: { CharacterSet.letters.contains($0) })
            && value.count >= 2
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for raw in values {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let key = normalized(value)
            guard seen.insert(key).inserted else { continue }
            output.append(value)
        }
        return output
    }
}
