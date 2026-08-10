import Foundation
import XCTest
@testable import LiveInterviewCopilotKit

@MainActor
final class CustomerCopilotEngineReferenceTests: XCTestCase {
    private static let apiFallbackModel = "api-fallback-model"

    func testTerraProducesTheOnlyVisibleProgressiveAnswer() async {
        let terra = ProgressiveProvider(behavior: .success(marker: "Terra", delayMilliseconds: 10))
        let spark = ProgressiveProvider(behavior: .success(marker: "Spark", delayMilliseconds: 0))
        let harness = makeHarness(api: terra, codex: spark)

        submitQuestion("如何判断产品优先级？", to: harness)

        let didFinish = await waitUntil { harness.engine.progressiveAnswer != nil }
        let terraRequestCount = await terra.requestCount()
        let sparkRequestCount = await spark.requestCount()
        XCTAssertTrue(didFinish)
        XCTAssertEqual(harness.engine.progressiveAnswer?.entry.text, "Terra：我会先统一目标，再按影响和证据排序。")
        XCTAssertEqual(harness.engine.answerOwnerModel, SettingsStore.defaultInterviewMainAnswerModel)
        XCTAssertFalse(harness.engine.answerFallbackTriggered)
        XCTAssertEqual(terraRequestCount, 1)
        XCTAssertEqual(sparkRequestCount, 0)
        XCTAssertEqual(harness.engine.progressiveAnswer?.spine.count, 3)
        XCTAssertEqual(harness.engine.progressiveAnswer?.segments.count, 3)
    }

    func testAPIFailureUsesSameProtocolFallbackAndLocksTheRound() async {
        let terra = ProgressiveProvider(
            behavior: .failure(.serverUnavailable(503)),
            fallbackModel: Self.apiFallbackModel,
            fallbackBehavior: .success(marker: "API fallback", delayMilliseconds: 10)
        )
        let codex = ProgressiveProvider(behavior: .failure(.invalidResponse))
        let harness = makeHarness(api: terra, codex: codex)
        harness.settings.interviewFallbackAnswerModel = Self.apiFallbackModel

        submitQuestion("资源减半时怎么取舍？", to: harness)

        let didFinish = await waitUntil { harness.engine.progressiveAnswer != nil }
        let terraRequestCount = await terra.requestCount()
        let codexRequestCount = await codex.requestCount()
        XCTAssertTrue(didFinish)
        XCTAssertTrue(harness.engine.answerFallbackTriggered)
        XCTAssertEqual(harness.engine.answerOwnerModel, Self.apiFallbackModel)
        XCTAssertEqual(harness.engine.progressiveAnswer?.entry.text, "API fallback：我会先统一目标，再按影响和证据排序。")
        XCTAssertEqual(terraRequestCount, 2)
        XCTAssertEqual(codexRequestCount, 0)
        XCTAssertEqual(harness.engine.runDiagnostics.attemptedModels, [
            SettingsStore.defaultInterviewMainAnswerModel,
            Self.apiFallbackModel,
        ])

        submitQuestion("下一题：你会如何验证取舍结果？", to: harness)
        let didFinishNext = await waitUntil {
            await terra.requestCount() == 3
                && harness.engine.progressiveAnswer?.entry.text.hasPrefix("API fallback：") == true
        }
        let terraRequestCountAfterNextQuestion = await terra.requestCount()
        XCTAssertTrue(didFinishNext)
        XCTAssertEqual(terraRequestCountAfterNextQuestion, 3)
        XCTAssertEqual(harness.engine.runDiagnostics.mainModel, Self.apiFallbackModel)
        XCTAssertEqual(harness.engine.runDiagnostics.ownerModel, Self.apiFallbackModel)
        XCTAssertEqual(harness.engine.runDiagnostics.attemptedModels, [Self.apiFallbackModel])
        XCTAssertTrue(harness.engine.isUsingFallbackAnswerModelForSession)
    }

    func testCodexCLIUsesTheConfiguredMainModelAndReasoning() async {
        let api = ProgressiveProvider(behavior: .failure(.invalidResponse))
        let codex = ProgressiveProvider(behavior: .success(marker: "Luna", delayMilliseconds: 10))
        let harness = makeHarness(api: api, codex: codex)
        harness.settings.interviewCodexModel = "gpt-5.6-luna"
        harness.settings.interviewCodexReasoningEffort = .high
        harness.engine.inferencePreference = .codexOnly

        submitQuestion("如何判断产品优先级？", to: harness)

        let didFinish = await waitUntil { harness.engine.progressiveAnswer != nil }
        XCTAssertTrue(didFinish)
        XCTAssertEqual(harness.engine.answerOwnerModel, "gpt-5.6-luna")
        XCTAssertEqual(harness.engine.primaryAnswerModel, "gpt-5.6-luna")
        XCTAssertEqual(harness.engine.activeAnswerModel, "gpt-5.6-luna")
        XCTAssertEqual(
            harness.engine.runDiagnostics.provider?.rawValue,
            InterviewProvider.codexSubscription.rawValue
        )
        XCTAssertEqual(harness.engine.runDiagnostics.reasoningEffort, .high)
        let apiRequestCount = await api.requestCount()
        let codexRequestCount = await codex.requestCount()
        XCTAssertEqual(apiRequestCount, 0)
        XCTAssertEqual(codexRequestCount, 1)
    }

