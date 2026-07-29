import Foundation
import XCTest
@testable import LiveInterviewCopilotKit

final class InterviewGenerationProviderTests: XCTestCase {
    func testReferenceAnswerRoundTripsWithPerSegmentCitations() throws {
        let answer = InterviewReferenceAnswer(
            segments: [
                .init(label: "结论", text: "我会先确认目标。", sourceIDs: []),
                .init(label: "经历", text: "我负责过相关项目。", sourceIDs: ["SRC-001"]),
                .init(label: "复盘", text: "最后说明权衡。", sourceIDs: ["SRC-002", "BLOCK-003"]),
            ],
            missingFacts: ["结果数字待补充，勿声称"],
            estimatedSpeakingSeconds: 60
        )

        let data = try JSONEncoder().encode(answer)
        XCTAssertEqual(try JSONDecoder().decode(InterviewReferenceAnswer.self, from: data), answer)
        XCTAssertTrue(OpenAIResponsesProvider.hasValidReferenceAnswerShape(answer))
    }

    func testReferenceAnswerShapeRequiresExactlyThreeSegmentsAndExpectedDuration() {
        let segment = InterviewReferenceAnswerSegment(label: "要点", text: "内容", sourceIDs: [])
        XCTAssertFalse(OpenAIResponsesProvider.hasValidReferenceAnswerShape(.init(
            segments: [segment, segment],
            missingFacts: [],
            estimatedSpeakingSeconds: 60
        )))
        XCTAssertFalse(OpenAIResponsesProvider.hasValidReferenceAnswerShape(.init(
            segments: [segment, segment, segment],
            missingFacts: [],
            estimatedSpeakingSeconds: 91
        )))
    }

