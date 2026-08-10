import Foundation

enum CopilotMode: String, Codable, CaseIterable, Sendable {
    case automatic
    case manual

    var label: String { self == .automatic ? "自动" : "手动" }
}

enum InterviewInferencePreference: String, Codable, CaseIterable, Sendable {
    case realtimePreferred
    case apiPreferred
    case codexOnly

    var label: String {
        switch self {
        case .realtimePreferred: "GPT Realtime 优先"
        case .apiPreferred: "API 优先"
        case .codexOnly: "仅 Codex CLI"
        }
    }
}

enum InterviewAPIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI
    case deepSeek

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        }
    }
}

enum InterviewAPIProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatCompletion = "chat_completion"
    case responses

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chatCompletion: "Chat Completions"
        case .responses: "Responses API"
        }
    }
}

enum InterviewProvider: String, Codable, Sendable {
    case local
    case openAIRealtime
    case openAIAPI
    case deepSeekAPI
    case codexSubscription

    var label: String {
        switch self {
        case .local: "本地骨架"
        case .openAIRealtime: "GPT Realtime"
        case .openAIAPI: "API"
        case .deepSeekAPI: "API"
        case .codexSubscription: "Codex CLI"
        }
    }
}

enum InterviewRequestKind: String, Codable, Sendable {
    case answer
    case cue
    case referenceAnswer
    case followUps
    case followUpAnswer
}

enum InterviewReasoningEffort: String, Codable, Sendable {
    case none
    case low
    case medium
    case high
    case xhigh

    var label: String {
        switch self {
        case .none: "关闭"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "Extra High"
        }
    }

    var description: String {
        switch self {
        case .none: "最低延迟，不额外展开思考"
        case .low: "平衡延迟与判断质量"
        case .medium: "更充分的分析，响应会更慢"
        case .high: "高强度分析，延迟和消耗更高"
        case .xhigh: "Extra High，最充分的分析，延迟最高"
        }
    }

    /// Value sent to OpenAI-compatible Chat Completions providers that accept
    /// the `reasoning_effort` parameter. DeepSeek and older chat models do not
    /// support it, so callers must gate on the provider before sending it.
    var chatCompletionValue: String {
        switch self {
        case .none: "low"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .xhigh: "high"
        }
    }
}

enum CopilotGenerationState: String, Codable, Sendable {
    case listening
    case waitingForEndpoint
    case draftReady
    case generating
    case completed
    case stopped
    case superseded
    case failed
}

enum InterviewQuestionType: String, Codable, CaseIterable, Sendable {
    case selfIntroduction = "self_introduction"
    case motivation
    case behavioral
    case projectDeepDive = "project_deep_dive"
    case productCase = "product_case"
    case businessAnalysis = "business_analysis"
    case professionalKnowledge = "professional_knowledge"
    case followUp = "follow_up"
    case other

    var label: String {
        switch self {
        case .selfIntroduction: "自我介绍"
        case .motivation: "动机匹配"
        case .behavioral: "行为题"
        case .projectDeepDive: "项目深挖"
        case .productCase: "产品案例"
        case .businessAnalysis: "业务分析"
        case .professionalKnowledge: "专业题"
        case .followUp: "追问"
        case .other: "通用题"
        }
    }

    /// json_object providers do not enforce enum values. Accept the raw enum
    /// id, common camelCase variants, and the Chinese UI label; fall back to
    /// `.other` only for genuinely unknown values.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let normalized = Self.normalized(raw)
        self = Self(rawValue: raw)
            ?? Self.allCases.first {
                Self.normalized($0.rawValue) == normalized || $0.label == raw
            }
            ?? .other
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

struct ConversationTurn: Codable, Equatable, Sendable {
    let speaker: String
    let text: String
    let timestamp: Date
}

struct InterviewExchange: Codable, Equatable, Sendable {
    let interviewerPrompt: String
    let candidateAnswer: String
}

struct InterviewEvidenceAnchor: Codable, Equatable, Sendable {
    var cue: String
    var sourceIDs: [String]
}

struct InterviewCue: Codable, Equatable, Sendable {
    var questionSummary: String
    var questionType: InterviewQuestionType
    var isFollowUp: Bool
    var directOpening: String
    var framework: String
    var talkingPoints: [String]
    var evidenceAnchors: [InterviewEvidenceAnchor]
    var missingFacts: [String]
    var clarifyingQuestion: String?
    var likelyFollowUps: [String]
    var confidence: String