    func testRequestBoundaryUsesTheLatestPersistedGenerationRoute() async {
        let api = ProgressiveProvider(behavior: .success(marker: "API", delayMilliseconds: 10))
        let codex = ProgressiveProvider(behavior: .success(marker: "Codex", delayMilliseconds: 10))
        let harness = makeHarness(api: api, codex: codex)
        harness.settings.interviewInferencePreference = .codexOnly

        submitQuestion("如何判断产品优先级？", to: harness)

        let didFinish = await waitUntil { harness.engine.progressiveAnswer != nil }
        XCTAssertTrue(didFinish)
        XCTAssertEqual(harness.engine.answerOwnerModel, SettingsStore.defaultInterviewCodexModel)
        XCTAssertEqual(await api.requestCount(), 0)
        XCTAssertEqual(await codex.requestCount(), 1)
    }

    func testInvalidCandidateFactNeverEntersVisibleProgress() async {
        let terra = ProgressiveProvider(behavior: .unsafeCandidateFact)
        let spark = ProgressiveProvider(behavior: .failure(.invalidResponse))
        let harness = makeHarness(api: terra, codex: spark)

        submitQuestion("说说你做过的增长项目", to: harness)

        let didFail = await waitUntil { harness.engine.referenceGenerationState == .failed }
        XCTAssertTrue(didFail)
        XCTAssertNil(harness.engine.answerProgress.entry)
        XCTAssertNil(harness.engine.progressiveAnswer)
        XCTAssertEqual(harness.engine.runDiagnostics.citationValidationPassed, false)
    }

    func testCompletedMainAnswerCanBeRegeneratedExplicitly() async {
        let terra = ProgressiveProvider(behavior: .success(marker: "Terra", delayMilliseconds: 10))
        let harness = makeHarness(api: terra, codex: ProgressiveProvider(behavior: .failure(.invalidResponse)))

        submitQuestion("如何判断产品优先级？", to: harness)
        let didFinishFirstAnswer = await waitUntil { harness.engine.progressiveAnswer != nil }
        XCTAssertTrue(didFinishFirstAnswer)
        XCTAssertTrue(harness.engine.canRegenerateCurrentAnswer)

        harness.engine.regenerateCurrentAnswer()

        let didFinishSecondAnswer = await waitUntil {
            await terra.requestCount() == 2 && harness.engine.progressiveAnswer != nil
        }
        let requestCount = await terra.requestCount()
        XCTAssertTrue(didFinishSecondAnswer)
        XCTAssertEqual(requestCount, 2)
    }

    func testAPIFallbackFailureUnlocksOriginalModelForRetry() async {
        let terra = ProgressiveProvider(
            behavior: .failure(.serverUnavailable(503)),
            fallbackModel: Self.apiFallbackModel,
            fallbackBehavior: .failure(.serverUnavailable(503))
        )
        let codex = ProgressiveProvider(behavior: .failure(.serverUnavailable(503)))
        let harness = makeHarness(api: terra, codex: codex)
        harness.settings.interviewFallbackAnswerModel = Self.apiFallbackModel

        submitQuestion("资源减半时怎么取舍？", to: harness)
        let didFail = await waitUntil { harness.engine.referenceGenerationState == .failed }
        let terraRequestCount = await terra.requestCount()
        let codexRequestCount = await codex.requestCount()
        XCTAssertTrue(didFail)
        XCTAssertEqual(terraRequestCount, 2)
        XCTAssertEqual(codexRequestCount, 0)
        XCTAssertTrue(harness.engine.answerFallbackTriggered)
        // Spark also failed before a visible entry, so unlock the original model.
        XCTAssertFalse(harness.engine.isUsingFallbackAnswerModelForSession)
        XCTAssertEqual(harness.engine.activeAnswerModel, SettingsStore.defaultInterviewMainAnswerModel)

        // A later regenerate should attempt the original primary model again.
        harness.engine.regenerateCurrentAnswer()
        let didRetryPrimary = await waitUntil { await terra.requestCount() >= 3 }
        XCTAssertTrue(didRetryPrimary)
        let terraRequestCountAfterRetry = await terra.requestCount()
        let codexRequestCountAfterRetry = await codex.requestCount()
        XCTAssertGreaterThanOrEqual(terraRequestCountAfterRetry, 3)
        XCTAssertEqual(codexRequestCountAfterRetry, 0)
    }

    func testRegenerateWithThinkingDepthUpdatesSettingsAndRetries() async {
        let terra = ProgressiveProvider(behavior: .success(marker: "Terra", delayMilliseconds: 10))
        let harness = makeHarness(api: terra, codex: ProgressiveProvider(behavior: .failure(.invalidResponse)))
        harness.settings.interviewCodexReasoningEffort = .low
        harness.settings.interviewAnswerDepth = .standard

        submitQuestion("如何判断产品优先级？", to: harness)
        let didFinishFirstAnswer = await waitUntil { harness.engine.progressiveAnswer != nil }
        XCTAssertTrue(didFinishFirstAnswer)

        harness.engine.regenerateCurrentAnswer(reasoningEffort: .high)

        let didFinishSecondAnswer = await waitUntil {
            await terra.requestCount() == 2 && harness.engine.progressiveAnswer != nil
        }
        XCTAssertTrue(didFinishSecondAnswer)
        XCTAssertEqual(harness.settings.interviewCodexReasoningEffort, .high)
        XCTAssertEqual(harness.settings.interviewAnswerDepth, .deep)
        XCTAssertEqual(harness.engine.selectedThinkingDepth, .medium)
        let lastEffort = await terra.latestReasoningEffort()
        // API requests follow the API answer-depth picker. `.deep` maps to
        // medium reasoning effort; the Codex-only setting remains `.high`.
        XCTAssertEqual(lastEffort, .medium)
    }

