import AppKit
import Foundation
import Observation

extension InterviewLensSelection {
    var title: String {
        switch self {
        case .question: "当前问题"
        case .answer: "参考回答"
        case .quickIdea: "快速思路"
        case .referenceAnswer: "完整回答"
        case .followUps: "可能追问"
        case .followUpAnswer: "追问回答"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .question: return "question"
        case .answer: return "answer"
        case .quickIdea: return "quickIdea"
        case .referenceAnswer: return "referenceAnswer"
        case .followUps: return "followUps"
        case .followUpAnswer(let question):
            let fingerprint = question.utf8.reduce(UInt64(1_469_598_103_934_665_603)) {
                ($0 ^ UInt64($1)) &* 1_099_511_628_211
            }
            return "followUpAnswer.\(String(fingerprint, radix: 16))"
        }
    }

    var persistentSelection: InterviewLensPersistentSelection? {
        switch self {
        case .question: .answer
        case .answer, .quickIdea, .referenceAnswer: .answer
        case .followUps: .followUps
        case .followUpAnswer: nil
        }
    }
}

extension InterviewLensPersistentSelection {
    var runtimeSelection: InterviewLensSelection {
        switch self {
        case .question: .answer
        case .answer: .answer
        case .quickIdea, .referenceAnswer: .answer
        case .followUps: .followUps
        }
    }
}

/// Converts the mutable interview engine into semantic units. Reference-answer
/// segments can be incomplete while streaming; their stable IDs let pagination
/// preserve the reader's position as text grows.
@MainActor
enum InterviewLensProjector {
    static func snapshot(
        from engine: CustomerCopilotEngine,
        selection: InterviewLensSelection
    ) -> InterviewLensSnapshot {
        let question = engine.currentQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let partial = engine.asrPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        let questionContext = question.isEmpty ? partial : question

        return InterviewLensSnapshot(
            turnToken: engine.interviewTurnToken.uuidString,
            questionContext: questionContext,
            units: units(
                from: engine,
                selection: selection,
                confirmedQuestion: question,
                partialQuestion: partial
            ),
            isFrozen: engine.isAnswerFrozen,
            isStreaming: isStreaming(engine, selection: selection),
            failure: failure(from: engine, selection: selection),
            selection: selection,
            navigationSelections: navigationSelections(from: engine, active: selection)
        )
    }

    private static func isStreaming(
        _ engine: CustomerCopilotEngine,
        selection: InterviewLensSelection
    ) -> Bool {
        switch selection {
        case .question:
            return engine.currentQuestion.isEmpty && !engine.asrPartialText.isEmpty
        case .answer:
            return engine.referenceGenerationState == .generating
        case .quickIdea:
            return engine.generationState == .generating
                || engine.generationState == .waitingForEndpoint
        case .referenceAnswer:
            return engine.referenceGenerationState == .generating
        case .followUps:
            return engine.followUpGenerationState == .generating
        case .followUpAnswer(let question):
            return engine.followUpAnswerState(for: question) == .generating
        }
    }

    private static func navigationSelections(
        from engine: CustomerCopilotEngine,
        active: InterviewLensSelection
    ) -> [InterviewLensSelection] {
        var result: [InterviewLensSelection] = [.answer]
        if engine.followUpSuggestions != nil || engine.followUpGenerationState != .idle {
            result.append(.followUps)
        }
        if active != .question, !result.contains(active) {
            result.append(active)
        }
        return result
    }

