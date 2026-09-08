import Foundation
@testable import LiveInterviewCopilotKit

@main
enum CLTProgressiveVerify {
    static func main() async {
        var failures: [String] = []

        do {
            try await runAPIFallbackFailureUnlocksOriginalModel()
            print("PASS apiFallbackFailureUnlocksOriginalModel")
        } catch {
            failures.append("apiFallbackFailureUnlocksOriginalModel: \(error)")
            print("FAIL apiFallbackFailureUnlocksOriginalModel: \(error)")
        }

        do {
            try await runRegenerateWithThinkingDepthUpdatesSettings()
            print("PASS regenerateWithThinkingDepthUpdatesSettings")
        } catch {
            failures.append("regenerateWithThinkingDepthUpdatesSettings: \(error)")
            print("FAIL regenerateWithThinkingDepthUpdatesSettings: \(error)")
        }

        do {
            try await runRegenerateCreatesNewQuestionRevision()
            print("PASS regenerateCreatesNewQuestionRevision")
        } catch {
            failures.append("regenerateCreatesNewQuestionRevision: \(error)")
            print("FAIL regenerateCreatesNewQuestionRevision: \(error)")
        }

        do {
            try runInterviewRoundModuleLifecycle()
            print("PASS interviewRoundModuleLifecycle")
        } catch {
            failures.append("interviewRoundModuleLifecycle: \(error)")
            print("FAIL interviewRoundModuleLifecycle: \(error)")
        }

        do {
            try await runSuccessfulAPIFallbackStillLocksSession()
            print("PASS successfulAPIFallbackStillLocksSession")
        } catch {
            failures.append("successfulAPIFallbackStillLocksSession: \(error)")
            print("FAIL successfulAPIFallbackStillLocksSession: \(error)")
        }

        if failures.isEmpty {
            print("CLT progressive verify: all checks passed")
            return
        }

        fputs("CLT progressive verify failed:\n\(failures.joined(separator: "\n"))\n", stderr)
        exit(1)
    }
}

@MainActor
private func runAPIFallbackFailureUnlocksOriginalModel() async throws {
    let terra = ProgressiveProvider(
        behavior: .failure(.serverUnavailable(503)),
        fallbackModel: "api-fallback-model",
        fallbackBehavior: .failure(.serverUnavailable(503))
    )
    let codex = ProgressiveProvider(behavior: .failure(.serverUnavailable(503)))
    let harness = makeHarness(api: terra, codex: codex)

    submitQuestion("资源减半时怎么取舍？", to: harness)
    guard await waitUntil({ harness.engine.referenceGenerationState == .failed }) else {
        throw VerifyError.message("expected progressive answer failure")
    }

    let terraCount = await terra.requestCount()
    let codexCount = await codex.requestCount()
    try expect(terraCount == 2, "API request count \(terraCount) != 2")
    try expect(codexCount == 0, "Codex request count \(codexCount) != 0")
    try expect(harness.engine.answerFallbackTriggered, "fallback not triggered")
    try expect(!harness.engine.isUsingFallbackAnswerModelForSession, "session still locked to fallback")
    try expect(
        harness.engine.activeAnswerModel == SettingsStore.defaultInterviewMainAnswerModel,
        "active model still \(harness.engine.activeAnswerModel)"
    )

    harness.engine.regenerateCurrentAnswer()
    guard await waitUntil({ await terra.requestCount() >= 3 }) else {
        throw VerifyError.message(
            "primary model was not retried after unlock; api=\(await terra.requestCount()) codex=\(await codex.requestCount()) state=\(harness.engine.referenceGenerationState.rawValue)"
        )
    }
    try expect(await terra.requestCount() >= 3, "expected primary retry after unlock")
    try expect(await codex.requestCount() == 0, "Codex should not be used for API fallback")
}

@MainActor
private func runRegenerateWithThinkingDepthUpdatesSettings() async throws {
    let terra = ProgressiveProvider(behavior: .success(marker: "Terra", delayMilliseconds: 10))
    let harness = makeHarness(
        api: terra,
        codex: ProgressiveProvider(behavior: .failure(.invalidResponse))
    )
    harness.settings.interviewCodexReasoningEffort = .low
    harness.settings.interviewAnswerDepth = .standard

    submitQuestion("如何判断产品优先级？", to: harness)
    guard await waitUntil({ harness.engine.progressiveAnswer != nil }) else {
        throw VerifyError.message("first answer did not complete")
    }

    harness.engine.regenerateCurrentAnswer(reasoningEffort: .high)
    guard await waitUntil({
        await terra.requestCount() == 2 && harness.engine.progressiveAnswer != nil
    }) else {
        throw VerifyError.message("regenerate did not complete")
    }

    try expect(harness.settings.interviewCodexReasoningEffort == .high, "codex reasoning not updated")
    try expect(harness.settings.interviewAnswerDepth == .deep, "answer depth not mapped to deep")
    try expect(harness.engine.selectedThinkingDepth == .medium, "selected API thinking depth not medium")
    try expect(await terra.latestReasoningEffort() == .medium, "API request reasoning effort not medium")
}