    static func localSkeleton(for question: String) -> InterviewCue {
        let type = InterviewQuestionClassifier.classify(question)
        let content: (String, String, [String]) = switch type {
        case .selfIntroduction:
            ("我会重点介绍与这个岗位最相关的定位、能力和求职动机。", "定位 → 相关能力 → 核心优势 → 求职动机", ["用一句话概括当前定位", "选择最相关的能力方向", "说明可迁移的核心优势", "连接目标岗位与求职动机"])
        case .motivation:
            ("我选择这个岗位，主要基于业务方向、能力匹配和可贡献价值三个考虑。", "动机 → 能力匹配 → 可贡献价值", ["岗位最吸引你的业务问题", "能力与要求如何对应", "可迁移的方法和优势", "入职后优先创造的价值"])
        case .behavioral:
            ("面对这类情况，我会先对齐目标和事实，再推动行动并复盘结果。", "STAR：背景 → 任务 → 行动 → 结果 → 复盘", ["说明挑战的目标与约束", "拆清相关方诉求和事实", "讲判断、沟通与行动顺序", "用定性结果和复盘收束"])
        case .projectDeepDive:
            ("我会围绕项目目标、个人职责、关键决策和结果复盘，说明具体贡献。", "目标 → 职责 → 决策 → 难点 → 结果 → 复盘", ["概括项目目标与约束", "界定个人职责范围", "解释关键决策及权衡", "用定性结果与复盘收束"])
        case .productCase:
            ("我会先明确目标用户和成功指标，再比较方案、权衡与验证路径。", "目标 → 用户 → 指标 → 方案 → 权衡", ["明确业务目标和目标用户", "定义可验证的成功指标", "拆解核心问题和方案", "说明优先级、风险与权衡"])
        case .businessAnalysis:
            ("我会先统一问题口径和目标，再按关键驱动因素、数据和风险逐层拆解。", "目标 → 驱动因素 → 数据 → 判断 → 风险", ["确认目标、口径与边界", "拆解主要业务驱动因素", "明确需要的数据和假设", "给出判断、风险和验证方式"])
        case .professionalKnowledge:
            ("我的理解是，先明确核心定义和适用条件，再讨论原理、权衡与验证。", "定义 → 原理 → 权衡 → 场景 → 验证", ["给出一句话定义或结论", "解释核心原理与关键条件", "说明方案权衡和失败边界", "用假设场景说明验证方法"])
        case .followUp:
            ("这个问题我先直接给结论，再补充最相关的依据和适用边界。", "直答 → 证据 → 口径或局限", ["直接回答为什么或怎么做", "补充最相关的依据", "说明数据口径或限制"])
        case .other:
            ("我的核心判断是先明确目标和约束，再给出依据与可执行方案。", "结论 → 依据 → 方案 → 岗位关联", ["一句话回答核心问题", "给出两项关键依据", "说明可执行的方法或方案", "连接目标岗位与业务价值"])
        }
        return InterviewCue(
            questionSummary: question,
            questionType: type,
            isFollowUp: type == .followUp,
            directOpening: content.0,
            framework: content.1,
            talkingPoints: content.2,
            evidenceAnchors: [],
            missingFacts: [],
            clarifyingQuestion: nil,
            likelyFollowUps: [],
            confidence: "low"
        )
    }
}

/// Safely renderable pieces extracted from an unfinished structured cue.
/// The final `InterviewCue` still goes through full decoding and validation.
struct InterviewCueProgress: Equatable, Sendable {
    var directOpening: String?
    var talkingPoints: [String]

    var hasVisibleContent: Bool {
        !(directOpening?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || talkingPoints.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct InterviewReferenceAnswerSegment: Codable, Equatable, Sendable {
    var label: String
    var text: String
    /// Candidate-fact citations used by this segment. The engine must keep only
    /// IDs that belong to resume or story-bank knowledge sources.
    var sourceIDs: [String]
}

struct InterviewReferenceAnswer: Codable, Equatable, Sendable {
    var segments: [InterviewReferenceAnswerSegment]
    var missingFacts: [String]
    var estimatedSpeakingSeconds: Int
}

enum InterviewAnswerClaimType: String, Codable, CaseIterable, Sendable {
    case candidateFact
    case professionalJudgment
    case explicitAssumption

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let normalized = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        self = Self(rawValue: raw)
            ?? Self.allCases.first { $0.rawValue.lowercased().filter { $0.isLetter || $0.isNumber } == normalized }
            ?? .professionalJudgment
    }
}

enum InterviewAnswerEntryMode: String, Codable, CaseIterable, Sendable {
    case directAnswer
    case conditionalAnswer

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let normalized = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        self = Self(rawValue: raw)
            ?? Self.allCases.first { $0.rawValue.lowercased().filter { $0.isLetter || $0.isNumber } == normalized }
            ?? .directAnswer
    }
}

enum InterviewAnswerSpineRole: String, Codable, CaseIterable, Sendable {
    case context
    case judgment
    case mechanism
    case action
    case evidence
    case tradeoff
    case validation
    case reflection
    case fit

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let normalized = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        self = Self(rawValue: raw)
            ?? Self.allCases.first { $0.rawValue.lowercased().filter { $0.isLetter || $0.isNumber } == normalized }
            ?? .context
    }
}

enum InterviewAnswerMode: String, Codable, CaseIterable, Sendable {
    case groundedExperience
    case professionalJudgment
    case hypotheticalPlan

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let normalized = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        self = Self(rawValue: raw)
            ?? Self.allCases.first { $0.rawValue.lowercased().filter { $0.isLetter || $0.isNumber } == normalized }
            ?? .professionalJudgment
    }
}

struct InterviewAnswerEntry: Codable, Equatable, Sendable {
    var mode: InterviewAnswerEntryMode
    var text: String
    var assumption: String?
    var claimType: InterviewAnswerClaimType
    var sourceIDs: [String]
}

struct InterviewAnswerSpinePoint: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var role: InterviewAnswerSpineRole
    var label: String
    /// Retained only so v1 history records continue to decode. New v2 answers
    /// keep the spine title-only and place all speakable detail in `segments`.
    var cue: String? = nil
    var claimType: InterviewAnswerClaimType
    var sourceIDs: [String]
}

struct InterviewAnswerSegment: Codable, Equatable, Sendable {
    var pointID: String
    var text: String
    var claimType: InterviewAnswerClaimType
    var sourceIDs: [String]
}

struct InterviewAnswerClosing: Codable, Equatable, Sendable {
    var text: String
    var claimType: InterviewAnswerClaimType
    var sourceIDs: [String]
}

struct InterviewAnswerMetadata: Codable, Equatable, Sendable {
    var questionType: InterviewQuestionType
    var answerMode: InterviewAnswerMode
    var concreteGaps: [String]

