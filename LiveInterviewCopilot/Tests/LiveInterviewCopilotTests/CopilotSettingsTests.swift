import AppKit
import XCTest
@testable import LiveInterviewCopilotKit

@MainActor
final class CopilotSettingsTests: XCTestCase {
    private final class SecretBox: @unchecked Sendable {
        var values: [String: String] = [:]
    }

    private func makeStore(
        defaults: UserDefaults? = nil,
        secretBox: SecretBox = SecretBox()
    ) -> SettingsStore {
        let suite = defaults ?? {
            let name = "com.jude864huang.liveinterviewcopilot.copilot-settings.\(UUID().uuidString)"
            let value = UserDefaults(suiteName: name)!
            value.removePersistentDomain(forName: name)
            return value
        }()
        return SettingsStore(storage: SettingsStorage(
            defaults: suite,
            secretStore: AppSecretStore(
                loadValue: { secretBox.values[$0] },
                saveValue: { secretBox.values[$0] = $1 }
            ),
            defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            runMigrations: false
        ))
    }

    func testInterviewDefaultsUseManualTencentModeAndDefaultShortcut() {
        let store = makeStore()

        XCTAssertEqual(store.interviewAudioMode, .manualStreamingASR)
        XCTAssertTrue(store.interviewASRAutoHotwordsEnabled)
        XCTAssertTrue(store.interviewAutoReferenceAnswerEnabled)
        XCTAssertEqual(
            store.interviewReferenceAnswerModel,
            SettingsStore.defaultInterviewReferenceAnswerModel
        )
        XCTAssertEqual(store.interviewCodexModel, SettingsStore.defaultInterviewCodexModel)
        XCTAssertEqual(store.interviewCodexReasoningEffort, .low)
        XCTAssertFalse(store.interviewIncludeCandidateAnswersInContext)
        XCTAssertTrue(store.interviewCodexSpeedModeEnabled)
        XCTAssertFalse(store.interviewCodexFastServiceTierEnabled)
        XCTAssertEqual(store.interviewCodexCueModel, SettingsStore.defaultInterviewCodexCueModel)
        XCTAssertTrue(store.interviewDelayedFallbackEnabled)
        XCTAssertEqual(store.interviewAnswerDepth, .standard)
        XCTAssertEqual(
            store.interviewKnowledgeBriefTokenBudget,
            SettingsStore.defaultInterviewKnowledgeBriefTokenBudget
        )
        XCTAssertEqual(store.copilotTurnHotkey, .defaultTurn)
        XCTAssertFalse(store.interviewLensEnabled)
        XCTAssertEqual(store.interviewLensLastSelection, .answer)
        XCTAssertEqual(store.interviewLensFontScale, .percent115)
        XCTAssertEqual(store.interviewLensSize, .defaultValue)
        XCTAssertEqual(store.interviewLensDisplayPlacements, [:])
        XCTAssertFalse(store.suggestionsAlwaysOnTop)
    }

    func testCodexModelAndReasoningSettingsRoundTrip() {
        let store = makeStore()

        store.interviewCodexModel = "gpt-5.6-luna"
        store.interviewCodexReasoningEffort = .xhigh

        XCTAssertEqual(store.interviewCodexModel, "gpt-5.6-luna")
        XCTAssertEqual(store.interviewCodexReasoningEffort, .xhigh)
    }

    func testGenerationRoutePersistsWithoutCreatingAnInterviewEngine() {
        let name = "com.jude864huang.liveinterviewcopilot.copilot-route.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.interviewInferencePreference, .apiPreferred)

        store.interviewInferencePreference = .codexOnly

        XCTAssertEqual(store.interviewInferencePreference, .codexOnly)
        XCTAssertEqual(defaults.string(forKey: "copilotInferenceProvider"), "codexOnly")
        XCTAssertEqual(makeStore(defaults: defaults).interviewInferencePreference, .codexOnly)
    }

    func testCodexCLIUsesTheUpdatedUserFacingLabels() {
        XCTAssertEqual(InterviewInferencePreference.codexOnly.label, "仅 Codex CLI")
        XCTAssertEqual(InterviewProvider.codexSubscription.label, "Codex CLI")
    }