    private static func units(
        from engine: CustomerCopilotEngine,
        selection: InterviewLensSelection,
        confirmedQuestion: String,
        partialQuestion: String
    ) -> [InterviewLensSemanticUnit] {
        switch selection {
        case .question:
            var result: [InterviewLensSemanticUnit] = []
            if !confirmedQuestion.isEmpty {
                result.append(unit(
                    id: "question.confirmed",
                    kind: .question,
                    text: confirmedQuestion
                ))
            } else if !partialQuestion.isEmpty {
                result.append(unit(
                    id: "question.partial",
                    kind: .other,
                    text: partialQuestion,
                    label: "识别中"
                ))
            }
            return result

        case .answer:
            let entry = engine.progressiveAnswer?.entry ?? engine.answerProgress.entry
            let spine = engine.progressiveAnswer?.spine ?? engine.answerProgress.spine
            let segments = engine.progressiveAnswer?.segments ?? engine.answerProgress.segments
            let segmentByPointID = Dictionary(
                uniqueKeysWithValues: segments.map { ($0.pointID, $0) }
            )
            var result: [InterviewLensSemanticUnit] = []
            if entry != nil || !spine.isEmpty {
                let opening = entry?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let outline = spine.prefix(4).enumerated().map { index, point in
                    "\(index + 1). \(point.label.trimmingCharacters(in: .whitespacesAndNewlines))"
                }.joined(separator: "\n")
                if !opening.isEmpty {
                    result.append(unit(
                        id: "answer.overview.opening",
                        kind: .directOpening,
                        text: opening,
                        label: "先说这句"
                    ))
                }
                if !outline.isEmpty {
                    result.append(unit(
                        id: "answer.overview.spine",
                        kind: .quickIdea,
                        text: outline,
                        label: "逻辑主线"
                    ))
                }
            }
            result.append(contentsOf: spine.prefix(4).enumerated().compactMap { index, point in
                guard let segment = segmentByPointID[point.id] else { return nil }
                let detail = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !detail.isEmpty else { return nil }
                return unit(
                    id: "answer.point.\(point.id)",
                    kind: .talkingPoint,
                    text: detail,
                    label: "\(index + 1). \(point.label.trimmingCharacters(in: .whitespacesAndNewlines))",
                    startNewPage: true
                )
            })
            return result

        case .quickIdea:
            let items: [InterviewLiveSupplementItem]
            if engine.generationState == .generating, !engine.cuePreviewItems.isEmpty {
                items = engine.cuePreviewItems
            } else {
                let cue = engine.supplementalSuggestion ?? engine.suggestion
                items = InterviewLiveSupplementComposer.compose(
                    supplementalCue: cue,
                    referenceAnswer: nil,
                    primaryCueFallback: nil,
                    candidateIsAnswering: true
                )
            }
            return items.prefix(3).enumerated().map { index, item in
                unit(
                    id: "quick-idea.\(index)",
                    kind: .quickIdea,
                    text: item.text
                )
            }

        case .referenceAnswer:
            let segments = engine.referenceAnswer?.segments
                ?? engine.referenceAnswerPreviewSegments
            return segments.prefix(3).enumerated().map { index, segment in
                unit(
                    id: "reference.\(index)",
                    kind: .referenceSegment,
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    label: segment.label.trimmingCharacters(in: .whitespacesAndNewlines),
                    startNewPage: true
                )
            }

        case .followUps:
            return (engine.followUpSuggestions?.items ?? []).prefix(3).enumerated().map { index, item in
                let question = item.question.trimmingCharacters(in: .whitespacesAndNewlines)
                let answer = engine.followUpAnswer(for: item.question)
                return unit(
                    id: "follow-up.\(index)",
                    kind: .followUpAnswer,
                    text: detailedFollowUpText(answer) ?? "正在生成回答…",
                    label: "追问 \(index + 1)｜\(question)",
                    startNewPage: true
                )
            }

        case .followUpAnswer(let question):
            let normalizedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
            return [unit(
                id: "follow-up-answer.paired",
                kind: .followUpAnswer,
                text: detailedFollowUpText(engine.followUpAnswer(for: question)) ?? "正在生成回答…",
                label: normalizedQuestion,
                startNewPage: true
            )]
        }
    }

    private static func detailedFollowUpText(_ answer: InterviewFollowUpAnswer?) -> String? {
        guard let answer else { return nil }
        let sample = answer.sampleAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sample.isEmpty { return sample }

        let opening = answer.directOpening.trimmingCharacters(in: .whitespacesAndNewlines)
        let points = answer.talkingPoints.prefix(4).enumerated().compactMap { index, point -> String? in
            let text = point.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : "\(index + 1). \(text)"
        }
        let combined = ([opening] + points).filter { !$0.isEmpty }.joined(separator: "\n")
        return combined.isEmpty ? nil : combined
    }