    enum CodingKeys: String, CodingKey {
        case questionType
        case answerMode
        case concreteGaps
    }

    init(questionType: InterviewQuestionType, answerMode: InterviewAnswerMode, concreteGaps: [String]) {
        self.questionType = questionType
        self.answerMode = answerMode
        self.concreteGaps = concreteGaps
    }

    /// DeepSeek and other json_object providers do not enforce the schema's
    /// enums. A localized or off-schema questionType must not invalidate an
    /// otherwise complete answer; fall back to `.other` instead.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try? container.decode(String.self, forKey: .questionType) {
            questionType = InterviewQuestionType(rawValue: raw) ?? .other
        } else {
            questionType = .other
        }
        answerMode = (try? container.decode(InterviewAnswerMode.self, forKey: .answerMode)) ?? .professionalJudgment
        concreteGaps = (try? container.decode([String].self, forKey: .concreteGaps)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(questionType.rawValue, forKey: .questionType)
        try container.encode(answerMode, forKey: .answerMode)
        try container.encode(concreteGaps, forKey: .concreteGaps)
    }
}

struct InterviewProgressiveAnswer: Codable, Equatable, Sendable {
    var entry: InterviewAnswerEntry
    var spine: [InterviewAnswerSpinePoint]
    var segments: [InterviewAnswerSegment]
    var closing: InterviewAnswerClosing?
    var metadata: InterviewAnswerMetadata

    var spokenText: String {
        ([entry.text] + segments.map(\.text) + [closing?.text].compactMap { $0 })
            .joined(separator: " ")
    }

    /// A deterministic client-side estimate. Chinese is measured by Han-like
    /// characters and English by words so the model never has to invent timing.
    var estimatedSpeakingSeconds: Int {
        let text = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return 0 }
        let scalarCount = text.unicodeScalars.count
        let asciiWords = text.split { $0.isWhitespace || $0.isPunctuation }.filter {
            $0.unicodeScalars.allSatisfy(\.isASCII)
        }.count
        let nonASCII = max(0, scalarCount - text.unicodeScalars.filter(\.isASCII).count)
        let seconds = Double(nonASCII) / 4.2 + Double(asciiWords) / 2.5
        return max(1, Int(ceil(seconds)))
    }
}

/// Only complete JSON objects that have passed citation validation are placed
/// here. Callers merge by stable IDs and never replace already visible text.
struct InterviewAnswerProgress: Equatable, Sendable {
    var entry: InterviewAnswerEntry?
    var spine: [InterviewAnswerSpinePoint]
    var segments: [InterviewAnswerSegment]
    var closing: InterviewAnswerClosing?
    var metadata: InterviewAnswerMetadata?
    /// True only after the closing bracket of the complete spine array arrived.
    /// This is a transport-stage signal, not persisted answer content.
    var isSpineComplete = false

    static let empty = InterviewAnswerProgress(
        entry: nil,
        spine: [],
        segments: [],
        closing: nil,
        metadata: nil,
        isSpineComplete: false
    )

    var hasUsefulContent: Bool { entry != nil || !spine.isEmpty || !segments.isEmpty || closing != nil }
}

/// A final, validated interview round retained with one interview session.
/// Streaming previews and quick ideas are intentionally excluded.
struct InterviewHistoryAnswer: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let createdAt: Date
    let question: String
    let answer: InterviewReferenceAnswer
    let progressiveAnswer: InterviewProgressiveAnswer?
    let followUpSuggestions: InterviewFollowUpSet?
    let followUpAnswers: [String: InterviewFollowUpAnswer]?
    let predictedFollowUpQuestion: String?
    let predictedFollowUpAnswer: InterviewFollowUpAnswer?
    let predictedFollowUpSourceQuestion: String?

    init(
        id: UUID,
        createdAt: Date,
        question: String,
        answer: InterviewReferenceAnswer,
        progressiveAnswer: InterviewProgressiveAnswer? = nil,
        followUpSuggestions: InterviewFollowUpSet? = nil,
        followUpAnswers: [String: InterviewFollowUpAnswer]? = nil,
        predictedFollowUpQuestion: String? = nil,
        predictedFollowUpAnswer: InterviewFollowUpAnswer? = nil,
        predictedFollowUpSourceQuestion: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.question = question
        self.answer = answer
        self.progressiveAnswer = progressiveAnswer
        self.followUpSuggestions = followUpSuggestions
        self.followUpAnswers = followUpAnswers
        self.predictedFollowUpQuestion = predictedFollowUpQuestion
        self.predictedFollowUpAnswer = predictedFollowUpAnswer
        self.predictedFollowUpSourceQuestion = predictedFollowUpSourceQuestion
    }

    var hasCompleteFollowUps: Bool {
        guard let items = followUpSuggestions?.items, items.count == 3 else { return false }
        return items.allSatisfy { followUpAnswers?[$0.question] != nil }
    }
}

struct InterviewFollowUpSuggestion: Codable, Equatable, Sendable, Identifiable {
    var question: String
    var intent: String

    var id: String { question }
}

struct InterviewFollowUpSet: Codable, Equatable, Sendable {
    var items: [InterviewFollowUpSuggestion]
}

struct InterviewFollowUpAnswer: Codable, Equatable, Sendable {
    var directOpening: String
    var talkingPoints: [String]
    var sampleAnswer: String
    /// Candidate-fact citations used anywhere in this answer.
    var sourceIDs: [String]
    var estimatedSpeakingSeconds: Int
}

