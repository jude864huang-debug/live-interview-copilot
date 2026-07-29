import Foundation
import XCTest
@testable import LiveInterviewCopilotKit

final class CopilotHistoryStoreTests: XCTestCase {
    func testV6GenerationTelemetryRoundTrips() throws {
        let record = CopilotHistoryRecord(
            schemaVersion: 6,
            id: UUID(),
            createdAt: Date(),
            question: "如何判断产品优先级？",
            cue: InterviewCue.localSkeleton(for: "如何判断产品优先级？"),
            state: .completed,
            promptVersion: "v6",
            knowledgePackageVersion: "kb",
            knowledgePackageHash: "hash",
            durationMilliseconds: 4_800,
            firstOutputMilliseconds: 1_250,
            sessionID: "session",
            provider: .codexSubscription,
            sourceUtteranceIDs: [],
            requestKind: .cue,
            supersedesRequestID: nil,
            model: "gpt-5.4-mini",
            attemptedModels: ["gpt-5.3-codex-spark", "gpt-5.4-mini"],
            generationFallbackReason: "gpt-5.3-codex-spark: unavailable",
            firstDeltaMilliseconds: 920,
            prewarmReady: true,
            prewarmDurationMilliseconds: 340,
            generationTransport: "app-server"
        )

        let decoded = try JSONDecoder().decode(
            CopilotHistoryRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded.schemaVersion, 6)
        XCTAssertEqual(decoded.model, "gpt-5.4-mini")
        XCTAssertEqual(decoded.attemptedModels, ["gpt-5.3-codex-spark", "gpt-5.4-mini"])
        XCTAssertEqual(decoded.firstOutputMilliseconds, 1_250)
        XCTAssertEqual(decoded.firstDeltaMilliseconds, 920)
        XCTAssertEqual(decoded.prewarmReady, true)
        XCTAssertEqual(decoded.generationTransport, "app-server")
    }

    func testV5FollowUpRecordRoundTrips() throws {
        let suggestions = InterviewFollowUpSet(items: [
            .init(question: "你会如何验证效果？", intent: "考察指标闭环"),
            .init(question: "最大的风险是什么？", intent: "考察风险意识"),
            .init(question: "如果资源减半呢？", intent: "考察优先级"),
        ])
        let record = CopilotHistoryRecord(
            schemaVersion: 5,
            id: UUID(),
            createdAt: Date(),
            question: "如何推广一个 AI 产品？",
            cue: nil,
            state: .completed,
            promptVersion: "v5",
            knowledgePackageVersion: "kb",
            knowledgePackageHash: "hash",
            durationMilliseconds: 420,
            sessionID: "session",
            provider: .openAIAPI,
            sourceUtteranceIDs: [],
            requestKind: .followUps,
            supersedesRequestID: nil,
            turnRevision: 2,
            model: "gpt-5.6-terra",
            followUps: suggestions
        )

        let decoded = try JSONDecoder().decode(
            CopilotHistoryRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded.schemaVersion, 5)
        XCTAssertEqual(decoded.requestKind, .followUps)
        XCTAssertEqual(decoded.followUps, suggestions)
        XCTAssertEqual(decoded.model, "gpt-5.6-terra")
    }

