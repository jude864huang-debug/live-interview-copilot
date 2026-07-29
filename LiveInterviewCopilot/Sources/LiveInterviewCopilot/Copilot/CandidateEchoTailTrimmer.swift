import Foundation

/// Removes only a sufficiently long interviewer echo from the end of a
/// candidate transcript. It never rewrites the candidate's unique prefix.
enum CandidateEchoTailTrimmer {
    static let defaultSimilarityThreshold = 0.82
    static let defaultMinimumCharacterCount = 12
    static let defaultMinimumWordCount = 4

    static func trim(
        candidateText: String,
        interviewerText: String,
        similarityThreshold: Double = defaultSimilarityThreshold,
        minimumCharacterCount: Int = defaultMinimumCharacterCount,
        minimumWordCount: Int = defaultMinimumWordCount
    ) -> String {
        let candidate = candidateText.trimmingCharacters(in: .whitespacesAndNewlines)
        let interviewer = interviewerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !interviewer.isEmpty else { return candidate }

        let characters = Array(candidate)
        let normalizedInterviewer = normalized(interviewer)
        guard isEligible(
            interviewer,
            normalized: normalizedInterviewer,
            minimumCharacterCount: minimumCharacterCount,
            minimumWordCount: minimumWordCount
        ) else { return candidate }

        var exactMatchStart: Int?
        var bestFuzzyMatch: (start: Int, similarity: Double)?

        for start in characters.indices {
            guard characters[start].isLetter || characters[start].isNumber else { continue }
            let suffix = String(characters[start...])
            let normalizedSuffix = normalized(suffix)
            guard isEligible(
                suffix,
                normalized: normalizedSuffix,
                minimumCharacterCount: minimumCharacterCount,
                minimumWordCount: minimumWordCount
            ) else { continue }

            if normalizedInterviewer.contains(normalizedSuffix) {
                exactMatchStart = start
                break
            }

            guard isNaturalBoundary(start, in: characters) else { continue }
            let similarity = bigramDice(normalizedSuffix, normalizedInterviewer)
            guard similarity >= similarityThreshold else { continue }
            if bestFuzzyMatch == nil || similarity > bestFuzzyMatch!.similarity {
                bestFuzzyMatch = (start, similarity)
            }
        }

        guard let start = exactMatchStart ?? bestFuzzyMatch?.start else { return candidate }
        return String(characters[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }
            .map { String($0) }
            .joined()
    }

    private static func isEligible(
        _ original: String,
        normalized: String,
        minimumCharacterCount: Int,
        minimumWordCount: Int
    ) -> Bool {
        let wordCount = original.split { $0.isWhitespace || $0.isPunctuation }.count
        return normalized.count >= minimumCharacterCount || wordCount >= minimumWordCount
    }

    private static func isNaturalBoundary(_ index: Int, in characters: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        return previous.isWhitespace || previous.isPunctuation
    }

    private static func bigramDice(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }

        let left = bigramCounts(lhs)
        let right = bigramCounts(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let overlap = left.reduce(into: 0) { count, entry in
            count += min(entry.value, right[entry.key, default: 0])
        }
        let total = left.values.reduce(0, +) + right.values.reduce(0, +)
        return total == 0 ? 0 : (2 * Double(overlap)) / Double(total)
    }

    private static func bigramCounts(_ text: String) -> [String: Int] {
        let characters = Array(text)
        guard characters.count >= 2 else { return [:] }
        var counts: [String: Int] = [:]
        for index in 0..<(characters.count - 1) {
            counts[String(characters[index...index + 1]), default: 0] += 1
        }
        return counts
    }
}