/// Read-only presentation state for the follow-up pipeline. The engine owns
/// all transitions so views can render progress without coordinating requests.
enum InterviewFollowUpPipelineState: Equatable, Sendable {
    case idle
    case generatingQuestions
    case generatingAnswer(index: Int, total: Int)
    case completed
    case partiallyFailed(failedIndices: [Int])
    case failed
    case stopped
    case superseded
}

/// A stable snapshot of the runtime details useful to the interview workspace
/// and diagnostics popover. Values that cannot be established from the active
/// request remain nil instead of being inferred.
struct InterviewRunDiagnostics: Equatable, Sendable {
    let mainModel: String
    let fallbackModel: String?
    let ownerModel: String?
    let attemptedModels: [String]
    let provider: InterviewProvider?
    let reasoningEffort: InterviewReasoningEffort
    let fallbackTriggered: Bool
    let asrMilliseconds: Int?
    let firstDeltaMilliseconds: Int?
    let firstUsefulEntryMilliseconds: Int?
    let spineReadyMilliseconds: Int?
    let answerCompleteMilliseconds: Int?
    let followUpQuestionsMilliseconds: Int?
    /// Durations are ordered to match `InterviewFollowUpSet.items`.
    let followUpAnswerMilliseconds: [Int?]
    let followUpAnswersCompleted: Int
    let followUpAnswersTotal: Int
    let citationValidationPassed: Bool?
    let mainlineLocked: Bool
    let revisionCount: Int
    let candidateStartedBeforeEntry: Bool
    let followUpPipelineState: InterviewFollowUpPipelineState
}

enum InterviewLiveSupplementKind: String, Equatable, Sendable {
    case talkingPoint
    case referenceSegment
    case missingFact
    case evidence
}

struct InterviewLiveSupplementItem: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let kind: InterviewLiveSupplementKind
}

enum InterviewLiveSupplementComposer {
    static func compose(
        supplementalCue: InterviewCue?,
        referenceAnswer: InterviewReferenceAnswer?,
        primaryCueFallback: InterviewCue? = nil,
        candidateIsAnswering: Bool
    ) -> [InterviewLiveSupplementItem] {
        if let supplementalCue {
            return cueItems(supplementalCue)
        }
        guard candidateIsAnswering else { return [] }
        if let referenceAnswer {
            return referenceItems(referenceAnswer)
        }
        if let primaryCueFallback {
            return cueItems(primaryCueFallback)
        }
        return []
    }

    private static func cueItems(_ cue: InterviewCue) -> [InterviewLiveSupplementItem] {
        var items: [InterviewLiveSupplementItem] = []
        let talkingPoints = cue.talkingPoints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        items.append(contentsOf: talkingPoints.prefix(2).enumerated().map { index, text in
            .init(id: "cue-point-\(index)-\(text)", text: text, kind: .talkingPoint)
        })

        let opening = cue.directOpening.trimmingCharacters(in: .whitespacesAndNewlines)
        if items.count < 2, !opening.isEmpty, !talkingPoints.contains(opening) {
            items.append(.init(
                id: "cue-opening-\(opening)",
                text: opening,
                kind: .talkingPoint
            ))
        }

        if let anchor = cue.evidenceAnchors.first(where: { !$0.cue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            items.append(.init(
                // Keep source IDs in the structured result and history for
                // auditability, but never make the candidate parse internal
                // citation codes while answering live.
                id: "cue-evidence-\(anchor.cue)",
                text: anchor.cue,
                kind: .evidence
            ))
        } else if talkingPoints.count > 2 {
            let thirdPoint = talkingPoints[2]
            items.append(.init(
                id: "cue-point-2-\(thirdPoint)",
                text: thirdPoint,
                kind: .talkingPoint
            ))
        } else if !opening.isEmpty, !items.contains(where: { $0.text == opening }) {
            items.append(.init(
                id: "cue-opening-\(opening)",
                text: opening,
                kind: .talkingPoint
            ))
        }
        return Array(items.prefix(3))
    }

    private static func referenceItems(_ answer: InterviewReferenceAnswer) -> [InterviewLiveSupplementItem] {
        let segments = answer.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var items: [InterviewLiveSupplementItem] = segments.prefix(2).enumerated().map { index, segment in
            let text = compactSegment(label: segment.label, text: segment.text)
            return .init(
                id: "reference-segment-\(index)-\(text)",
                text: text,
                kind: .referenceSegment
            )
        }
        if let sourcedSegment = segments.first(where: { !$0.sourceIDs.isEmpty }) {
            let text = compactSegment(label: sourcedSegment.label, text: sourcedSegment.text)
            items.append(.init(
                id: "reference-evidence-\(text)",
                text: text,
                kind: .evidence
            ))
        } else if segments.count > 2 {
            let segment = segments[2]
            let text = compactSegment(label: segment.label, text: segment.text)
            items.append(.init(
                id: "reference-segment-2-\(text)",
                text: text,
                kind: .referenceSegment
            ))
        }
        return Array(items.prefix(3))
    }

    private static func compactSegment(label: String, text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstSentence = cleaned.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { "。！？!?\n".contains($0) }
        ).first.map(String.init) ?? cleaned
        let asciiCount = firstSentence.unicodeScalars.lazy.filter(\.isASCII).count
        let mostlyASCII = asciiCount * 4 >= max(1, firstSentence.unicodeScalars.count * 3)
        let limit = mostlyASCII ? 96 : 42
        let shortened = firstSentence.count > limit
            ? String(firstSentence.prefix(limit)) + "…"
            : firstSentence
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanLabel.isEmpty ? shortened : "\(cleanLabel)：\(shortened)"
    }
}