    func testInterviewLensSupportedSelectionsAndFontScalesAreStable() {
        XCTAssertEqual(
            InterviewLensPersistentSelection.allCases.map(\.rawValue),
            ["question", "answer", "quickIdea", "referenceAnswer", "followUps"]
        )
        XCTAssertEqual(
            InterviewLensFontScale.allCases.map(\.rawValue),
            [100, 115, 130, 150, 175, 200]
        )
        XCTAssertEqual(InterviewLensFontScale.percent150.multiplier, 1.5)
    }

    func testInterviewLensInvalidStoredValuesAreNormalized() throws {
        let name = "com.jude864huang.liveinterviewcopilot.copilot-lens-normalization.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set("follow-up-42", forKey: "interviewLensLastSelection")
        defaults.set(999, forKey: "interviewLensFontScale")
        defaults.set(
            Data(#"{"width":100,"height":900}"#.utf8),
            forKey: "interviewLensSize"
        )
        defaults.set(
            Data(
                #"{"display-A":{"normalizedX":-0.25,"normalizedY":1.4,"size":{"width":800,"height":100}}}"#.utf8
            ),
            forKey: "interviewLensDisplayPlacements"
        )

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.interviewLensLastSelection, .answer)
        XCTAssertEqual(store.interviewLensFontScale, .percent115)
        XCTAssertEqual(store.interviewLensSize, InterviewLensSize(width: 440, height: 320))
        XCTAssertEqual(
            store.interviewLensDisplayPlacements["display-A"],
            InterviewLensDisplayPlacement(
                normalizedX: 0,
                normalizedY: 1,
                size: InterviewLensSize(width: 680, height: 220)
            )
        )

        XCTAssertEqual(defaults.string(forKey: "interviewLensLastSelection"), "answer")
        XCTAssertEqual(defaults.integer(forKey: "interviewLensFontScale"), 115)
        XCTAssertEqual(
            try JSONDecoder().decode(
                InterviewLensSize.self,
                from: XCTUnwrap(defaults.data(forKey: "interviewLensSize"))
            ),
            InterviewLensSize(width: 440, height: 320)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                [String: InterviewLensDisplayPlacement].self,
                from: XCTUnwrap(defaults.data(forKey: "interviewLensDisplayPlacements"))
            )["display-A"],
            store.interviewLensDisplayPlacements["display-A"]
        )

