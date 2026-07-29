import XCTest
@testable import LiveInterviewCopilotKit

@MainActor
final class InterviewLensPresentationTests: XCTestCase {
    func testAnsweringSnapshotAppliesLateContentImmediately() {
        let state = makeState()
        state.activate(.quickIdea, initialSnapshot: snapshot(text: "原始提示"))
        state.receive(snapshot(text: "原始提示", frozen: true))

        state.receive(snapshot(text: "晚到的个性化提示", frozen: true))

        XCTAssertEqual(state.snapshot?.units.first?.text, "晚到的个性化提示")
        XCTAssertTrue(state.snapshot?.isFrozen == true)
    }

    func testEmptyCardAcceptsSuccessiveStreamingResultsWhileAnswering() {
        let state = makeState()
        state.activate(
            .referenceAnswer,
            initialSnapshot: snapshot(selection: .referenceAnswer, text: nil, frozen: true)
        )

        state.receive(snapshot(selection: .referenceAnswer, text: "第一条稳定结果", frozen: true))
        XCTAssertEqual(state.snapshot?.units.first?.text, "第一条稳定结果")

        state.receive(snapshot(selection: .referenceAnswer, text: "第二条晚到结果", frozen: true))
        XCTAssertEqual(state.snapshot?.units.first?.text, "第二条晚到结果")
    }

    func testQuestionPartialDoesNotBlockFirstConfirmedQuestionAfterFreeze() {
        let state = makeState()
        let partial = InterviewLensSnapshot(
            turnToken: "turn-1",
            questionContext: "请说说一个复…",
            units: [InterviewLensSemanticUnit(
                id: "question.partial",
                kind: .other,
                text: "请说说一个复…",
                label: "识别中"
            )],
            isFrozen: true,
            selection: .question
        )
        state.activate(.question, initialSnapshot: partial)

        let confirmed = InterviewLensSnapshot(
            turnToken: "turn-1",
            questionContext: "请说说一个复杂项目。",
            units: [InterviewLensSemanticUnit(
                id: "question.confirmed",
                kind: .question,
                text: "请说说一个复杂项目。"
            )],
            isFrozen: true,
            selection: .question
        )
        state.receive(confirmed)

        XCTAssertEqual(state.snapshot?.units.first?.text, "请说说一个复杂项目。")
    }

    func testFollowUpQuestionHeaderDoesNotBlockFirstStableAnswerAfterFreeze() {
        let selection = InterviewLensSelection.followUpAnswer(question: "为什么这样判断？")
        let headerOnly = InterviewLensSnapshot(
            turnToken: "turn-1",
            questionContext: "原问题",
            units: [InterviewLensSemanticUnit(
                id: "follow-up-answer.question",
                kind: .followUpQuestion,
                text: "为什么这样判断？",
                label: "追问"
            )],
            isFrozen: true,
            selection: selection
        )
        let state = makeState()
        state.activate(selection, initialSnapshot: headerOnly)

        var withAnswer = headerOnly
        withAnswer.units.append(InterviewLensSemanticUnit(
            id: "follow-up-answer.opening",
            kind: .directOpening,
            text: "我主要基于用户影响和证据强度判断。",
            label: "直接开场"
        ))
        state.receive(withAnswer)

        XCTAssertEqual(state.snapshot?.units.count, 2)
    }

    func testNewTurnFollowsSameSelectionAndReturnsToFirstPage() {
        let state = makeState(panelSize: CGSize(width: 440, height: 220), scale: .percent200)
        let longText = String(repeating: "这是一个需要分页的完整句子。", count: 30)
        state.activate(
            .referenceAnswer,
            initialSnapshot: snapshot(
                turn: "turn-1",
                selection: .referenceAnswer,
                text: longText
            )
        )
        XCTAssertGreaterThan(state.pages.count, 1)
        state.nextPage()
        XCTAssertEqual(state.pageIndex, 1)

        state.receive(snapshot(
            turn: "turn-2",
            selection: .referenceAnswer,
            text: "新题的完整回答"
        ))

        XCTAssertEqual(state.activeSelection, .referenceAnswer)
        XCTAssertEqual(state.snapshot?.turnToken, "turn-2")
        XCTAssertEqual(state.pageIndex, 0)
        XCTAssertEqual(state.snapshot?.units.first?.text, "新题的完整回答")
    }