enum ReferenceAnswerGenerationState: String, Codable, Sendable {
    case idle
    case generating
    case completed
    case stopped
    case superseded
    case failed
}

struct RecentInterviewCue: Identifiable, Equatable, Sendable {
    let id: UUID
    let question: String
    let cue: InterviewCue
}

enum InterviewQuestionClassifier {
    static func classify(_ question: String) -> InterviewQuestionType {
        let value = question.lowercased()
        if matches(value, ["自我介绍", "介绍一下自己", "tell me about yourself", "walk me through your background"]) { return .selfIntroduction }
        if matches(value, ["为什么选择", "为什么加入", "为什么应聘", "why this role", "why our company", "motivation"]) { return .motivation }
        if matches(value, ["举个例子", "冲突", "失败", "压力", "领导力", "协作", "tell me about a time", "behavioral"]) { return .behavioral }
        if matches(value, ["这个项目", "项目中", "你负责", "项目经历", "walk me through this project", "your role in"]) { return .projectDeepDive }
        if matches(value, ["设计一个", "产品方案", "用户需求", "优先级", "product case", "improve this product"]) { return .productCase }
        if matches(value, ["商业模式", "增长", "收入", "市场", "业务分析", "business case", "market size", "size this market", "market sizing"]) { return .businessAnalysis }
        if matches(value, ["具体一点", "为什么", "后来呢", "怎么衡量", "你本人", "如果重来", "why exactly", "how did you measure"]) { return .followUp }
        if value.contains("?") || value.contains("？") { return .professionalKnowledge }
        return .other
    }

    private static func matches(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}

struct InterviewGenerationRequest: Sendable {
    let id: UUID
    let model: String
    let prompt: String
    let promptCacheKey: String
    let maxOutputTokens: Int
    let kind: InterviewRequestKind
    let fastServiceTier: Bool
    let reasoningEffort: InterviewReasoningEffort
    let apiProtocol: InterviewAPIProtocol
    let apiBaseURL: String

    init(
        id: UUID,
        model: String,
        prompt: String,
        promptCacheKey: String,
        maxOutputTokens: Int,
        kind: InterviewRequestKind,
        fastServiceTier: Bool = false,
        reasoningEffort: InterviewReasoningEffort = .low,
        apiProtocol: InterviewAPIProtocol = .responses,
        apiBaseURL: String = "https://api.openai.com"
    ) {
        self.id = id
        self.model = model
        self.prompt = prompt
        self.promptCacheKey = promptCacheKey
        self.maxOutputTokens = maxOutputTokens
        self.kind = kind
        self.fastServiceTier = fastServiceTier
        self.reasoningEffort = reasoningEffort
        self.apiProtocol = apiProtocol
        self.apiBaseURL = apiBaseURL
    }
}

struct CopilotGenerationRequest: Codable, Sendable {
    let id: UUID
    let model: String
    let prompt: String
    let kind: InterviewRequestKind
    let maxOutputTokens: Int
    /// Requests Codex's separately metered priority service tier. This is not
    /// the interview speed-mode model selection, which is made by the engine.
    let fastServiceTier: Bool
    let reasoningEffort: InterviewReasoningEffort
}

struct CopilotWorkerMessage: Codable, Sendable {
    let command: String
    let id: UUID
    let model: String?
    let prompt: String?
    let kind: InterviewRequestKind?
    let maxOutputTokens: Int?
    let fastServiceTier: Bool?
    let reasoningEffort: InterviewReasoningEffort?

    static func generate(_ request: CopilotGenerationRequest) -> CopilotWorkerMessage {
        CopilotWorkerMessage(
            command: "generate",
            id: request.id,
            model: request.model,
            prompt: request.prompt,
            kind: request.kind,
            maxOutputTokens: request.maxOutputTokens,
            fastServiceTier: request.fastServiceTier,
            reasoningEffort: request.reasoningEffort
        )
    }

    static func cancel(id: UUID) -> CopilotWorkerMessage {
        CopilotWorkerMessage(
            command: "cancel",
            id: id,
            model: nil,
            prompt: nil,
            kind: nil,
            maxOutputTokens: nil,
            fastServiceTier: nil,
            reasoningEffort: nil
        )
    }

    static func prewarm(id: UUID) -> CopilotWorkerMessage {
        CopilotWorkerMessage(
            command: "prewarm",
            id: id,
            model: nil,
            prompt: nil,
            kind: nil,
            maxOutputTokens: nil,
            fastServiceTier: false,
            reasoningEffort: nil
        )
    }
}

struct CopilotWorkerEvent: Codable, Sendable {
    let event: String
    let id: UUID
    let response: String?
    let error: String?
    let delta: String?
    let transport: String?
}

struct CopilotHistoryRecord: Codable, Sendable, Identifiable {
    static let currentSchemaVersion = 7