    func testPromptContainsVersionedContractAndDoesNotAnchorToFastCue() async {
        let terra = ProgressiveProvider(behavior: .success(marker: "Terra", delayMilliseconds: 0))
        let harness = makeHarness(api: terra, codex: ProgressiveProvider(behavior: .failure(.invalidResponse)))

        submitQuestion("如何设计一个新产品？", to: harness)
        let didFinish = await waitUntil { harness.engine.progressiveAnswer != nil }
        XCTAssertTrue(didFinish)

        let prompt = await terra.latestPrompt()
        XCTAssertTrue(prompt.contains("<PROGRESSIVE_ANSWER_CONTRACT version=\"progressive-answer-v3\">"))
        XCTAssertTrue(prompt.contains(ProgressiveAnswerPrompt.coreContract))
        XCTAssertTrue(prompt.contains("<SUGGESTED_QUESTION_TYPE>"))
        XCTAssertFalse(prompt.contains("<APPROVED_FAST_CUE>"))
        XCTAssertTrue(prompt.contains("按 entry → spine → segments → closing → metadata"))
    }

    func testFailureAfterVisibleEntryLeavesGeneratingState() async {
        let terra = ProgressiveProvider(behavior: .entryThenFailure(marker: "Terra"))
        let harness = makeHarness(api: terra, codex: ProgressiveProvider(behavior: .failure(.invalidResponse)))

        submitQuestion("如何判断产品优先级？", to: harness)
        let didFail = await waitUntil { harness.engine.referenceGenerationState == .failed }

        XCTAssertTrue(didFail)
        XCTAssertEqual(harness.engine.answerProgress.entry?.text, "Terra：我会先统一目标，再按影响和证据排序。")
        XCTAssertNotNil(harness.engine.referenceErrorMessage)
    }

    func testFollowUpsCommitQuestionsThenGenerateAllAnswersSerially() async {
        let terra = ProgressiveProvider(
            behavior: .success(marker: "Terra", delayMilliseconds: 0),
            supportsFollowUps: true
        )
        let harness = makeHarness(api: terra, codex: ProgressiveProvider(behavior: .failure(.invalidResponse)))

        submitQuestion("如何推广企业 AI 产品？", to: harness)

        let didComplete = await waitUntil { harness.engine.followUpPipelineState == .completed }
        let maximumConcurrency = await terra.maximumFollowUpAnswerConcurrency()
        let events = await terra.followUpEvents()
        XCTAssertTrue(didComplete)
        XCTAssertEqual(harness.engine.followUpSuggestions?.items.count, 3)
        XCTAssertTrue(harness.engine.isFollowUpsExpanded)
        XCTAssertEqual(harness.engine.followUpAnswersByQuestion.count, 3)
        XCTAssertEqual(maximumConcurrency, 1)
        XCTAssertEqual(
            events,
            ["questions", "start:A1", "finish:A1", "start:A2", "finish:A2", "start:A3", "finish:A3"]
        )

        let diagnostics = harness.engine.runDiagnostics
        XCTAssertEqual(diagnostics.mainModel, SettingsStore.defaultInterviewMainAnswerModel)
        XCTAssertEqual(diagnostics.ownerModel, SettingsStore.defaultInterviewMainAnswerModel)
        XCTAssertEqual(diagnostics.provider, .openAIAPI)
        XCTAssertEqual(diagnostics.reasoningEffort, .low)
        XCTAssertEqual(diagnostics.followUpAnswersCompleted, 3)
        XCTAssertEqual(diagnostics.followUpAnswersTotal, 3)
        XCTAssertEqual(diagnostics.followUpAnswerMilliseconds.count, 3)
        XCTAssertEqual(diagnostics.citationValidationPassed, true)
        XCTAssertEqual(diagnostics.followUpPipelineState, .completed)
    }

    func testNewQuestionArchivesCompleteRoundAndKeepsMatchedPredictionVisible() async {
        let terra = ProgressiveProvider(
            behavior: .success(marker: "Terra", delayMilliseconds: 10),
            supportsFollowUps: true
        )
        let harness = makeHarness(
            api: terra,
            codex: ProgressiveProvider(behavior: .failure(.invalidResponse))
        )

        submitQuestion("如何推广企业 AI 产品？", to: harness)
        let firstRoundCompleted = await waitUntil {
            harness.engine.followUpPipelineState == .completed
        }
        XCTAssertTrue(firstRoundCompleted)

        submitCandidateAnswer("我会先从目标客户和试点场景开始。", to: harness)
        submitQuestion("你如何验证效果？", to: harness)

        XCTAssertEqual(harness.engine.archivedRounds.count, 1)
        XCTAssertEqual(harness.engine.archivedRounds.first?.followUpSuggestions?.items.count, 3)
        XCTAssertEqual(harness.engine.archivedRounds.first?.followUpAnswers?.count, 3)
        XCTAssertEqual(harness.engine.archivedRounds.first?.hasCompleteFollowUps, true)
        XCTAssertEqual(harness.engine.predictedFollowUpQuestion, "你如何验证效果？")
        XCTAssertNotNil(harness.engine.predictedFollowUpAnswer)

        let didFinishNewAnswer = await waitUntil {
            await terra.requestCount() == 2 && harness.engine.progressiveAnswer != nil
        }
        XCTAssertTrue(didFinishNewAnswer)
        XCTAssertEqual(harness.engine.predictedFollowUpQuestion, "你如何验证效果？")
        XCTAssertNotNil(harness.engine.predictedFollowUpAnswer)
    }