    func testV4ReferenceAnswerRecordRoundTripsWithParentAndRequestMetadata() throws {
        let parentCueRequestID = UUID()
        let answer = InterviewReferenceAnswer(
            segments: [
                InterviewReferenceAnswerSegment(
                    label: "结论",
                    text: "我会先确认目标与成功指标。",
                    sourceIDs: ["RES-001"]
                ),
                InterviewReferenceAnswerSegment(
                    label: "案例",
                    text: "再用一段真实经历说明关键取舍。",
                    sourceIDs: ["STORY-002"]
                ),
            ],
            missingFacts: ["最终结果数字待补充，勿声称"],
            estimatedSpeakingSeconds: 62
        )
        let record = makeRecord(
            schemaVersion: 4,
            state: .completed,
            durationMilliseconds: 812,
            provider: .openAIAPI,
            requestKind: .referenceAnswer,
            turnRevision: 4,
            referenceAnswer: answer,
            parentCueRequestID: parentCueRequestID
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(CopilotHistoryRecord.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 4)
        XCTAssertEqual(decoded.requestKind, .referenceAnswer)
        XCTAssertEqual(decoded.referenceAnswer, answer)
        XCTAssertEqual(decoded.parentCueRequestID, parentCueRequestID)
        XCTAssertEqual(decoded.state, .completed)
        XCTAssertEqual(decoded.durationMilliseconds, 812)
        XCTAssertEqual(decoded.provider, .openAIAPI)
        XCTAssertEqual(decoded.turnRevision, 4)
    }

    func testV4FailedReferenceAnswerPreservesFailureStateWithoutPayload() throws {
        let parentCueRequestID = UUID()
        let record = makeRecord(
            state: .failed,
            durationMilliseconds: 1_504,
            provider: .openAIAPI,
            requestKind: .referenceAnswer,
            turnRevision: 7,
            parentCueRequestID: parentCueRequestID
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(CopilotHistoryRecord.self, from: data)

        XCTAssertEqual(decoded.requestKind, .referenceAnswer)
        XCTAssertEqual(decoded.state, .failed)
        XCTAssertEqual(decoded.provider, .openAIAPI)
        XCTAssertEqual(decoded.durationMilliseconds, 1_504)
        XCTAssertEqual(decoded.turnRevision, 7)
        XCTAssertEqual(decoded.parentCueRequestID, parentCueRequestID)
        XCTAssertNil(decoded.referenceAnswer)
    }

    func testV3RecordRoundTripsASRMetadataAndDecodesNilV4Fields() throws {
        let boundaryID = UUID()
        let record = makeRecord(
            schemaVersion: 3,
            audioMode: .manualStreamingASR,
            asrProvider: .tencentStreaming,
            asrLatencyMilliseconds: 438,
            manualBoundaryID: boundaryID,
            fallbackUsed: false,
            turnRevision: 2
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(CopilotHistoryRecord.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 3)
        XCTAssertEqual(decoded.audioMode, .manualStreamingASR)
        XCTAssertEqual(decoded.asrProvider, .tencentStreaming)
        XCTAssertEqual(decoded.asrLatencyMilliseconds, 438)
        XCTAssertEqual(decoded.manualBoundaryID, boundaryID)
        XCTAssertEqual(decoded.fallbackUsed, false)
        XCTAssertEqual(decoded.turnRevision, 2)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["partialText"])
        XCTAssertNil(object["audioSamples"])
        XCTAssertNil(object["pcm"])
        XCTAssertNil(decoded.referenceAnswer)
        XCTAssertNil(decoded.parentCueRequestID)
    }

    func testV2RecordDecodesWithNilV3Metadata() throws {
        let id = UUID()
        let payload: [String: Any] = [
            "schemaVersion": 2,
            "id": id.uuidString,
            "createdAt": 0,
            "question": "Why this role?",
            "state": CopilotGenerationState.completed.rawValue,
            "promptVersion": "v2-prompt",
            "knowledgePackageVersion": "v2-package",
            "knowledgePackageHash": "abc123",
            "sourceUtteranceIDs": [],
            "requestKind": InterviewRequestKind.cue.rawValue,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let decoded = try JSONDecoder().decode(CopilotHistoryRecord.self, from: data)

        XCTAssertEqual(decoded.id, id)
        XCTAssertTrue(decoded.isInterviewRecord)
        XCTAssertNil(decoded.audioMode)
        XCTAssertNil(decoded.asrProvider)
        XCTAssertNil(decoded.asrLatencyMilliseconds)
        XCTAssertNil(decoded.manualBoundaryID)
        XCTAssertNil(decoded.fallbackUsed)
        XCTAssertNil(decoded.turnRevision)
        XCTAssertNil(decoded.referenceAnswer)
        XCTAssertNil(decoded.parentCueRequestID)
    }

    func testLegacyCustomerRecordUsesSafeDefaultsAndRemainsReadable() throws {
        let id = UUID()
        let payload: [String: Any] = [
            "id": id.uuidString,
            "createdAt": 0,
            "question": "旧客服问题",
            "answer": "旧客服答案",
            "state": "legacy_ready",
            "provider": "legacy_provider",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let decoded = try JSONDecoder().decode(CopilotHistoryRecord.self, from: data)

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.question, "旧客服问题")
        XCTAssertFalse(decoded.isInterviewRecord)
        XCTAssertEqual(decoded.state, .completed)
        XCTAssertEqual(decoded.promptVersion, "legacy")
        XCTAssertEqual(decoded.knowledgePackageVersion, "legacy")
        XCTAssertEqual(decoded.knowledgePackageHash, "legacy")
        XCTAssertEqual(decoded.sourceUtteranceIDs, [])
        XCTAssertEqual(decoded.requestKind, .cue)
        XCTAssertNil(decoded.provider)
        XCTAssertNil(decoded.referenceAnswer)
        XCTAssertNil(decoded.parentCueRequestID)
    }

    func testRecentExcludesLegacyCustomerRecordsButMigrationReadIncludesThem() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopilotHistoryStoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CopilotHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let legacy = makeRecord(
            schemaVersion: 1,
            createdAt: Date(timeIntervalSince1970: 2),
            question: "legacy customer"
        )
        let interview = makeRecord(
            createdAt: Date(timeIntervalSince1970: 1),
            question: "interview question",
            audioMode: .manualStreamingASR,
            asrProvider: .tencentStreaming
        )

        await store.save(legacy)
        await store.save(interview)

        let recent = await store.recent(limit: 10)
        let migrationRecords = await store.recentIncludingLegacy(limit: 10)

        XCTAssertEqual(recent.map(\.id), [interview.id])
        XCTAssertEqual(Set(migrationRecords.map(\.id)), Set([legacy.id, interview.id]))
    }

    func testStorePersistsStructuredReferenceAnswerAndCueLink() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopilotReferenceHistoryTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let answer = InterviewReferenceAnswer(
            segments: [
                InterviewReferenceAnswerSegment(
                    label: "起手",
                    text: "我先直接回答核心结论。",
                    sourceIDs: []
                ),
            ],
            missingFacts: [],
            estimatedSpeakingSeconds: 48
        )
        let parentCueRequestID = UUID()
        let record = makeRecord(
            requestKind: .referenceAnswer,
            turnRevision: 2,
            referenceAnswer: answer,
            parentCueRequestID: parentCueRequestID
        )
        let store = CopilotHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))