    func testFollowUpAnswerFallsBackToQuickIdeaOnNewTurn() {
        let selection = InterviewLensSelection.followUpAnswer(question: "为什么这样判断？")
        let state = makeState()
        state.activate(
            selection,
            initialSnapshot: snapshot(turn: "turn-1", selection: selection, text: "回答")
        )

        let result = state.receive(snapshot(
            turn: "turn-2",
            selection: selection,
            text: "旧追问不应跨题跟随"
        ))

        XCTAssertEqual(result, .selectionChanged(.answer))
        XCTAssertEqual(state.activeSelection, .answer)
        XCTAssertNil(state.snapshot)
        XCTAssertTrue(state.pages.isEmpty)
    }

    func testFailureRetainsLastStableContent() throws {
        let state = makeState()
        state.activate(.quickIdea, initialSnapshot: snapshot(text: "保留这版"))
        let failure = InterviewLensFailure(
            message: "生成中断",
            recoverySuggestion: "重试"
        )

        state.receive(snapshot(text: nil, failure: failure))

        XCTAssertEqual(state.snapshot?.units.first?.text, "保留这版")
        XCTAssertEqual(state.snapshot?.failure, failure)
        XCTAssertEqual(try XCTUnwrap(state.currentPage).text, "保留这版")
    }

    func testFollowUpRegenerationRetainsStableAnswerUntilReplacementCompletes() {
        let selection = InterviewLensSelection.followUpAnswer(question: "为什么这样判断？")
        let state = makeState()
        let questionUnit = InterviewLensSemanticUnit(
            id: "follow-up-answer.question",
            kind: .followUpQuestion,
            text: "为什么这样判断？",
            label: "追问"
        )
        let oldOpening = InterviewLensSemanticUnit(
            id: "follow-up-answer.opening",
            kind: .directOpening,
            text: "旧的稳定回答",
            label: "直接开场"
        )
        state.activate(selection, initialSnapshot: InterviewLensSnapshot(
            turnToken: "turn-1",
            questionContext: "原问题",
            units: [questionUnit, oldOpening],
            selection: selection
        ))

        state.receive(InterviewLensSnapshot(
            turnToken: "turn-1",
            questionContext: "原问题",
            units: [questionUnit],
            selection: selection
        ))
        XCTAssertEqual(state.snapshot?.units.last?.text, "旧的稳定回答")

        let failure = InterviewLensFailure(message: "重新生成失败")
        state.receive(InterviewLensSnapshot(
            turnToken: "turn-1",
            questionContext: "原问题",
            units: [questionUnit],
            failure: failure,
            selection: selection
        ))
        XCTAssertEqual(state.snapshot?.units.last?.text, "旧的稳定回答")
        XCTAssertEqual(state.snapshot?.failure, failure)

        let newOpening = InterviewLensSemanticUnit(
            id: "follow-up-answer.opening",
            kind: .directOpening,
            text: "新的稳定回答",
            label: "直接开场"
        )
        state.receive(InterviewLensSnapshot(
            turnToken: "turn-1",
            questionContext: "原问题",
            units: [questionUnit, newOpening],
            selection: selection
        ))
        XCTAssertEqual(state.snapshot?.units.last?.text, "新的稳定回答")
    }

    func testLensNeverReservesQuestionContextSpace() {
        let state = makeState()
        state.activate(.quickIdea, initialSnapshot: snapshot(text: "一条稳定提示"))

        state.updateLayout(
            panelSize: CGSize(width: 440, height: 175),
            fontScale: .percent200
        )
        XCTAssertFalse(state.showsQuestionContext)
        XCTAssertFalse(state.pages.isEmpty)

        state.updateLayout(
            panelSize: CGSize(width: 440, height: 220),
            fontScale: .percent200
        )
        XCTAssertFalse(state.showsQuestionContext)
    }

