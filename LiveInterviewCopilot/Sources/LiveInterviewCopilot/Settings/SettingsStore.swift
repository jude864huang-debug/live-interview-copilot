import AppKit
import CoreAudio
import Foundation
import Observation
import Security
import SQLite3

@Observable
@MainActor
final class SettingsStore {
    static let defaultInterviewCodexCueModel = "gpt-5.3-codex-spark"
    static let defaultInterviewReferenceAnswerModel = "gpt-5.6-terra"
    static let defaultInterviewCodexModel = "gpt-5.6-terra"
    static let interviewCodexModelPresets = ["gpt-5.6-terra", "gpt-5.6-luna"]
    static let defaultInterviewMainAnswerModel = defaultInterviewReferenceAnswerModel
    static let defaultInterviewFallbackAnswerModel = defaultInterviewCodexCueModel
    static let defaultInterviewKnowledgeBriefTokenBudget = 6_000
    static let interviewKnowledgeBriefTokenRange = 4_000...6_000

    private let defaults: UserDefaults
    private let secretStore: AppSecretStore
    private static let enableLiveTranscriptCleanupLegacyKey = "enableTranscriptRefinement"
    private static let enableBatchRetranscriptionLegacyKey = "enableBatchRefinement"
    @ObservationIgnored private var loadedSecretKeys: Set<String> = []