    func testEndingInterviewArchivesFinalCompleteRound() async {
        let terra = ProgressiveProvider(
            behavior: .success(marker: "Terra", delayMilliseconds: 0),
            supportsFollowUps: true
        )
        let harness = makeHarness(
            api: terra,
            codex: ProgressiveProvider(behavior: .failure(.invalidResponse))
        )

        submitQuestion("如何推广企业 AI 产品？", to: harness)
        let roundCompleted = await waitUntil {
            harness.engine.followUpPipelineState == .completed
        }
        XCTAssertTrue(roundCompleted)

        harness.engine.endInterviewAudioSession()

        XCTAssertEqual(harness.engine.archivedRounds.count, 1)
        XCTAssertEqual(harness.engine.archivedRounds.first?.hasCompleteFollowUps, true)
    }

    func testEndingInterviewWaitsForFinalRoundFollowUpsToPersist() async {
        let terra = ProgressiveProvider(
            behavior: .success(marker: "Terra", delayMilliseconds: 0),
            supportsFollowUps: true,
            followUpAnswerDelayMilliseconds: 60
        )
        let harness = makeHarness(
            api: terra,
            codex: ProgressiveProvider(behavior: .failure(.invalidResponse))
        )
        harness.engine.setSessionID("ending-session")

        submitQuestion("如何推广企业 AI 产品？", to: harness)
        let followUpsStarted = await waitUntil {
            harness.engine.followUpSuggestions?.items.count == 3
                && harness.engine.followUpAnswersByQuestion.count < 3
        }
        XCTAssertTrue(followUpsStarted)

        harness.engine.endInterviewAudioSession()
        await harness.engine.awaitPendingInterviewHistoryPersistence()

        XCTAssertEqual(harness.engine.archivedRounds.first?.hasCompleteFollowUps, true)
        let persisted = await harness.savedAnswers.latestRecord(sessionID: "ending-session")
        XCTAssertEqual(persisted?.hasCompleteFollowUps, true)
        XCTAssertEqual(persisted?.followUpAnswers?.count, 3)
    }

    func testNewQuestionsAccumulateArchivedRoundsWithoutClearingEarlierHistory() async {
        let terra = ProgressiveProvider(
            behavior: .success(marker: "Terra", delayMilliseconds: 0),
            supportsFollowUps: true
        )
        let harness = makeHarness(
            api: terra,
            codex: ProgressiveProvider(behavior: .failure(.invalidResponse))
        )

        submitQuestion("第一轮：如何定义目标？", to: harness)
        let firstRoundCompleted = await waitUntil {
            harness.engine.followUpPipelineState == .completed
        }
        XCTAssertTrue(firstRoundCompleted)
        submitCandidateAnswer("我会先统一目标。", to: harness)
        submitQuestion("第二轮：如何验证结果？", to: harness)
        let secondRoundCompleted = await waitUntil {
            harness.engine.followUpPipelineState == .completed
        }
        XCTAssertTrue(secondRoundCompleted)
        submitCandidateAnswer("我会建立指标闭环。", to: harness)
        submitQuestion("第三轮：如何复盘？", to: harness)

        XCTAssertEqual(harness.engine.archivedRounds.count, 2)
        XCTAssertEqual(
            Set(harness.engine.archivedRounds.map(\.question)),
            Set(["第一轮：如何定义目标？", "第二轮：如何验证结果？"])
        )
        XCTAssertTrue(harness.engine.archivedRounds.allSatisfy(\.hasCompleteFollowUps))
    }