    private static func failure(
        from engine: CustomerCopilotEngine,
        selection: InterviewLensSelection
    ) -> InterviewLensFailure? {
        switch selection {
        case .question:
            return nil
        case .answer where engine.referenceGenerationState == .failed:
            return InterviewLensFailure(
                message: engine.referenceErrorMessage ?? "参考回答生成中断",
                recoverySuggestion: "重试参考回答"
            )
        case .quickIdea where engine.generationState == .failed:
            return InterviewLensFailure(
                message: engine.errorMessage ?? "快速思路生成中断",
                recoverySuggestion: "重试生成"
            )
        case .referenceAnswer where engine.referenceGenerationState == .failed:
            return InterviewLensFailure(
                message: engine.referenceErrorMessage ?? "完整回答生成中断",
                recoverySuggestion: "重试完整回答"
            )
        case .followUps where engine.followUpGenerationState == .failed:
            return InterviewLensFailure(
                message: engine.followUpErrorMessage ?? "可能追问生成中断",
                recoverySuggestion: "重试可能追问"
            )
        case .followUpAnswer(let question) where engine.followUpAnswerState(for: question) == .failed:
            return InterviewLensFailure(
                message: engine.followUpAnswerError(for: question) ?? "追问回答生成中断",
                recoverySuggestion: "重试追问回答"
            )
        default:
            return nil
        }
    }

    private static func unit(
        id: String,
        kind: InterviewLensSemanticUnit.Kind,
        text: String,
        label: String? = nil,
        startNewPage: Bool = false
    ) -> InterviewLensSemanticUnit {
        InterviewLensSemanticUnit(
            id: id,
            kind: kind,
            text: text,
            label: label,
            startNewPage: startNewPage
        )
    }
}

@Observable
@MainActor
final class InterviewLensPresentationState {
    static let panelChromeHeight: CGFloat = 102

    enum Reception: Equatable {
        case unchanged
        case selectionChanged(InterviewLensSelection)
    }

    private(set) var activeSelection: InterviewLensSelection?
    private(set) var snapshot: InterviewLensSnapshot?
    private(set) var pages: [InterviewLensPage] = []
    private(set) var pageIndex = 0
    private(set) var showsQuestionContext = false

    private var configuration = InterviewLensPaginator.Configuration()

    var currentPage: InterviewLensPage? {
        guard pages.indices.contains(pageIndex) else { return nil }
        return pages[pageIndex]
    }

    var canGoBack: Bool { pageIndex > 0 }
    var canGoForward: Bool { pageIndex + 1 < pages.count }

    var preferredPanelHeight: CGFloat {
        guard let currentPage else { return Self.panelChromeHeight + 48 }
        let contentHeight = InterviewLensPaginator.measuredContentHeight(
            of: currentPage,
            configuration: configuration
        )
        return ceil(Self.panelChromeHeight + contentHeight + 2)
    }

    func activate(
        _ selection: InterviewLensSelection,
        initialSnapshot: InterviewLensSnapshot
    ) {
        activeSelection = selection
        snapshot = initialSnapshot
        rebuildPages(resetToFirstPage: true)
    }

    func clear() {
        activeSelection = nil
        snapshot = nil
        pages = []
        pageIndex = 0
        showsQuestionContext = false
    }

    @discardableResult
    func receive(_ projected: InterviewLensSnapshot) -> Reception {
        guard projected.selection == activeSelection else { return .unchanged }
        guard var current = snapshot else {
            activate(projected.selection, initialSnapshot: projected)
            return .unchanged
        }

        if current.turnToken != projected.turnToken {
            if case .followUpAnswer = current.selection {
                let fallback = InterviewLensSelection.answer
                activeSelection = fallback
                snapshot = nil
                pages = []
                pageIndex = 0
                return .selectionChanged(fallback)
            }

            snapshot = projected
            rebuildPages(resetToFirstPage: true)
            return .unchanged
        }

        let contentChanged = current.questionContext != projected.questionContext
            || current.units != projected.units

        if !projected.hasStableLensContent, current.hasStableLensContent {
            current.failure = projected.failure
            current.isStreaming = projected.isStreaming
            current.navigationSelections = projected.navigationSelections
            current.isFrozen = projected.isFrozen
            snapshot = current
            return .unchanged
        }

        snapshot = projected
        if contentChanged {
            rebuildPages(resetToFirstPage: false)
        }
        return .unchanged
    }