        await store.save(record)

        let recent = await store.recent(limit: 1)
        let loaded = try XCTUnwrap(recent.first)
        XCTAssertEqual(loaded.id, record.id)
        XCTAssertEqual(loaded.referenceAnswer, answer)
        XCTAssertEqual(loaded.parentCueRequestID, parentCueRequestID)
    }

    func testDeleteSessionAlsoDeletesReadableLegacyPayloads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopilotHistoryDeleteTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CopilotHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let legacy = makeRecord(schemaVersion: 1, sessionID: "session-to-delete")
        let retained = makeRecord(sessionID: "session-to-keep")
        await store.save(legacy)
        await store.save(retained)

        await store.delete(sessionID: "session-to-delete")

        let remaining = await store.recentIncludingLegacy(limit: 10)
        XCTAssertEqual(remaining.map(\.id), [retained.id])
    }

    private func makeRecord(
        schemaVersion: Int = CopilotHistoryRecord.currentSchemaVersion,
        createdAt: Date = Date(timeIntervalSince1970: 1),
        question: String = "Tell me about yourself",
        sessionID: String? = "interview-session",
        state: CopilotGenerationState = .completed,
        durationMilliseconds: Int? = 600,
        provider: InterviewProvider? = .openAIAPI,
        requestKind: InterviewRequestKind = .cue,
        audioMode: InterviewAudioMode? = nil,
        asrProvider: InterviewASRProvider? = nil,
        asrLatencyMilliseconds: Int? = nil,
        manualBoundaryID: UUID? = nil,
        fallbackUsed: Bool? = nil,
        turnRevision: Int? = nil,
        referenceAnswer: InterviewReferenceAnswer? = nil,
        parentCueRequestID: UUID? = nil
    ) -> CopilotHistoryRecord {
        CopilotHistoryRecord(
            schemaVersion: schemaVersion,
            id: UUID(),
            createdAt: createdAt,
            question: question,
            cue: nil,
            state: state,
            promptVersion: "prompt-v3",
            knowledgePackageVersion: "package-v3",
            knowledgePackageHash: "hash-v3",
            durationMilliseconds: durationMilliseconds,
            sessionID: sessionID,
            provider: provider,
            sourceUtteranceIDs: [],
            requestKind: requestKind,
            supersedesRequestID: nil,
            audioMode: audioMode,
            asrProvider: asrProvider,
            asrLatencyMilliseconds: asrLatencyMilliseconds,
            manualBoundaryID: manualBoundaryID,
            fallbackUsed: fallbackUsed,
            turnRevision: turnRevision,
            referenceAnswer: referenceAnswer,
            parentCueRequestID: parentCueRequestID
        )
    }
}