    func testPersistedRoundsReloadAndParticipateInPredictionMatching() async {
        let suggestions = InterviewFollowUpSet(items: [
            .init(question: "你如何验证效果？", intent: "考察指标闭环"),
            .init(question: "最大的风险是什么？", intent: "考察风险意识"),
            .init(question: "资源继续减少怎么办？", intent: "考察取舍"),
        ])
        let predictedAnswer = InterviewFollowUpAnswer(
            directOpening: "我会先定义成功指标。",
            talkingPoints: ["定义基线", "分阶段验证"],
            sampleAnswer: "我会先定义基线和成功指标，再通过分阶段实验验证。",
            sourceIDs: [],
            estimatedSpeakingSeconds: 25
        )
        let storedRound = InterviewHistoryAnswer(
            id: UUID(),
            createdAt: Date(),
            question: "如何推广企业 AI 产品？",
            answer: InterviewReferenceAnswer(
                segments: [
                    .init(label: "结论", text: "先聚焦高价值场景。", sourceIDs: []),
                    .init(label: "方法", text: "用试点验证价值。", sourceIDs: []),
                    .init(label: "收束", text: "再复制规模化。", sourceIDs: []),
                ],
                missingFacts: [],
                estimatedSpeakingSeconds: 45
            ),
            followUpSuggestions: suggestions,
            followUpAnswers: Dictionary(uniqueKeysWithValues: suggestions.items.map {
                ($0.question, predictedAnswer)
            })
        )
        let terra = ProgressiveProvider(
            behavior: .success(marker: "Terra", delayMilliseconds: 10),
            supportsFollowUps: true
        )
        let harness = makeHarness(
            api: terra,
            codex: ProgressiveProvider(behavior: .failure(.invalidResponse)),
            loadedAnswers: [storedRound]
        )

        harness.engine.setSessionID("restored-session")
        let didLoad = await waitUntil { harness.engine.archivedRounds.count == 1 }
        XCTAssertTrue(didLoad)

        submitQuestion("你如何验证这个方案的效果？", to: harness)

        XCTAssertEqual(harness.engine.predictedFollowUpQuestion, "你如何验证效果？")
        XCTAssertEqual(harness.engine.predictedFollowUpAnswer, predictedAnswer)
    }

    func testPredictionMatchingRecognizesParaphraseFromPreviousRound() async {
        let suggestions = InterviewFollowUpSet(items: [
            .init(question: "你如何验证效果？", intent: "考察指标闭环"),
            .init(question: "最大的风险是什么？", intent: "考察风险意识"),
            .init(question: "资源继续减少怎么办？", intent: "考察取舍"),
        ])
        let predictedAnswer = InterviewFollowUpAnswer(
            directOpening: "我会先定义成功指标。",
            talkingPoints: ["定义基线", "分阶段验证"],
            sampleAnswer: "我会先定义基线和成功指标，再通过分阶段实验验证。",
            sourceIDs: [],
            estimatedSpeakingSeconds: 25
        )
        let storedRound = InterviewHistoryAnswer(
            id: UUID(),
            createdAt: Date(),
            question: "如何推广企业 AI 产品？",
            answer: InterviewReferenceAnswer(
                segments: [.init(label: "结论", text: "先聚焦高价值场景。", sourceIDs: [])],
                missingFacts: [],
                estimatedSpeakingSeconds: 30
            ),
            followUpSuggestions: suggestions,
            followUpAnswers: Dictionary(uniqueKeysWithValues: suggestions.items.map {
                ($0.question, predictedAnswer)
            })
        )
        let harness = makeHarness(
            api: ProgressiveProvider(
                behavior: .success(marker: "Terra", delayMilliseconds: 10),
                supportsFollowUps: true
            ),
            codex: ProgressiveProvider(behavior: .failure(.invalidResponse)),
            loadedAnswers: [storedRound]
        )

        harness.engine.setSessionID("paraphrase-session")
        let didLoad = await waitUntil { harness.engine.archivedRounds.count == 1 }
        XCTAssertTrue(didLoad)

        submitQuestion("怎么判断这个项目最后做得好不好？", to: harness)

        XCTAssertEqual(harness.engine.predictedFollowUpQuestion, "你如何验证效果？")
        XCTAssertEqual(harness.engine.predictedFollowUpAnswer, predictedAnswer)
    }

    func testArchivedRoundFinishesMissingFollowUpAnswersInBackground() async {
        let terra = ProgressiveProvider(
            behavior: .success(marker: "Terra", delayMilliseconds: 0),
            supportsFollowUps: true,
            followUpAnswerDelayMilliseconds: 80
        )
        let harness = makeHarness(
            api: terra,
            codex: ProgressiveProvider(behavior: .failure(.invalidResponse))
        )

        submitQuestion("如何推广企业 AI 产品？", to: harness)
        let followUpsStarted = await waitUntil {
            harness.engine.followUpSuggestions?.items.count == 3
                && harness.engine.followUpAnswersByQuestion.count < 3
        }
        XCTAssertTrue(followUpsStarted)

        submitCandidateAnswer("我会先做一个小范围试点。", to: harness)
        submitQuestion("请介绍你的长期职业规划。", to: harness)

        let archivedRoundCompleted = await waitUntil {
            harness.engine.archivedRounds.first?.hasCompleteFollowUps == true
        }
        XCTAssertTrue(archivedRoundCompleted)
        XCTAssertEqual(harness.engine.archivedRounds.first?.followUpAnswers?.count, 3)
    }