    func testReferenceAnswerSchemaIsStrictAndBounded() throws {
        let schema = OpenAIResponsesProvider.makeReferenceAnswerOutputSchema()
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let segments = try XCTUnwrap(properties["segments"] as? [String: Any])
        XCTAssertEqual(segments["minItems"] as? Int, 3)
        XCTAssertEqual(segments["maxItems"] as? Int, 3)
        let item = try XCTUnwrap(segments["items"] as? [String: Any])
        XCTAssertEqual(item["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(item["required"] as? [String] ?? []), ["label", "text", "sourceIDs"])
    }

    func testFollowUpSchemasUseThreeQuestionsAndCompactAnswers() throws {
        let followUpsSchema = OpenAIResponsesProvider.makeFollowUpsOutputSchema()
        let followUpsProperties = try XCTUnwrap(followUpsSchema["properties"] as? [String: Any])
        let items = try XCTUnwrap(followUpsProperties["items"] as? [String: Any])
        XCTAssertEqual(items["minItems"] as? Int, 3)
        XCTAssertEqual(items["maxItems"] as? Int, 3)

        let answerSchema = OpenAIResponsesProvider.makeFollowUpAnswerOutputSchema()
        XCTAssertEqual(answerSchema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(
            Set(answerSchema["required"] as? [String] ?? []),
            ["directOpening", "talkingPoints", "sampleAnswer", "sourceIDs", "estimatedSpeakingSeconds"]
        )
        let answerProperties = try XCTUnwrap(answerSchema["properties"] as? [String: Any])
        let talkingPoints = try XCTUnwrap(answerProperties["talkingPoints"] as? [String: Any])
        XCTAssertEqual(talkingPoints["minItems"] as? Int, 2)
        XCTAssertEqual(talkingPoints["maxItems"] as? Int, 3)
        let speakingSeconds = try XCTUnwrap(answerProperties["estimatedSpeakingSeconds"] as? [String: Any])
        XCTAssertEqual(speakingSeconds["minimum"] as? Int, 20)
        XCTAssertEqual(speakingSeconds["maximum"] as? Int, 40)
    }

    func testFollowUpShapeValidationMatchesSchemasAtBoundaries() {
        let suggestion = InterviewFollowUpSuggestion(question: "为什么这样判断？", intent: "考察依据")
        XCTAssertFalse(OpenAIResponsesProvider.hasValidFollowUpsShape(.init(items: [suggestion, suggestion])))
        XCTAssertTrue(OpenAIResponsesProvider.hasValidFollowUpsShape(.init(items: [suggestion, suggestion, suggestion])))
        XCTAssertFalse(OpenAIResponsesProvider.hasValidFollowUpsShape(.init(
            items: [suggestion, suggestion, suggestion, suggestion]
        )))

        func answer(points: Int, seconds: Int) -> InterviewFollowUpAnswer {
            InterviewFollowUpAnswer(
                directOpening: "先直接回答。",
                talkingPoints: Array(repeating: "口述锚点", count: points),
                sampleAnswer: "这是示例回答。",
                sourceIDs: [],
                estimatedSpeakingSeconds: seconds
            )
        }

        XCTAssertTrue(OpenAIResponsesProvider.hasValidFollowUpAnswerShape(answer(points: 2, seconds: 20)))
        XCTAssertTrue(OpenAIResponsesProvider.hasValidFollowUpAnswerShape(answer(points: 3, seconds: 40)))
        XCTAssertFalse(OpenAIResponsesProvider.hasValidFollowUpAnswerShape(answer(points: 1, seconds: 20)))
        XCTAssertFalse(OpenAIResponsesProvider.hasValidFollowUpAnswerShape(answer(points: 4, seconds: 40)))
        XCTAssertFalse(OpenAIResponsesProvider.hasValidFollowUpAnswerShape(answer(points: 2, seconds: 19)))
        XCTAssertFalse(OpenAIResponsesProvider.hasValidFollowUpAnswerShape(answer(points: 3, seconds: 41)))
    }

    func testStreamingParserPublishesOnlyCompletedReferenceSegments() {
        let partial = """
        {"segments":[{"label":"结论","text":"先确认目标。","sourceIDs":[]},{"label":"方法","text":"再拆解方案"
        """
        let segments = OpenAIResponsesProvider.completedReferenceSegments(in: partial)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.label, "结论")
    }

    func testStreamingProgressIncludesGrowingCurrentReferenceSegment() {
        let first = """
        {"segments":[{"label":"结论","text":"先确认目
        """
        let second = """
        {"segments":[{"label":"结论","text":"先确认目标，再拆解方案。","sourceIDs":[]},{"label":"方法","text":"补充权
        """

        let firstProgress = OpenAIResponsesProvider.referenceSegmentsProgress(in: first)
        XCTAssertEqual(firstProgress.count, 1)
        XCTAssertEqual(firstProgress[0].label, "结论")
        XCTAssertEqual(firstProgress[0].text, "先确认目")

        let secondProgress = OpenAIResponsesProvider.referenceSegmentsProgress(in: second)
        XCTAssertEqual(secondProgress.count, 2)
        XCTAssertEqual(secondProgress[0].text, "先确认目标，再拆解方案。")
        XCTAssertEqual(secondProgress[1].label, "方法")
        XCTAssertEqual(secondProgress[1].text, "补充权")
    }

    func testStreamingProgressDecodesEscapedCharactersWithoutLeakingJSON() {
        let partial = #"{"segments":[{"label":"经历","text":"第一行\n第二行：\"实时"#
        let segments = OpenAIResponsesProvider.referenceSegmentsProgress(in: partial)

        XCTAssertEqual(segments.first?.text, "第一行\n第二行：\"实时")
    }

    func testCueStreamingProgressPublishesOpeningBeforeTalkingPoints() {
        let openingOnly = #"{"questionSummary":"题目","directOpening":"我会先确认目"#
        let withPoints = #"{"directOpening":"我会先确认目标。","talkingPoints":["先统一口径","再拆解关键驱"#

        let first = OpenAIResponsesProvider.cueProgress(in: openingOnly)
        XCTAssertEqual(first.directOpening, "我会先确认目")
        XCTAssertTrue(first.talkingPoints.isEmpty)

        let second = OpenAIResponsesProvider.cueProgress(in: withPoints)
        XCTAssertEqual(second.directOpening, "我会先确认目标。")
        XCTAssertEqual(second.talkingPoints, ["先统一口径", "再拆解关键驱"])
    }

    func testCueStreamingProgressDecodesEscapesAndNeverLeaksJSONSyntax() {
        let partial = #"{"directOpening":"第一行\n第二行","talkingPoints":["用\"用户价值\"判断"#
        let progress = OpenAIResponsesProvider.cueProgress(in: partial)

        XCTAssertEqual(progress.directOpening, "第一行\n第二行")
        XCTAssertEqual(progress.talkingPoints, ["用\"用户价值\"判断"])
        XCTAssertFalse(progress.talkingPoints[0].contains("talkingPoints"))
    }

    func testReferenceAnswerFeedsFixedSupplementOnlyWhileCandidateIsAnswering() {
        let answer = InterviewReferenceAnswer(
            segments: [
                .init(label: "先说结论", text: "先明确目标、用户和评价指标，再说明判断依据。", sourceIDs: []),
                .init(label: "补充权衡", text: "补上优先级、风险以及后续验证方法。", sourceIDs: []),
                .init(label: "收束", text: "最后回到岗位价值。", sourceIDs: []),
            ],
            missingFacts: ["结果数字待补充，勿声称"],
            estimatedSpeakingSeconds: 60
        )

        XCTAssertTrue(InterviewLiveSupplementComposer.compose(
            supplementalCue: nil,
            referenceAnswer: answer,
            candidateIsAnswering: false
        ).isEmpty)

        let items = InterviewLiveSupplementComposer.compose(
            supplementalCue: nil,
            referenceAnswer: answer,
            candidateIsAnswering: true
        )
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items.allSatisfy { $0.kind == .referenceSegment })
        XCTAssertFalse(items.contains { $0.kind == .missingFact })
        XCTAssertTrue(items[0].text.contains("先说结论"))
    }

    func testLateCueTakesPriorityOverReferenceAnswerInFixedSupplement() {
        let cue = InterviewCue.localSkeleton(for: "请设计一个新产品")
        let answer = InterviewReferenceAnswer(
            segments: [
                .init(label: "A", text: "参考回答 A", sourceIDs: []),
                .init(label: "B", text: "参考回答 B", sourceIDs: []),
                .init(label: "C", text: "参考回答 C", sourceIDs: []),
            ],
            missingFacts: [],
            estimatedSpeakingSeconds: 60
        )

        let items = InterviewLiveSupplementComposer.compose(
            supplementalCue: cue,
            referenceAnswer: answer,
            primaryCueFallback: InterviewCue.localSkeleton(for: "不应显示的旧提纲"),
            candidateIsAnswering: true
        )
        XCTAssertFalse(items.contains { $0.kind == .referenceSegment })
        XCTAssertTrue(items.contains { $0.kind == .talkingPoint })
    }

    func testPrimaryCueFallbackAppearsOnlyWhileCandidateIsAnswering() {
        let cue = InterviewCue.localSkeleton(for: "请分析这个产品案例")

        XCTAssertTrue(InterviewLiveSupplementComposer.compose(
            supplementalCue: nil,
            referenceAnswer: nil,
            primaryCueFallback: cue,
            candidateIsAnswering: false
        ).isEmpty)

        let items = InterviewLiveSupplementComposer.compose(
            supplementalCue: nil,
            referenceAnswer: nil,
            primaryCueFallback: cue,
            candidateIsAnswering: true
        )
        XCTAssertFalse(items.isEmpty)
        XCTAssertLessThanOrEqual(items.count, 3)
        XCTAssertTrue(items.allSatisfy { $0.kind == .talkingPoint })
    }

    func testCueSupplementShowsTwoAnswerPointsAndEvidenceBeforeThirdPoint() {
        var cue = InterviewCue.localSkeleton(for: "请设计一个新产品")
        cue.talkingPoints = ["回答一", "回答二", "回答三"]
        cue.evidenceAnchors = [.init(cue: "经历依据", sourceIDs: ["SRC-001"])]
        cue.missingFacts = ["这条风险提示不应进入实时卡片"]

        let items = InterviewLiveSupplementComposer.compose(
            supplementalCue: cue,
            referenceAnswer: nil,
            candidateIsAnswering: true
        )

        XCTAssertEqual(items.map(\.kind), [.talkingPoint, .talkingPoint, .evidence])
        XCTAssertEqual(items.prefix(2).map(\.text), ["回答一", "回答二"])
        XCTAssertEqual(items[2].text, "经历依据")
        XCTAssertFalse(items[2].text.contains("SRC-001"))
        XCTAssertFalse(items.contains { $0.kind == .missingFact })
        XCTAssertFalse(items.contains { $0.text.contains("风险提示") })
    }

    func testCueSupplementUsesThirdAnswerWhenThereIsNoEvidence() {
        var cue = InterviewCue.localSkeleton(for: "请分析一个业务问题")
        cue.talkingPoints = ["回答一", "回答二", "回答三"]
        cue.missingFacts = ["不展示"]

        let items = InterviewLiveSupplementComposer.compose(
            supplementalCue: cue,
            referenceAnswer: nil,
            candidateIsAnswering: true
        )

        XCTAssertEqual(items.map(\.kind), [.talkingPoint, .talkingPoint, .talkingPoint])
        XCTAssertEqual(items.map(\.text), ["回答一", "回答二", "回答三"])
    }

    func testReferenceSupplementUsesEvidenceAsThirdItemAndNeverShowsMissingFacts() {
        let answer = InterviewReferenceAnswer(
            segments: [
                .init(label: "结论", text: "先说结论。", sourceIDs: []),
                .init(label: "方法", text: "再讲方法。", sourceIDs: ["SRC-002"]),
                .init(label: "验证", text: "最后讲验证。", sourceIDs: []),
            ],
            missingFacts: ["待补充，勿声称"],
            estimatedSpeakingSeconds: 60
        )

        let items = InterviewLiveSupplementComposer.compose(
            supplementalCue: nil,
            referenceAnswer: answer,
            candidateIsAnswering: true
        )

        XCTAssertEqual(items.map(\.kind), [.referenceSegment, .referenceSegment, .evidence])
        XCTAssertFalse(items[2].text.contains("SRC-002"))
        XCTAssertFalse(items.contains { $0.kind == .missingFact })
    }
}