    func updateLayout(
        panelSize: CGSize,
        fontScale: InterviewLensFontScale,
        maximumPanelHeight: CGFloat? = nil
    ) {
        let fontSize = CGFloat(18 * fontScale.multiplier)
        let systemLineHeight = NSFont.systemFont(ofSize: fontSize).boundingRectForFont.height
        let lineSpacing = max(0, fontSize * 1.4 - systemLineHeight)
        showsQuestionContext = false
        let availableHeight = max(
            1,
            (maximumPanelHeight ?? panelSize.height) - Self.panelChromeHeight - 2
        )
        let bodyHeight = activeSelection == .question
            ? min(availableHeight, fontSize * 1.4 * 3)
            : availableHeight
        let next = InterviewLensPaginator.Configuration(
            fontSize: fontSize,
            width: max(1, panelSize.width - 32),
            height: bodyHeight,
            lineSpacing: lineSpacing,
            unitSpacing: 8,
            labelSpacing: 6,
            maximumPages: 12,
            overflowMessage: "其余内容请在主窗口查看"
        )
        guard next != configuration else { return }
        configuration = next
        rebuildPages(resetToFirstPage: false)
    }

    func previousPage() {
        guard canGoBack else { return }
        pageIndex -= 1
    }

    func nextPage() {
        guard canGoForward else { return }
        pageIndex += 1
    }

    func goToFirstPage() {
        pageIndex = 0
    }

    func goToLastPage() {
        pageIndex = max(0, pages.count - 1)
    }

    private func rebuildPages(resetToFirstPage: Bool) {
        let previousAnchor = resetToFirstPage ? nil : currentReadingAnchor
        pages = snapshot.map {
            InterviewLensPaginator.paginate(snapshot: $0, configuration: configuration)
        } ?? []

        guard !pages.isEmpty else {
            pageIndex = 0
            return
        }
        if resetToFirstPage {
            pageIndex = 0
        } else if let previousAnchor,
                  let anchoredIndex = pageIndex(containing: previousAnchor) {
            pageIndex = anchoredIndex
        } else {
            pageIndex = min(pageIndex, pages.count - 1)
        }
    }

    private var currentReadingAnchor: InterviewLensTextAnchor? {
        currentPage?.items.first?.anchor
    }

    private func pageIndex(containing anchor: InterviewLensTextAnchor) -> Int? {
        if let exact = pages.firstIndex(where: { page in
            page.items.contains { item in
                item.anchor.sourceID == anchor.sourceID
                    && item.anchor.lowerBound <= anchor.lowerBound
                    && item.anchor.upperBound > anchor.lowerBound
            }
        }) {
            return exact
        }

        return pages.lastIndex(where: { page in
            page.items.contains { item in
                item.anchor.sourceID == anchor.sourceID
                    && item.anchor.lowerBound <= anchor.lowerBound
            }
        })
    }
}

private extension InterviewLensSnapshot {
    /// Structural context can be useful while an answer is regenerating, but it
    /// should not erase the last useful text until replacement content arrives.
    var hasStableLensContent: Bool {
        switch selection {
        case .question:
            return units.contains { $0.kind == .question }
        case .followUpAnswer:
            return units.contains {
                switch $0.kind {
                case .directOpening, .talkingPoint, .followUpAnswer, .sampleAnswer:
                    return true
                default:
                    return false
                }
            }
        case .answer, .quickIdea, .referenceAnswer, .followUps:
            return !units.isEmpty
        }
    }
}