    func testFollowUpFailureContinuesWithRemainingAnswers() async {
        let terra = ProgressiveProvider(
            behavior: .success(marker: "Terra", delayMilliseconds: 0),
            supportsFollowUps: true,
            failingFollowUpAnswerIndices: [1]
        )
        let harness = makeHarness(api: terra, codex: ProgressiveProvider(behavior: .failure(.invalidResponse)))

        submitQuestion("如何推广企业 AI 产品？", to: harness)

        let didFinish = await waitUntil {
            harness.engine.followUpPipelineState == .partiallyFailed(failedIndices: [2])
        }
        let maximumConcurrency = await terra.maximumFollowUpAnswerConcurrency()
        let events = await terra.followUpEvents()
        XCTAssertTrue(didFinish)
        let questions = harness.engine.followUpSuggestions?.items.map(\.question) ?? []
        XCTAssertEqual(questions.count, 3)
        XCTAssertEqual(harness.engine.followUpAnswerState(for: questions[0]), .completed)
        XCTAssertEqual(harness.engine.followUpAnswerState(for: questions[1]), .failed)
        XCTAssertEqual(harness.engine.followUpAnswerState(for: questions[2]), .completed)
        XCTAssertNotNil(harness.engine.followUpAnswer(for: questions[0]))
        XCTAssertNil(harness.engine.followUpAnswer(for: questions[1]))
        XCTAssertNotNil(harness.engine.followUpAnswer(for: questions[2]))
        XCTAssertEqual(maximumConcurrency, 1)
        XCTAssertEqual(
            events,
            ["questions", "start:A1", "finish:A1", "start:A2", "fail:A2", "start:A3", "finish:A3"]
        )
    }

    func testFollowUpQuestionSetMustContainExactlyThreeItems() async {
        let terra = ProgressiveProvider(
            behavior: .success(marker: "Terra", delayMilliseconds: 0),
            supportsFollowUps: true,
            followUpSuggestionCount: 4
        )
        let harness = makeHarness(api: terra, codex: ProgressiveProvider(behavior: .failure(.invalidResponse)))

        submitQuestion("如何推广企业 AI 产品？", to: harness)

        let didFail = await waitUntil { harness.engine.followUpPipelineState == .failed }
        XCTAssertTrue(didFail)
        XCTAssertNil(harness.engine.followUpSuggestions)
        XCTAssertEqual(harness.engine.followUpGenerationState, .failed)
    }

    func testFollowUpRegenerationKeepsStableAnswerUntilAtomicReplacement() async {
        let terra = ProgressiveProvider(
            behavior: .success(marker: "Terra", delayMilliseconds: 0),
            supportsFollowUps: true,
            followUpAnswerDelayMilliseconds: 30
        )
        let harness = makeHarness(api: terra, codex: ProgressiveProvider(behavior: .failure(.invalidResponse)))
        submitQuestion("如何推广企业 AI 产品？", to: harness)
        let didComplete = await waitUntil { harness.engine.followUpPipelineState == .completed }
        XCTAssertTrue(didComplete)
        guard let first = harness.engine.followUpSuggestions?.items.first,
              let stable = harness.engine.followUpAnswer(for: first.question) else {
            return XCTFail("缺少首个追问答案")
        }

        harness.engine.answerFollowUp(first)

        XCTAssertEqual(harness.engine.followUpAnswerState(for: first.question), .generating)
        XCTAssertEqual(harness.engine.followUpAnswer(for: first.question), stable)
        let didReplace = await waitUntil {
            harness.engine.followUpAnswerState(for: first.question) == .completed
                && harness.engine.followUpAnswer(for: first.question) != stable
        }
        let maximumConcurrency = await terra.maximumFollowUpAnswerConcurrency()
        XCTAssertTrue(didReplace)
        XCTAssertEqual(maximumConcurrency, 1)
    }

    func testStoppedFollowUpRequestCannotWriteBackLateResult() async {
        let terra = ProgressiveProvider(
            behavior: .success(marker: "Terra", delayMilliseconds: 0),
            supportsFollowUps: true,
            followUpAnswerDelayMilliseconds: 200,
            ignoreFollowUpAnswerCancellation: true
        )
        let harness = makeHarness(api: terra, codex: ProgressiveProvider(behavior: .failure(.invalidResponse)))
        submitQuestion("如何推广企业 AI 产品？", to: harness)
        let didStart = await waitUntil {
            harness.engine.followUpPipelineState == .generatingAnswer(index: 1, total: 3)
        }
        let providerDidStart = await waitUntil {
            await terra.followUpEvents().contains("start:A1")
        }
        XCTAssertTrue(didStart)
        XCTAssertTrue(providerDidStart)
        let firstQuestion = harness.engine.followUpSuggestions?.items.first?.question

        harness.engine.stopGeneration()
        let providerDidFinish = await waitUntil {
            await terra.followUpEvents().contains("finish:A1")
        }

        XCTAssertTrue(providerDidFinish)
        XCTAssertEqual(harness.engine.followUpPipelineState, .stopped)
        if let firstQuestion {
            XCTAssertNil(harness.engine.followUpAnswer(for: firstQuestion))
            XCTAssertEqual(harness.engine.followUpAnswerState(for: firstQuestion), .stopped)
        }
    }

    func testCandidateTranscriptPrivacyStillDefaultsToLocalOnly() async {
        let terra = ProgressiveProvider(behavior: .success(marker: "Terra", delayMilliseconds: 0))
        let harness = makeHarness(api: terra, codex: ProgressiveProvider(behavior: .failure(.invalidResponse)))
        let candidate = Utterance(text: "PrivateCandidateContext987", speaker: .you)
        XCTAssertTrue(harness.transcriptStore.append(candidate, suppressAcousticEcho: false))
        harness.engine.onUtterance(candidate)

        submitQuestion("下一题：如何复盘？", to: harness)
        let didFinish = await waitUntil { harness.engine.progressiveAnswer != nil }
        XCTAssertTrue(didFinish)

        let prompt = await terra.latestPrompt()
        XCTAssertFalse(prompt.contains("PrivateCandidateContext987"))
        XCTAssertTrue(harness.engine.candidateContextText.contains("PrivateCandidateContext987"))
    }