        XCTAssertEqual(
            InterviewLensSize(width: .nan, height: .infinity),
            .defaultValue
        )
        let nonFinitePlacement = InterviewLensDisplayPlacement(
            normalizedX: .nan,
            normalizedY: -.infinity
        )
        XCTAssertEqual(nonFinitePlacement.normalizedX, 0.5)
        XCTAssertEqual(nonFinitePlacement.normalizedY, 0.5)
    }

    func testInterviewLensPreferencesRoundTripAcrossStoreInstances() {
        let name = "com.jude864huang.liveinterviewcopilot.copilot-lens-round-trip.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let placements = [
            "builtin-display": InterviewLensDisplayPlacement(
                normalizedX: 0.2,
                normalizedY: 0.75,
                size: InterviewLensSize(width: 620, height: 320)
            ),
            "external-display": InterviewLensDisplayPlacement(
                normalizedX: 0.85,
                normalizedY: 0.1
            ),
        ]

        let firstStore = makeStore(defaults: defaults)
        firstStore.interviewLensEnabled = true
        firstStore.interviewLensLastSelection = .answer
        firstStore.interviewLensFontScale = .percent175
        firstStore.interviewLensSize = InterviewLensSize(width: 640, height: 340)
        firstStore.interviewLensDisplayPlacements = placements

        let restoredStore = makeStore(defaults: defaults)
        XCTAssertTrue(restoredStore.interviewLensEnabled)
        XCTAssertEqual(restoredStore.interviewLensLastSelection, .answer)
        XCTAssertEqual(restoredStore.interviewLensFontScale, .percent175)
        XCTAssertEqual(
            restoredStore.interviewLensSize,
            InterviewLensSize(width: 640, height: 340)
        )
        XCTAssertEqual(restoredStore.interviewLensDisplayPlacements, placements)
    }

    func testAutoReferenceAnswerPreferenceRoundTripsThroughDefaults() {
        let name = "com.jude864huang.liveinterviewcopilot.copilot-reference-answer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let firstStore = makeStore(defaults: defaults)
        XCTAssertTrue(firstStore.interviewAutoReferenceAnswerEnabled)
        firstStore.interviewAutoReferenceAnswerEnabled = false
        firstStore.interviewReferenceAnswerModel = "  gpt-5.6-sol  "
        firstStore.interviewIncludeCandidateAnswersInContext = true

        let restoredStore = makeStore(defaults: defaults)
        XCTAssertFalse(restoredStore.interviewAutoReferenceAnswerEnabled)
        XCTAssertEqual(restoredStore.interviewReferenceAnswerModel, "gpt-5.6-sol")
        XCTAssertTrue(restoredStore.interviewIncludeCandidateAnswersInContext)
    }

    func testCodexSpeedPreferencesRoundTripThroughDefaults() {
        let name = "com.jude864huang.liveinterviewcopilot.copilot-codex-speed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let firstStore = makeStore(defaults: defaults)
        XCTAssertTrue(firstStore.interviewCodexSpeedModeEnabled)
        XCTAssertFalse(firstStore.interviewCodexFastServiceTierEnabled)

        firstStore.interviewCodexSpeedModeEnabled = false
        firstStore.interviewCodexFastServiceTierEnabled = true
        firstStore.interviewCodexCueModel = "  gpt-5.4  "
        firstStore.interviewKnowledgeBriefTokenBudget = 6_000

        let restoredStore = makeStore(defaults: defaults)
        XCTAssertFalse(restoredStore.interviewCodexSpeedModeEnabled)
        XCTAssertTrue(restoredStore.interviewCodexFastServiceTierEnabled)
        XCTAssertEqual(restoredStore.interviewCodexCueModel, "gpt-5.4")
        XCTAssertEqual(restoredStore.interviewKnowledgeBriefTokenBudget, 6_000)
    }

    func testSingleAnswerSettingsReuseLegacyModelKeysAndPersistNewControls() {
        let name = "com.jude864huang.liveinterviewcopilot.copilot-single-answer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set("legacy-terra", forKey: "interviewReferenceAnswerModel")
        defaults.set("legacy-spark", forKey: "interviewCodexCueModel")

        let firstStore = makeStore(defaults: defaults)
        XCTAssertEqual(firstStore.interviewMainAnswerModel, "legacy-terra")
        XCTAssertEqual(firstStore.interviewFallbackAnswerModel, "legacy-spark")
        XCTAssertTrue(firstStore.interviewDelayedFallbackEnabled)
        XCTAssertEqual(firstStore.interviewAnswerDepth, .standard)

        firstStore.interviewMainAnswerModel = "new-terra"
        firstStore.interviewFallbackAnswerModel = "new-spark"
        firstStore.interviewDelayedFallbackEnabled = false
        firstStore.interviewAnswerDepth = .deep

        let restored = makeStore(defaults: defaults)
        XCTAssertEqual(restored.interviewReferenceAnswerModel, "new-terra")
        XCTAssertEqual(restored.interviewCodexCueModel, "new-spark")
        XCTAssertFalse(restored.interviewDelayedFallbackEnabled)
        XCTAssertEqual(restored.interviewAnswerDepth, .deep)
    }

    func testKnowledgeBriefBudgetIsClampedToSupportedRange() {
        let store = makeStore()

        store.interviewKnowledgeBriefTokenBudget = 100
        XCTAssertEqual(
            store.interviewKnowledgeBriefTokenBudget,
            SettingsStore.interviewKnowledgeBriefTokenRange.lowerBound
        )

        store.interviewKnowledgeBriefTokenBudget = 100_000
        XCTAssertEqual(
            store.interviewKnowledgeBriefTokenBudget,
            SettingsStore.interviewKnowledgeBriefTokenRange.upperBound
        )
    }

    func testTencentSecretsUseSecretStoreAndAreTrimmed() {
        let box = SecretBox()
        let store = makeStore(secretBox: box)

        store.tencentASRAppID = " 123456 "
        store.tencentASRSecretID = " id-value \n"
        store.tencentASRSecretKey = " key-value \n"

        XCTAssertEqual(store.tencentASRAppID, "123456")
        XCTAssertEqual(box.values["tencentASRSecretID"], "id-value")
        XCTAssertEqual(box.values["tencentASRSecretKey"], "key-value")
        XCTAssertTrue(store.hasTencentASRCredentials)
    }

    func testTurnShortcutRoundTripsThroughDefaults() {
        let name = "com.jude864huang.liveinterviewcopilot.copilot-hotkey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let shortcut = CopilotTurnHotkey(
            keyCode: 40,
            modifierRawValue: NSEvent.ModifierFlags([.command, .shift]).rawValue,
            keyLabel: "K"
        )

        makeStore(defaults: defaults).copilotTurnHotkey = shortcut

        XCTAssertEqual(makeStore(defaults: defaults).copilotTurnHotkey, shortcut)
    }

    func testManualTermsMergeExistingVocabularyAndOverrides() {
        let store = makeStore()
        store.transcriptionCustomVocabulary = "OpenAI, CRM"
        store.interviewASRHotwordOverrides = "crm\n腾讯云"

        XCTAssertEqual(store.interviewASRManualTerms, ["OpenAI", "CRM", "腾讯云"])
    }

    func testShortcutValidationRejectsAppConflictsAndWarnsForSystemShortcut() {
        XCTAssertEqual(
            CopilotTurnHotkeyValidation.validate(.merge),
            .invalid("该组合已用于“合并上一段”。")
        )
        XCTAssertEqual(
            CopilotTurnHotkeyValidation.validate(.lensPrevious),
            .invalid("该按键已用于镜头模式翻页。")
        )
        XCTAssertEqual(
            CopilotTurnHotkeyValidation.validate(.lensNext),
            .invalid("该按键已用于镜头模式翻页。")
        )
        XCTAssertEqual(CopilotTurnHotkey.lensToggle.displayName, "⌥A")
        XCTAssertEqual(
            CopilotTurnHotkeyValidation.validate(.lensToggle),
            .invalid("该组合已用于“镜头卡开关”。")
        )
        let toggleMeeting = CopilotTurnHotkey(
            keyCode: 37,
            modifierRawValue: NSEvent.ModifierFlags([.command, .shift]).rawValue,
            keyLabel: "L"
        )
        XCTAssertEqual(
            CopilotTurnHotkeyValidation.validate(toggleMeeting),
            .invalid("该组合已被 LiveInterviewCopilot 的现有操作使用。")
        )
        let commandQ = CopilotTurnHotkey(
            keyCode: 12,
            modifierRawValue: NSEvent.ModifierFlags.command.rawValue,
            keyLabel: "Q"
        )
        guard case .systemConflict = CopilotTurnHotkeyValidation.validate(commandQ) else {
            return XCTFail("Expected a macOS shortcut conflict warning")
        }
        XCTAssertEqual(
            CopilotHotkeyManager.action(for: .defaultTurn, primaryShortcut: .defaultTurn),
            .commitTurn
        )
        XCTAssertEqual(
            CopilotHotkeyManager.action(for: .stop, primaryShortcut: .defaultTurn),
            .stopGeneration
        )
        XCTAssertEqual(
            CopilotHotkeyManager.action(for: .lensToggle, primaryShortcut: .defaultTurn),
            .toggleLens
        )
        XCTAssertEqual(
            CopilotHotkeyManager.action(for: .lensToggle, primaryShortcut: .lensToggle),
            .toggleLens,
            "The fixed lens action must win over a legacy saved primary shortcut"
        )
        XCTAssertEqual(
            CopilotHotkeyManager.action(for: .lensPrevious, primaryShortcut: .defaultTurn),
            .lensPreviousPage
        )
        XCTAssertEqual(
            CopilotHotkeyManager.action(for: .lensNext, primaryShortcut: .defaultTurn),
            .lensNextPage
        )
    }
}
