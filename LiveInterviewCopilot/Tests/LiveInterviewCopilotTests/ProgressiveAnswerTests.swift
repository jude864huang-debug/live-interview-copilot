import Foundation
import XCTest
@testable import LiveInterviewCopilotKit

final class ProgressiveAnswerTests: XCTestCase {
    func testPromptContractKeepsTheCompleteProductText() {
        let required = """
        你生成的不是“提纲”和“完整答案”两套内容，
        而是同一份答案的逐层表示。
        """
        XCTAssertEqual(ProgressiveAnswerPrompt.version, "progressive-answer-v3")
        XCTAssertTrue(ProgressiveAnswerPrompt.coreContract.contains(required))
        XCTAssertTrue(ProgressiveAnswerPrompt.coreContract.contains("第一分句直接回答核心问题"))
        XCTAssertTrue(ProgressiveAnswerPrompt.coreContract.contains("锚点之间必须形成因果、决策、时间或论证关系"))
        XCTAssertTrue(ProgressiveAnswerPrompt.coreContract.contains("不得新增另一个主案例或新的一级方向"))
        XCTAssertTrue(ProgressiveAnswerPrompt.coreContract.contains("只讲该条线的场景、方案、指标和结果"))
        XCTAssertTrue(ProgressiveAnswerPrompt.coreContract.contains("不得跨线挪用架构、指标或成果"))
        XCTAssertTrue(ProgressiveAnswerPrompt.coreContract.contains("明确询问项目全貌、产品组合或多条线对比"))
        XCTAssertTrue(ProgressiveAnswerPrompt.coreContract.contains("不机械重复 entry"))
        XCTAssertTrue(ProgressiveAnswerPrompt.coreContract.contains("全部标题完成前不得开始任何 segment"))
        XCTAssertTrue(ProgressiveAnswerPrompt.questionTypeRules.contains("每份回答至少包含两类有效专业信号"))
    }

    func testSchemaRequiresOrderedSemanticStagesAndNullableClosing() throws {
        let schema = OpenAIResponsesProvider.makeProgressiveAnswerOutputSchema()
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(
            schema["required"] as? [String],
            ["entry", "spine", "segments", "closing", "metadata"]
        )
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let spine = try XCTUnwrap(properties["spine"] as? [String: Any])
        XCTAssertEqual(spine["minItems"] as? Int, 2)
        XCTAssertEqual(spine["maxItems"] as? Int, 4)
        let spineItems = try XCTUnwrap(spine["items"] as? [String: Any])
        XCTAssertEqual(
            spineItems["required"] as? [String],
            ["id", "label", "role", "claimType", "sourceIDs"]
        )
        let spineProperties = try XCTUnwrap(spineItems["properties"] as? [String: Any])
        XCTAssertNil(spineProperties["cue"])
        let closing = try XCTUnwrap(properties["closing"] as? [String: Any])
        XCTAssertNotNil(closing["anyOf"])
    }

    func testCompatibilitySchemasSeparateStableSkeletonFromSegments() throws {
        let skeleton = OpenAIResponsesProvider.makeCompatibilityAnswerSkeletonSchema()
        XCTAssertEqual(skeleton["required"] as? [String], ["entry", "spine", "metadata"])
        let skeletonProperties = try XCTUnwrap(skeleton["properties"] as? [String: Any])
        XCTAssertNil(skeletonProperties["segments"])
        XCTAssertNil(skeletonProperties["closing"])

        let segment = OpenAIResponsesProvider.makeCompatibilityAnswerSegmentSchema()
        XCTAssertEqual(segment["required"] as? [String], ["text", "claimType", "sourceIDs"])
        let segmentProperties = try XCTUnwrap(segment["properties"] as? [String: Any])
        XCTAssertEqual(segmentProperties["text"] as? [String: String], ["type": "string"])
    }