    var schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let question: String
    let cue: InterviewCue?
    let state: CopilotGenerationState
    let promptVersion: String
    let knowledgePackageVersion: String
    let knowledgePackageHash: String
    let durationMilliseconds: Int?
    /// Time until the first safely renderable structured segment was available.
    let firstOutputMilliseconds: Int?
    let sessionID: String?
    let provider: InterviewProvider?
    let sourceUtteranceIDs: [UUID]
    let requestKind: InterviewRequestKind
    let supersedesRequestID: UUID?
    let audioMode: InterviewAudioMode?
    let asrProvider: InterviewASRProvider?
    let asrLatencyMilliseconds: Int?
    let manualBoundaryID: UUID?
    let fallbackUsed: Bool?
    let turnRevision: Int?
    /// Present for `referenceAnswer` records. Reference request state, provider,
    /// duration and turn revision continue to use the record's existing fields.
    let referenceAnswer: InterviewReferenceAnswer?
    /// Links a reference-answer request to the cue request that triggered it.
    let parentCueRequestID: UUID?
    /// Optional request model, added in schema v5 for latency comparisons.
    let model: String?
    /// Models attempted in order. `model` is the model that produced the saved result.
    let attemptedModels: [String]?
    /// Infrastructure or model error that caused generation to move to another model.
    let generationFallbackReason: String?
    /// Time until the transport emitted its first raw text delta.
    let firstDeltaMilliseconds: Int?
    /// Whether Codex app-server prewarm had completed when this request finished.
    let prewarmReady: Bool?
    let prewarmDurationMilliseconds: Int?
    let generationTransport: String?
    /// Present for third-stage follow-up-list records.
    let followUps: InterviewFollowUpSet?
    /// Present when the user asks the Copilot to answer one suggested follow-up.
    let followUpAnswer: InterviewFollowUpAnswer?
    let selectedFollowUpQuestion: String?
    let progressiveAnswer: InterviewProgressiveAnswer?
    let firstDeltaMs: Int?
    let firstUsefulEntryMs: Int?
    let spineReadyMs: Int?
    let answerCompleteMs: Int?
    let spineReadyMilliseconds: Int?
    let answerCompleteMilliseconds: Int?
    let fallbackTriggered: Bool?
    let ownerModel: String?
    let candidateStartedBeforeEntry: Bool?
    let revisionCount: Int?

