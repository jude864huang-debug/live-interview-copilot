import Foundation

enum TextSimilarity {
    private enum MatchRunKind {
        case cjk
        case word
    }

    private static let ignoredInterviewFeatures: Set<String> = [
        "c:如何", "c:怎么", "c:什么", "c:请问", "c:一下", "c:可以", "c:是否",
        "c:如果", "c:那么", "c:这个", "c:那个",
        "w:the", "w:a", "w:an", "w:is", "w:are", "w:do", "w:does", "w:did",
        "w:how", "w:what", "w:why", "w:would", "w:could", "w:you", "w:your",
    ]

    /// Small, deterministic concept groups cover common interview paraphrases
    /// without adding a network or model call to the latency-critical match.
    private static let interviewConceptAliases: [String: [String]] = [
        "validation": [
            "验证", "衡量", "评估", "评价", "检验", "效果指标", "成功指标", "成功标准",
            "判断成功", "判断效果", "做得好不好", "效果好不好", "是否有效", "成效如何",
            "证明有效", "证明成功", "指标闭环",
            "validate", "validation", "measure", "measurement", "metric", "metrics",
            "evaluate", "evaluation", "success criteria", "kpi",
        ],
        "risk": [
            "风险", "隐患", "最坏情况", "不及预期", "失败怎么办", "主要挑战", "最大挑战", "困难",
            "risk", "risks", "worst case", "failure", "fail", "challenge",
        ],
        "resources": [
            "资源", "预算", "人手", "资源不足", "资源减少", "资源缩减", "资源有限",
            "预算不足", "预算减少", "预算砍半",
            "人手不足", "人员减少", "时间不足", "砍半", "缩减资源",
            "resource constraint", "fewer resources", "budget cut", "headcount", "time constraint",
        ],
        "tradeoff": [
            "优先级", "优先顺序", "取舍", "权衡", "舍弃", "先做什么", "后做什么",
            "prioritize", "prioritization", "priority", "tradeoff", "trade-off",
        ],
        "scale": [
            "推广", "规模化", "扩展", "扩大范围", "大规模落地", "复制到", "全面上线", "采用率",
            "rollout", "roll out", "scale", "scaling", "adoption", "launch",
        ],
        "stakeholders": [
            "利益相关方", "跨部门", "协作", "协调", "对齐", "分歧", "冲突", "说服", "反对意见",
            "stakeholder", "cross-functional", "alignment", "conflict", "persuade", "objection",
        ],
        "retrospective": [
            "复盘", "回顾", "经验教训", "学到了什么", "如何改进", "反思",
            "retrospective", "lesson learned", "lessons learned", "what did you learn",
        ],
        "root-cause": [
            "根因", "根本原因", "为什么失败", "失败原因", "问题原因",
            "root cause", "why did it fail", "reason for failure",
        ],
    ]