    func testLongCandidateContextKeepsHeadAndTailWithinLimit() {
        let original = "HEAD-" + String(repeating: "中", count: 2_000) + "-TAIL"
        let compacted = CustomerCopilotEngine.compactCandidateContext(original, limit: 500)
        XCTAssertLessThanOrEqual(compacted.count, 500)
        XCTAssertTrue(compacted.hasPrefix("HEAD-"))
        XCTAssertTrue(compacted.hasSuffix("-TAIL"))
        XCTAssertTrue(compacted.contains("中间转写已省略"))
    }

    func testAnswerLensProjectsOverviewThenOneDetailCardPerSpinePoint() async {
        let terra = ProgressiveProvider(behavior: .success(marker: "Terra", delayMilliseconds: 0))
        let harness = makeHarness(api: terra, codex: ProgressiveProvider(behavior: .failure(.invalidResponse)))

        submitQuestion("如何判断产品优先级？", to: harness)
        let didFinish = await waitUntil { harness.engine.progressiveAnswer != nil }
        XCTAssertTrue(didFinish)

        let snapshot = InterviewLensProjector.snapshot(from: harness.engine, selection: .answer)
        XCTAssertEqual(snapshot.units.map(\.kind), [
            .directOpening, .quickIdea, .talkingPoint, .talkingPoint, .talkingPoint,
        ])
        XCTAssertEqual(snapshot.units.first?.label, "先说这句")
        XCTAssertEqual(snapshot.units[1].label, "逻辑主线")
        XCTAssertEqual(snapshot.units[1].text, "1. 统一目标\n2. 比较取舍\n3. 验证调整")
        XCTAssertEqual(snapshot.units.dropFirst(2).map(\.label), [
            "1. 统一目标",
            "2. 比较取舍",
            "3. 验证调整",
        ])
        XCTAssertEqual(snapshot.units.dropFirst(2).map(\.text), [
            "先对齐业务目标、目标用户和成功指标。",
            "再用同一标准比较候选方案。",
            "最后通过小范围验证决定是否继续投入。",
        ])
        XCTAssertTrue(snapshot.units.dropFirst(2).allSatisfy(\.startNewPage))
        XCTAssertFalse(snapshot.navigationSelections.contains(.question))
    }

    private func makeHarness(
        api: ProgressiveProvider,
        codex: ProgressiveProvider,
        loadedAnswers: [InterviewHistoryAnswer] = []
    ) -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("liveinterviewcopilot-progressive-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "com.jude864huang.liveinterviewcopilot.progressive-tests.\(UUID().uuidString)"
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
        settings.interviewIncludeCandidateAnswersInContext = false

        let transcriptStore = TranscriptStore()
        let historyStore = CopilotHistoryStore(databaseURL: root.appendingPathComponent("history.sqlite"))
        let savedAnswers = InterviewAnswerCapture()
        let engine = CustomerCopilotEngine(
            transcriptStore: transcriptStore,
            compiler: KnowledgePackageCompiler(stateDirectory: root),
            worker: CodexWorkerClient(workerPath: nil),
            historyStore: historyStore,
            settings: settings,
            apiProvider: api,
            codexProvider: codex,
            apiCredentialProvider: { "test-only-key" },
            interviewAnswerSaveHandler: { sessionID, record in
                await savedAnswers.save(sessionID: sessionID, record: record)
            },
            interviewAnswerLoadHandler: { _ in loadedAnswers },
            defaults: defaults
        )
        return Harness(
            engine: engine,
            transcriptStore: transcriptStore,
            settings: settings,
            savedAnswers: savedAnswers
        )
    }

    private func submitQuestion(_ text: String, to harness: Harness) {
        let utterance = Utterance(text: text, speaker: .them)
        XCTAssertTrue(harness.transcriptStore.append(utterance, suppressAcousticEcho: false))
        harness.engine.onUtterance(utterance)
    }

    private func submitCandidateAnswer(_ text: String, to harness: Harness) {
        let utterance = Utterance(text: text, speaker: .you)
        XCTAssertTrue(harness.transcriptStore.append(utterance, suppressAcousticEcho: false))
        harness.engine.onUtterance(utterance)
    }