@MainActor
private func runRegenerateCreatesNewQuestionRevision() async throws {
    let terra = ProgressiveProvider(behavior: .success(marker: "Terra", delayMilliseconds: 10))
    let harness = makeHarness(
        api: terra,
        codex: ProgressiveProvider(behavior: .failure(.invalidResponse))
    )

    submitQuestion("如何判断产品优先级？", to: harness)
    guard await waitUntil({ harness.engine.progressiveAnswer != nil }) else {
        throw VerifyError.message("first answer did not complete")
    }
    let turnToken = harness.engine.interviewTurnToken
    let revision = harness.engine.runDiagnostics.revisionCount

    harness.engine.regenerateCurrentAnswer()
    guard await waitUntil({
        await terra.requestCount() == 2 && harness.engine.progressiveAnswer != nil
    }) else {
        throw VerifyError.message("regenerated answer did not complete")
    }
    try expect(harness.engine.interviewTurnToken == turnToken, "regenerate changed Interview Round")
    try expect(
        harness.engine.runDiagnostics.revisionCount == revision + 1,
        "regenerate did not create a Question Revision"
    )
}

@MainActor
private func runInterviewRoundModuleLifecycle() throws {
    let rounds = InterviewRoundModule()
    rounds.accept(.interviewerQuestionObserved)
    let initial = rounds.presentation
    rounds.accept(.questionRevised)
    rounds.accept(.answerRegenerated)
    let latest = rounds.presentation

    try expect(initial.roundID == latest.roundID, "revision changed Interview Round")
    try expect(initial.turnID == latest.turnID, "revision changed turn identity")
    try expect(latest.revision == 2, "expected correction and regeneration revisions")
    try expect(!rounds.accepts(turnID: initial.turnID, revision: initial.revision), "stale revision accepted")
    try expect(rounds.accepts(turnID: latest.turnID, revision: latest.revision), "latest revision rejected")

    rounds.accept(.candidateBeganAnswering)
    try expect(rounds.presentation.isAnswerFrozen, "candidate answer did not freeze presentation")
    rounds.accept(.interviewerQuestionObserved)
    try expect(!rounds.presentation.isAnswerFrozen, "new Interview Round remained frozen")
}

@MainActor
private func runSuccessfulAPIFallbackStillLocksSession() async throws {
    let terra = ProgressiveProvider(
        behavior: .failure(.serverUnavailable(503)),
        fallbackModel: "api-fallback-model",
        fallbackBehavior: .success(marker: "Fallback", delayMilliseconds: 10)
    )
    let codex = ProgressiveProvider(behavior: .failure(.invalidResponse))
    let harness = makeHarness(api: terra, codex: codex)

    submitQuestion("资源减半时怎么取舍？", to: harness)
    guard await waitUntil({ harness.engine.progressiveAnswer != nil }) else {
        throw VerifyError.message("API fallback answer did not complete")
    }
    try expect(harness.engine.answerFallbackTriggered, "fallback not triggered")
    try expect(harness.engine.isUsingFallbackAnswerModelForSession, "session not locked after success")
    try expect(
        harness.engine.answerOwnerModel == "api-fallback-model",
        "owner model not API fallback"
    )

    submitQuestion("下一题：你会如何验证取舍结果？", to: harness)
    guard await waitUntil({
        await terra.requestCount() == 3
            && harness.engine.progressiveAnswer?.entry.text.hasPrefix("Fallback：") == true
    }) else {
        throw VerifyError.message(
            "next question did not stay on fallback; api=\(await terra.requestCount()) codex=\(await codex.requestCount()) model=\(harness.engine.activeAnswerModel) entry=\(harness.engine.progressiveAnswer?.entry.text ?? "nil")"
        )
    }
    try expect(await terra.requestCount() == 3, "API primary should remain on the fallback model")
    try expect(harness.engine.isUsingFallbackAnswerModelForSession, "session unlock after API fallback success")
}

@MainActor
private func makeHarness(
    api: ProgressiveProvider,
    codex: ProgressiveProvider
) -> Harness {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("liveinterviewcopilot-clt-verify-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "com.jude864huang.liveinterviewcopilot.clt-verify.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let settings = SettingsStore(storage: SettingsStorage(
        defaults: defaults,
        secretStore: .ephemeral,
        defaultNotesDirectory: root,
        runMigrations: false
    ))
    settings.interviewDelayedFallbackEnabled = true
    settings.interviewAnswerDepth = .standard
    settings.interviewAPIProtocol = .responses
    settings.interviewAPIModel = SettingsStore.defaultInterviewMainAnswerModel
    settings.interviewFallbackAnswerModel = "api-fallback-model"
    settings.interviewIncludeCandidateAnswersInContext = false

    let transcriptStore = TranscriptStore()
    let historyStore = CopilotHistoryStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let engine = CustomerCopilotEngine(
        transcriptStore: transcriptStore,
        compiler: KnowledgePackageCompiler(stateDirectory: root),
        worker: CodexWorkerClient(workerPath: nil),
        historyStore: historyStore,
        settings: settings,
        apiProvider: api,
        codexProvider: codex,
        apiCredentialProvider: { "test-only-key" },
        defaults: defaults
    )
    return Harness(engine: engine, transcriptStore: transcriptStore, settings: settings)
}

@MainActor
private func submitQuestion(_ text: String, to harness: Harness) {
    let utterance = Utterance(text: text, speaker: .them)
    precondition(harness.transcriptStore.append(utterance, suppressAcousticEcho: false))
    harness.engine.onUtterance(utterance)
}

@MainActor
private func waitUntil(
    _ condition: @escaping @MainActor () async -> Bool,
    attempts: Int = 300
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw VerifyError.message(message) }
}