    func testResponsesRequestBodyPreservesProgressiveSchemaPropertyOrder() throws {
        let request = InterviewGenerationRequest(
            id: UUID(),
            model: "gpt-5.6-terra",
            prompt: "question",
            promptCacheKey: "cache",
            maxOutputTokens: 1_100,
            kind: .answer
        )
        let data = try OpenAIResponsesProvider.makeResponsesRequestBodyData(
            request: request,
            schemaName: "interview_progressive_answer",
            schema: OpenAIResponsesProvider.makeProgressiveAnswerOutputSchema(),
            orderedSchemaJSON: OpenAIResponsesProvider.progressiveAnswerOutputSchemaJSON
        )
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(body.contains(#""schema":{"type":"object""#))
        let decodedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let text = try XCTUnwrap(decodedBody["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        let decodedSchema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(decodedSchema["type"] as? String, "object")
        let orderedSchema = OpenAIResponsesProvider.progressiveAnswerOutputSchemaJSON
        XCTAssertTrue(body.contains(orderedSchema))
        let propertiesMarker = try XCTUnwrap(orderedSchema.range(of: #""properties":{"#))
        let orderedBody = orderedSchema[propertiesMarker.upperBound...]
        let keys = ["entry", "spine", "segments", "closing", "metadata"]
        let positions = try keys.map { key in
            try XCTUnwrap(orderedBody.range(of: "\"\(key)\":" )?.lowerBound)
        }
        for pair in zip(positions, positions.dropFirst()) {
            XCTAssertLessThan(pair.0, pair.1)
        }
    }

    func testStreamingParserNeverPublishesHalfAnEntry() {
        let partial = #"{"entry":{"mode":"directAnswer","text":"我会先统一目标"#
        let progress = OpenAIResponsesProvider.answerProgress(in: partial)
        XCTAssertNil(progress.entry)
        XCTAssertTrue(progress.spine.isEmpty)
        XCTAssertFalse(progress.hasUsefulContent)
    }

    func testStreamingParserPublishesOnlyCompletedSemanticObjects() {
        let text = #"{"entry":{"mode":"directAnswer","text":"我会先统一目标，再按影响和证据排序。","assumption":null,"claimType":"professionalJudgment","sourceIDs":[]},"spine":[{"id":"p1","label":"统一口径","role":"judgment","claimType":"professionalJudgment","sourceIDs":[]},{"id":"p2","label":"排序方案","role":"action","claimType":"professionalJudgment"#
        let progress = OpenAIResponsesProvider.answerProgress(in: text)
        XCTAssertEqual(progress.entry?.text, "我会先统一目标，再按影响和证据排序。")
        XCTAssertEqual(progress.spine.map(\.id), ["p1"])
        XCTAssertFalse(progress.isSpineComplete)
        XCTAssertTrue(progress.segments.isEmpty)
    }

    func testStreamingParserPublishesAllTitlesBeforeOrderedDetails() {
        let entry = #"{"entry":{"mode":"directAnswer","text":"先统一目标，再排序验证。","assumption":null,"claimType":"professionalJudgment","sourceIDs":[]}"#
        let p1 = #"{"id":"p1","label":"统一口径","role":"judgment","claimType":"professionalJudgment","sourceIDs":[]}"#
        let p2 = #"{"id":"p2","label":"排序验证","role":"validation","claimType":"professionalJudgment","sourceIDs":[]}"#
        let s1 = #"{"pointID":"p1","text":"先统一目标与指标。","claimType":"professionalJudgment","sourceIDs":[]}"#
        let s2 = #"{"pointID":"p2","text":"再排序并设置验证。","claimType":"professionalJudgment","sourceIDs":[]}"#

        let openSpine = entry + #", "spine":["# + p1 + "," + p2
        var progress = OpenAIResponsesProvider.answerProgress(in: openSpine)
        XCTAssertEqual(progress.spine.map(\.label), ["统一口径", "排序验证"])
        XCTAssertFalse(progress.isSpineComplete)
        XCTAssertTrue(progress.segments.isEmpty)

        let completeSpine = openSpine + "]"
        progress = OpenAIResponsesProvider.answerProgress(in: completeSpine)
        XCTAssertTrue(progress.isSpineComplete)
        XCTAssertEqual(progress.spine.map(\.label), ["统一口径", "排序验证"])
        XCTAssertTrue(progress.segments.isEmpty)

        progress = OpenAIResponsesProvider.answerProgress(
            in: completeSpine + #", "segments":["# + s1
        )
        XCTAssertEqual(progress.segments.map(\.pointID), ["p1"])

        progress = OpenAIResponsesProvider.answerProgress(
            in: completeSpine + #", "segments":["# + s1 + "," + s2
        )
        XCTAssertEqual(progress.segments.map(\.pointID), ["p1", "p2"])

        progress = OpenAIResponsesProvider.answerProgress(
            in: completeSpine + #", "segments":["# + s2 + "," + s1
        )
        XCTAssertTrue(progress.segments.isEmpty)
    }

    func testProgressiveShapeRequiresUniqueSpineAndOneToOneSegments() {
        let valid = makeAnswer()
        XCTAssertTrue(OpenAIResponsesProvider.hasValidProgressiveAnswerShape(valid))

        var duplicate = valid
        duplicate.spine[1].id = "p1"
        XCTAssertFalse(OpenAIResponsesProvider.hasValidProgressiveAnswerShape(duplicate))

        var mismatched = valid
        mismatched.segments[1].pointID = "missing"
        XCTAssertFalse(OpenAIResponsesProvider.hasValidProgressiveAnswerShape(mismatched))

        var reversed = valid
        reversed.segments.reverse()
        XCTAssertFalse(OpenAIResponsesProvider.hasValidProgressiveAnswerShape(reversed))
    }

    func testProgressiveNormalizerCanonicalizesWhitespaceAndInternalIDs() throws {
        var answer = makeAnswer()
        answer.spine[0].id = " p1 "
        answer.segments[0].pointID = "p1 "
        answer.spine[1].id = "step-two"
        answer.segments[1].pointID = " step-two "

        let normalized = try XCTUnwrap(
            OpenAIResponsesProvider.normalizedProgressiveAnswerShape(answer)
        )

        XCTAssertEqual(normalized.spine.map(\.id), ["p1", "p2"])
        XCTAssertEqual(normalized.segments.map(\.pointID), ["p1", "p2"])
        XCTAssertTrue(OpenAIResponsesProvider.hasValidProgressiveAnswerShape(normalized))
    }

    func testProgressiveNormalizerReordersSegmentsByMatchingIDs() throws {
        var answer = makeAnswer()
        answer.segments.reverse()

        let normalized = try XCTUnwrap(
            OpenAIResponsesProvider.normalizedProgressiveAnswerShape(answer)
        )

        XCTAssertEqual(normalized.segments[0].text, makeAnswer().segments[0].text)
        XCTAssertEqual(normalized.segments[1].text, makeAnswer().segments[1].text)
        XCTAssertEqual(normalized.segments.map(\.pointID), ["p1", "p2"])
    }

    func testProgressiveNormalizerRejectsAmbiguousOrContradictoryIDs() {
        var duplicate = makeAnswer()
        duplicate.spine[1].id = "p1"
        duplicate.segments[1].pointID = "p1"
        XCTAssertNil(OpenAIResponsesProvider.normalizedProgressiveAnswerShape(duplicate))

        var contradictory = makeAnswer()
        contradictory.segments[0].pointID = "x1"
        contradictory.segments[1].pointID = "x2"
        XCTAssertNil(OpenAIResponsesProvider.normalizedProgressiveAnswerShape(contradictory))
    }

    func testProgressiveDecoderAcceptsFencedJSONAndTrailingNote() throws {
        let encoded = try JSONEncoder().encode(makeAnswer())
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let response = "```json\n\(json)\n```\n已完成"

        let decoded = try XCTUnwrap(
            OpenAIResponsesProvider.decodeProgressiveAnswerResponse(response)
        )

        XCTAssertEqual(decoded.spine.map(\.id), ["p1", "p2"])
        XCTAssertEqual(decoded.segments.count, 2)
    }

    func testStreamingParserKeepsCompleteObjectsWhenOnlyOuterBraceIsMissing() throws {
        let encoded = try JSONEncoder().encode(makeAnswer())
        var json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertEqual(json.popLast(), "}")

        let progress = OpenAIResponsesProvider.answerProgress(in: json)

        XCTAssertNotNil(progress.entry)
        XCTAssertTrue(progress.isSpineComplete)
        XCTAssertEqual(progress.spine.map(\.id), ["p1", "p2"])
        XCTAssertEqual(progress.segments.map(\.pointID), ["p1", "p2"])
        XCTAssertNotNil(progress.metadata)
    }

    func testProgressiveAnswerBudgetsLeaveRoomForStrictJSONEnvelope() {
        XCTAssertEqual(InterviewAnswerDepth.concise.progressiveAnswerOutputTokenBudget, 1_200)
        XCTAssertEqual(InterviewAnswerDepth.standard.progressiveAnswerOutputTokenBudget, 1_800)
        XCTAssertEqual(InterviewAnswerDepth.deep.progressiveAnswerOutputTokenBudget, 2_400)
    }

    func testV1SpineCueStillDecodesWhileV2MayOmitIt() throws {
        let legacy = #"{"id":"p1","role":"judgment","label":"统一口径","cue":"先统一指标。","claimType":"professionalJudgment","sourceIDs":[]}"#
        let current = #"{"id":"p1","label":"统一口径","role":"judgment","claimType":"professionalJudgment","sourceIDs":[]}"#
        XCTAssertEqual(
            try JSONDecoder().decode(InterviewAnswerSpinePoint.self, from: Data(legacy.utf8)).cue,
            "先统一指标。"
        )
        XCTAssertNil(
            try JSONDecoder().decode(InterviewAnswerSpinePoint.self, from: Data(current.utf8)).cue
        )
    }

    func testV7HistoryRoundTripsProgressiveMetrics() throws {
        let answer = makeAnswer()
        let record = CopilotHistoryRecord(
            id: UUID(),
            createdAt: Date(),
            question: "如何做产品优先级？",
            cue: nil,
            state: .completed,
            promptVersion: "progressive-answer-v2:test",
            knowledgePackageVersion: "kb",
            knowledgePackageHash: "hash",
            durationMilliseconds: 5_100,
            firstOutputMilliseconds: 1_200,
            sessionID: "session",
            provider: .openAIAPI,
            sourceUtteranceIDs: [],
            requestKind: .answer,
            supersedesRequestID: nil,
            model: "gpt-5.6-terra",
            attemptedModels: ["gpt-5.6-terra"],
            progressiveAnswer: answer,
            firstDeltaMs: 800,
            firstUsefulEntryMs: 1_200,
            spineReadyMs: 2_200,
            answerCompleteMs: 5_100,
            spineReadyMilliseconds: 2_200,
            answerCompleteMilliseconds: 5_100,
            fallbackTriggered: false,
            ownerModel: "gpt-5.6-terra",
            candidateStartedBeforeEntry: false,
            revisionCount: 1
        )
        let decoded = try JSONDecoder().decode(
            CopilotHistoryRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded.schemaVersion, 7)
        XCTAssertEqual(decoded.progressiveAnswer, answer)
        XCTAssertEqual(decoded.firstUsefulEntryMs, 1_200)
        XCTAssertEqual(decoded.answerCompleteMs, 5_100)
        XCTAssertEqual(decoded.spineReadyMilliseconds, 2_200)
        XCTAssertEqual(decoded.ownerModel, "gpt-5.6-terra")
    }

    func testV6LegacyReferenceAnswerStillDecodesWithoutProgressiveFields() throws {
        let legacy = CopilotHistoryRecord(
            schemaVersion: 6,
            id: UUID(),
            createdAt: Date(),
            question: "旧问题",
            cue: nil,
            state: .completed,
            promptVersion: "v6",
            knowledgePackageVersion: "kb",
            knowledgePackageHash: "hash",
            durationMilliseconds: 4_000,
            sessionID: "session",
            provider: .codexSubscription,
            sourceUtteranceIDs: [],
            requestKind: .referenceAnswer,
            supersedesRequestID: nil,
            referenceAnswer: InterviewReferenceAnswer(
                segments: [.init(label: "结论", text: "旧回答", sourceIDs: [])],
                missingFacts: [],
                estimatedSpeakingSeconds: 45
            )
        )
        let decoded = try JSONDecoder().decode(
            CopilotHistoryRecord.self,
            from: JSONEncoder().encode(legacy)
        )
        XCTAssertEqual(decoded.schemaVersion, 6)
        XCTAssertEqual(decoded.referenceAnswer?.segments.first?.text, "旧回答")
        XCTAssertNil(decoded.progressiveAnswer)
    }

    func testKnowledgeBriefRanksQuestionRelevantBlocksInsideCategoryQuota() throws {
        let source = KnowledgeSource(
            id: "SRC-1",
            relativePath: "05-domain/notes.md",
            title: "产品方法",
            contentHash: "hash",
            modifiedAt: Date(),
            category: .domain
        )
        let snapshot = KnowledgePackageSnapshot(
            version: "v1",
            hash: "hash",
            compiledAt: Date(),
            sources: [source],
            blocks: [
                .init(id: "BLOCK-001", sourceID: source.id, heading: "通用说明", location: "L1", text: "这是无关内容。"),
                .init(id: "BLOCK-999", sourceID: source.id, heading: "支付增长", location: "L2", text: "支付转化率需要按漏斗验证。"),
            ],
            text: "",
            characterCount: 0,
            estimatedTokenCount: 0,
            failedFiles: []
        )
        let brief = snapshot.makeRealtimeBrief(maxTokens: 2_000, question: "如何提升支付转化率？")
        let relevant = try XCTUnwrap(brief.text.range(of: "BLOCK-999"))
        let irrelevant = try XCTUnwrap(brief.text.range(of: "BLOCK-001"))
        XCTAssertLessThan(relevant.lowerBound, irrelevant.lowerBound)
    }

    private func makeAnswer() -> InterviewProgressiveAnswer {
        InterviewProgressiveAnswer(
            entry: .init(
                mode: .directAnswer,
                text: "我会先统一目标，再按用户影响、证据强度和成本排序。",
                assumption: nil,
                claimType: .professionalJudgment,
                sourceIDs: []
            ),
            spine: [
                .init(id: "p1", role: .judgment, label: "统一口径", claimType: .professionalJudgment, sourceIDs: []),
                .init(id: "p2", role: .tradeoff, label: "排序取舍", claimType: .professionalJudgment, sourceIDs: []),
            ],
            segments: [
                .init(pointID: "p1", text: "先把业务目标、用户范围和指标口径对齐。", claimType: .professionalJudgment, sourceIDs: []),
                .init(pointID: "p2", text: "再用统一标准比较方案，并为关键假设设置验证。", claimType: .professionalJudgment, sourceIDs: []),
            ],
            closing: .init(text: "最终以验证结果决定是否继续投入。", claimType: .professionalJudgment, sourceIDs: []),
            metadata: .init(questionType: .productCase, answerMode: .professionalJudgment, concreteGaps: [])
        )
    }
}