    private func waitUntil(
        attempts: Int = 300,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private struct Harness {
        let engine: CustomerCopilotEngine
        let transcriptStore: TranscriptStore
        let settings: SettingsStore
        let savedAnswers: InterviewAnswerCapture
    }
}

private actor InterviewAnswerCapture {
    private var recordsBySession: [String: [UUID: InterviewHistoryAnswer]] = [:]

    func save(sessionID: String, record: InterviewHistoryAnswer) {
        recordsBySession[sessionID, default: [:]][record.id] = record
    }

    func latestRecord(sessionID: String) -> InterviewHistoryAnswer? {
        recordsBySession[sessionID]?.values.max { $0.createdAt < $1.createdAt }
    }
}

private actor ProgressiveProvider: InterviewGenerationProvider {
    enum Behavior: Sendable {
        case success(marker: String, delayMilliseconds: Int)
        case entryThenFailure(marker: String)
        case failure(CopilotError)
        case unsafeCandidateFact
    }

    private let behavior: Behavior
    private let fallbackModel: String?
    private let fallbackBehavior: Behavior?
    private let supportsFollowUps: Bool
    private let followUpSuggestionCount: Int
    private let failingFollowUpAnswerIndices: Set<Int>
    private let followUpAnswerDelayMilliseconds: Int
    private let ignoreFollowUpAnswerCancellation: Bool
    private var requests = 0
    private var prompts: [String] = []
    private var reasoningEfforts: [InterviewReasoningEffort] = []
    private var followUpAnswerAttemptsByIndex: [Int: Int] = [:]
    private var activeFollowUpAnswerRequests = 0
    private var maximumActiveFollowUpAnswerRequests = 0
    private var recordedFollowUpEvents: [String] = []

    init(
        behavior: Behavior,
        fallbackModel: String? = nil,
        fallbackBehavior: Behavior? = nil,
        supportsFollowUps: Bool = false,
        followUpSuggestionCount: Int = 3,
        failingFollowUpAnswerIndices: Set<Int> = [],
        followUpAnswerDelayMilliseconds: Int = 5,
        ignoreFollowUpAnswerCancellation: Bool = false
    ) {
        self.behavior = behavior
        self.fallbackModel = fallbackModel
        self.fallbackBehavior = fallbackBehavior
        self.supportsFollowUps = supportsFollowUps
        self.followUpSuggestionCount = followUpSuggestionCount
        self.failingFollowUpAnswerIndices = failingFollowUpAnswerIndices
        self.followUpAnswerDelayMilliseconds = followUpAnswerDelayMilliseconds
        self.ignoreFollowUpAnswerCancellation = ignoreFollowUpAnswerCancellation
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
        case .entryThenFailure(let marker):
            let answer = Self.answer(marker: marker)
            onProgress(.init(entry: answer.entry, spine: [], segments: [], closing: nil, metadata: nil))
            await Task.yield()
            throw CopilotError.invalidResponse
        case .unsafeCandidateFact:
            let answer = Self.answer(marker: "Unsafe")
            var unsafe = answer
            unsafe.entry = InterviewAnswerEntry(
                mode: .directAnswer,
                text: "我主导过增长项目并把转化率提升了 30%。",
                assumption: nil,
                claimType: .candidateFact,
                sourceIDs: []
            )
            onProgress(.init(entry: unsafe.entry, spine: [], segments: [], closing: nil, metadata: nil))
            return unsafe
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
        guard supportsFollowUps else { throw CopilotError.invalidResponse }
        recordedFollowUpEvents.append("questions")
        return InterviewFollowUpSet(items: Array(Self.followUpSuggestions.prefix(followUpSuggestionCount)))
    }

    func generateFollowUpAnswer(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewFollowUpAnswer {
        guard supportsFollowUps,
              let index = Self.followUpSuggestions.firstIndex(where: {
                  request.prompt.contains($0.question)
              }) else { throw CopilotError.invalidResponse }
        let label = "A\(index + 1)"
        activeFollowUpAnswerRequests += 1
        maximumActiveFollowUpAnswerRequests = max(
            maximumActiveFollowUpAnswerRequests,
            activeFollowUpAnswerRequests
        )
        recordedFollowUpEvents.append("start:\(label)")
        defer { activeFollowUpAnswerRequests -= 1 }
        if followUpAnswerDelayMilliseconds > 0 {
            if ignoreFollowUpAnswerCancellation {
                try? await Task.sleep(for: .milliseconds(followUpAnswerDelayMilliseconds))
            } else {
                try await Task.sleep(for: .milliseconds(followUpAnswerDelayMilliseconds))
            }
        }
        if failingFollowUpAnswerIndices.contains(index) {
            recordedFollowUpEvents.append("fail:\(label)")
            throw CopilotError.invalidResponse
        }
        let attempt = (followUpAnswerAttemptsByIndex[index] ?? 0) + 1
        followUpAnswerAttemptsByIndex[index] = attempt
        recordedFollowUpEvents.append("finish:\(label)")
        return InterviewFollowUpAnswer(
            directOpening: "\(label)-v\(attempt)：先直接回答，再说明判断依据。",
            talkingPoints: ["明确判断标准", "给出验证和边界"],
            sampleAnswer: "我会先直接回应这个追问，再说明判断标准、验证方法和适用边界。",
            sourceIDs: [],
            estimatedSpeakingSeconds: 30
        )
    }

    func cancel(id: UUID) {}

    func requestCount() -> Int { requests }
    func latestPrompt() -> String { prompts.last ?? "" }
    func latestReasoningEffort() -> InterviewReasoningEffort? { reasoningEfforts.last }
    func maximumFollowUpAnswerConcurrency() -> Int { maximumActiveFollowUpAnswerRequests }
    func followUpEvents() -> [String] { recordedFollowUpEvents }

    private static let followUpSuggestions: [InterviewFollowUpSuggestion] = [
        .init(question: "你如何验证效果？", intent: "考察指标闭环"),
        .init(question: "最大的风险是什么？", intent: "考察风险意识"),
        .init(question: "资源继续减少怎么办？", intent: "考察取舍"),
        .init(question: "如果结果不及预期怎么办？", intent: "考察复盘能力"),
    ]

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