private enum VerifyError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let value): value
        }
    }
}

@MainActor
private struct Harness {
    let engine: CustomerCopilotEngine
    let transcriptStore: TranscriptStore
    let settings: SettingsStore
}

private actor ProgressiveProvider: InterviewGenerationProvider {
    enum Behavior: Sendable {
        case success(marker: String, delayMilliseconds: Int)
        case failure(CopilotError)
    }

    private let behavior: Behavior
    private let fallbackModel: String?
    private let fallbackBehavior: Behavior?
    private var requests = 0
    private var prompts: [String] = []
    private var reasoningEfforts: [InterviewReasoningEffort] = []

    init(
        behavior: Behavior,
        fallbackModel: String? = nil,
        fallbackBehavior: Behavior? = nil
    ) {
        self.behavior = behavior
        self.fallbackModel = fallbackModel
        self.fallbackBehavior = fallbackBehavior
    }

    func generateProgressiveAnswer(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewProgressiveAnswer {
        try await generateProgressiveAnswerStreaming(request, credential: credential) { _ in }
    }

    func generateProgressiveAnswerStreaming(
        _ request: InterviewGenerationRequest,
        credential: String?,
        onProgress: @escaping @Sendable (InterviewAnswerProgress) -> Void
    ) async throws -> InterviewProgressiveAnswer {
        requests += 1
        prompts.append(request.prompt)
        reasoningEfforts.append(request.reasoningEffort)
        let selectedBehavior = request.model == fallbackModel
            ? (fallbackBehavior ?? behavior)
            : behavior
        switch selectedBehavior {
        case .failure(let error):
            throw error
        case .success(let marker, let delayMilliseconds):
            if delayMilliseconds > 0 {
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
            }
            let answer = Self.answer(marker: marker)
            onProgress(.init(entry: answer.entry, spine: [], segments: [], closing: nil, metadata: nil))
            onProgress(.init(
                entry: answer.entry,
                spine: answer.spine,
                segments: answer.segments,
                closing: answer.closing,
                metadata: answer.metadata,
                isSpineComplete: true
            ))
            return answer
        }
    }

    func generateCue(_ request: InterviewGenerationRequest, credential: String?) async throws -> InterviewCue {
        throw CopilotError.invalidResponse
    }

    func generateReferenceAnswer(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewReferenceAnswer {
        throw CopilotError.invalidResponse
    }

    func generateFollowUps(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewFollowUpSet {
        throw CopilotError.invalidResponse
    }

    func generateFollowUpAnswer(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewFollowUpAnswer {
        throw CopilotError.invalidResponse
    }

    func cancel(id: UUID) {}

    func requestCount() -> Int { requests }
    func latestPrompt() -> String { prompts.last ?? "" }
    func latestReasoningEffort() -> InterviewReasoningEffort? { reasoningEfforts.last }

    private static func answer(marker: String) -> InterviewProgressiveAnswer {
        InterviewProgressiveAnswer(
            entry: .init(
                mode: .directAnswer,
                text: "\(marker)：我会先统一目标，再按影响和证据排序。",
                assumption: nil,
                claimType: .professionalJudgment,
                sourceIDs: []
            ),
            spine: [
                .init(id: "p1", role: .context, label: "统一目标", cue: "明确用户、目标和指标口径。", claimType: .professionalJudgment, sourceIDs: []),
                .init(id: "p2", role: .tradeoff, label: "比较取舍", cue: "比较影响、证据、成本和风险。", claimType: .professionalJudgment, sourceIDs: []),
                .init(id: "p3", role: .validation, label: "验证调整", cue: "设置领先指标和停止条件。", claimType: .professionalJudgment, sourceIDs: []),
            ],
            segments: [
                .init(pointID: "p1", text: "先对齐业务目标、目标用户和成功指标。", claimType: .professionalJudgment, sourceIDs: []),
                .init(pointID: "p2", text: "再用同一标准比较候选方案。", claimType: .professionalJudgment, sourceIDs: []),
                .init(pointID: "p3", text: "最后通过小范围验证决定是否继续投入。", claimType: .professionalJudgment, sourceIDs: []),
            ],
            closing: .init(text: "新证据出现后及时调整。", claimType: .professionalJudgment, sourceIDs: []),
            metadata: .init(questionType: .productCase, answerMode: .professionalJudgment, concreteGaps: [])
        )
    }
}