    var isInterviewRecord: Bool { schemaVersion >= 2 }

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: UUID,
        createdAt: Date,
        question: String,
        cue: InterviewCue?,
        state: CopilotGenerationState,
        promptVersion: String,
        knowledgePackageVersion: String,
        knowledgePackageHash: String,
        durationMilliseconds: Int?,
        firstOutputMilliseconds: Int? = nil,
        sessionID: String?,
        provider: InterviewProvider?,
        sourceUtteranceIDs: [UUID],
        requestKind: InterviewRequestKind,
        supersedesRequestID: UUID?,
        audioMode: InterviewAudioMode? = nil,
        asrProvider: InterviewASRProvider? = nil,
        asrLatencyMilliseconds: Int? = nil,
        manualBoundaryID: UUID? = nil,
        fallbackUsed: Bool? = nil,
        turnRevision: Int? = nil,
        referenceAnswer: InterviewReferenceAnswer? = nil,
        parentCueRequestID: UUID? = nil,
        model: String? = nil,
        attemptedModels: [String]? = nil,
        generationFallbackReason: String? = nil,
        firstDeltaMilliseconds: Int? = nil,
        prewarmReady: Bool? = nil,
        prewarmDurationMilliseconds: Int? = nil,
        generationTransport: String? = nil,
        followUps: InterviewFollowUpSet? = nil,
        followUpAnswer: InterviewFollowUpAnswer? = nil,
        selectedFollowUpQuestion: String? = nil,
        progressiveAnswer: InterviewProgressiveAnswer? = nil,
        firstDeltaMs: Int? = nil,
        firstUsefulEntryMs: Int? = nil,
        spineReadyMs: Int? = nil,
        answerCompleteMs: Int? = nil,
        spineReadyMilliseconds: Int? = nil,
        answerCompleteMilliseconds: Int? = nil,
        fallbackTriggered: Bool? = nil,
        ownerModel: String? = nil,
        candidateStartedBeforeEntry: Bool? = nil,
        revisionCount: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.question = question
        self.cue = cue
        self.state = state
        self.promptVersion = promptVersion
        self.knowledgePackageVersion = knowledgePackageVersion
        self.knowledgePackageHash = knowledgePackageHash
        self.durationMilliseconds = durationMilliseconds
        self.firstOutputMilliseconds = firstOutputMilliseconds
        self.sessionID = sessionID
        self.provider = provider
        self.sourceUtteranceIDs = sourceUtteranceIDs
        self.requestKind = requestKind
        self.supersedesRequestID = supersedesRequestID
        self.audioMode = audioMode
        self.asrProvider = asrProvider
        self.asrLatencyMilliseconds = asrLatencyMilliseconds
        self.manualBoundaryID = manualBoundaryID
        self.fallbackUsed = fallbackUsed
        self.turnRevision = turnRevision
        self.referenceAnswer = referenceAnswer
        self.parentCueRequestID = parentCueRequestID
        self.model = model
        self.attemptedModels = attemptedModels
        self.generationFallbackReason = generationFallbackReason
        self.firstDeltaMilliseconds = firstDeltaMilliseconds
        self.prewarmReady = prewarmReady
        self.prewarmDurationMilliseconds = prewarmDurationMilliseconds
        self.generationTransport = generationTransport
        self.followUps = followUps
        self.followUpAnswer = followUpAnswer
        self.selectedFollowUpQuestion = selectedFollowUpQuestion
        self.progressiveAnswer = progressiveAnswer
        self.firstDeltaMs = firstDeltaMs
        self.firstUsefulEntryMs = firstUsefulEntryMs
        self.spineReadyMs = spineReadyMs
        self.answerCompleteMs = answerCompleteMs
        self.spineReadyMilliseconds = spineReadyMilliseconds
        self.answerCompleteMilliseconds = answerCompleteMilliseconds
        self.fallbackTriggered = fallbackTriggered
        self.ownerModel = ownerModel
        self.candidateStartedBeforeEntry = candidateStartedBeforeEntry
        self.revisionCount = revisionCount
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case createdAt
        case question
        case cue
        case state
        case promptVersion
        case knowledgePackageVersion
        case knowledgePackageHash
        case durationMilliseconds
        case firstOutputMilliseconds
        case sessionID
        case provider
        case sourceUtteranceIDs
        case requestKind
        case supersedesRequestID
        case audioMode
        case asrProvider
        case asrLatencyMilliseconds
        case manualBoundaryID
        case fallbackUsed
        case turnRevision
        case referenceAnswer
        case parentCueRequestID
        case model
        case attemptedModels
        case generationFallbackReason
        case firstDeltaMilliseconds
        case prewarmReady
        case prewarmDurationMilliseconds
        case generationTransport
        case followUps
        case followUpAnswer
        case selectedFollowUpQuestion
        case progressiveAnswer
        case firstDeltaMs
        case firstUsefulEntryMs
        case spineReadyMs
        case answerCompleteMs
        case spineReadyMilliseconds
        case answerCompleteMilliseconds
        case fallbackTriggered
        case ownerModel
        case candidateStartedBeforeEntry
        case revisionCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 1
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        question = try container.decode(String.self, forKey: .question)
        cue = try? container.decodeIfPresent(InterviewCue.self, forKey: .cue)
        state = Self.decodeRawValue(
            CopilotGenerationState.self,
            from: container,
            key: .state,
            default: .completed
        )
        promptVersion = (try? container.decode(String.self, forKey: .promptVersion)) ?? "legacy"
        knowledgePackageVersion = (try? container.decode(String.self, forKey: .knowledgePackageVersion)) ?? "legacy"
        knowledgePackageHash = (try? container.decode(String.self, forKey: .knowledgePackageHash)) ?? "legacy"
        durationMilliseconds = try? container.decodeIfPresent(Int.self, forKey: .durationMilliseconds)
        firstOutputMilliseconds = try? container.decodeIfPresent(Int.self, forKey: .firstOutputMilliseconds)
        sessionID = try? container.decodeIfPresent(String.self, forKey: .sessionID)
        provider = Self.decodeOptionalRawValue(InterviewProvider.self, from: container, key: .provider)
        sourceUtteranceIDs = (try? container.decode([UUID].self, forKey: .sourceUtteranceIDs)) ?? []
        requestKind = Self.decodeRawValue(
            InterviewRequestKind.self,
            from: container,
            key: .requestKind,
            default: .cue
        )
        supersedesRequestID = try? container.decodeIfPresent(UUID.self, forKey: .supersedesRequestID)
        audioMode = Self.decodeOptionalRawValue(InterviewAudioMode.self, from: container, key: .audioMode)
        asrProvider = Self.decodeOptionalRawValue(InterviewASRProvider.self, from: container, key: .asrProvider)
        asrLatencyMilliseconds = try? container.decodeIfPresent(Int.self, forKey: .asrLatencyMilliseconds)
        manualBoundaryID = try? container.decodeIfPresent(UUID.self, forKey: .manualBoundaryID)
        fallbackUsed = try? container.decodeIfPresent(Bool.self, forKey: .fallbackUsed)
        turnRevision = try? container.decodeIfPresent(Int.self, forKey: .turnRevision)
        referenceAnswer = try? container.decodeIfPresent(InterviewReferenceAnswer.self, forKey: .referenceAnswer)
        parentCueRequestID = try? container.decodeIfPresent(UUID.self, forKey: .parentCueRequestID)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        attemptedModels = try? container.decodeIfPresent([String].self, forKey: .attemptedModels)
        generationFallbackReason = try? container.decodeIfPresent(String.self, forKey: .generationFallbackReason)
        firstDeltaMilliseconds = try? container.decodeIfPresent(Int.self, forKey: .firstDeltaMilliseconds)
        prewarmReady = try? container.decodeIfPresent(Bool.self, forKey: .prewarmReady)
        prewarmDurationMilliseconds = try? container.decodeIfPresent(Int.self, forKey: .prewarmDurationMilliseconds)
        generationTransport = try? container.decodeIfPresent(String.self, forKey: .generationTransport)
        followUps = try? container.decodeIfPresent(InterviewFollowUpSet.self, forKey: .followUps)
        followUpAnswer = try? container.decodeIfPresent(InterviewFollowUpAnswer.self, forKey: .followUpAnswer)
        selectedFollowUpQuestion = try? container.decodeIfPresent(String.self, forKey: .selectedFollowUpQuestion)
        progressiveAnswer = try? container.decodeIfPresent(InterviewProgressiveAnswer.self, forKey: .progressiveAnswer)
        firstDeltaMs = try? container.decodeIfPresent(Int.self, forKey: .firstDeltaMs)
        firstUsefulEntryMs = try? container.decodeIfPresent(Int.self, forKey: .firstUsefulEntryMs)
        spineReadyMs = try? container.decodeIfPresent(Int.self, forKey: .spineReadyMs)
        answerCompleteMs = try? container.decodeIfPresent(Int.self, forKey: .answerCompleteMs)
        spineReadyMilliseconds = try? container.decodeIfPresent(Int.self, forKey: .spineReadyMilliseconds)
        answerCompleteMilliseconds = try? container.decodeIfPresent(Int.self, forKey: .answerCompleteMilliseconds)
        fallbackTriggered = try? container.decodeIfPresent(Bool.self, forKey: .fallbackTriggered)
        ownerModel = try? container.decodeIfPresent(String.self, forKey: .ownerModel)
        candidateStartedBeforeEntry = try? container.decodeIfPresent(Bool.self, forKey: .candidateStartedBeforeEntry)
        revisionCount = try? container.decodeIfPresent(Int.self, forKey: .revisionCount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(question, forKey: .question)
        try container.encodeIfPresent(cue, forKey: .cue)
        try container.encode(state.rawValue, forKey: .state)
        try container.encode(promptVersion, forKey: .promptVersion)
        try container.encode(knowledgePackageVersion, forKey: .knowledgePackageVersion)
        try container.encode(knowledgePackageHash, forKey: .knowledgePackageHash)
        try container.encodeIfPresent(durationMilliseconds, forKey: .durationMilliseconds)
        try container.encodeIfPresent(firstOutputMilliseconds, forKey: .firstOutputMilliseconds)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(provider?.rawValue, forKey: .provider)
        try container.encode(sourceUtteranceIDs, forKey: .sourceUtteranceIDs)
        try container.encode(requestKind.rawValue, forKey: .requestKind)
        try container.encodeIfPresent(supersedesRequestID, forKey: .supersedesRequestID)
        try container.encodeIfPresent(audioMode?.rawValue, forKey: .audioMode)
        try container.encodeIfPresent(asrProvider?.rawValue, forKey: .asrProvider)
        try container.encodeIfPresent(asrLatencyMilliseconds, forKey: .asrLatencyMilliseconds)
        try container.encodeIfPresent(manualBoundaryID, forKey: .manualBoundaryID)
        try container.encodeIfPresent(fallbackUsed, forKey: .fallbackUsed)
        try container.encodeIfPresent(turnRevision, forKey: .turnRevision)
        try container.encodeIfPresent(referenceAnswer, forKey: .referenceAnswer)
        try container.encodeIfPresent(parentCueRequestID, forKey: .parentCueRequestID)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(attemptedModels, forKey: .attemptedModels)
        try container.encodeIfPresent(generationFallbackReason, forKey: .generationFallbackReason)
        try container.encodeIfPresent(firstDeltaMilliseconds, forKey: .firstDeltaMilliseconds)
        try container.encodeIfPresent(prewarmReady, forKey: .prewarmReady)
        try container.encodeIfPresent(prewarmDurationMilliseconds, forKey: .prewarmDurationMilliseconds)
        try container.encodeIfPresent(generationTransport, forKey: .generationTransport)
        try container.encodeIfPresent(followUps, forKey: .followUps)
        try container.encodeIfPresent(followUpAnswer, forKey: .followUpAnswer)
        try container.encodeIfPresent(selectedFollowUpQuestion, forKey: .selectedFollowUpQuestion)
        try container.encodeIfPresent(progressiveAnswer, forKey: .progressiveAnswer)
        try container.encodeIfPresent(firstDeltaMs, forKey: .firstDeltaMs)
        try container.encodeIfPresent(firstUsefulEntryMs, forKey: .firstUsefulEntryMs)
        try container.encodeIfPresent(spineReadyMs, forKey: .spineReadyMs)
        try container.encodeIfPresent(answerCompleteMs, forKey: .answerCompleteMs)
        try container.encodeIfPresent(spineReadyMilliseconds, forKey: .spineReadyMilliseconds)
        try container.encodeIfPresent(answerCompleteMilliseconds, forKey: .answerCompleteMilliseconds)
        try container.encodeIfPresent(fallbackTriggered, forKey: .fallbackTriggered)
        try container.encodeIfPresent(ownerModel, forKey: .ownerModel)
        try container.encodeIfPresent(candidateStartedBeforeEntry, forKey: .candidateStartedBeforeEntry)
        try container.encodeIfPresent(revisionCount, forKey: .revisionCount)
    }