    private static func normalizedIdentifierList(_ values: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for rawValue in values {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func normalizeDefaultNotesTemplateID(_ value: UUID?) -> UUID? {
        guard value != TemplateStore.genericID else { return nil }
        return value
    }

    private func loadSecretIfNeeded(
        key: String,
        currentValue: String,
        assign: (String) -> Void
    ) -> String {
        guard !loadedSecretKeys.contains(key) else { return currentValue }
        let value = secretStore.load(key: key) ?? ""
        loadedSecretKeys.insert(key)
        assign(value)
        return value
    }

    private func markSecretLoaded(_ key: String) {
        loadedSecretKeys.insert(key)
    }

    func isSecretLoaded(_ key: String) -> Bool {
        loadedSecretKeys.contains(key)
    }

    // MARK: - AI Settings

    @ObservationIgnored nonisolated(unsafe) private var _llmProvider: LLMProvider
    var llmProvider: LLMProvider {
        get { access(keyPath: \.llmProvider); return _llmProvider }
        set {
            withMutation(keyPath: \.llmProvider) {
                _llmProvider = newValue
                defaults.set(newValue.rawValue, forKey: "llmProvider")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openRouterApiKey: String
    var openRouterApiKey: String {
        get {
            access(keyPath: \.openRouterApiKey)
            return loadSecretIfNeeded(key: "openRouterApiKey", currentValue: _openRouterApiKey) {
                _openRouterApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.openRouterApiKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _openRouterApiKey = trimmed
                markSecretLoaded("openRouterApiKey")
                secretStore.save(key: "openRouterApiKey", value: trimmed)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _requestyApiKey: String
    var requestyApiKey: String {
        get {
            access(keyPath: \.requestyApiKey)
            return loadSecretIfNeeded(key: "requestyApiKey", currentValue: _requestyApiKey) {
                _requestyApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.requestyApiKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _requestyApiKey = trimmed
                markSecretLoaded("requestyApiKey")
                secretStore.save(key: "requestyApiKey", value: trimmed)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _requestyBaseURL: String
    var requestyBaseURL: String {
        get { access(keyPath: \.requestyBaseURL); return _requestyBaseURL }
        set {
            withMutation(keyPath: \.requestyBaseURL) {
                _requestyBaseURL = newValue
                defaults.set(newValue, forKey: "requestyBaseURL")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _requestyModel: String
    var requestyModel: String {
        get { access(keyPath: \.requestyModel); return _requestyModel }
        set {
            withMutation(keyPath: \.requestyModel) {
                _requestyModel = newValue
                defaults.set(newValue, forKey: "requestyModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openAIApiKey: String
    var openAIApiKey: String {
        get {
            access(keyPath: \.openAIApiKey)
            return loadSecretIfNeeded(key: "openAIApiKey", currentValue: _openAIApiKey) {
                _openAIApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.openAIApiKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _openAIApiKey = trimmed
                markSecretLoaded("openAIApiKey")
                secretStore.save(key: "openAIApiKey", value: trimmed)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openAIBaseURL: String
    var openAIBaseURL: String {
        get { access(keyPath: \.openAIBaseURL); return _openAIBaseURL }
        set {
            withMutation(keyPath: \.openAIBaseURL) {
                _openAIBaseURL = newValue
                defaults.set(newValue, forKey: "openAIBaseURL")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openAIModel: String
    var openAIModel: String {
        get { access(keyPath: \.openAIModel); return _openAIModel }
        set {
            withMutation(keyPath: \.openAIModel) {
                _openAIModel = newValue
                defaults.set(newValue, forKey: "openAIModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _anthropicApiKey: String
    var anthropicApiKey: String {
        get {
            access(keyPath: \.anthropicApiKey)
            return loadSecretIfNeeded(key: "anthropicApiKey", currentValue: _anthropicApiKey) {
                _anthropicApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.anthropicApiKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _anthropicApiKey = trimmed
                markSecretLoaded("anthropicApiKey")
                secretStore.save(key: "anthropicApiKey", value: trimmed)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _anthropicBaseURL: String
    var anthropicBaseURL: String {
        get { access(keyPath: \.anthropicBaseURL); return _anthropicBaseURL }
        set {
            withMutation(keyPath: \.anthropicBaseURL) {
                _anthropicBaseURL = newValue
                defaults.set(newValue, forKey: "anthropicBaseURL")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _anthropicModel: String
    var anthropicModel: String {
        get { access(keyPath: \.anthropicModel); return _anthropicModel }
        set {
            withMutation(keyPath: \.anthropicModel) {
                _anthropicModel = newValue
                defaults.set(newValue, forKey: "anthropicModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _assemblyAIApiKey: String
    var assemblyAIApiKey: String {
        get {
            access(keyPath: \.assemblyAIApiKey)
            return loadSecretIfNeeded(key: "assemblyAIApiKey", currentValue: _assemblyAIApiKey) {
                _assemblyAIApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.assemblyAIApiKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _assemblyAIApiKey = trimmed
                markSecretLoaded("assemblyAIApiKey")
                secretStore.save(key: "assemblyAIApiKey", value: trimmed)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _elevenLabsApiKey: String
    var elevenLabsApiKey: String {
        get {
            access(keyPath: \.elevenLabsApiKey)
            return loadSecretIfNeeded(key: "elevenLabsApiKey", currentValue: _elevenLabsApiKey) {
                _elevenLabsApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.elevenLabsApiKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _elevenLabsApiKey = trimmed
                markSecretLoaded("elevenLabsApiKey")
                secretStore.save(key: "elevenLabsApiKey", value: trimmed)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _cohereApiKey: String
    var cohereApiKey: String {
        get {
            access(keyPath: \.cohereApiKey)
            return loadSecretIfNeeded(key: "cohereApiKey", currentValue: _cohereApiKey) {
                _cohereApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.cohereApiKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _cohereApiKey = trimmed
                markSecretLoaded("cohereApiKey")
                secretStore.save(key: "cohereApiKey", value: trimmed)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _ollamaBaseURL: String
    var ollamaBaseURL: String {
        get { access(keyPath: \.ollamaBaseURL); return _ollamaBaseURL }
        set {
            withMutation(keyPath: \.ollamaBaseURL) {
                _ollamaBaseURL = newValue
                defaults.set(newValue, forKey: "ollamaBaseURL")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _ollamaLLMModel: String
    var ollamaLLMModel: String {
        get { access(keyPath: \.ollamaLLMModel); return _ollamaLLMModel }
        set {
            withMutation(keyPath: \.ollamaLLMModel) {
                _ollamaLLMModel = newValue
                defaults.set(newValue, forKey: "ollamaLLMModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _ollamaEmbedModel: String
    var ollamaEmbedModel: String {
        get { access(keyPath: \.ollamaEmbedModel); return _ollamaEmbedModel }
        set {
            withMutation(keyPath: \.ollamaEmbedModel) {
                _ollamaEmbedModel = newValue
                defaults.set(newValue, forKey: "ollamaEmbedModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _mlxBaseURL: String
    var mlxBaseURL: String {
        get { access(keyPath: \.mlxBaseURL); return _mlxBaseURL }
        set {
            withMutation(keyPath: \.mlxBaseURL) {
                _mlxBaseURL = newValue
                defaults.set(newValue, forKey: "mlxBaseURL")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _mlxModel: String
    var mlxModel: String {
        get { access(keyPath: \.mlxModel); return _mlxModel }
        set {
            withMutation(keyPath: \.mlxModel) {
                _mlxModel = newValue
                defaults.set(newValue, forKey: "mlxModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _lmStudioBaseURL: String
    var lmStudioBaseURL: String {
        get { access(keyPath: \.lmStudioBaseURL); return _lmStudioBaseURL }
        set {
            withMutation(keyPath: \.lmStudioBaseURL) {
                _lmStudioBaseURL = newValue
                defaults.set(newValue, forKey: "lmStudioBaseURL")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _lmStudioApiKey: String
    var lmStudioApiKey: String {
        get {
            access(keyPath: \.lmStudioApiKey)
            return loadSecretIfNeeded(key: "lmStudioApiKey", currentValue: _lmStudioApiKey) {
                _lmStudioApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.lmStudioApiKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _lmStudioApiKey = trimmed
                markSecretLoaded("lmStudioApiKey")
                secretStore.save(key: "lmStudioApiKey", value: trimmed)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _lmStudioModel: String
    var lmStudioModel: String {
        get { access(keyPath: \.lmStudioModel); return _lmStudioModel }
        set {
            withMutation(keyPath: \.lmStudioModel) {
                _lmStudioModel = newValue
                defaults.set(newValue, forKey: "lmStudioModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openAILLMBaseURL: String
    var openAILLMBaseURL: String {
        get { access(keyPath: \.openAILLMBaseURL); return _openAILLMBaseURL }
        set {
            withMutation(keyPath: \.openAILLMBaseURL) {
                _openAILLMBaseURL = newValue
                defaults.set(newValue, forKey: "openAILLMBaseURL")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openAILLMApiKey: String
    var openAILLMApiKey: String {
        get {
            access(keyPath: \.openAILLMApiKey)
            return loadSecretIfNeeded(key: "openAILLMApiKey", currentValue: _openAILLMApiKey) {
                _openAILLMApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.openAILLMApiKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _openAILLMApiKey = trimmed
                markSecretLoaded("openAILLMApiKey")
                secretStore.save(key: "openAILLMApiKey", value: trimmed)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openAILLMModel: String
    var openAILLMModel: String {
        get { access(keyPath: \.openAILLMModel); return _openAILLMModel }
        set {
            withMutation(keyPath: \.openAILLMModel) {
                _openAILLMModel = newValue
                defaults.set(newValue, forKey: "openAILLMModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openAIEmbedBaseURL: String
    var openAIEmbedBaseURL: String {
        get { access(keyPath: \.openAIEmbedBaseURL); return _openAIEmbedBaseURL }
        set {
            withMutation(keyPath: \.openAIEmbedBaseURL) {
                _openAIEmbedBaseURL = newValue
                defaults.set(newValue, forKey: "openAIEmbedBaseURL")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openAIEmbedApiKey: String
    var openAIEmbedApiKey: String {
        get {
            access(keyPath: \.openAIEmbedApiKey)
            return loadSecretIfNeeded(key: "openAIEmbedApiKey", currentValue: _openAIEmbedApiKey) {
                _openAIEmbedApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.openAIEmbedApiKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _openAIEmbedApiKey = trimmed
                markSecretLoaded("openAIEmbedApiKey")
                secretStore.save(key: "openAIEmbedApiKey", value: trimmed)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openAIEmbedModel: String
    var openAIEmbedModel: String {
        get { access(keyPath: \.openAIEmbedModel); return _openAIEmbedModel }
        set {
            withMutation(keyPath: \.openAIEmbedModel) {
                _openAIEmbedModel = newValue
                defaults.set(newValue, forKey: "openAIEmbedModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _selectedModel: String
    var selectedModel: String {
        get { access(keyPath: \.selectedModel); return _selectedModel }
        set {
            withMutation(keyPath: \.selectedModel) {
                _selectedModel = newValue
                defaults.set(newValue, forKey: "selectedModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _defaultNotesTemplateID: UUID?
    var defaultNotesTemplateID: UUID? {
        get { access(keyPath: \.defaultNotesTemplateID); return _defaultNotesTemplateID }
        set {
            withMutation(keyPath: \.defaultNotesTemplateID) {
                let normalized = Self.normalizeDefaultNotesTemplateID(newValue)
                _defaultNotesTemplateID = normalized
                if let normalized {
                    defaults.set(normalized.uuidString, forKey: "defaultNotesTemplateID")
                } else {
                    defaults.removeObject(forKey: "defaultNotesTemplateID")
                }
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _embeddingProvider: EmbeddingProvider
    var embeddingProvider: EmbeddingProvider {
        get { access(keyPath: \.embeddingProvider); return _embeddingProvider }
        set {
            withMutation(keyPath: \.embeddingProvider) {
                _embeddingProvider = newValue
                defaults.set(newValue.rawValue, forKey: "embeddingProvider")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _voyageApiKey: String
    var voyageApiKey: String {
        get {
            access(keyPath: \.voyageApiKey)
            return loadSecretIfNeeded(key: "voyageApiKey", currentValue: _voyageApiKey) {
                _voyageApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.voyageApiKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _voyageApiKey = trimmed
                markSecretLoaded("voyageApiKey")
                secretStore.save(key: "voyageApiKey", value: trimmed)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _suggestionVerbosity: SuggestionVerbosity
    var suggestionVerbosity: SuggestionVerbosity {
        get { access(keyPath: \.suggestionVerbosity); return _suggestionVerbosity }
        set {
            withMutation(keyPath: \.suggestionVerbosity) {
                _suggestionVerbosity = newValue
                defaults.set(newValue.rawValue, forKey: "suggestionVerbosity")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _enableLiveTranscriptCleanup: Bool
    var enableLiveTranscriptCleanup: Bool {
        get { access(keyPath: \.enableLiveTranscriptCleanup); return _enableLiveTranscriptCleanup }
        set {
            withMutation(keyPath: \.enableLiveTranscriptCleanup) {
                _enableLiveTranscriptCleanup = newValue
                defaults.set(newValue, forKey: "enableLiveTranscriptCleanup")
                defaults.set(newValue, forKey: Self.enableLiveTranscriptCleanupLegacyKey)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _realtimeModel: String
    var realtimeModel: String {
        get { access(keyPath: \.realtimeModel); return _realtimeModel }
        set {
            withMutation(keyPath: \.realtimeModel) {
                _realtimeModel = newValue
                defaults.set(newValue, forKey: "realtimeModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _realtimeOllamaModel: String
    var realtimeOllamaModel: String {
        get { access(keyPath: \.realtimeOllamaModel); return _realtimeOllamaModel }
        set {
            withMutation(keyPath: \.realtimeOllamaModel) {
                _realtimeOllamaModel = newValue
                defaults.set(newValue, forKey: "realtimeOllamaModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _suggestionPanelEnabled: Bool
    var suggestionPanelEnabled: Bool {
        get { access(keyPath: \.suggestionPanelEnabled); return _suggestionPanelEnabled }
        set {
            withMutation(keyPath: \.suggestionPanelEnabled) {
                _suggestionPanelEnabled = newValue
                defaults.set(newValue, forKey: "suggestionPanelEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _suggestionsAlwaysOnTop: Bool
    var suggestionsAlwaysOnTop: Bool {
        get { access(keyPath: \.suggestionsAlwaysOnTop); return _suggestionsAlwaysOnTop }
        set {
            withMutation(keyPath: \.suggestionsAlwaysOnTop) {
                _suggestionsAlwaysOnTop = newValue
                defaults.set(newValue, forKey: "suggestionsAlwaysOnTop")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _sidebarMode: SidebarMode
    var sidebarMode: SidebarMode {
        get { access(keyPath: \.sidebarMode); return _sidebarMode }
        set {
            withMutation(keyPath: \.sidebarMode) {
                _sidebarMode = newValue
                defaults.set(newValue.rawValue, forKey: "sidebarMode")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _sidecastIntensity: SidecastIntensity
    var sidecastIntensity: SidecastIntensity {
        get { access(keyPath: \.sidecastIntensity); return _sidecastIntensity }
        set {
            withMutation(keyPath: \.sidecastIntensity) {
                _sidecastIntensity = newValue
                defaults.set(newValue.rawValue, forKey: "sidecastIntensity")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _sidecastPersonas: [SidecastPersona]
    var sidecastPersonas: [SidecastPersona] {
        get { access(keyPath: \.sidecastPersonas); return _sidecastPersonas }
        set {
            withMutation(keyPath: \.sidecastPersonas) {
                _sidecastPersonas = newValue
                defaults.set(Self.encodePersonas(newValue), forKey: "sidecastPersonas")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _sidecastTemperature: Double
    var sidecastTemperature: Double {
        get { access(keyPath: \.sidecastTemperature); return _sidecastTemperature }
        set {
            withMutation(keyPath: \.sidecastTemperature) {
                _sidecastTemperature = newValue
                defaults.set(newValue, forKey: "sidecastTemperature")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _sidecastMaxTokens: Int
    var sidecastMaxTokens: Int {
        get { access(keyPath: \.sidecastMaxTokens); return _sidecastMaxTokens }
        set {
            withMutation(keyPath: \.sidecastMaxTokens) {
                _sidecastMaxTokens = newValue
                defaults.set(newValue, forKey: "sidecastMaxTokens")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _sidecastSystemPrompt: String
    var sidecastSystemPrompt: String {
        get { access(keyPath: \.sidecastSystemPrompt); return _sidecastSystemPrompt }
        set {
            withMutation(keyPath: \.sidecastSystemPrompt) {
                _sidecastSystemPrompt = newValue
                defaults.set(newValue, forKey: "sidecastSystemPrompt")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _sidecastMinValueThreshold: Double
    var sidecastMinValueThreshold: Double {
        get { access(keyPath: \.sidecastMinValueThreshold); return _sidecastMinValueThreshold }
        set {
            withMutation(keyPath: \.sidecastMinValueThreshold) {
                _sidecastMinValueThreshold = newValue
                defaults.set(newValue, forKey: "sidecastMinValueThreshold")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _preFetchIntervalSeconds: Double
    var preFetchIntervalSeconds: Double {
        get { access(keyPath: \.preFetchIntervalSeconds); return _preFetchIntervalSeconds }
        set {
            withMutation(keyPath: \.preFetchIntervalSeconds) {
                _preFetchIntervalSeconds = newValue
                defaults.set(newValue, forKey: "preFetchIntervalSeconds")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _kbSimilarityThreshold: Double
    var kbSimilarityThreshold: Double {
        get { access(keyPath: \.kbSimilarityThreshold); return _kbSimilarityThreshold }
        set {
            withMutation(keyPath: \.kbSimilarityThreshold) {
                _kbSimilarityThreshold = newValue
                defaults.set(newValue, forKey: "kbSimilarityThreshold")
            }
        }
    }

    // MARK: - Interview Copilot Settings

    @ObservationIgnored nonisolated(unsafe) private var _interviewAudioMode: InterviewAudioMode
    var interviewAudioMode: InterviewAudioMode {
        get { access(keyPath: \.interviewAudioMode); return _interviewAudioMode }
        set {
            withMutation(keyPath: \.interviewAudioMode) {
                _interviewAudioMode = newValue
                defaults.set(newValue.rawValue, forKey: "interviewAudioMode")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _tencentASRAppID: String
    var tencentASRAppID: String {
        get { access(keyPath: \.tencentASRAppID); return _tencentASRAppID }
        set {
            withMutation(keyPath: \.tencentASRAppID) {
                _tencentASRAppID = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                defaults.set(_tencentASRAppID, forKey: "tencentASRAppID")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _tencentASRSecretID: String
    var tencentASRSecretID: String {
        get {
            access(keyPath: \.tencentASRSecretID)
            return loadSecretIfNeeded(key: "tencentASRSecretID", currentValue: _tencentASRSecretID) {
                _tencentASRSecretID = $0
            }
        }
        set {
            withMutation(keyPath: \.tencentASRSecretID) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _tencentASRSecretID = trimmed
                markSecretLoaded("tencentASRSecretID")
                secretStore.save(key: "tencentASRSecretID", value: trimmed)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _tencentASRSecretKey: String
    var tencentASRSecretKey: String {
        get {
            access(keyPath: \.tencentASRSecretKey)
            return loadSecretIfNeeded(key: "tencentASRSecretKey", currentValue: _tencentASRSecretKey) {
                _tencentASRSecretKey = $0
            }
        }
        set {
            withMutation(keyPath: \.tencentASRSecretKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _tencentASRSecretKey = trimmed
                markSecretLoaded("tencentASRSecretKey")
                secretStore.save(key: "tencentASRSecretKey", value: trimmed)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewASRAutoHotwordsEnabled: Bool
    var interviewASRAutoHotwordsEnabled: Bool {
        get { access(keyPath: \.interviewASRAutoHotwordsEnabled); return _interviewASRAutoHotwordsEnabled }
        set {
            withMutation(keyPath: \.interviewASRAutoHotwordsEnabled) {
                _interviewASRAutoHotwordsEnabled = newValue
                defaults.set(newValue, forKey: "interviewASRAutoHotwordsEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewAutoReferenceAnswerEnabled: Bool
    var interviewAutoReferenceAnswerEnabled: Bool {
        get {
            access(keyPath: \.interviewAutoReferenceAnswerEnabled)
            return _interviewAutoReferenceAnswerEnabled
        }
        set {
            withMutation(keyPath: \.interviewAutoReferenceAnswerEnabled) {
                _interviewAutoReferenceAnswerEnabled = newValue
                defaults.set(newValue, forKey: "interviewAutoReferenceAnswerEnabled")
            }
        }
    }

    /// The selected text-generation route belongs to settings, not to a live
    /// interview engine. Settings windows may exist before that engine does.
    @ObservationIgnored nonisolated(unsafe) private var _interviewInferencePreference: InterviewInferencePreference
    var interviewInferencePreference: InterviewInferencePreference {
        get {
            access(keyPath: \.interviewInferencePreference)
            return _interviewInferencePreference
        }
        set {
            withMutation(keyPath: \.interviewInferencePreference) {
                _interviewInferencePreference = newValue
                // Keep the established key so existing user selections migrate
                // without a one-off data conversion.
                defaults.set(newValue.rawValue, forKey: "copilotInferenceProvider")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewReferenceAnswerModel: String
    var interviewReferenceAnswerModel: String {
        get {
            access(keyPath: \.interviewReferenceAnswerModel)
            return _interviewReferenceAnswerModel
        }
        set {
            withMutation(keyPath: \.interviewReferenceAnswerModel) {
                _interviewReferenceAnswerModel = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                defaults.set(_interviewReferenceAnswerModel, forKey: "interviewReferenceAnswerModel")
            }
        }
    }

    /// Renamed public surface for the v7 single-answer pipeline. The legacy
    /// storage key is intentionally retained so upgrades do not lose choices.
    var interviewMainAnswerModel: String {
        get { interviewReferenceAnswerModel }
        set { interviewReferenceAnswerModel = newValue }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewAPIProtocol: InterviewAPIProtocol
    var interviewAPIProtocol: InterviewAPIProtocol {
        get {
            access(keyPath: \.interviewAPIProtocol)
            return _interviewAPIProtocol
        }
        set {
            withMutation(keyPath: \.interviewAPIProtocol) {
                _interviewAPIProtocol = newValue
                defaults.set(newValue.rawValue, forKey: "interviewAPIProtocol")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewAPIBaseURL: String
    var interviewAPIBaseURL: String {
        get { access(keyPath: \.interviewAPIBaseURL); return _interviewAPIBaseURL }
        set {
            withMutation(keyPath: \.interviewAPIBaseURL) {
                _interviewAPIBaseURL = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                defaults.set(_interviewAPIBaseURL, forKey: "interviewAPIBaseURL")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewAPIKey: String
    var interviewAPIKey: String {
        get {
            access(keyPath: \.interviewAPIKey)
            return loadSecretIfNeeded(key: "interviewAPIKey", currentValue: _interviewAPIKey) {
                _interviewAPIKey = $0
            }
        }
        set {
            withMutation(keyPath: \.interviewAPIKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _interviewAPIKey = trimmed
                markSecretLoaded("interviewAPIKey")
                secretStore.save(key: "interviewAPIKey", value: trimmed)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewAPIModel: String
    var interviewAPIModel: String {
        get { access(keyPath: \.interviewAPIModel); return _interviewAPIModel }
        set {
            withMutation(keyPath: \.interviewAPIModel) {
                _interviewAPIModel = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                defaults.set(_interviewAPIModel, forKey: "interviewAPIModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewAPIModelOptions: [String]
    var interviewAPIModelOptions: [String] {
        get { access(keyPath: \.interviewAPIModelOptions); return _interviewAPIModelOptions }
        set {
            withMutation(keyPath: \.interviewAPIModelOptions) {
                _interviewAPIModelOptions = newValue
                defaults.set(newValue, forKey: "interviewAPIModelOptions")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewAPIFastServiceTierEnabled: Bool
    var interviewAPIFastServiceTierEnabled: Bool {
        get { access(keyPath: \.interviewAPIFastServiceTierEnabled); return _interviewAPIFastServiceTierEnabled }
        set {
            withMutation(keyPath: \.interviewAPIFastServiceTierEnabled) {
                _interviewAPIFastServiceTierEnabled = newValue
                defaults.set(newValue, forKey: "interviewAPIFastServiceTierEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewAPIProvider: InterviewAPIProvider
    var interviewAPIProvider: InterviewAPIProvider {
        get {
            access(keyPath: \.interviewAPIProvider)
            return _interviewAPIProvider
        }
        set {
            withMutation(keyPath: \.interviewAPIProvider) {
                _interviewAPIProvider = newValue
                defaults.set(newValue.rawValue, forKey: "copilotAPIProvider")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _deepSeekApiKey: String
    var deepSeekApiKey: String {
        get {
            access(keyPath: \.deepSeekApiKey)
            return loadSecretIfNeeded(key: "deepSeekApiKey", currentValue: _deepSeekApiKey) {
                _deepSeekApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.deepSeekApiKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _deepSeekApiKey = trimmed
                markSecretLoaded("deepSeekApiKey")
                secretStore.save(key: "deepSeekApiKey", value: trimmed)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _deepSeekBaseURL: String
    var deepSeekBaseURL: String {
        get { access(keyPath: \.deepSeekBaseURL); return _deepSeekBaseURL }
        set {
            withMutation(keyPath: \.deepSeekBaseURL) {
                _deepSeekBaseURL = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                defaults.set(_deepSeekBaseURL, forKey: "deepSeekBaseURL")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewDeepSeekModel: String
    var interviewDeepSeekModel: String {
        get { access(keyPath: \.interviewDeepSeekModel); return _interviewDeepSeekModel }
        set {
            withMutation(keyPath: \.interviewDeepSeekModel) {
                _interviewDeepSeekModel = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                defaults.set(_interviewDeepSeekModel, forKey: "interviewDeepSeekModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewCodexModel: String
    var interviewCodexModel: String {
        get {
            access(keyPath: \.interviewCodexModel)
            return _interviewCodexModel
        }
        set {
            withMutation(keyPath: \.interviewCodexModel) {
                _interviewCodexModel = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                defaults.set(_interviewCodexModel, forKey: "interviewCodexModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewIncludeCandidateAnswersInContext: Bool
    var interviewIncludeCandidateAnswersInContext: Bool {
        get {
            access(keyPath: \.interviewIncludeCandidateAnswersInContext)
            return _interviewIncludeCandidateAnswersInContext
        }
        set {
            withMutation(keyPath: \.interviewIncludeCandidateAnswersInContext) {
                _interviewIncludeCandidateAnswersInContext = newValue
                defaults.set(newValue, forKey: "interviewIncludeCandidateAnswersInContext")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewCodexSpeedModeEnabled: Bool
    var interviewCodexSpeedModeEnabled: Bool {
        get {
            access(keyPath: \.interviewCodexSpeedModeEnabled)
            return _interviewCodexSpeedModeEnabled
        }
        set {
            withMutation(keyPath: \.interviewCodexSpeedModeEnabled) {
                _interviewCodexSpeedModeEnabled = newValue
                defaults.set(newValue, forKey: "interviewCodexSpeedModeEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewCodexCueModel: String
    var interviewCodexCueModel: String {
        get {
            access(keyPath: \.interviewCodexCueModel)
            return _interviewCodexCueModel
        }
        set {
            withMutation(keyPath: \.interviewCodexCueModel) {
                _interviewCodexCueModel = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                defaults.set(_interviewCodexCueModel, forKey: "interviewCodexCueModel")
            }
        }
    }

    var interviewFallbackAnswerModel: String {
        get { interviewCodexCueModel }
        set { interviewCodexCueModel = newValue }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewDelayedFallbackEnabled: Bool
    var interviewDelayedFallbackEnabled: Bool {
        get {
            access(keyPath: \.interviewDelayedFallbackEnabled)
            return _interviewDelayedFallbackEnabled
        }
        set {
            withMutation(keyPath: \.interviewDelayedFallbackEnabled) {
                _interviewDelayedFallbackEnabled = newValue
                defaults.set(newValue, forKey: "interviewDelayedFallbackEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewAnswerDepth: InterviewAnswerDepth
    var interviewAnswerDepth: InterviewAnswerDepth {
        get {
            access(keyPath: \.interviewAnswerDepth)
            return _interviewAnswerDepth
        }
        set {
            withMutation(keyPath: \.interviewAnswerDepth) {
                _interviewAnswerDepth = newValue
                defaults.set(newValue.rawValue, forKey: "interviewAnswerDepth")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewCodexReasoningEffort: InterviewReasoningEffort
    var interviewCodexReasoningEffort: InterviewReasoningEffort {
        get {
            access(keyPath: \.interviewCodexReasoningEffort)
            return _interviewCodexReasoningEffort
        }
        set {
            withMutation(keyPath: \.interviewCodexReasoningEffort) {
                _interviewCodexReasoningEffort = newValue
                defaults.set(newValue.rawValue, forKey: "interviewCodexReasoningEffort")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewKnowledgeBriefTokenBudget: Int
    var interviewKnowledgeBriefTokenBudget: Int {
        get {
            access(keyPath: \.interviewKnowledgeBriefTokenBudget)
            return _interviewKnowledgeBriefTokenBudget
        }
        set {
            withMutation(keyPath: \.interviewKnowledgeBriefTokenBudget) {
                _interviewKnowledgeBriefTokenBudget = min(
                    max(newValue, Self.interviewKnowledgeBriefTokenRange.lowerBound),
                    Self.interviewKnowledgeBriefTokenRange.upperBound
                )
                defaults.set(_interviewKnowledgeBriefTokenBudget, forKey: "interviewKnowledgeBriefTokenBudget")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewCodexFastServiceTierEnabled: Bool
    var interviewCodexFastServiceTierEnabled: Bool {
        get {
            access(keyPath: \.interviewCodexFastServiceTierEnabled)
            return _interviewCodexFastServiceTierEnabled
        }
        set {
            withMutation(keyPath: \.interviewCodexFastServiceTierEnabled) {
                _interviewCodexFastServiceTierEnabled = newValue
                defaults.set(newValue, forKey: "interviewCodexFastServiceTierEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewASRHotwordOverrides: String
    var interviewASRHotwordOverrides: String {
        get { access(keyPath: \.interviewASRHotwordOverrides); return _interviewASRHotwordOverrides }
        set {
            withMutation(keyPath: \.interviewASRHotwordOverrides) {
                _interviewASRHotwordOverrides = newValue
                defaults.set(newValue, forKey: "interviewASRHotwordOverrides")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _qwenASRExecutablePath: String
    var qwenASRExecutablePath: String {
        get { access(keyPath: \.qwenASRExecutablePath); return _qwenASRExecutablePath }
        set {
            withMutation(keyPath: \.qwenASRExecutablePath) {
                _qwenASRExecutablePath = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                defaults.set(_qwenASRExecutablePath, forKey: "qwenASRExecutablePath")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _qwenASRModelPath: String
    var qwenASRModelPath: String {
        get { access(keyPath: \.qwenASRModelPath); return _qwenASRModelPath }
        set {
            withMutation(keyPath: \.qwenASRModelPath) {
                _qwenASRModelPath = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                defaults.set(_qwenASRModelPath, forKey: "qwenASRModelPath")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _copilotTurnHotkey: CopilotTurnHotkey
    var copilotTurnHotkey: CopilotTurnHotkey {
        get { access(keyPath: \.copilotTurnHotkey); return _copilotTurnHotkey }
        set {
            withMutation(keyPath: \.copilotTurnHotkey) {
                _copilotTurnHotkey = newValue
                defaults.set(try? JSONEncoder().encode(newValue), forKey: "copilotTurnHotkey")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewLensEnabled: Bool
    var interviewLensEnabled: Bool {
        get { access(keyPath: \.interviewLensEnabled); return _interviewLensEnabled }
        set {
            withMutation(keyPath: \.interviewLensEnabled) {
                _interviewLensEnabled = newValue
                defaults.set(newValue, forKey: "interviewLensEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewLensLastSelection: InterviewLensPersistentSelection
    var interviewLensLastSelection: InterviewLensPersistentSelection {
        get { access(keyPath: \.interviewLensLastSelection); return _interviewLensLastSelection }
        set {
            withMutation(keyPath: \.interviewLensLastSelection) {
                _interviewLensLastSelection = newValue
                defaults.set(newValue.rawValue, forKey: "interviewLensLastSelection")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewLensFontScale: InterviewLensFontScale
    var interviewLensFontScale: InterviewLensFontScale {
        get { access(keyPath: \.interviewLensFontScale); return _interviewLensFontScale }
        set {
            withMutation(keyPath: \.interviewLensFontScale) {
                _interviewLensFontScale = newValue
                defaults.set(newValue.rawValue, forKey: "interviewLensFontScale")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewLensSize: InterviewLensSize
    var interviewLensSize: InterviewLensSize {
        get { access(keyPath: \.interviewLensSize); return _interviewLensSize }
        set {
            withMutation(keyPath: \.interviewLensSize) {
                _interviewLensSize = newValue
                defaults.set(try? JSONEncoder().encode(newValue), forKey: "interviewLensSize")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _interviewLensDisplayPlacements: [String: InterviewLensDisplayPlacement]
    var interviewLensDisplayPlacements: [String: InterviewLensDisplayPlacement] {
        get {
            access(keyPath: \.interviewLensDisplayPlacements)
            return _interviewLensDisplayPlacements
        }
        set {
            withMutation(keyPath: \.interviewLensDisplayPlacements) {
                _interviewLensDisplayPlacements = newValue
                defaults.set(
                    try? JSONEncoder().encode(newValue),
                    forKey: "interviewLensDisplayPlacements"
                )
            }
        }
    }

    // MARK: - Capture Settings

    @ObservationIgnored nonisolated(unsafe) private var _inputDeviceID: AudioDeviceID
    var inputDeviceID: AudioDeviceID {
        get { access(keyPath: \.inputDeviceID); return _inputDeviceID }
        set {
            withMutation(keyPath: \.inputDeviceID) {
                _inputDeviceID = newValue
                defaults.set(Int(newValue), forKey: "inputDeviceID")
                if newValue > 0 {
                    if let uid = MicCapture.deviceUID(for: newValue) {
                        defaults.set(uid, forKey: "inputDeviceUID")
                    }
                    let name = MicCapture.availableInputDevices().first(where: { $0.id == newValue })?.name
                    if let name { defaults.set(name, forKey: "inputDeviceName") }
                } else {
                    defaults.removeObject(forKey: "inputDeviceUID")
                    defaults.removeObject(forKey: "inputDeviceName")
                }
            }
        }
    }

    /// Stable UID of the last selected input device (survives reboots/reconnects).
    var inputDeviceUID: String? { defaults.string(forKey: "inputDeviceUID") }
    /// Cached display name for the last selected input device.
    var inputDeviceName: String? { defaults.string(forKey: "inputDeviceName") }

    @ObservationIgnored nonisolated(unsafe) private var _outputDeviceID: AudioDeviceID
    var outputDeviceID: AudioDeviceID {
        get { access(keyPath: \.outputDeviceID); return _outputDeviceID }
        set {
            withMutation(keyPath: \.outputDeviceID) {
                _outputDeviceID = newValue
                defaults.set(Int(newValue), forKey: "outputDeviceID")
                if newValue > 0 {
                    if let uid = try? SystemAudioCapture.outputDeviceUID(for: newValue) {
                        defaults.set(uid, forKey: "outputDeviceUID")
                    }
                    let name = SystemAudioCapture.availableOutputDevices().first(where: { $0.id == newValue })?.name
                    if let name { defaults.set(name, forKey: "outputDeviceName") }
                } else {
                    defaults.removeObject(forKey: "outputDeviceUID")
                    defaults.removeObject(forKey: "outputDeviceName")
                }
            }
        }
    }

    /// Stable UID of the last selected output device (survives reboots/reconnects).
    var outputDeviceUID: String? { defaults.string(forKey: "outputDeviceUID") }
    /// Cached display name for the last selected output device.
    var outputDeviceName: String? { defaults.string(forKey: "outputDeviceName") }

    @ObservationIgnored nonisolated(unsafe) private var _transcriptionModel: TranscriptionModel
    var transcriptionModel: TranscriptionModel {
        get { access(keyPath: \.transcriptionModel); return _transcriptionModel }
        set {
            withMutation(keyPath: \.transcriptionModel) {
                _transcriptionModel = newValue
                defaults.set(newValue.rawValue, forKey: "transcriptionModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _transcriptionLocale: String
    var transcriptionLocale: String {
        get { access(keyPath: \.transcriptionLocale); return _transcriptionLocale }
        set {
            withMutation(keyPath: \.transcriptionLocale) {
                _transcriptionLocale = newValue
                defaults.set(newValue, forKey: "transcriptionLocale")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _transcriptionCustomVocabulary: String
    var transcriptionCustomVocabulary: String {
        get { access(keyPath: \.transcriptionCustomVocabulary); return _transcriptionCustomVocabulary }
        set {
            withMutation(keyPath: \.transcriptionCustomVocabulary) {
                _transcriptionCustomVocabulary = newValue
                defaults.set(newValue, forKey: "transcriptionCustomVocabulary")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _removeFillerWords: Bool
    var removeFillerWords: Bool {
        get { access(keyPath: \.removeFillerWords); return _removeFillerWords }
        set {
            withMutation(keyPath: \.removeFillerWords) {
                _removeFillerWords = newValue
                defaults.set(newValue, forKey: "removeFillerWords")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _saveAudioRecording: Bool
    var saveAudioRecording: Bool {
        get { access(keyPath: \.saveAudioRecording); return _saveAudioRecording }
        set {
            withMutation(keyPath: \.saveAudioRecording) {
                _saveAudioRecording = newValue
                defaults.set(newValue, forKey: "saveAudioRecording")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _enableEchoCancellation: Bool
    var enableEchoCancellation: Bool {
        get { access(keyPath: \.enableEchoCancellation); return _enableEchoCancellation }
        set {
            withMutation(keyPath: \.enableEchoCancellation) {
                _enableEchoCancellation = newValue
                defaults.set(newValue, forKey: "enableEchoCancellation")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _enableBatchRetranscription: Bool
    var enableBatchRetranscription: Bool {
        get { access(keyPath: \.enableBatchRetranscription); return _enableBatchRetranscription }
        set {
            withMutation(keyPath: \.enableBatchRetranscription) {
                _enableBatchRetranscription = newValue
                defaults.set(newValue, forKey: "enableBatchRetranscription")
                defaults.set(newValue, forKey: Self.enableBatchRetranscriptionLegacyKey)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _batchTranscriptionModel: TranscriptionModel
    var batchTranscriptionModel: TranscriptionModel {
        get { access(keyPath: \.batchTranscriptionModel); return _batchTranscriptionModel }
        set {
            withMutation(keyPath: \.batchTranscriptionModel) {
                _batchTranscriptionModel = newValue
                defaults.set(newValue.rawValue, forKey: "batchTranscriptionModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _enableDiarization: Bool
    var enableDiarization: Bool {
        get { access(keyPath: \.enableDiarization); return _enableDiarization }
        set {
            withMutation(keyPath: \.enableDiarization) {
                _enableDiarization = newValue
                defaults.set(newValue, forKey: "enableDiarization")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _diarizationVariant: String
    var diarizationVariant: DiarizationVariant {
        get { access(keyPath: \.diarizationVariant); return DiarizationVariant(rawValue: _diarizationVariant) ?? .dihard3 }
        set {
            withMutation(keyPath: \.diarizationVariant) {
                _diarizationVariant = newValue.rawValue
                defaults.set(newValue.rawValue, forKey: "diarizationVariant")
            }
        }
    }

    // MARK: - Detection Settings

    @ObservationIgnored nonisolated(unsafe) private var _meetingAutoDetectEnabled: Bool
    var meetingAutoDetectEnabled: Bool {
        get { access(keyPath: \.meetingAutoDetectEnabled); return _meetingAutoDetectEnabled }
        set {
            withMutation(keyPath: \.meetingAutoDetectEnabled) {
                _meetingAutoDetectEnabled = newValue
                defaults.set(newValue, forKey: "meetingAutoDetectEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _customMeetingAppBundleIDs: [String]
    var customMeetingAppBundleIDs: [String] {
        get { access(keyPath: \.customMeetingAppBundleIDs); return _customMeetingAppBundleIDs }
        set {
            withMutation(keyPath: \.customMeetingAppBundleIDs) {
                _customMeetingAppBundleIDs = newValue
                defaults.set(newValue, forKey: "customMeetingAppBundleIDs")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _ignoredAppBundleIDs: [String]
    var ignoredAppBundleIDs: [String] {
        get { access(keyPath: \.ignoredAppBundleIDs); return _ignoredAppBundleIDs }
        set {
            withMutation(keyPath: \.ignoredAppBundleIDs) {
                _ignoredAppBundleIDs = newValue
                defaults.set(newValue, forKey: "ignoredAppBundleIDs")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _silenceTimeoutSeconds: Int
    /// Auto-stop a recording after this many seconds of silence. 0 disables it.
    /// Applies to both manual and auto-detected sessions.
    var silenceTimeoutSeconds: Int {
        get { access(keyPath: \.silenceTimeoutSeconds); return _silenceTimeoutSeconds }
        set {
            withMutation(keyPath: \.silenceTimeoutSeconds) {
                _silenceTimeoutSeconds = max(0, newValue)
                defaults.set(_silenceTimeoutSeconds, forKey: "silenceTimeoutSeconds")
            }
        }
    }

    /// The silence timeout read straight from persistent storage, bypassing the
    /// in-memory cache. A long-running recording reads this every poll so that a
    /// change made in the Settings window takes effect immediately, even if the
    /// session happens to hold a different `SettingsStore` instance than the UI.
    var persistedSilenceTimeoutSeconds: Int? {
        defaults.object(forKey: "silenceTimeoutSeconds") != nil
            ? defaults.integer(forKey: "silenceTimeoutSeconds")
            : nil
    }

    @ObservationIgnored nonisolated(unsafe) private var _silenceTimeoutUnitIsSeconds: Bool
    /// UI display preference for the silence timeout: true shows seconds, false minutes.
    var silenceTimeoutUnitIsSeconds: Bool {
        get { access(keyPath: \.silenceTimeoutUnitIsSeconds); return _silenceTimeoutUnitIsSeconds }
        set {
            withMutation(keyPath: \.silenceTimeoutUnitIsSeconds) {
                _silenceTimeoutUnitIsSeconds = newValue
                defaults.set(newValue, forKey: "silenceTimeoutUnitIsSeconds")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _detectionLogEnabled: Bool
    var detectionLogEnabled: Bool {
        get { access(keyPath: \.detectionLogEnabled); return _detectionLogEnabled }
        set {
            withMutation(keyPath: \.detectionLogEnabled) {
                _detectionLogEnabled = newValue
                defaults.set(newValue, forKey: "detectionLogEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _diagnosticLoggingEnabled: Bool
    var diagnosticLoggingEnabled: Bool {
        get { access(keyPath: \.diagnosticLoggingEnabled); return _diagnosticLoggingEnabled }
        set {
            withMutation(keyPath: \.diagnosticLoggingEnabled) {
                _diagnosticLoggingEnabled = newValue
                defaults.set(newValue, forKey: "diagnosticLoggingEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _hasShownAutoDetectExplanation: Bool
    var hasShownAutoDetectExplanation: Bool {
        get { access(keyPath: \.hasShownAutoDetectExplanation); return _hasShownAutoDetectExplanation }
        set {
            withMutation(keyPath: \.hasShownAutoDetectExplanation) {
                _hasShownAutoDetectExplanation = newValue
                defaults.set(newValue, forKey: "hasShownAutoDetectExplanation")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _hasShownCameraDetectExplanation: Bool
    var hasShownCameraDetectExplanation: Bool {
        get { access(keyPath: \.hasShownCameraDetectExplanation); return _hasShownCameraDetectExplanation }
        set {
            withMutation(keyPath: \.hasShownCameraDetectExplanation) {
                _hasShownCameraDetectExplanation = newValue
                defaults.set(newValue, forKey: "hasShownCameraDetectExplanation")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _calendarIntegrationEnabled: Bool
    var calendarIntegrationEnabled: Bool {
        get { access(keyPath: \.calendarIntegrationEnabled); return _calendarIntegrationEnabled }
        set {
            withMutation(keyPath: \.calendarIntegrationEnabled) {
                _calendarIntegrationEnabled = newValue
                defaults.set(newValue, forKey: "calendarIntegrationEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _shareCalendarContextWithCloudNotes: Bool
    var shareCalendarContextWithCloudNotes: Bool {
        get { access(keyPath: \.shareCalendarContextWithCloudNotes); return _shareCalendarContextWithCloudNotes }
        set {
            withMutation(keyPath: \.shareCalendarContextWithCloudNotes) {
                _shareCalendarContextWithCloudNotes = newValue
                defaults.set(newValue, forKey: "shareCalendarContextWithCloudNotes")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _excludedCalendarIDs: [String]
    var excludedCalendarIDs: [String] {
        get { access(keyPath: \.excludedCalendarIDs); return _excludedCalendarIDs }
        set {
            withMutation(keyPath: \.excludedCalendarIDs) {
                let normalized = Self.normalizedIdentifierList(newValue)
                _excludedCalendarIDs = normalized
                defaults.set(normalized, forKey: "excludedCalendarIDs")
            }
        }
    }

    // MARK: - Privacy Settings

    @ObservationIgnored nonisolated(unsafe) private var _hasAcknowledgedRecordingConsent: Bool
    var hasAcknowledgedRecordingConsent: Bool {
        get { access(keyPath: \.hasAcknowledgedRecordingConsent); return _hasAcknowledgedRecordingConsent }
        set {
            withMutation(keyPath: \.hasAcknowledgedRecordingConsent) {
                _hasAcknowledgedRecordingConsent = newValue
                defaults.set(newValue, forKey: "hasAcknowledgedRecordingConsent")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _hideFromScreenShare: Bool
    var hideFromScreenShare: Bool {
        get { access(keyPath: \.hideFromScreenShare); return _hideFromScreenShare }
        set {
            withMutation(keyPath: \.hideFromScreenShare) {
                _hideFromScreenShare = newValue
                defaults.set(newValue, forKey: "hideFromScreenShare")
                applyScreenShareVisibility()
            }
        }
    }

    // MARK: - Import Settings

    @ObservationIgnored nonisolated(unsafe) private var _granolaApiKey: String
    var granolaApiKey: String {
        get {
            access(keyPath: \.granolaApiKey)
            return loadSecretIfNeeded(key: "granolaApiKey", currentValue: _granolaApiKey) {
                _granolaApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.granolaApiKey) {
                _granolaApiKey = newValue
                markSecretLoaded("granolaApiKey")
                secretStore.save(key: "granolaApiKey", value: newValue)
            }
        }
    }

    // MARK: - Apple Notes Settings

    @ObservationIgnored nonisolated(unsafe) private var _appleNotesEnabled: Bool
    var appleNotesEnabled: Bool {
        get { access(keyPath: \.appleNotesEnabled); return _appleNotesEnabled }
        set {
            withMutation(keyPath: \.appleNotesEnabled) {
                _appleNotesEnabled = newValue
                defaults.set(newValue, forKey: "appleNotesEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _appleNotesIncludeTranscript: Bool
    var appleNotesIncludeTranscript: Bool {
        get { access(keyPath: \.appleNotesIncludeTranscript); return _appleNotesIncludeTranscript }
        set {
            withMutation(keyPath: \.appleNotesIncludeTranscript) {
                _appleNotesIncludeTranscript = newValue
                defaults.set(newValue, forKey: "appleNotesIncludeTranscript")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _appleNotesFolderName: String
    var appleNotesFolderName: String {
        get { access(keyPath: \.appleNotesFolderName); return _appleNotesFolderName }
        set {
            withMutation(keyPath: \.appleNotesFolderName) {
                _appleNotesFolderName = newValue
                defaults.set(newValue, forKey: "appleNotesFolderName")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _appleNotesAccountName: String
    var appleNotesAccountName: String {
        get { access(keyPath: \.appleNotesAccountName); return _appleNotesAccountName }
        set {
            withMutation(keyPath: \.appleNotesAccountName) {
                _appleNotesAccountName = newValue
                defaults.set(newValue, forKey: "appleNotesAccountName")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _appleNotesAutoExport: Bool
    var appleNotesAutoExport: Bool {
        get { access(keyPath: \.appleNotesAutoExport); return _appleNotesAutoExport }
        set {
            withMutation(keyPath: \.appleNotesAutoExport) {
                _appleNotesAutoExport = newValue
                defaults.set(newValue, forKey: "appleNotesAutoExport")
            }
        }
    }

    // MARK: - Webhook Settings

    @ObservationIgnored nonisolated(unsafe) private var _webhookEnabled: Bool
    var webhookEnabled: Bool {
        get { access(keyPath: \.webhookEnabled); return _webhookEnabled }
        set {
            withMutation(keyPath: \.webhookEnabled) {
                _webhookEnabled = newValue
                defaults.set(newValue, forKey: "webhookEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _webhookURL: String
    var webhookURL: String {
        get { access(keyPath: \.webhookURL); return _webhookURL }
        set {
            withMutation(keyPath: \.webhookURL) {
                _webhookURL = newValue
                defaults.set(newValue, forKey: "webhookURL")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _webhookSecret: String
    var webhookSecret: String {
        get {
            access(keyPath: \.webhookSecret)
            return loadSecretIfNeeded(key: "webhookSecret", currentValue: _webhookSecret) {
                _webhookSecret = $0
            }
        }
        set {
            withMutation(keyPath: \.webhookSecret) {
                _webhookSecret = newValue
                markSecretLoaded("webhookSecret")
                secretStore.save(key: "webhookSecret", value: newValue)
            }
        }
    }

    // MARK: - UI Settings

    @ObservationIgnored nonisolated(unsafe) private var _showLiveTranscript: Bool
    var showLiveTranscript: Bool {
        get { access(keyPath: \.showLiveTranscript); return _showLiveTranscript }
        set {
            withMutation(keyPath: \.showLiveTranscript) {
                _showLiveTranscript = newValue
                defaults.set(newValue, forKey: "showLiveTranscript")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _notesFolderPath: String
    var notesFolderPath: String {
        get { access(keyPath: \.notesFolderPath); return _notesFolderPath }
        set {
            withMutation(keyPath: \.notesFolderPath) {
                _notesFolderPath = newValue
                defaults.set(newValue, forKey: "notesFolderPath")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _saveMeetingTranscriptsInDateSubfolders: Bool
    var saveMeetingTranscriptsInDateSubfolders: Bool {
        get {
            access(keyPath: \.saveMeetingTranscriptsInDateSubfolders)
            return _saveMeetingTranscriptsInDateSubfolders
        }
        set {
            withMutation(keyPath: \.saveMeetingTranscriptsInDateSubfolders) {
                _saveMeetingTranscriptsInDateSubfolders = newValue
                defaults.set(newValue, forKey: "saveMeetingTranscriptsInDateSubfolders")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _meetingTranscriptDateFolderFormat: MeetingTranscriptDateFolderFormat
    var meetingTranscriptDateFolderFormat: MeetingTranscriptDateFolderFormat {
        get {
            access(keyPath: \.meetingTranscriptDateFolderFormat)
            return _meetingTranscriptDateFolderFormat
        }
        set {
            withMutation(keyPath: \.meetingTranscriptDateFolderFormat) {
                _meetingTranscriptDateFolderFormat = newValue
                defaults.set(newValue.rawValue, forKey: "meetingTranscriptDateFolderFormat")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _notesFolders: [NotesFolderDefinition]
    var notesFolders: [NotesFolderDefinition] {
        get { access(keyPath: \.notesFolders); return _notesFolders }
        set {
            withMutation(keyPath: \.notesFolders) {
                _notesFolders = Self.normalizeNotesFolders(newValue)
                defaults.set(Self.encodeNotesFolders(_notesFolders), forKey: "notesFolders")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _meetingPrepNotesByKey: [String: String]
    var meetingPrepNotesByKey: [String: String] {
        get { access(keyPath: \.meetingPrepNotesByKey); return _meetingPrepNotesByKey }
        set {
            withMutation(keyPath: \.meetingPrepNotesByKey) {
                _meetingPrepNotesByKey = Self.normalizeMeetingPrepNotes(newValue)
                defaults.set(Self.encodeMeetingPrepNotes(_meetingPrepNotesByKey), forKey: "meetingPrepNotesByKey")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _meetingHistoryAliasesByKey: [String: String]
    var meetingHistoryAliasesByKey: [String: String] {
        get { access(keyPath: \.meetingHistoryAliasesByKey); return _meetingHistoryAliasesByKey }
        set {
            withMutation(keyPath: \.meetingHistoryAliasesByKey) {
                _meetingHistoryAliasesByKey = Self.normalizeMeetingHistoryAliases(newValue)
                defaults.set(
                    Self.encodeMeetingHistoryAliases(_meetingHistoryAliasesByKey),
                    forKey: "meetingHistoryAliasesByKey"
                )
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _meetingFamilyPreferencesByKey: [String: MeetingFamilyPreferences]
    var meetingFamilyPreferencesByKey: [String: MeetingFamilyPreferences] {
        get { access(keyPath: \.meetingFamilyPreferencesByKey); return _meetingFamilyPreferencesByKey }
        set {
            withMutation(keyPath: \.meetingFamilyPreferencesByKey) {
                _meetingFamilyPreferencesByKey = Self.normalizeMeetingFamilyPreferences(newValue)
                defaults.set(
                    Self.encodeMeetingFamilyPreferences(_meetingFamilyPreferencesByKey),
                    forKey: "meetingFamilyPreferencesByKey"
                )
            }
        }
    }

    func meetingPrepNotes(for event: CalendarEvent) -> String {
        for key in orderedMeetingFamilyKeys(for: event) {
            if let notes = meetingPrepNotesByKey[key], !notes.isEmpty {
                return notes
            }
        }
        return ""
    }

    func setMeetingPrepNotes(_ text: String, for event: CalendarEvent) {
        let key = canonicalMeetingHistoryKey(for: event)
        var notes = meetingPrepNotesByKey
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes.removeValue(forKey: key)
        } else {
            notes[key] = text
        }
        meetingPrepNotesByKey = notes
    }

    func canonicalMeetingHistoryKey(for event: CalendarEvent) -> String {
        canonicalMeetingHistoryKey(forHistoryKey: MeetingHistoryResolver.preferredHistoryKey(for: event))
    }

    func canonicalMeetingHistoryKey(forHistoryKey historyKey: String) -> String {
        MeetingHistoryResolver.canonicalHistoryKey(
            for: historyKey,
            aliases: meetingHistoryAliasesByKey
        )
    }

    func meetingFamilyPreferences(for event: CalendarEvent) -> MeetingFamilyPreferences? {
        for key in orderedMeetingFamilyKeys(for: event) {
            if let preferences = meetingFamilyPreferencesByKey[key] {
                return preferences
            }
        }
        return nil
    }

    func meetingFamilyPreferences(forHistoryKey historyKey: String) -> MeetingFamilyPreferences? {
        let key = canonicalMeetingHistoryKey(forHistoryKey: historyKey)
        return meetingFamilyPreferencesByKey[key]
    }

    func setMeetingFamilyTemplatePreference(_ templateID: UUID?, for event: CalendarEvent) {
        setMeetingFamilyTemplatePreference(
            templateID,
            forHistoryKey: MeetingHistoryResolver.preferredHistoryKey(for: event)
        )
    }

    func setMeetingFamilyTemplatePreference(_ templateID: UUID?, forHistoryKey historyKey: String) {
        let key = canonicalMeetingHistoryKey(forHistoryKey: historyKey)
        guard !key.isEmpty else { return }

        var preferences = meetingFamilyPreferencesByKey
        var value = preferences[key] ?? MeetingFamilyPreferences()
        value.templateID = templateID

        if value.isEmpty {
            preferences.removeValue(forKey: key)
        } else {
            preferences[key] = value
        }
        meetingFamilyPreferencesByKey = preferences
    }

    func setMeetingFamilyFolderPreference(_ folderPath: String?, for event: CalendarEvent) {
        setMeetingFamilyFolderPreference(
            folderPath,
            forHistoryKey: MeetingHistoryResolver.preferredHistoryKey(for: event)
        )
    }

    private func orderedMeetingFamilyKeys(for event: CalendarEvent) -> [String] {
        var keys: [String] = []
        for historyKey in MeetingHistoryResolver.historyKeys(for: event) {
            let canonicalKey = canonicalMeetingHistoryKey(forHistoryKey: historyKey)
            if !canonicalKey.isEmpty, !keys.contains(canonicalKey) {
                keys.append(canonicalKey)
            }
        }
        return keys
    }

    func setMeetingFamilyFolderPreference(_ folderPath: String?, forHistoryKey historyKey: String) {
        let key = canonicalMeetingHistoryKey(forHistoryKey: historyKey)
        guard !key.isEmpty else { return }

        var preferences = meetingFamilyPreferencesByKey
        var value = preferences[key] ?? MeetingFamilyPreferences()
        value.folderPath = Self.normalizeMeetingFamilyFolderPath(folderPath)

        if value.isEmpty {
            preferences.removeValue(forKey: key)
        } else {
            preferences[key] = value
        }
        meetingFamilyPreferencesByKey = preferences
    }

    func linkMeetingHistoryAlias(from aliasHistoryKey: String, to canonicalHistoryKey: String) {
        let aliasKey = MeetingHistoryResolver.historyKey(for: aliasHistoryKey)
        let targetKey = canonicalMeetingHistoryKey(forHistoryKey: canonicalHistoryKey)
        guard !aliasKey.isEmpty, !targetKey.isEmpty, aliasKey != targetKey else { return }

        var aliases = meetingHistoryAliasesByKey
        aliases[aliasKey] = targetKey
        meetingHistoryAliasesByKey = aliases
    }

    /// Save a security-scoped bookmark for the user-selected notes folder.
    func saveNotesFolderBookmark(from url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmarkData, forKey: "notesFolderBookmark")
        } catch {
            Log.sessionRepository.error("Failed to create notes folder bookmark: \(error, privacy: .public)")
        }
    }

    /// Resolve the stored security-scoped bookmark to a URL.
    /// Returns `nil` if no bookmark is stored or resolution fails.
    func resolveNotesFolderBookmark() -> URL? {
        guard let data = defaults.data(forKey: "notesFolderBookmark") else {
            return nil
        }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                saveNotesFolderBookmark(from: url)
            }
            return url
        } catch {
            Log.sessionRepository.error("Failed to resolve notes folder bookmark: \(error, privacy: .public)")
            return nil
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _kbFolderPath: String
    var kbFolderPath: String {
        get { access(keyPath: \.kbFolderPath); return _kbFolderPath }
        set {
            withMutation(keyPath: \.kbFolderPath) {
                _kbFolderPath = newValue
                defaults.set(newValue, forKey: "kbFolderPath")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _hasSeenLaunchAtLoginSuggestion: Bool
    var hasSeenLaunchAtLoginSuggestion: Bool {
        get { access(keyPath: \.hasSeenLaunchAtLoginSuggestion); return _hasSeenLaunchAtLoginSuggestion }
        set {
            withMutation(keyPath: \.hasSeenLaunchAtLoginSuggestion) {
                _hasSeenLaunchAtLoginSuggestion = newValue
                defaults.set(newValue, forKey: "hasSeenLaunchAtLoginSuggestion")
            }
        }
    }

    // MARK: - Initialization

    init(storage: SettingsStorage = .live()) {
        self.defaults = storage.defaults
        self.secretStore = storage.secretStore

        let defaults = storage.defaults

        // One-time migrations from previous bundle IDs
        if storage.runMigrations {
            Self.migrateFromOldBundleIfNeeded(defaults: defaults)
            Self.migrateFromOpenGranolaIfNeeded(defaults: defaults)
            Self.migrateFromOpenOatsIfNeeded(defaults: defaults)
            Self.migrateKeychainServiceIfNeeded(defaults: defaults)
            Self.migrateNotesDirectoryToCurrentDefaultIfNeeded(
                defaults: defaults,
                defaultDirectory: storage.defaultNotesDirectory
            )
        }

        // Migrate renamed settings keys (old -> new)
        if defaults.object(forKey: "enableLiveTranscriptCleanup") == nil,
           let oldValue = defaults.object(forKey: Self.enableLiveTranscriptCleanupLegacyKey) {
            defaults.set(oldValue, forKey: "enableLiveTranscriptCleanup")
        }
        if defaults.object(forKey: "enableBatchRetranscription") == nil,
           let oldValue = defaults.object(forKey: Self.enableBatchRetranscriptionLegacyKey) {
            defaults.set(oldValue, forKey: "enableBatchRetranscription")
        }

        // AI Settings
        self._llmProvider = LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .openRouter
        self._openRouterApiKey = ""
        self._requestyApiKey = ""
        self._requestyBaseURL = defaults.string(forKey: "requestyBaseURL") ?? "https://router.requesty.ai/v1"
        self._requestyModel = defaults.string(forKey: "requestyModel") ?? "openai/gpt-4o-mini"
        self._openAIApiKey = ""
        self._openAIBaseURL = defaults.string(forKey: "openAIBaseURL") ?? "https://api.openai.com"
        self._openAIModel = defaults.string(forKey: "openAIModel") ?? "gpt-4.1-mini"
        self._anthropicApiKey = ""
        self._anthropicBaseURL = defaults.string(forKey: "anthropicBaseURL") ?? "https://api.anthropic.com"
        self._anthropicModel = defaults.string(forKey: "anthropicModel") ?? "claude-sonnet-4-5-20250929"
        self._assemblyAIApiKey = ""
        self._elevenLabsApiKey = ""
        self._cohereApiKey = ""
        self._ollamaBaseURL = defaults.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
        self._ollamaLLMModel = defaults.string(forKey: "ollamaLLMModel") ?? "qwen3:8b"
        self._ollamaEmbedModel = defaults.string(forKey: "ollamaEmbedModel") ?? "nomic-embed-text"
        self._mlxBaseURL = defaults.string(forKey: "mlxBaseURL") ?? "http://localhost:8080"
        self._mlxModel = defaults.string(forKey: "mlxModel") ?? "mlx-community/Llama-3.2-3B-Instruct-4bit"
        self._lmStudioBaseURL = defaults.string(forKey: "lmStudioBaseURL") ?? "http://localhost:1234"
        self._lmStudioApiKey = ""
        self._lmStudioModel = defaults.string(forKey: "lmStudioModel") ?? ""
        self._openAILLMBaseURL = defaults.string(forKey: "openAILLMBaseURL") ?? "http://localhost:4000"
        self._openAILLMApiKey = ""
        self._openAILLMModel = defaults.string(forKey: "openAILLMModel") ?? ""
        self._openAIEmbedBaseURL = defaults.string(forKey: "openAIEmbedBaseURL") ?? "http://localhost:8080"
        self._openAIEmbedApiKey = ""
        self._openAIEmbedModel = defaults.string(forKey: "openAIEmbedModel") ?? "text-embedding-3-small"
        self._selectedModel = defaults.string(forKey: "selectedModel") ?? "google/gemini-3-flash-preview"
        self._defaultNotesTemplateID = Self.normalizeDefaultNotesTemplateID(
            defaults.string(forKey: "defaultNotesTemplateID").flatMap(UUID.init(uuidString:))
        )
        self._embeddingProvider = EmbeddingProvider(rawValue: defaults.string(forKey: "embeddingProvider") ?? "") ?? .voyageAI
        self._voyageApiKey = ""
        self._suggestionVerbosity = SuggestionVerbosity(
            rawValue: defaults.string(forKey: "suggestionVerbosity") ?? ""
        ) ?? .quiet
        self._enableLiveTranscriptCleanup = defaults.bool(forKey: "enableLiveTranscriptCleanup")
        self._realtimeModel = defaults.string(forKey: "realtimeModel") ?? "google/gemini-3.1-flash-lite-preview"
        self._realtimeOllamaModel = defaults.string(forKey: "realtimeOllamaModel") ?? ""
        if defaults.object(forKey: "suggestionPanelEnabled") == nil {
            self._suggestionPanelEnabled = true
        } else {
            self._suggestionPanelEnabled = defaults.bool(forKey: "suggestionPanelEnabled")
        }
        if defaults.object(forKey: "suggestionsAlwaysOnTop") == nil {
            self._suggestionsAlwaysOnTop = false
        } else {
            self._suggestionsAlwaysOnTop = defaults.bool(forKey: "suggestionsAlwaysOnTop")
        }
        self._sidebarMode = SidebarMode(rawValue: defaults.string(forKey: "sidebarMode") ?? "") ?? .classicSuggestions
        self._sidecastIntensity = SidecastIntensity(rawValue: defaults.string(forKey: "sidecastIntensity") ?? "") ?? .balanced
        self._sidecastPersonas = Self.decodePersonas(defaults.data(forKey: "sidecastPersonas")) ?? SidecastPersona.starterPack
        self._sidecastTemperature = defaults.object(forKey: "sidecastTemperature") != nil
            ? defaults.double(forKey: "sidecastTemperature") : 1.0
        self._sidecastMaxTokens = defaults.object(forKey: "sidecastMaxTokens") != nil
            ? defaults.integer(forKey: "sidecastMaxTokens") : 1500
        self._sidecastSystemPrompt = defaults.string(forKey: "sidecastSystemPrompt") ?? ""
        self._sidecastMinValueThreshold = defaults.object(forKey: "sidecastMinValueThreshold") != nil
            ? defaults.double(forKey: "sidecastMinValueThreshold") : 0.5
        self._preFetchIntervalSeconds = defaults.object(forKey: "preFetchIntervalSeconds") != nil
            ? defaults.double(forKey: "preFetchIntervalSeconds") : 4.0
        self._kbSimilarityThreshold = defaults.object(forKey: "kbSimilarityThreshold") != nil
            ? defaults.double(forKey: "kbSimilarityThreshold") : 0.35

        // Interview Copilot Settings. Users upgrading from the old realtime-first
        // preference intentionally land on manual streaming ASR.
        self._interviewAudioMode = InterviewAudioMode(
            rawValue: defaults.string(forKey: "interviewAudioMode") ?? ""
        ) ?? .manualStreamingASR
        self._tencentASRAppID = defaults.string(forKey: "tencentASRAppID") ?? ""
        self._tencentASRSecretID = ""
        self._tencentASRSecretKey = ""
        if defaults.object(forKey: "interviewASRAutoHotwordsEnabled") == nil {
            self._interviewASRAutoHotwordsEnabled = true
        } else {
            self._interviewASRAutoHotwordsEnabled = defaults.bool(forKey: "interviewASRAutoHotwordsEnabled")
        }
        if defaults.object(forKey: "interviewAutoReferenceAnswerEnabled") == nil {
            self._interviewAutoReferenceAnswerEnabled = true
        } else {
            self._interviewAutoReferenceAnswerEnabled = defaults.bool(forKey: "interviewAutoReferenceAnswerEnabled")
        }
        let storedInferencePreference = InterviewInferencePreference(
            rawValue: defaults.string(forKey: "copilotInferenceProvider") ?? ""
        )
        self._interviewInferencePreference = storedInferencePreference == .codexOnly
            ? .codexOnly
            : .apiPreferred
        let storedReferenceAnswerModel = defaults.string(forKey: "interviewReferenceAnswerModel")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self._interviewReferenceAnswerModel = storedReferenceAnswerModel.isEmpty
            ? Self.defaultInterviewReferenceAnswerModel
            : storedReferenceAnswerModel
        let storedAPIProtocol = InterviewAPIProtocol(
            rawValue: defaults.string(forKey: "interviewAPIProtocol") ?? ""
        ) ?? .chatCompletion
        self._interviewAPIProtocol = storedAPIProtocol
        self._interviewAPIBaseURL = defaults.string(forKey: "interviewAPIBaseURL") ?? (
            storedAPIProtocol == .chatCompletion
                ? "https://api.deepseek.com"
                : "https://api.openai.com"
        )
        self._interviewAPIKey = ""
        self._interviewAPIModel = defaults.string(forKey: "interviewAPIModel") ?? (
            storedAPIProtocol == .chatCompletion
                ? "deepseek-chat"
                : Self.defaultInterviewMainAnswerModel
        )
        self._interviewAPIModelOptions = defaults.stringArray(forKey: "interviewAPIModelOptions") ?? []
        self._interviewAPIFastServiceTierEnabled = defaults.bool(forKey: "interviewAPIFastServiceTierEnabled")
        self._interviewAPIProvider = InterviewAPIProvider(
            rawValue: defaults.string(forKey: "copilotAPIProvider") ?? ""
        ) ?? .openAI
        self._deepSeekApiKey = ""
        self._deepSeekBaseURL = defaults.string(forKey: "deepSeekBaseURL") ?? "https://api.deepseek.com"
        self._interviewDeepSeekModel = defaults.string(forKey: "interviewDeepSeekModel") ?? "deepseek-chat"
        let storedCodexModel = defaults.string(forKey: "interviewCodexModel")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let legacyCodexModel = Self.interviewCodexModelPresets.contains(storedReferenceAnswerModel)
            ? storedReferenceAnswerModel
            : Self.defaultInterviewCodexModel
        self._interviewCodexModel = storedCodexModel.isEmpty ? legacyCodexModel : storedCodexModel
        if defaults.object(forKey: "interviewIncludeCandidateAnswersInContext") == nil {
            self._interviewIncludeCandidateAnswersInContext = false
        } else {
            self._interviewIncludeCandidateAnswersInContext = defaults.bool(
                forKey: "interviewIncludeCandidateAnswersInContext"
            )
        }
        if defaults.object(forKey: "interviewCodexSpeedModeEnabled") == nil {
            self._interviewCodexSpeedModeEnabled = true
        } else {
            self._interviewCodexSpeedModeEnabled = defaults.bool(forKey: "interviewCodexSpeedModeEnabled")
        }
        let storedCodexCueModel = defaults.string(forKey: "interviewCodexCueModel")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedInferencePreferenceRaw = defaults.string(forKey: "copilotInferenceProvider") ?? ""
        let isAPIPreferred = storedInferencePreferenceRaw != InterviewInferencePreference.codexOnly.rawValue
        self._interviewCodexCueModel = storedCodexCueModel.isEmpty
            ? (isAPIPreferred ? "" : Self.defaultInterviewCodexCueModel)
            : storedCodexCueModel
        if defaults.object(forKey: "interviewDelayedFallbackEnabled") == nil {
            self._interviewDelayedFallbackEnabled = true
        } else {
            self._interviewDelayedFallbackEnabled = defaults.bool(forKey: "interviewDelayedFallbackEnabled")
        }
        self._interviewAnswerDepth = InterviewAnswerDepth(
            rawValue: defaults.string(forKey: "interviewAnswerDepth") ?? ""
        ) ?? .standard
        self._interviewCodexReasoningEffort = InterviewReasoningEffort(
            rawValue: defaults.string(forKey: "interviewCodexReasoningEffort") ?? ""
        ) ?? .low
        if defaults.object(forKey: "interviewKnowledgeBriefTokenBudget") == nil {
            self._interviewKnowledgeBriefTokenBudget = Self.defaultInterviewKnowledgeBriefTokenBudget
        } else {
            self._interviewKnowledgeBriefTokenBudget = min(
                max(
                    defaults.integer(forKey: "interviewKnowledgeBriefTokenBudget"),
                    Self.interviewKnowledgeBriefTokenRange.lowerBound
                ),
                Self.interviewKnowledgeBriefTokenRange.upperBound
            )
        }
        if defaults.object(forKey: "interviewCodexFastServiceTierEnabled") == nil {
            self._interviewCodexFastServiceTierEnabled = false
        } else {
            self._interviewCodexFastServiceTierEnabled = defaults.bool(forKey: "interviewCodexFastServiceTierEnabled")
        }
        self._interviewASRHotwordOverrides = defaults.string(forKey: "interviewASRHotwordOverrides") ?? ""
        self._qwenASRExecutablePath = defaults.string(forKey: "qwenASRExecutablePath") ?? ""
        self._qwenASRModelPath = defaults.string(forKey: "qwenASRModelPath") ?? ""
        self._copilotTurnHotkey = defaults.data(forKey: "copilotTurnHotkey")
            .flatMap { try? JSONDecoder().decode(CopilotTurnHotkey.self, from: $0) }
            ?? .defaultTurn
        self._interviewLensEnabled = defaults.bool(forKey: "interviewLensEnabled")

        let storedInterviewLensSelection = defaults.string(forKey: "interviewLensLastSelection")
        let decodedInterviewLensSelection = storedInterviewLensSelection
            .flatMap(InterviewLensPersistentSelection.init(rawValue:))
            ?? .defaultValue
        let interviewLensSelection: InterviewLensPersistentSelection = switch decodedInterviewLensSelection {
        case .question, .quickIdea, .referenceAnswer: .answer
        default: decodedInterviewLensSelection
        }
        self._interviewLensLastSelection = interviewLensSelection
        if defaults.object(forKey: "interviewLensLastSelection") != nil,
           storedInterviewLensSelection != interviewLensSelection.rawValue {
            defaults.set(interviewLensSelection.rawValue, forKey: "interviewLensLastSelection")
        }

        let storedInterviewLensFontScale = defaults.integer(forKey: "interviewLensFontScale")
        let interviewLensFontScale = InterviewLensFontScale(rawValue: storedInterviewLensFontScale)
            ?? .defaultValue
        self._interviewLensFontScale = interviewLensFontScale
        if defaults.object(forKey: "interviewLensFontScale") != nil,
           storedInterviewLensFontScale != interviewLensFontScale.rawValue {
            defaults.set(interviewLensFontScale.rawValue, forKey: "interviewLensFontScale")
        }

        let interviewLensSize = defaults.data(forKey: "interviewLensSize")
            .flatMap { try? JSONDecoder().decode(InterviewLensSize.self, from: $0) }
            ?? .defaultValue
        self._interviewLensSize = interviewLensSize
        if defaults.object(forKey: "interviewLensSize") != nil {
            defaults.set(try? JSONEncoder().encode(interviewLensSize), forKey: "interviewLensSize")
        }

        let interviewLensDisplayPlacements = defaults.data(forKey: "interviewLensDisplayPlacements")
            .flatMap {
                try? JSONDecoder().decode(
                    [String: InterviewLensDisplayPlacement].self,
                    from: $0
                )
            }
            ?? [:]
        self._interviewLensDisplayPlacements = interviewLensDisplayPlacements
        if defaults.object(forKey: "interviewLensDisplayPlacements") != nil {
            defaults.set(
                try? JSONEncoder().encode(interviewLensDisplayPlacements),
                forKey: "interviewLensDisplayPlacements"
            )
        }

        // Capture Settings
        self._inputDeviceID = AudioDeviceID(defaults.integer(forKey: "inputDeviceID"))
        self._outputDeviceID = AudioDeviceID(defaults.integer(forKey: "outputDeviceID"))
        // Seed stable UIDs for users upgrading from an older version.
        let savedInputID = _inputDeviceID
        let savedOutputID = _outputDeviceID
        if savedInputID > 0, defaults.string(forKey: "inputDeviceUID") == nil {
            if let uid = MicCapture.deviceUID(for: savedInputID) { defaults.set(uid, forKey: "inputDeviceUID") }
            let name = MicCapture.availableInputDevices().first(where: { $0.id == savedInputID })?.name
            if let name { defaults.set(name, forKey: "inputDeviceName") }
        }
        if savedOutputID > 0, defaults.string(forKey: "outputDeviceUID") == nil {
            if let uid = try? SystemAudioCapture.outputDeviceUID(for: savedOutputID) { defaults.set(uid, forKey: "outputDeviceUID") }
            let name = SystemAudioCapture.availableOutputDevices().first(where: { $0.id == savedOutputID })?.name
            if let name { defaults.set(name, forKey: "outputDeviceName") }
        }
        self._transcriptionModel = TranscriptionModel(
            rawValue: defaults.string(forKey: "transcriptionModel") ?? ""
        ) ?? .parakeetV2
        self._transcriptionLocale = defaults.string(forKey: "transcriptionLocale") ?? "en-US"
        self._transcriptionCustomVocabulary = defaults.string(forKey: "transcriptionCustomVocabulary") ?? ""
        self._removeFillerWords = defaults.bool(forKey: "removeFillerWords")
        if defaults.object(forKey: "saveAudioRecording") == nil {
            self._saveAudioRecording = true
        } else {
            self._saveAudioRecording = defaults.bool(forKey: "saveAudioRecording")
        }

        if defaults.object(forKey: "enableEchoCancellation") == nil {
            self._enableEchoCancellation = true
        } else {
            self._enableEchoCancellation = defaults.bool(forKey: "enableEchoCancellation")
        }

        if defaults.object(forKey: "enableBatchRetranscription") == nil {
            self._enableBatchRetranscription = false
        } else {
            self._enableBatchRetranscription = defaults.bool(forKey: "enableBatchRetranscription")
        }
        self._batchTranscriptionModel = TranscriptionModel(
            rawValue: defaults.string(forKey: "batchTranscriptionModel") ?? ""
        ) ?? .whisperLargeV3Turbo
        self._enableDiarization = defaults.bool(forKey: "enableDiarization")
        self._diarizationVariant = defaults.string(forKey: "diarizationVariant") ?? DiarizationVariant.dihard3.rawValue

        // Detection Settings
        if defaults.object(forKey: "meetingAutoDetectEnabled") == nil {
            self._meetingAutoDetectEnabled = true
        } else {
            self._meetingAutoDetectEnabled = defaults.bool(forKey: "meetingAutoDetectEnabled")
        }
        self._customMeetingAppBundleIDs = defaults.stringArray(forKey: "customMeetingAppBundleIDs") ?? []
        self._ignoredAppBundleIDs = defaults.stringArray(forKey: "ignoredAppBundleIDs") ?? []
        // Canonical timeout is seconds; migrate from the legacy minutes key.
        let silenceSeconds: Int
        if defaults.object(forKey: "silenceTimeoutSeconds") != nil {
            silenceSeconds = defaults.integer(forKey: "silenceTimeoutSeconds")
        } else if defaults.object(forKey: "silenceTimeoutMinutes") != nil {
            silenceSeconds = defaults.integer(forKey: "silenceTimeoutMinutes") * 60
        } else {
            silenceSeconds = 900
        }
        self._silenceTimeoutSeconds = silenceSeconds
        self._silenceTimeoutUnitIsSeconds = defaults.object(forKey: "silenceTimeoutUnitIsSeconds") != nil
            ? defaults.bool(forKey: "silenceTimeoutUnitIsSeconds")
            : (silenceSeconds < 60)
        self._detectionLogEnabled = defaults.bool(forKey: "detectionLogEnabled")
        self._diagnosticLoggingEnabled = defaults.bool(forKey: "diagnosticLoggingEnabled")
        self._hasShownAutoDetectExplanation = defaults.bool(forKey: "hasShownAutoDetectExplanation")
        self._hasShownCameraDetectExplanation = defaults.bool(forKey: "hasShownCameraDetectExplanation")
        self._calendarIntegrationEnabled = defaults.bool(forKey: "calendarIntegrationEnabled")
        self._shareCalendarContextWithCloudNotes = defaults.bool(forKey: "shareCalendarContextWithCloudNotes")
        self._excludedCalendarIDs = Self.normalizedIdentifierList(
            defaults.stringArray(forKey: "excludedCalendarIDs") ?? []
        )

        // Privacy Settings
        self._hasAcknowledgedRecordingConsent = defaults.bool(forKey: "hasAcknowledgedRecordingConsent")
        if defaults.object(forKey: "hideFromScreenShare") == nil {
            self._hideFromScreenShare = false
        } else {
            self._hideFromScreenShare = defaults.bool(forKey: "hideFromScreenShare")
        }

        // Import Settings
        self._granolaApiKey = ""

        // Apple Notes Settings
        self._appleNotesEnabled = defaults.bool(forKey: "appleNotesEnabled")
        if defaults.object(forKey: "appleNotesIncludeTranscript") == nil {
            self._appleNotesIncludeTranscript = true
        } else {
            self._appleNotesIncludeTranscript = defaults.bool(forKey: "appleNotesIncludeTranscript")
        }
        self._appleNotesFolderName = defaults.string(forKey: "appleNotesFolderName") ?? "Live Interview Copilot"
        self._appleNotesAccountName = defaults.string(forKey: "appleNotesAccountName") ?? "iCloud"
        if defaults.object(forKey: "appleNotesAutoExport") == nil {
            self._appleNotesAutoExport = false
        } else {
            self._appleNotesAutoExport = defaults.bool(forKey: "appleNotesAutoExport")
        }

        // Webhook Settings
        self._webhookEnabled = defaults.bool(forKey: "webhookEnabled")
        self._webhookURL = defaults.string(forKey: "webhookURL") ?? ""
        self._webhookSecret = ""

        // UI Settings
        if defaults.object(forKey: "showLiveTranscript") == nil {
            self._showLiveTranscript = true
        } else {
            self._showLiveTranscript = defaults.bool(forKey: "showLiveTranscript")
        }
        let defaultNotesPath = storage.defaultNotesDirectory.path
        self._notesFolderPath = defaults.string(forKey: "notesFolderPath") ?? defaultNotesPath
        self._saveMeetingTranscriptsInDateSubfolders = defaults.bool(forKey: "saveMeetingTranscriptsInDateSubfolders")
        self._meetingTranscriptDateFolderFormat = defaults
            .string(forKey: "meetingTranscriptDateFolderFormat")
            .flatMap(MeetingTranscriptDateFolderFormat.init(rawValue:)) ?? .iso
        self._notesFolders = Self.decodeNotesFolders(defaults.data(forKey: "notesFolders")) ?? []
        self._meetingPrepNotesByKey = Self.decodeMeetingPrepNotes(defaults.data(forKey: "meetingPrepNotesByKey")) ?? [:]
        self._meetingHistoryAliasesByKey = Self.decodeMeetingHistoryAliases(
            defaults.data(forKey: "meetingHistoryAliasesByKey")
        ) ?? [:]
        self._meetingFamilyPreferencesByKey = Self.decodeMeetingFamilyPreferences(
            defaults.data(forKey: "meetingFamilyPreferencesByKey")
        ) ?? [:]
        self._kbFolderPath = defaults.string(forKey: "kbFolderPath") ?? ""
        self._hasSeenLaunchAtLoginSuggestion = defaults.bool(forKey: "hasSeenLaunchAtLoginSuggestion")

        // Ensure notes folder exists
        try? FileManager.default.createDirectory(
            atPath: notesFolderPath,
            withIntermediateDirectories: true
        )

        // Prevent Spotlight from indexing transcript contents
        Self.dropMetadataNeverIndex(atPath: notesFolderPath)
    }

    // MARK: - Computed Properties

    /// Returns the cloud ASR API key for the current transcription model.
    var cloudASRApiKey: String {
        switch transcriptionModel {
        case .assemblyAI: assemblyAIApiKey
        case .elevenLabsScribe: elevenLabsApiKey
        case .cohereTranscribeArabic: cohereApiKey
        default: ""
        }
    }

    var kbFolderURL: URL? {
        guard !kbFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: kbFolderPath)
    }

    var hasTencentASRCredentials: Bool {
        !tencentASRAppID.isEmpty && !tencentASRSecretID.isEmpty && !tencentASRSecretKey.isEmpty
    }

    /// User-owned terms are kept separate from automatically extracted knowledge
    /// terms so they can receive the highest Tencent hotword weight.
    var interviewASRManualTerms: [String] {
        let combined = [transcriptionCustomVocabulary, interviewASRHotwordOverrides]
            .joined(separator: "\n")
        var seen: Set<String> = []
        return combined
            .components(separatedBy: CharacterSet(charactersIn: ",，;；\n\t"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { term in
                guard !term.isEmpty else { return false }
                return seen.insert(term.lowercased()).inserted
            }
    }

    var qwenASRRuntimeStatus: Qwen3RuntimeStatus {
        Qwen3RuntimeConfiguration.discover(
            executableOverride: qwenASRExecutablePath,
            modelOverride: qwenASRModelPath
        ).status
    }

    var resolvedQwenASRExecutableURL: URL? {
        qwenASRRuntimeStatus.executablePath.map { URL(fileURLWithPath: $0) }
    }

    var resolvedQwenASRModelURL: URL? {
        qwenASRRuntimeStatus.modelPath.map { URL(fileURLWithPath: $0) }
    }

    var isQwenASRFallbackAvailable: Bool {
        qwenASRRuntimeStatus.isReady
    }

    var locale: Locale {
        Locale(identifier: transcriptionLocale)
    }

    var transcriptionModelDisplay: String {
        transcriptionModel.displayName
    }

    /// The model ID to use for notes generation, respecting the active LLM provider.
    var activeNotesModel: String {
        switch llmProvider {
        case .openRouter:
            selectedModel
        case .requesty:
            requestyModel
        case .openAI:
            openAIModel
        case .anthropic:
            anthropicModel
        case .ollama:
            ollamaLLMModel
        case .lmStudio:
            lmStudioModel
        case .mlx:
            mlxModel
        case .openAICompatible:
            openAILLMModel
        }
    }

    /// Returns true when notes generation has enough provider-specific configuration
    /// to run automatically after a meeting ends without a guaranteed setup failure.
    var canAutoGeneratePostMeetingNotes: Bool {
        let model = activeNotesModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return false }

        switch llmProvider {
        case .openRouter:
            return !openRouterApiKey.isEmpty
        case .requesty:
            return !requestyApiKey.isEmpty && OpenRouterClient.chatCompletionsURL(from: requestyBaseURL) != nil
        case .openAI:
            return !openAIApiKey.isEmpty && OpenRouterClient.chatCompletionsURL(from: openAIBaseURL) != nil
        case .anthropic:
            return !anthropicApiKey.isEmpty && OpenRouterClient.anthropicMessagesURL(from: anthropicBaseURL) != nil
        case .ollama:
            return OpenRouterClient.chatCompletionsURL(from: ollamaBaseURL) != nil
        case .lmStudio:
            return OpenRouterClient.chatCompletionsURL(from: lmStudioBaseURL) != nil
        case .mlx:
            return OpenRouterClient.chatCompletionsURL(from: mlxBaseURL) != nil
        case .openAICompatible:
            return OpenRouterClient.chatCompletionsURL(from: openAILLMBaseURL) != nil
        }
    }

    /// The model name to display in the UI, respecting the active LLM provider.
    var activeModelDisplay: String {
        let raw = activeNotesModel
        return raw.split(separator: "/").last.map(String.init) ?? raw
    }

    /// The model ID to use for real-time suggestion synthesis.
    var activeRealtimeModel: String {
        switch llmProvider {
        case .openRouter: return realtimeModel
        case .requesty: return requestyModel
        case .openAI: return openAIModel
        case .anthropic: return anthropicModel
        case .ollama: return realtimeOllamaModel.isEmpty ? ollamaLLMModel : realtimeOllamaModel
        case .lmStudio: return lmStudioModel
        case .mlx: return mlxModel
        case .openAICompatible: return openAILLMModel
        }
    }

    var activeLLMTransport: OpenRouterClient.CompletionTransport {
        llmProvider == .anthropic ? .anthropicMessages : .chatCompletions
    }

    var activeLLMApiKey: String? {
        switch llmProvider {
        case .openRouter:
            openRouterApiKey.isEmpty ? nil : openRouterApiKey
        case .requesty:
            requestyApiKey.isEmpty ? nil : requestyApiKey
        case .openAI:
            openAIApiKey.isEmpty ? nil : openAIApiKey
        case .anthropic:
            anthropicApiKey.isEmpty ? nil : anthropicApiKey
        case .ollama, .mlx:
            nil
        case .lmStudio:
            lmStudioApiKey.isEmpty ? nil : lmStudioApiKey
        case .openAICompatible:
            openAILLMApiKey.isEmpty ? nil : openAILLMApiKey
        }
    }

    var activeLLMBaseURL: URL? {
        switch llmProvider {
        case .openRouter:
            nil
        case .requesty:
            OpenRouterClient.chatCompletionsURL(from: requestyBaseURL)
        case .openAI:
            OpenRouterClient.chatCompletionsURL(from: openAIBaseURL)
        case .anthropic:
            OpenRouterClient.anthropicMessagesURL(from: anthropicBaseURL)
        case .ollama:
            OpenRouterClient.chatCompletionsURL(from: ollamaBaseURL)
        case .lmStudio:
            OpenRouterClient.chatCompletionsURL(from: lmStudioBaseURL)
        case .mlx:
            OpenRouterClient.chatCompletionsURL(from: mlxBaseURL)
        case .openAICompatible:
            OpenRouterClient.chatCompletionsURL(from: openAILLMBaseURL)
        }
    }

    /// Display name for the active realtime model.
    var activeRealtimeModelDisplay: String {
        let raw = activeRealtimeModel
        return raw.split(separator: "/").last.map(String.init) ?? raw
    }

    var enabledSidecastPersonas: [SidecastPersona] {
        sidecastPersonas.filter(\.isEnabled)
    }

    func toggleSidecastPersona(at index: Int) {
        guard sidecastPersonas.indices.contains(index) else { return }
        sidecastPersonas[index].isEnabled.toggle()
    }

    // MARK: - Screen Share Visibility

    /// Apply current screen-share visibility to all app windows.
    func applyScreenShareVisibility() {
        let type: NSWindow.SharingType = hideFromScreenShare ? .none : .readOnly
        for window in NSApp.windows {
            window.sharingType = type
        }
    }

    // MARK: - Spotlight Indexing

    /// Place a .metadata_never_index sentinel so Spotlight skips the directory.
    private static func dropMetadataNeverIndex(atPath directoryPath: String) {
        let sentinel = URL(fileURLWithPath: directoryPath).appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: sentinel.path) {
            FileManager.default.createFile(atPath: sentinel.path, contents: nil)
        }
    }

    private static func encodePersonas(_ personas: [SidecastPersona]) -> Data? {
        let encoder = JSONEncoder()
        return try? encoder.encode(personas)
    }

    private static func decodePersonas(_ data: Data?) -> [SidecastPersona]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([SidecastPersona].self, from: data)
    }

    private static func encodeNotesFolders(_ folders: [NotesFolderDefinition]) -> Data? {
        let encoder = JSONEncoder()
        return try? encoder.encode(folders)
    }

    private static func decodeNotesFolders(_ data: Data?) -> [NotesFolderDefinition]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([NotesFolderDefinition].self, from: data)
    }

    private static func normalizeNotesFolders(_ folders: [NotesFolderDefinition]) -> [NotesFolderDefinition] {
        var seen = Set<String>()
        var result: [NotesFolderDefinition] = []
        for folder in folders {
            guard let normalizedPath = NotesFolderDefinition.normalizePath(folder.path) else { continue }
            let key = normalizedPath.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(NotesFolderDefinition(id: folder.id, path: normalizedPath, color: folder.color))
        }
        return result.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private static func encodeMeetingPrepNotes(_ notes: [String: String]) -> Data? {
        let encoder = JSONEncoder()
        return try? encoder.encode(notes)
    }

    private static func decodeMeetingPrepNotes(_ data: Data?) -> [String: String]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func encodeMeetingHistoryAliases(_ aliases: [String: String]) -> Data? {
        let encoder = JSONEncoder()
        return try? encoder.encode(aliases)
    }

    private static func decodeMeetingHistoryAliases(_ data: Data?) -> [String: String]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func encodeMeetingFamilyPreferences(_ preferences: [String: MeetingFamilyPreferences]) -> Data? {
        let encoder = JSONEncoder()
        return try? encoder.encode(preferences)
    }

    private static func decodeMeetingFamilyPreferences(_ data: Data?) -> [String: MeetingFamilyPreferences]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([String: MeetingFamilyPreferences].self, from: data)
    }

    private static func normalizeMeetingPrepNotes(_ notes: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (rawKey, rawValue) in notes {
            let normalizedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedKey.isEmpty else { continue }
            guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            result[normalizedKey] = rawValue
        }
        return result
    }

    private static func normalizeMeetingHistoryAliases(_ aliases: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (rawKey, rawValue) in aliases {
            let normalizedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedKey.isEmpty, !normalizedValue.isEmpty, normalizedKey != normalizedValue else {
                continue
            }
            result[normalizedKey] = normalizedValue
        }
        return result
    }

    private static func normalizeMeetingFamilyPreferences(
        _ preferences: [String: MeetingFamilyPreferences]
    ) -> [String: MeetingFamilyPreferences] {
        var result: [String: MeetingFamilyPreferences] = [:]
        for (rawKey, rawValue) in preferences {
            let normalizedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedKey.isEmpty else { continue }
            let normalizedValue = MeetingFamilyPreferences(
                templateID: rawValue.templateID,
                folderPath: normalizeMeetingFamilyFolderPath(rawValue.folderPath)
            )
            guard !normalizedValue.isEmpty else { continue }
            result[normalizedKey] = normalizedValue
        }
        return result
    }

    private static func normalizeMeetingFamilyFolderPath(_ folderPath: String?) -> String? {
        guard let normalized = NotesFolderDefinition.normalizePath(folderPath ?? "") else { return nil }
        let componentCount = normalized.split(separator: "/").count
        guard componentCount <= 2 else { return nil }
        return normalized
    }
}

// MARK: - Migration

extension SettingsStore {
    /// Migrate settings, credentials, and local history from the locally
    /// shipped OpenOats bundle. The application was renamed, so this must merge
    /// data rather than assume the destination directory is empty.
    private static func migrateFromOpenOatsIfNeeded(defaults: UserDefaults) {
        let migrationKey = "didMigrateFromOpenOatsToLiveInterviewCopilot"
        guard !defaults.bool(forKey: migrationKey) else { return }
        var migrationSucceeded = true

        let oldBundleID = "com.openoats.app"
        if let oldDefaults = UserDefaults(suiteName: oldBundleID),
           let domain = oldDefaults.persistentDomain(forName: oldBundleID) {
            for (key, value) in domain where !key.hasPrefix("didMigrate") {
                if defaults.object(forKey: key) == nil {
                    defaults.set(value, forKey: key)
                }
            }
        }

        let keychainMappings = [
            (source: "openRouterApiKey", destination: "openRouterApiKey"),
            (source: "requestyApiKey", destination: "requestyApiKey"),
            // The interview route was renamed from the legacy OpenAI setting.
            // Keep the old setting for existing screens and also populate the
            // new route key used by CustomerCopilotEngine.
            (source: "openAIApiKey", destination: "openAIApiKey"),
            (source: "openAIApiKey", destination: "interviewAPIKey"),
            (source: "deepSeekApiKey", destination: "deepSeekApiKey"),
            (source: "anthropicApiKey", destination: "anthropicApiKey"),
            (source: "assemblyAIApiKey", destination: "assemblyAIApiKey"),
            (source: "elevenLabsApiKey", destination: "elevenLabsApiKey"),
            (source: "cohereApiKey", destination: "cohereApiKey"),
            (source: "lmStudioApiKey", destination: "lmStudioApiKey"),
            (source: "openAILLMApiKey", destination: "openAILLMApiKey"),
            (source: "openAIEmbedApiKey", destination: "openAIEmbedApiKey"),
            (source: "voyageApiKey", destination: "voyageApiKey"),
            (source: "tencentASRSecretID", destination: "tencentASRSecretID"),
            (source: "tencentASRSecretKey", destination: "tencentASRSecretKey"),
            (source: "granolaApiKey", destination: "granolaApiKey"),
            (source: "webhookSecret", destination: "webhookSecret"),
        ]
        for mapping in keychainMappings {
            if let oldValue = loadKeychain(service: oldBundleID, key: mapping.source) {
                migrationSucceeded = KeychainHelper.saveIfMissing(
                    key: mapping.destination,
                    value: oldValue
                ) && migrationSucceeded
            }
        }

        migrationSucceeded = migrateFilesFromOpenOats() && migrationSucceeded
        if migrationSucceeded {
            defaults.set(true, forKey: migrationKey)
        } else {
            Log.sessionRepository.warning(
                "OpenOats migration is incomplete; retaining retry state for the next launch."
            )
        }
    }

    private static func migrateFilesFromOpenOats() -> Bool {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let sourceDirectory = applicationSupport.appendingPathComponent("OpenOats", isDirectory: true)
        let destinationDirectory = applicationSupport.appendingPathComponent(
            "Live Interview Copilot",
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: sourceDirectory.path) else { return true }

        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            Log.sessionRepository.error(
                "Failed to create OpenOats migration directory: \(error, privacy: .public)"
            )
            return false
        }

        var migrationSucceeded = mergeDirectoryContents(
            from: sourceDirectory.appendingPathComponent("sessions", isDirectory: true),
            into: destinationDirectory.appendingPathComponent("sessions", isDirectory: true),
            fileManager: fileManager
        )

        migrationSucceeded = mergeTemplatesJSON(
            from: sourceDirectory.appendingPathComponent("templates.json"),
            into: destinationDirectory.appendingPathComponent("templates.json"),
            fileManager: fileManager
        ) && migrationSucceeded
        migrationSucceeded = mergeKBCacheJSON(
            from: sourceDirectory.appendingPathComponent("kb_cache.json"),
            into: destinationDirectory.appendingPathComponent("kb_cache.json"),
            fileManager: fileManager
        ) && migrationSucceeded

        let sourceCopilotDirectory = sourceDirectory.appendingPathComponent("copilot", isDirectory: true)
        let destinationCopilotDirectory = destinationDirectory.appendingPathComponent("copilot", isDirectory: true)
        do {
            try fileManager.createDirectory(at: destinationCopilotDirectory, withIntermediateDirectories: true)
        } catch {
            Log.sessionRepository.error(
                "Failed to create OpenOats copilot migration directory: \(error, privacy: .public)"
            )
            migrationSucceeded = false
        }
        migrationSucceeded = mergeKnowledgeSourceMapJSON(
            from: sourceCopilotDirectory.appendingPathComponent("knowledge-source-map.json"),
            into: destinationCopilotDirectory.appendingPathComponent("knowledge-source-map.json"),
            fileManager: fileManager
        ) && migrationSucceeded
        migrationSucceeded = mergeKnowledgePackageJSON(
            from: sourceCopilotDirectory.appendingPathComponent("knowledge-package.json"),
            into: destinationCopilotDirectory.appendingPathComponent("knowledge-package.json"),
            fileManager: fileManager
        ) && migrationSucceeded
        migrationSucceeded = mergeCopilotHistory(
            from: sourceCopilotDirectory.appendingPathComponent("history.sqlite"),
            into: destinationCopilotDirectory.appendingPathComponent("history.sqlite")
        ) && migrationSucceeded
        return migrationSucceeded
    }

    private static func mergeDirectoryContents(
        from sourceDirectory: URL,
        into destinationDirectory: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: sourceDirectory.path) else { return true }
        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            Log.sessionRepository.error(
                "Failed to create migrated sessions directory: \(error, privacy: .public)"
            )
            return false
        }
        guard let items = try? fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }

        var migrationSucceeded = true
        for item in items {
            let destination = destinationDirectory.appendingPathComponent(item.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                // Session IDs are stable file names; an existing destination
                // already contains that record, so keep it and continue.
                continue
            }
            migrationSucceeded = moveItemIfMissing(
                from: item,
                to: destination,
                fileManager: fileManager
            ) && migrationSucceeded
        }
        return migrationSucceeded
    }

    private static func moveItemIfMissing(from source: URL, to destination: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: source.path) else { return true }
        guard !fileManager.fileExists(atPath: destination.path) else {
            Log.sessionRepository.warning(
                "OpenOats migration deferred because destination already exists: \(destination.lastPathComponent, privacy: .public)"
            )
            return false
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
            return true
        } catch {
            Log.sessionRepository.error(
                "Failed to migrate OpenOats item \(source.lastPathComponent, privacy: .public): \(error, privacy: .public)"
            )
            return false
        }
    }

    private static func mergeTemplatesJSON(from source: URL, into destination: URL, fileManager: FileManager) -> Bool {
        mergeJSONFile(from: source, into: destination, fileManager: fileManager) { destinationObject, sourceObject in
            guard let sourceTemplates = sourceObject["templates"] as? [[String: Any]] else { return false }
            if let existing = destinationObject["templates"], existing as? [[String: Any]] == nil {
                return false
            }
            var destinationTemplates = destinationObject["templates"] as? [[String: Any]] ?? []
            var existingIDs = Set(destinationTemplates.compactMap { $0["id"] as? String })
            for template in sourceTemplates {
                guard let id = template["id"] as? String, !id.isEmpty else { continue }
                if existingIDs.insert(id).inserted {
                    destinationTemplates.append(template)
                }
            }
            destinationObject["templates"] = destinationTemplates
            if destinationObject["version"] == nil {
                destinationObject["version"] = sourceObject["version"]
            }
            return true
        }
    }

    private static func mergeKBCacheJSON(from source: URL, into destination: URL, fileManager: FileManager) -> Bool {
        mergeJSONFile(from: source, into: destination, fileManager: fileManager) { destinationObject, sourceObject in
            guard let sourceEntries = sourceObject["entries"] as? [String: Any] else { return false }
            if let existing = destinationObject["entries"], existing as? [String: Any] == nil {
                return false
            }
            var destinationEntries = destinationObject["entries"] as? [String: Any] ?? [:]
            for (key, value) in sourceEntries where destinationEntries[key] == nil {
                destinationEntries[key] = value
            }
            destinationObject["entries"] = destinationEntries
            if destinationObject["embeddingConfigFingerprint"] == nil {
                destinationObject["embeddingConfigFingerprint"] = sourceObject["embeddingConfigFingerprint"]
            }
            if destinationObject["folderPath"] == nil {
                destinationObject["folderPath"] = sourceObject["folderPath"]
            }
            return true
        }
    }

    private static func mergeKnowledgeSourceMapJSON(
        from source: URL,
        into destination: URL,
        fileManager: FileManager
    ) -> Bool {
        mergeJSONFile(from: source, into: destination, fileManager: fileManager) { destinationObject, sourceObject in
            for (key, value) in sourceObject where destinationObject[key] == nil {
                destinationObject[key] = value
            }
            return true
        }
    }

    private static func mergeKnowledgePackageJSON(
        from source: URL,
        into destination: URL,
        fileManager: FileManager
    ) -> Bool {
        mergeJSONFile(from: source, into: destination, fileManager: fileManager) { destinationObject, sourceObject in
            guard mergeIdentifiedJSONArray(key: "sources", destination: &destinationObject, source: sourceObject),
                  mergeIdentifiedJSONArray(key: "blocks", destination: &destinationObject, source: sourceObject)
            else { return false }

            if let sourceFailures = sourceObject["failedFiles"] as? [String] {
                if let existing = destinationObject["failedFiles"], existing as? [String] == nil {
                    return false
                }
                var destinationFailures = destinationObject["failedFiles"] as? [String] ?? []
                for failure in sourceFailures where !destinationFailures.contains(failure) {
                    destinationFailures.append(failure)
                }
                destinationObject["failedFiles"] = destinationFailures
            }
            return true
        }
    }

    private static func mergeIdentifiedJSONArray(
        key: String,
        destination: inout [String: Any],
        source: [String: Any]
    ) -> Bool {
        guard let sourceItems = source[key] as? [[String: Any]] else {
            return source[key] == nil
        }
        if let existing = destination[key], existing as? [[String: Any]] == nil {
            return false
        }
        var destinationItems = destination[key] as? [[String: Any]] ?? []
        var existingIDs = Set(destinationItems.compactMap { $0["id"] as? String })
        for item in sourceItems {
            guard let id = item["id"] as? String, !id.isEmpty else { continue }
            if existingIDs.insert(id).inserted {
                destinationItems.append(item)
            }
        }
        destination[key] = destinationItems
        return true
    }

    private static func mergeJSONFile(
        from source: URL,
        into destination: URL,
        fileManager: FileManager,
        merge: (inout [String: Any], [String: Any]) -> Bool
    ) -> Bool {
        guard fileManager.fileExists(atPath: source.path) else { return true }
        guard fileManager.fileExists(atPath: destination.path) else {
            return moveItemIfMissing(from: source, to: destination, fileManager: fileManager)
        }
        guard let sourceObject = readJSONObject(at: source),
              var destinationObject = readJSONObject(at: destination),
              merge(&destinationObject, sourceObject) else {
            Log.sessionRepository.warning(
                "OpenOats JSON migration deferred because a file could not be merged: \(source.lastPathComponent, privacy: .public)"
            )
            return false
        }
        guard let data = try? JSONSerialization.data(withJSONObject: destinationObject, options: [.sortedKeys]) else {
            return false
        }
        do {
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            Log.sessionRepository.error(
                "Failed to write merged OpenOats JSON \(destination.lastPathComponent, privacy: .public): \(error, privacy: .public)"
            )
            return false
        }
    }

    private static func readJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private static func mergeCopilotHistory(from sourceDatabase: URL, into destinationDatabase: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: sourceDatabase.path) else { return true }

        var database: OpaquePointer?
        guard sqlite3_open(destinationDatabase.path, &database) == SQLITE_OK, let database else {
            return false
        }
        defer { sqlite3_close(database) }

        guard sqlite3_exec(database, """
            CREATE TABLE IF NOT EXISTS copilot_history (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                question TEXT NOT NULL,
                payload BLOB NOT NULL
            );
            """, nil, nil, nil) == SQLITE_OK else {
            return false
        }

        let escapedSourcePath = sourceDatabase.path.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(database, "ATTACH DATABASE '\(escapedSourcePath)' AS openoats_legacy", nil, nil, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_exec(database, "DETACH DATABASE openoats_legacy", nil, nil, nil) }

        return sqlite3_exec(database, """
            INSERT OR IGNORE INTO copilot_history(id, created_at, question, payload)
            SELECT id, created_at, question, payload FROM openoats_legacy.copilot_history;
            """, nil, nil, nil)
            == SQLITE_OK
    }

    /// Migrate settings from the old "On The Spot" (com.onthespot.app) bundle.
    /// Copies UserDefaults and Keychain entries to the current bundle, then marks migration as done.
    private static func migrateFromOldBundleIfNeeded(defaults: UserDefaults) {
        let migrationKey = "didMigrateFromOnTheSpot"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        guard let oldDefaults = UserDefaults(suiteName: "com.onthespot.app") else { return }

        let keysToMigrate = [
            "kbFolderPath", "selectedModel", "transcriptionLocale", "transcriptionModel", "inputDeviceID",
            "llmProvider", "embeddingProvider", "openAIBaseURL", "openAIModel",
            "anthropicBaseURL", "anthropicModel", "ollamaBaseURL", "ollamaLLMModel",
            "lmStudioBaseURL", "lmStudioModel",
            "ollamaEmbedModel", "hideFromScreenShare",
            "isTranscriptExpanded", "hasCompletedOnboarding",
        ]
        for key in keysToMigrate {
            if let value = oldDefaults.object(forKey: key), defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        let oldService = "com.onthespot.app"
        let keychainKeys = ["openRouterApiKey", "lmStudioApiKey", "voyageApiKey"]
        for key in keychainKeys {
            if let oldValue = Self.loadKeychain(service: oldService, key: key) {
                KeychainHelper.saveIfMissing(key: key, value: oldValue)
            }
        }
    }

    /// Migrate settings from the previous "OpenGranola" (com.opengranola.app) bundle.
    private static func migrateFromOpenGranolaIfNeeded(defaults: UserDefaults) {
        let migrationKey = "didMigrateFromOpenGranola"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        guard let oldDefaults = UserDefaults(suiteName: "com.opengranola.app") else {
            migrateFilesFromOpenGranola(defaults: defaults)
            return
        }

        let keysToMigrate = [
            "kbFolderPath", "selectedModel", "transcriptionLocale", "transcriptionModel", "inputDeviceID",
            "llmProvider", "embeddingProvider", "openAIBaseURL", "openAIModel",
            "anthropicBaseURL", "anthropicModel", "ollamaBaseURL", "ollamaLLMModel",
            "lmStudioBaseURL", "lmStudioModel",
            "ollamaEmbedModel", "hideFromScreenShare",
            "isTranscriptExpanded", "hasCompletedOnboarding",
            "hasAcknowledgedRecordingConsent",
        ]
        for key in keysToMigrate {
            if let value = oldDefaults.object(forKey: key), defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        let oldService = "com.opengranola.app"
        let keychainKeys = ["openRouterApiKey", "lmStudioApiKey", "voyageApiKey"]
        for key in keychainKeys {
            if let oldValue = Self.loadKeychain(service: oldService, key: key) {
                KeychainHelper.saveIfMissing(key: key, value: oldValue)
            }
        }

        migrateFilesFromOpenGranola(defaults: defaults)
    }

    /// Migrate file-backed state (sessions, templates, KB cache, transcripts)
    /// from ~/Library/Application Support/OpenGranola/ to LiveInterviewCopilot/ and
    /// handle the implicit KB folder default.
    private static func migrateFilesFromOpenGranola(defaults: UserDefaults) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        let oldAppSupportDir = appSupport.appendingPathComponent("OpenGranola")
        let newAppSupportDir = appSupport.appendingPathComponent("Live Interview Copilot")

        if fm.fileExists(atPath: oldAppSupportDir.path) {
            try? fm.createDirectory(at: newAppSupportDir, withIntermediateDirectories: true)

            let oldSessions = oldAppSupportDir.appendingPathComponent("sessions")
            let newSessions = newAppSupportDir.appendingPathComponent("sessions")
            if fm.fileExists(atPath: oldSessions.path) && !fm.fileExists(atPath: newSessions.path) {
                try? fm.moveItem(at: oldSessions, to: newSessions)
            }

            let oldTemplates = oldAppSupportDir.appendingPathComponent("templates.json")
            let newTemplates = newAppSupportDir.appendingPathComponent("templates.json")
            if fm.fileExists(atPath: oldTemplates.path) && !fm.fileExists(atPath: newTemplates.path) {
                try? fm.moveItem(at: oldTemplates, to: newTemplates)
            }

            let oldCache = oldAppSupportDir.appendingPathComponent("kb_cache.json")
            let newCache = newAppSupportDir.appendingPathComponent("kb_cache.json")
            if fm.fileExists(atPath: oldCache.path) && !fm.fileExists(atPath: newCache.path) {
                try? fm.moveItem(at: oldCache, to: newCache)
            }
        }

        let oldDocDir = home.appendingPathComponent("Documents/OpenGranola")
        let newDocDir = home.appendingPathComponent("Documents/LiveInterviewCopilot")

        if defaults.string(forKey: "notesFolderPath") == nil {
            if fm.fileExists(atPath: oldDocDir.path) {
                let contents = (try? fm.contentsOfDirectory(atPath: oldDocDir.path)) ?? []
                if !contents.isEmpty {
                    defaults.set(oldDocDir.path, forKey: "notesFolderPath")
                }
            }
        }

        let activeKB = defaults.string(forKey: "kbFolderPath") ?? ""
        let activeNotes = defaults.string(forKey: "notesFolderPath") ?? ""
        if fm.fileExists(atPath: oldDocDir.path) && oldDocDir.path != activeKB && oldDocDir.path != activeNotes {
            try? fm.createDirectory(at: newDocDir, withIntermediateDirectories: true)
            if let files = try? fm.contentsOfDirectory(at: oldDocDir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "txt" {
                    let dest = newDocDir.appendingPathComponent(file.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        try? fm.moveItem(at: file, to: dest)
                    }
                }
            }
        }
    }

    /// Migrate keychain entries from the old "com.opengranola.app" service to the
    /// current "com.jude864huang.liveinterviewcopilot.app" service.
    /// Renames the original export folder to the user-facing app name without
    /// touching it when a destination already exists. The canonical session
    /// store remains in Application Support; this only moves user-visible
    /// transcript and note exports.
    private static func migrateNotesDirectoryToCurrentDefaultIfNeeded(
        defaults: UserDefaults,
        defaultDirectory: URL
    ) {
        let fileManager = FileManager.default
        let legacyDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/LiveInterviewCopilot", isDirectory: true)

        let configuredDirectory = defaults.string(forKey: "notesFolderPath")
        guard legacyDirectory.standardizedFileURL != defaultDirectory.standardizedFileURL,
              configuredDirectory == nil || configuredDirectory == legacyDirectory.path,
              fileManager.fileExists(atPath: legacyDirectory.path),
              !fileManager.fileExists(atPath: defaultDirectory.path) else {
            return
        }

        do {
            try fileManager.moveItem(at: legacyDirectory, to: defaultDirectory)
            defaults.set(defaultDirectory.path, forKey: "notesFolderPath")
        } catch {
            Log.sessionRepository.error("Failed to migrate notes directory: \(error, privacy: .public)")
        }
    }

    private static func migrateKeychainServiceIfNeeded(defaults: UserDefaults) {
        let migrationKey = "didMigrateKeychainToLiveInterviewCopilot"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        let oldService = "com.opengranola.app"
        let keychainKeys = ["openRouterApiKey", "voyageApiKey", "openAIEmbedApiKey", "openAILLMApiKey"]
        for key in keychainKeys {
            if let oldValue = loadKeychain(service: oldService, key: key) {
                KeychainHelper.saveIfMissing(key: key, value: oldValue)
            }
        }
    }

    /// Read a keychain entry from a specific service (used for migration only).
    private static func loadKeychain(service: String, key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Backward-compatible alias so existing code continues to compile during migration.
typealias AppSettings = SettingsStore