    static func normalizedWords(in text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func normalizedText(_ text: String) -> String {
        normalizedWords(in: text).joined(separator: " ")
    }

    static func jaccard(_ a: String, _ b: String) -> Double {
        let setA = Set(normalizedWords(in: a))
        let setB = Set(normalizedWords(in: b))
        guard !setA.isEmpty || !setB.isEmpty else { return 1.0 }
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        return Double(intersection) / Double(union)
    }

    /// Deterministic similarity for interview questions. Exact normalized text
    /// wins first; otherwise CJK character phrases and non-CJK words are scored
    /// together so Chinese and mixed-language questions do not depend on spaces.
    static func interviewMatchScore(_ first: String, _ second: String) -> Double {
        let firstRuns = interviewMatchRuns(in: first)
        let secondRuns = interviewMatchRuns(in: second)
        let firstCompact = firstRuns.map(\.text).joined()
        let secondCompact = secondRuns.map(\.text).joined()
        guard !firstCompact.isEmpty, !secondCompact.isEmpty else { return 0 }
        if firstCompact == secondCompact { return 1 }

        let shorterCount = min(firstCompact.count, secondCompact.count)
        if shorterCount >= 5,
           firstCompact.contains(secondCompact) || secondCompact.contains(firstCompact) {
            return 0.94
        }

        let lexicalScore: Double = {
            let firstFeatures = interviewMatchFeatures(from: firstRuns)
            let secondFeatures = interviewMatchFeatures(from: secondRuns)
            guard !firstFeatures.isEmpty, !secondFeatures.isEmpty else { return 0 }

            let intersection = firstFeatures.intersection(secondFeatures).count
            guard intersection > 0 else { return 0 }
            let union = firstFeatures.union(secondFeatures).count
            let smallerFeatureCount = min(firstFeatures.count, secondFeatures.count)
            let containment = Double(intersection) / Double(smallerFeatureCount)
            let jaccard = Double(intersection) / Double(union)
            let commonFragment = longestCommonSubstringLength(firstCompact, secondCompact)
            let fragmentCoverage = Double(commonFragment) / Double(shorterCount)
            return min(0.89, containment * 0.55 + jaccard * 0.25 + fragmentCoverage * 0.20)
        }()

        let firstConcepts = interviewConcepts(in: first)
        let secondConcepts = interviewConcepts(in: second)
        let sharedConcepts = firstConcepts.intersection(secondConcepts)
        guard !sharedConcepts.isEmpty else { return lexicalScore }

        let smallerConceptCount = min(firstConcepts.count, secondConcepts.count)
        let unionConceptCount = firstConcepts.union(secondConcepts).count
        let conceptContainment = Double(sharedConcepts.count) / Double(smallerConceptCount)
        let conceptJaccard = Double(sharedConcepts.count) / Double(unionConceptCount)
        let conceptScore = min(
            0.89,
            0.62 + conceptContainment * 0.14 + conceptJaccard * 0.08 + min(lexicalScore, 0.5) * 0.10
        )
        return max(lexicalScore, conceptScore)
    }

    private static func interviewMatchRuns(
        in text: String
    ) -> [(kind: MatchRunKind, text: String)] {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        var runs: [(kind: MatchRunKind, text: String)] = []
        var currentKind: MatchRunKind?
        var current = ""

        func flush() {
            guard let currentKind, !current.isEmpty else { return }
            runs.append((currentKind, current))
            current = ""
        }

        for character in folded {
            let kind: MatchRunKind?
            if character.unicodeScalars.allSatisfy({ isCJK($0) }) {
                kind = .cjk
            } else if character.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0)
            }) {
                kind = .word
            } else {
                kind = nil
            }

            guard let kind else {
                flush()
                currentKind = nil
                continue
            }
            if currentKind != kind {
                flush()
                currentKind = kind
            }
            current.append(character)
        }
        flush()
        return runs
    }

    private static func interviewMatchFeatures(
        from runs: [(kind: MatchRunKind, text: String)]
    ) -> Set<String> {
        var features: Set<String> = []
        for run in runs {
            switch run.kind {
            case .word:
                guard run.text.count >= 2 else { continue }
                features.insert("w:\(run.text)")
            case .cjk:
                let characters = Array(run.text)
                if characters.count == 1 {
                    features.insert("c:\(run.text)")
                    continue
                }
                for size in 2...min(3, characters.count) {
                    for start in 0...(characters.count - size) {
                        features.insert("c:\(String(characters[start..<(start + size)]))")
                    }
                }
            }
        }
        return features.subtracting(ignoredInterviewFeatures)
    }

    private static func interviewConcepts(in text: String) -> Set<String> {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        let compact = folded.components(separatedBy: .whitespacesAndNewlines).joined(separator: " ")
        return Set(interviewConceptAliases.compactMap { concept, aliases in
            aliases.contains(where: compact.contains) ? concept : nil
        })
    }

    private static func longestCommonSubstringLength(_ first: String, _ second: String) -> Int {
        let lhs = Array(first)
        let rhs = Array(second)
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var previous = Array(repeating: 0, count: rhs.count + 1)
        var best = 0
        for left in lhs {
            var current = Array(repeating: 0, count: rhs.count + 1)
            for (index, right) in rhs.enumerated() where left == right {
                current[index + 1] = previous[index] + 1
                best = max(best, current[index + 1])
            }
            previous = current
        }
        return best
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x2A6DF, 0x2A700...0x2B73F, 0x2B740...0x2B81F,
             0x2B820...0x2CEAF:
            true
        default:
            false
        }
    }
}