    func testRepaginationPreservesSourceAnchor() throws {
        let state = makeState(panelSize: CGSize(width: 440, height: 220), scale: .percent200)
        let text = String(repeating: "先说明结论，再解释依据和边界。", count: 40)
        state.activate(.quickIdea, initialSnapshot: snapshot(text: text))
        XCTAssertGreaterThan(state.pages.count, 2)
        state.nextPage()
        state.nextPage()
        let oldAnchor = try XCTUnwrap(state.currentPage?.items.first?.anchor)

        state.updateLayout(
            panelSize: CGSize(width: 680, height: 360),
            fontScale: .percent150
        )

        let newPage = try XCTUnwrap(state.currentPage)
        XCTAssertTrue(newPage.items.contains { item in
            item.anchor.sourceID == oldAnchor.sourceID
                && item.anchor.lowerBound <= oldAnchor.lowerBound
                && item.anchor.upperBound > oldAnchor.lowerBound
        })
    }

    func testStreamingGrowthPreservesCurrentSourceAnchor() throws {
        let state = makeState(panelSize: CGSize(width: 440, height: 220), scale: .percent175)
        let initialText = String(repeating: "先说结论，再解释依据。", count: 24)
        state.activate(
            .referenceAnswer,
            initialSnapshot: snapshot(selection: .referenceAnswer, text: initialText)
        )
        XCTAssertGreaterThan(state.pages.count, 1)
        state.nextPage()
        let oldAnchor = try XCTUnwrap(state.currentPage?.items.first?.anchor)

        state.receive(snapshot(
            selection: .referenceAnswer,
            text: initialText + String(repeating: "最后补充边界和复盘。", count: 18),
            frozen: true
        ))

        let newPage = try XCTUnwrap(state.currentPage)
        XCTAssertTrue(newPage.items.contains { item in
            item.anchor.sourceID == oldAnchor.sourceID
                && item.anchor.lowerBound <= oldAnchor.lowerBound
                && item.anchor.upperBound > oldAnchor.lowerBound
        })
        XCTAssertTrue(state.snapshot?.isFrozen == true)
    }

    func testStreamingGrowthNeverMovesReaderToLatestPage() {
        let state = makeState(panelSize: CGSize(width: 440, height: 220), scale: .percent175)
        state.activate(
            .referenceAnswer,
            initialSnapshot: snapshot(selection: .referenceAnswer, text: "实时开场")
        )
        XCTAssertEqual(state.pageIndex, 0)

        state.receive(snapshot(
            selection: .referenceAnswer,
            text: "实时开场" + String(repeating: "，继续补充新的回答内容", count: 40),
            streaming: true
        ))

        XCTAssertGreaterThan(state.pages.count, 1)
        XCTAssertEqual(state.pageIndex, 0)
    }

    func testPreferredPanelHeightGrowsWithCurrentCardContent() {
        let state = InterviewLensPresentationState()
        state.updateLayout(
            panelSize: CGSize(width: 560, height: 288),
            fontScale: .percent115,
            maximumPanelHeight: 760
        )
        state.activate(.quickIdea, initialSnapshot: snapshot(text: "一句短提示"))
        let shortHeight = state.preferredPanelHeight

        state.receive(snapshot(
            text: String(repeating: "这是一段需要更多垂直空间的回答内容。", count: 12),
            frozen: true
        ))

        XCTAssertGreaterThan(state.preferredPanelHeight, shortHeight)
        XCTAssertLessThanOrEqual(state.preferredPanelHeight, 760)
    }

    private func makeState(
        panelSize: CGSize = CGSize(width: 560, height: 288),
        scale: InterviewLensFontScale = .percent115
    ) -> InterviewLensPresentationState {
        let state = InterviewLensPresentationState()
        state.updateLayout(panelSize: panelSize, fontScale: scale)
        return state
    }

    private func snapshot(
        turn: String = "turn-1",
        selection: InterviewLensSelection = .quickIdea,
        text: String?,
        frozen: Bool = false,
        streaming: Bool = false,
        failure: InterviewLensFailure? = nil
    ) -> InterviewLensSnapshot {
        let units = text.map {
            [InterviewLensSemanticUnit(
                id: "stable-unit",
                kind: .quickIdea,
                text: $0
            )]
        } ?? []
        return InterviewLensSnapshot(
            turnToken: turn,
            questionContext: "当前问题",
            units: units,
            isFrozen: frozen,
            isStreaming: streaming,
            failure: failure,
            selection: selection
        )
    }
}