    private static func decodeRawValue<T: RawRepresentable, K: CodingKey>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<K>,
        key: K,
        default defaultValue: T
    ) -> T where T.RawValue == String {
        guard let rawValue = try? container.decode(String.self, forKey: key) else { return defaultValue }
        return T(rawValue: rawValue) ?? defaultValue
    }

    private static func decodeOptionalRawValue<T: RawRepresentable, K: CodingKey>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<K>,
        key: K
    ) -> T? where T.RawValue == String {
        guard let rawValue = try? container.decode(String.self, forKey: key) else { return nil }
        return T(rawValue: rawValue)
    }
}

enum CopilotError: LocalizedError, Equatable {
    case contextTooLarge(estimated: Int, limit: Int)
    case emptyQuestion
    case missingAPIKey
    case authenticationFailed
    case rateLimited
    case serverUnavailable(Int)
    case invalidRequest(String)
    case network(String)
    case workerUnavailable(String)
    case invalidResponse
    case unsafeCandidateClaims
    case cancelled

    var errorDescription: String? {
        switch self {
        case .contextTooLarge(let estimated, let limit): "上下文过大（估算 \(estimated) tokens，上限 \(limit)）。请精简面试材料。"
        case .emptyQuestion: "当前没有可生成的面试官问题。"
        case .missingAPIKey: "未配置 OpenAI API key，将使用 Codex 订阅通路。"
        case .authenticationFailed: "OpenAI API key 无效或无权限，请在设置中检查。"
        case .rateLimited: "OpenAI API 请求过于频繁，已切换到 Codex 订阅通路。"
        case .serverUnavailable(let code): "OpenAI API 暂时不可用（HTTP \(code)）。"
        case .invalidRequest(let message): "OpenAI API 请求无效：\(message)"
        case .network(let message): "网络请求失败：\(message)"
        case .workerUnavailable(let message): "Codex worker 不可用：\(message)"
        case .invalidResponse: "模型返回了无法解析的面试提示。"
        case .unsafeCandidateClaims: "参考回答含有无法验证的个人经历，已拦截相关表述。"
        case .cancelled: "本次生成已停止。"
        }
    }
}
