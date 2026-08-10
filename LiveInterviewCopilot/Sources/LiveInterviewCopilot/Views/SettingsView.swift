import AppKit
import AVFoundation
import SwiftUI
import CoreAudio
import LaunchAtLogin
import ServiceManagement
import Sparkle

// MARK: - Settings Tab Enum

private enum SettingsTab: String, CaseIterable {
    case general
    case copilot
    case calendar
    case transcription
    case intelligence
    case sidecast
    case templates
    case integrations
}

// MARK: - Settings View

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var updater: SPUUpdater
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab(settings: settings, updater: updater)
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsTab.general)

            CopilotSettingsTab(settings: settings)
                .tabItem { Label("Copilot", systemImage: "headset") }
                .tag(SettingsTab.copilot)

            CalendarSettingsTab(settings: settings)
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(SettingsTab.calendar)

            TranscriptionSettingsTab(settings: settings)
                .tabItem { Label("Transcription", systemImage: "waveform") }
                .tag(SettingsTab.transcription)

            TemplatesSettingsTab(settings: settings)
                .tabItem { Label("Templates", systemImage: "doc.text") }
                .tag(SettingsTab.templates)

        }
        .accessibilityIdentifier("settings.tabView")
        .frame(width: 640, height: 700)
    }
}

// MARK: - Interview Copilot

private struct CopilotSettingsTab: View {
    @Bindable var settings: AppSettings
    @Environment(AppCoordinator.self) private var coordinator
    @State private var confirmDeleteSession = false
    @State private var confirmDeleteAll = false
    @State private var apiModelsLoading = false
    @State private var apiModelsError: String?
    @State private var modelLoadTask: Task<Void, Never>?
    @State private var microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var tencentConnectionMessage: String?
    @State private var tencentConnectionSucceeded = false
    @State private var testingTencentConnection = false
    @State private var resolvingTencentAppID = false
    @State private var audioTestTask: Task<Void, Never>?
    @State private var audioTestMessage: String?
    @State private var showQwenAdvanced = false

    private var engine: CustomerCopilotEngine? { coordinator.customerCopilotEngine }
    private var codexModelPresetLabel: String {
        modelDisplayName(settings.interviewCodexModel)
    }
    private var defaultAPIBaseURL: String {
        settings.interviewAPIProtocol == .chatCompletion
            ? "https://api.deepseek.com"
            : "https://api.openai.com"
    }
    private var defaultAPIModel: String {
        settings.interviewAPIProtocol == .chatCompletion
            ? "deepseek-chat"
            : SettingsStore.defaultInterviewMainAnswerModel
    }
    private var activeAPIModelLabel: String {
        settings.interviewAPIModel.isEmpty ? defaultAPIModel : settings.interviewAPIModel
    }

    var body: some View {
        ScrollView(.vertical) {
            Form {
            Section("面试材料") {
                HStack {
                    Text(settings.kbFolderPath.isEmpty ? "No folder selected" : settings.kbFolderPath)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择…", action: chooseKnowledgeFolder)
                    Button("重新编译") {
                        guard let folder = settings.kbFolderURL else { return }
                        Task { await engine?.compiler.compile(folderURL: folder) }
                    }
                    .disabled(settings.kbFolderURL == nil)
                }

                if let compiler = engine?.compiler {
                    LabeledContent("状态", value: compiler.status.label)
                    if let package = compiler.snapshot {
                        LabeledContent("文件", value: "\(package.sources.count)")
                        LabeledContent("字符", value: package.characterCount.formatted())
                        LabeledContent("估算 tokens", value: package.estimatedTokenCount.formatted())
                        if let brief = compiler.realtimeBrief {
                            LabeledContent("Realtime 简报", value: "约 \(brief.estimatedTokenCount.formatted()) tokens")
                            LabeledContent("简报来源块", value: brief.includedBlockIDs.count.formatted())
                        }
                        LabeledContent("更新时间", value: package.compiledAt.formatted(date: .abbreviated, time: .standard))
                        ForEach(KnowledgeSourceCategory.allCases, id: \.rawValue) { category in
                            if let count = package.categoryCounts[category], count > 0 {
                                LabeledContent(category.label, value: "\(count)")
                            }
                        }
                        if !package.classificationWarnings.isEmpty {
                            Text(package.classificationWarnings.joined(separator: "\n"))
                                .font(.system(size: 10)).foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }
                    if !compiler.failedFiles.isEmpty {
                        Text(compiler.failedFiles.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                Text("推荐结构：01-resume、02-story-bank、03-job-description、04-company、05-domain。未分类文件不能作为个人经历依据。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Section("面试 ASR") {
                Picker("音频模式", selection: $settings.interviewAudioMode) {
                    Text("腾讯流式 ASR（手动分轮）")
                        .tag(InterviewAudioMode.manualStreamingASR)
                    Text("GPT Realtime（实验）")
                        .tag(InterviewAudioMode.openAIRealtimeExperimental)
                }
                .disabled(coordinator.transcriptionEngine?.isRunning == true)
                .onChange(of: settings.interviewAudioMode) { _, _ in
                    engine?.reconfigureInterviewAudioMode()
                }

                if coordinator.transcriptionEngine?.isRunning == true {
                    Text("面试进行中不能切换音频模式；请先停止本场面试。")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }

                if settings.interviewAudioMode == .manualStreamingASR {
                    LabeledContent("主识别服务", value: "腾讯云 · 16k_zh（标准版）")
                    Text("默认使用腾讯云标准实时语音识别，可抵扣账户每月实时 ASR 免费额度；具体剩余额度以腾讯云控制台为准。英文术语主要通过下方热词增强。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        TextField("腾讯云 AppID", text: $settings.tencentASRAppID)
                        Button(resolvingTencentAppID ? "正在获取…" : "自动获取") {
                            Task { await resolveTencentAppID(force: true) }
                        }
                        .disabled(resolvingTencentAppID || !hasTencentSecretPair)
                    }
                    SecureField("SecretID（保存在 Keychain）", text: $settings.tencentASRSecretID)
                    SecureField("SecretKey（保存在 Keychain）", text: $settings.tencentASRSecretKey)

                    HStack {
                        Button(testingTencentConnection ? "正在测试…" : "测试连接") {
                            testTencentConnection()
                        }
                        .disabled(testingTencentConnection || !settings.hasTencentASRCredentials)
                        if testingTencentConnection { ProgressView().controlSize(.small) }
                        if let tencentConnectionMessage {
                            Label(
                                tencentConnectionMessage,
                                systemImage: tencentConnectionSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                            )
                            .font(.system(size: 10))
                            .foregroundStyle(tencentConnectionSucceeded ? Color.green : Color.orange)
                        }
                    }

                    Toggle("根据面试材料自动生成热词", isOn: $settings.interviewASRAutoHotwordsEnabled)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("手动热词（逗号或换行分隔，优先级最高）")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $settings.interviewASRHotwordOverrides)
                            .font(.system(size: 11))
                            .frame(minHeight: 58, maxHeight: 82)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.primary.opacity(0.12))
                            }
                        Text(hotwordPreviewText)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }

                    LabeledContent("本地故障兜底") {
                        Label(
                            settings.qwenASRRuntimeStatus.message,
                            systemImage: settings.isQwenASRFallbackAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(settings.isQwenASRFallbackAvailable ? Color.green : Color.orange)
                    }
                    if let engine {
                        LabeledContent("本场预热状态", value: engine.qwenFallbackPrewarmStatus)
                            .foregroundStyle(
                                engine.qwenFallbackPrewarmStatus.hasPrefix("预热失败")
                                    ? Color.orange
                                    : Color.secondary
                            )
                    }

                    DisclosureGroup("Qwen 高级路径", isExpanded: $showQwenAdvanced) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("mlx-qwen3-asr 可执行文件（留空自动发现）", text: $settings.qwenASRExecutablePath)
                            TextField("Qwen3-ASR-0.6B 模型目录（留空自动发现）", text: $settings.qwenASRModelPath)
                            LabeledContent("已发现程序", value: settings.resolvedQwenASRExecutableURL?.path ?? "未发现")
                            LabeledContent("已发现模型", value: settings.resolvedQwenASRModelURL?.path ?? "未发现")
                        }
                        .font(.system(size: 10))
                        .padding(.top, 6)
                    }

                    Text("腾讯模式只发送当前活动角色的音频和热词；精简知识包只会发送给文字生成模型。腾讯云费用与 ChatGPT Pro、OpenAI API 分开。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("实验功能：中文识别、打断和轮次判断可能不稳定。", systemImage: "flask.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    TextField("Realtime 模型", text: Binding(
                        get: { engine?.realtimeModel ?? "gpt-realtime-2.1" },
                        set: { engine?.realtimeModel = $0 }
                    ))
                    Text("实验模式会把双方实时音频、面试简报和会话上下文发送给 OpenAI。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Section("音频检查") {
                LabeledContent("候选人麦克风", value: settings.inputDeviceName ?? "系统默认输入设备")
                LabeledContent("面试官系统音频", value: settings.outputDeviceName ?? "系统默认输出设备")
                LabeledContent("麦克风权限") {
                    Text(microphonePermissionLabel)
                        .foregroundStyle(microphonePermission == .authorized ? Color.green : Color.orange)
                }
                LabeledContent("屏幕录制权限") {
                    Text(CGPreflightScreenCaptureAccess() ? "已允许" : "尚未允许或需重新启动")
                        .foregroundStyle(CGPreflightScreenCaptureAccess() ? Color.green : Color.orange)
                }
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    let transcription = coordinator.transcriptionEngine
                    let health = transcription?.captureHealthSnapshot
                    VStack(alignment: .leading, spacing: 6) {
                        audioChannelMeter(
                            title: "Mic / 候选人",
                            level: transcription?.micAudioLevel ?? 0,
                            hasFrames: health?.micHasCapturedFrames ?? false,
                            lastFrameAt: health?.micLastFrameAt,
                            sampleRate: health?.micSampleRate
                        )
                        audioChannelMeter(
                            title: "System / 面试官",
                            level: transcription?.systemAudioLevel ?? 0,
                            hasFrames: health?.systemHasCapturedFrames ?? false,
                            lastFrameAt: health?.systemLastFrameAt,
                            sampleRate: health?.systemSampleRate
                        )
                        LabeledContent("采集状态", value: coordinator.transcriptionEngine?.assetStatus ?? "尚未启动")
                        if let error = health?.micCaptureError ?? coordinator.transcriptionEngine?.lastError,
                           !error.isEmpty {
                            Text(error)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
                HStack {
                    if microphonePermission == .notDetermined {
                        Button("请求麦克风权限") {
                            Task {
                                _ = await AVCaptureDevice.requestAccess(for: .audio)
                                microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
                            }
                        }
                    } else if microphonePermission != .authorized {
                        Button("打开麦克风隐私设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    if !CGPreflightScreenCaptureAccess() {
                        Button("打开屏幕录制设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    Button(audioTestTask == nil ? "进行 3 秒双路测试" : "测试中…") {
                        runAudioTest()
                    }
                    .disabled(audioTestTask != nil || coordinator.transcriptionEngine?.isRunning != true)
                }
                if let audioTestMessage {
                    Text(audioTestMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(audioTestMessage.contains("通过") ? Color.green : Color.orange)
                }
                Text("请先点击 Start，再测试两路音频。收到帧但电平过低通常是静音或音量问题；完全没有帧通常是权限、设备或采集启动问题。设备可在 Transcription → Audio Input 中切换。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("文字生成") {
                Picker("生成通路", selection: Binding(
                    get: { settings.interviewInferencePreference },
                    set: { preference in
                        guard settings.interviewInferencePreference != preference else { return }
                        // A live engine forwards this directly to the durable
                        // setting; without an engine, the setting still takes
                        // effect for the next interview.
                        if let engine {
                            engine.inferencePreference = preference
                        } else {
                            settings.interviewInferencePreference = preference
                        }
                    }
                )) {
                    ForEach([InterviewInferencePreference.apiPreferred, .codexOnly], id: \.rawValue) { value in
                        Text(value.label).tag(value)
                    }
                }
                .accessibilityIdentifier("settings.copilot.inferenceProviderPicker")
                if settings.interviewInferencePreference == .apiPreferred {
                    Picker("API 协议", selection: $settings.interviewAPIProtocol) {
                        ForEach(InterviewAPIProtocol.allCases) { apiProtocol in
                            Text(apiProtocol.label).tag(apiProtocol)
                        }
                    }
                    .accessibilityIdentifier("settings.copilot.apiProtocolPicker")
                    .onChange(of: settings.interviewAPIProtocol) { _, newValue in
                        applyProtocolDefaults(newValue)
                        scheduleModelLoad()
                    }
                    TextField(
                        "API Base URL",
                        text: $settings.interviewAPIBaseURL,
                        prompt: Text(defaultAPIBaseURL)
                    )
                        .font(.system(size: 11, design: .monospaced))
                        .onChange(of: settings.interviewAPIBaseURL) { _, _ in
                            scheduleModelLoad()
                        }
                    HStack {
                        SecureField("API Key", text: $settings.interviewAPIKey)
                            .onChange(of: settings.interviewAPIKey) { _, _ in
                                scheduleModelLoad()
                            }
                        Button(apiModelsLoading ? "加载中…" : "验证并加载模型") {
                            Task { await loadAPIModels() }
                        }
                        .disabled(apiModelsLoading || settings.interviewAPIKey.isEmpty)
                    }
                    if let apiModelsError {
                        Text(apiModelsError)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    if settings.interviewAPIModelOptions.isEmpty {
                        TextField(
                            "主回答模型",
                            text: $settings.interviewAPIModel,
                            prompt: Text(defaultAPIModel)
                        )
                    } else {
                        Picker("主回答模型", selection: $settings.interviewAPIModel) {
                            ForEach(settings.interviewAPIModelOptions, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }
                    if settings.interviewAPIModelOptions.isEmpty {
                        TextField("备用回答模型", text: $settings.interviewFallbackAnswerModel)
                            .accessibilityHint("主回答在可用首句前失败时启动")
                    } else {
                        Picker("备用回答模型", selection: Binding(
                            get: { settings.interviewFallbackAnswerModel },
                            set: { settings.interviewFallbackAnswerModel = $0 }
                        )) {
                            Text("不使用").tag("")
                            ForEach(settings.interviewAPIModelOptions, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .accessibilityHint("主回答在可用首句前失败时启动；留空则只使用主模型")
                    }
                    Picker("思考深度", selection: $settings.interviewAnswerDepth) {
                        ForEach(InterviewAnswerDepth.allCases) { depth in
                            Text(depth.label).tag(depth)
                        }
                    }
                    Text(settings.interviewAnswerDepth.targetDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if settings.interviewAPIProtocol == .responses {
                        Toggle("API 快速模式", isOn: $settings.interviewAPIFastServiceTierEnabled)
                            .accessibilityHint("对支持 Priority Processing 服务的模型启用，会增加用量或费用")
                        Text("Responses API 会在支持该服务层的模型上使用 priority service tier；Chat Completions 协议一般没有等价入口。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("API key 只保存在 macOS Keychain。生成通路选择 API 优先时，会把精简知识包、最近六轮面试官问题和当前问题发送给所选 API；候选人转写只有开启上方开关后才发送。缺少 key 时使用 Codex CLI 通路。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("主回答通过 \(settings.interviewAPIProtocol.label) 使用 \(activeAPIModelLabel)。若在可用首句出现前失败，会先切换到备用模型；若备用也失败，会解除本场锁定。实际模型和切换原因可在「运行详情」查看。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack {
                        TextField("Codex CLI 模型 ID", text: $settings.interviewCodexModel)
                            .accessibilityIdentifier("settings.copilot.codexModelField")
                        Menu(codexModelPresetLabel) {
                            ForEach(SettingsStore.interviewCodexModelPresets, id: \.self) { model in
                                Button(modelDisplayName(model)) {
                                    settings.interviewCodexModel = model
                                }
                            }
                        }
                    }
                    Text("Codex CLI 主回答当前使用 \(settings.interviewCodexModel.isEmpty ? SettingsStore.defaultInterviewCodexModel : settings.interviewCodexModel)。可直接输入其他模型 ID；快速思路仍使用下方备用模型。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("Codex 思考深度", selection: $settings.interviewCodexReasoningEffort) {
                        ForEach([InterviewReasoningEffort.none, .low, .medium, .high, .xhigh], id: \.rawValue) { effort in
                            Text(effort.label).tag(effort)
                        }
                    }
                    .accessibilityIdentifier("settings.copilot.codexReasoningPicker")
                    Text(settings.interviewCodexReasoningEffort.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("备用回答模型", text: $settings.interviewFallbackAnswerModel)
                        .accessibilityHint("主回答在可用首句前失败时启动；备用也失败则解除本场锁定")
                    Text("默认 \(SettingsStore.defaultInterviewFallbackAnswerModel)。只有主回答模型在可用首句前失败时才会切换到备用模型；若备用模型也失败，会解除本场锁定，后续可再回到用户选择的主模型。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(isOn: $settings.interviewCodexFastServiceTierEnabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Codex 官方 Fast mode", systemImage: "hare.fill")
                            Label("对支持该服务层的 Codex 模型提速，但会消耗更多订阅额度；备用 \(settings.interviewFallbackAnswerModel) 使用自身的低延迟通路。", systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityHint("控制 Codex 官方 Fast mode；开启后会增加订阅额度消耗")
                }
                Toggle("将我的转写用于后续文字提示", isOn: $settings.interviewIncludeCandidateAnswersInContext)
                    .accessibilityHint("关闭时仍转写并本地保存，但不会发送给后续文字模型")
                Text("默认关闭。开启后，最近六轮候选人回答每轮最多发送约 500 字，当前回答最多约 800 字；转写只帮助理解追问，不能作为个人经历或数字的事实依据。腾讯云 ASR 仍会接收当前活动角色的音频。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Stepper(
                    value: $settings.interviewKnowledgeBriefTokenBudget,
                    in: SettingsStore.interviewKnowledgeBriefTokenRange,
                    step: 1_000
                ) {
                    Label(
                        "主回答材料：约 \(settings.interviewKnowledgeBriefTokenBudget.formatted()) tokens",
                        systemImage: "doc.text.magnifyingglass"
                    )
                }
                .accessibilityHint("调整主回答使用的精简知识包大小")
                Text("各材料分类仍保留既定配额，分类内部会按当前问题相关度排序；可能追问使用更小的上下文。完整文件只保留在本机。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("生成") {
                Text("首版使用手动分轮，不使用 VAD 自动终点检测。按主快捷键结束当前角色的发言并立即切换到另一方。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("最大上下文 tokens", value: Binding(
                    get: { engine?.maxContextTokens ?? 128_000 },
                    set: { engine?.maxContextTokens = max(8_192, $0) }
                ), format: .number)
            }

            Section("固定面试 Prompt") {
                TextEditor(text: Binding(
                    get: { engine?.interviewPrompt ?? CustomerCopilotEngine.defaultPrompt },
                    set: { engine?.interviewPrompt = $0 }
                ))
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 220)

                HStack {
                    Spacer()
                    Button("恢复默认") { engine?.interviewPrompt = CustomerCopilotEngine.defaultPrompt }
                }
            }

            Section("本地留存") {
                Text("面试转写和提示会导出到下方目录；历史记录和本地录音仍由应用安全地关联保存。删除操作不可恢复。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Text(settings.notesFolderPath)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("更改目录…", action: chooseLocalRetentionFolder)
                }
                HStack {
                    Button("删除本场面试（含转写）", role: .destructive) { confirmDeleteSession = true }
                    Button("清空全部 Copilot 历史", role: .destructive) { confirmDeleteAll = true }
                }
            }

                Section("全局快捷键") {
                    LabeledContent("结束当前发言 / 切换角色") {
                        CopilotHotkeyRecorder(shortcut: $settings.copilotTurnHotkey)
                    }
                    LabeledContent("合并上一段", value: CopilotTurnHotkey.merge.displayName)
                    LabeledContent("停止生成", value: CopilotTurnHotkey.stop.displayName)
                    LabeledContent("镜头卡开关", value: CopilotTurnHotkey.lensToggle.displayName)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .padding(20)
        }
        .scrollIndicators(.visible)
        .task {
            await resolveTencentAppID(force: false)
        }
        .onDisappear {
            audioTestTask?.cancel()
            audioTestTask = nil
        }
        .confirmationDialog("删除本场面试的转写和 Copilot 历史？", isPresented: $confirmDeleteSession, titleVisibility: .visible) {
            Button("删除", role: .destructive) { engine?.deleteCurrentSessionHistory() }
        }
        .confirmationDialog("清空全部 Copilot 历史？", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("全部删除", role: .destructive) { engine?.deleteAllHistory() }
        }
    }

    private func chooseLocalRetentionFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择面试转写和笔记的本地留存目录"

        if panel.runModal() == .OK, let url = panel.url {
            settings.notesFolderPath = url.path
            settings.saveNotesFolderBookmark(from: url)
        }
    }

    private func chooseKnowledgeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "使用此面试材料文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.kbFolderPath = url.path
        engine?.compiler.watch(folderURL: url)
    }

    private var hotwords: [InterviewHotword] {
        InterviewHotwordExtractor.extract(
            manualTerms: settings.interviewASRManualTerms,
            snapshot: settings.interviewASRAutoHotwordsEnabled ? engine?.compiler.snapshot : nil
        )
    }

    private var hotwordPreviewText: String {
        guard !hotwords.isEmpty else {
            return "当前没有热词。可在上方填写专业词，或先编译面试材料。"
        }
        let preview = hotwords.prefix(24).map { "\($0.phrase)|\($0.weight)" }.joined(separator: "、")
        let suffix = hotwords.count > 24 ? " …" : ""
        return "将发送 \(hotwords.count)/128 条：\(preview)\(suffix)"
    }

    @ViewBuilder
    private func audioChannelMeter(
        title: String,
        level: Float,
        hasFrames: Bool,
        lastFrameAt: Date?,
        sampleRate: Double?
    ) -> some View {
        let state: (text: String, color: Color) = if !hasFrames {
            ("未收到音频帧", .orange)
        } else if level > 0.002 {
            ("检测到声音", .green)
        } else {
            ("已收到帧，当前音量低", .secondary)
        }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(title).frame(width: 105, alignment: .leading)
                ProgressView(value: Double(level), total: 1)
                Text(state.text)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(state.color)
                    .frame(width: 124, alignment: .trailing)
            }
            HStack(spacing: 8) {
                if let sampleRate {
                    Text("\(Int(sampleRate.rounded()).formatted()) Hz")
                }
                if let lastFrameAt {
                    Text("最后一帧 \(lastFrameAt.formatted(date: .omitted, time: .standard))")
                }
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.leading, 113)
        }
    }

    private func runAudioTest() {
        guard audioTestTask == nil, let transcription = coordinator.transcriptionEngine, transcription.isRunning else {
            audioTestMessage = "请先点击 Start，启动系统音频和麦克风采集。"
            return
        }
        audioTestMessage = nil
        audioTestTask = Task { @MainActor in
            var micPeak: Float = 0
            var systemPeak: Float = 0
            var micFrames = false
            var systemFrames = false
            for _ in 0..<15 {
                guard !Task.isCancelled else { return }
                micPeak = max(micPeak, transcription.micAudioLevel)
                systemPeak = max(systemPeak, transcription.systemAudioLevel)
                let health = transcription.captureHealthSnapshot
                micFrames = micFrames || health.micHasCapturedFrames
                systemFrames = systemFrames || health.systemHasCapturedFrames
                try? await Task.sleep(for: .milliseconds(200))
            }

            let micResult = !micFrames ? "Mic 无帧" : (micPeak > 0.002 ? "Mic 通过" : "Mic 音量低")
            let systemResult = !systemFrames ? "System 无帧" : (systemPeak > 0.002 ? "System 通过" : "System 音量低")
            audioTestMessage = "测试完成：\(micResult)；\(systemResult)。"
            audioTestTask = nil
        }
    }

    private var hasTencentSecretPair: Bool {
        !settings.tencentASRSecretID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.tencentASRSecretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    private func resolveTencentAppID(force: Bool) async {
        guard !resolvingTencentAppID, hasTencentSecretPair else { return }
        guard force || settings.tencentASRAppID.isEmpty else { return }

        resolvingTencentAppID = true
        tencentConnectionSucceeded = false
        tencentConnectionMessage = nil
        do {
            settings.tencentASRAppID = try await TencentAccountAppIDResolver.resolve(
                secretID: settings.tencentASRSecretID,
                secretKey: settings.tencentASRSecretKey
            )
            tencentConnectionSucceeded = true
            tencentConnectionMessage = "已从腾讯云账号自动获取 APPID。"
        } catch {
            tencentConnectionSucceeded = false
            tencentConnectionMessage = error.localizedDescription
        }
        resolvingTencentAppID = false
    }

    private func testTencentConnection() {
        guard settings.hasTencentASRCredentials else {
            tencentConnectionSucceeded = false
            tencentConnectionMessage = "请完整填写 AppID、SecretID 和 SecretKey。"
            return
        }
        testingTencentConnection = true
        tencentConnectionSucceeded = false
        tencentConnectionMessage = nil
        let configuration = TencentASRConfiguration(
            credentials: TencentASRCredentials(
                appID: settings.tencentASRAppID,
                secretID: settings.tencentASRSecretID,
                secretKey: settings.tencentASRSecretKey
            ),
            hotwords: [],
            connectionTimeout: .seconds(8)
        )
        Task {
            do {
                try await TencentASRConnectionTester.test(configuration: configuration)
                tencentConnectionSucceeded = true
                tencentConnectionMessage = "腾讯云连接和鉴权成功。"
            } catch {
                tencentConnectionSucceeded = false
                tencentConnectionMessage = error.localizedDescription
            }
            testingTencentConnection = false
        }
    }

    private var microphonePermissionLabel: String {
        switch microphonePermission {
        case .authorized: "已允许"
        case .notDetermined: "尚未请求"
        case .denied: "已拒绝"
        case .restricted: "受系统限制"
        @unknown default: "未知"
        }
    }

    private func modelDisplayName(_ model: String) -> String {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "gpt-5.6-terra": return "Terra"
        case "gpt-5.6-luna": return "Luna"
        case "gpt-5.3-codex-spark": return "Spark"
        default: return normalized.isEmpty ? "自定义" : model
        }
    }

    private func applyProtocolDefaults(_ apiProtocol: InterviewAPIProtocol) {
        let defaults = apiProtocol == .chatCompletion
            ? ("https://api.deepseek.com", "deepseek-chat")
            : ("https://api.openai.com", SettingsStore.defaultInterviewMainAnswerModel)
        let currentBase = settings.interviewAPIBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if currentBase.isEmpty
            || currentBase == "https://api.openai.com"
            || currentBase == "https://api.deepseek.com" {
            settings.interviewAPIBaseURL = defaults.0
        }
        if settings.interviewAPIModel.isEmpty {
            settings.interviewAPIModel = defaults.1
        }
        settings.interviewAPIModelOptions = []
    }

    private func scheduleModelLoad() {
        modelLoadTask?.cancel()
        modelLoadTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await loadAPIModels()
        }
    }

    private func loadAPIModels() async {
        let key = settings.interviewAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              let url = OpenRouterClient.modelsURL(from: settings.interviewAPIBaseURL) else {
            return
        }
        apiModelsLoading = true
        apiModelsError = nil
        defer { apiModelsLoading = false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                apiModelsError = "模型列表加载失败：无法识别的响应"
                return
            }
            guard (200...299).contains(http.statusCode) else {
                apiModelsError = http.statusCode == 401 || http.statusCode == 403
                    ? "API key 无效或无权访问模型列表"
                    : "模型列表加载失败：HTTP \(http.statusCode)"
                return
            }
            struct ModelsResponse: Decodable {
                let data: [ModelEntry]
            }
            struct ModelEntry: Decodable {
                let id: String
            }
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            let ids = decoded.data.map(\.id).filter { !$0.isEmpty }
            guard !ids.isEmpty else {
                apiModelsError = "模型列表为空，请检查 Base URL"
                return
            }
            settings.interviewAPIModelOptions = ids.sorted()
            if settings.interviewAPIModel.isEmpty || !ids.contains(settings.interviewAPIModel) {
                settings.interviewAPIModel = ids.first ?? settings.interviewAPIModel
            }
            if settings.interviewFallbackAnswerModel.isEmpty
                || !ids.contains(settings.interviewFallbackAnswerModel) {
                settings.interviewFallbackAnswerModel = ""
            }
        } catch {
            apiModelsError = "模型列表加载失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - General Settings Tab

private struct GeneralSettingsTab: View {
    @Bindable var settings: AppSettings
    var updater: SPUUpdater
    @Environment(AppCoordinator.self) private var coordinator
    @State private var automaticallyChecksForUpdates = false
    @State private var showAutoDetectExplanation = false
    @State private var launchAtLoginEnabled = false
    @State private var showAdvancedDetection = false
    @State private var showWizard = false
    @State private var diagnosticsExportMessage: String?
    @State private var diagnosticsExportHadError = false
    @State private var diagnosticsExportInFlight = false

    /// Bridges the canonical seconds setting to the value shown in the field,
    /// converting to/from the user's chosen display unit (seconds vs minutes).
    private var silenceTimeoutDisplayValue: Binding<Int> {
        Binding(
            get: {
                settings.silenceTimeoutUnitIsSeconds
                    ? settings.silenceTimeoutSeconds
                    : settings.silenceTimeoutSeconds / 60
            },
            set: { newValue in
                let clamped = max(0, newValue)
                settings.silenceTimeoutSeconds = settings.silenceTimeoutUnitIsSeconds
                    ? clamped
                    : clamped * 60
            }
        )
    }

    var body: some View {
        ScrollView {
            Form {
                Section("Meeting Notes") {
                    Text("Where meeting transcripts are saved as plain text files.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    HStack {
                        Text(settings.notesFolderPath)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button("Choose...") {
                            chooseNotesFolder()
                        }
                    }

                    HStack(alignment: .center) {
                        Toggle("", isOn: $settings.saveMeetingTranscriptsInDateSubfolders)
                            .labelsHidden()
                            .accessibilityLabel("Save meeting transcripts into subfolders")

                        Text("Save meeting transcripts into subfolders.")
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer()

                        Picker("", selection: $settings.meetingTranscriptDateFolderFormat) {
                            ForEach(MeetingTranscriptDateFolderFormat.allCases) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 175)
                        .disabled(!settings.saveMeetingTranscriptsInDateSubfolders)
                    }
                }

                Section("Meeting Detection") {
                    Toggle("Auto-detect meetings", isOn: $settings.meetingAutoDetectEnabled)
                        .font(.system(size: 12))
                        .onChange(of: settings.meetingAutoDetectEnabled) {
                            if settings.meetingAutoDetectEnabled && !settings.hasShownAutoDetectExplanation {
                                settings.meetingAutoDetectEnabled = false
                                showAutoDetectExplanation = true
                            }
                        }

                    Text("When enabled, LiveInterviewCopilot monitors camera and microphone activation to detect when a meeting starts. No audio or video is captured until you accept the notification.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Toggle("Launch at login", isOn: $launchAtLoginEnabled)
                        .font(.system(size: 12))
                        .onChange(of: launchAtLoginEnabled) { _, newValue in
                            LaunchAtLogin.isEnabled = newValue
                        }
                        .task {
                            launchAtLoginEnabled = await Task.detached {
                                SMAppService.mainApp.status == .enabled
                            }.value
                        }
                }
                .sheet(isPresented: $showAutoDetectExplanation) {
                    VStack(spacing: 16) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)

                        Text("How Meeting Detection Works")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 10) {
                            Label("Live Interview Copilot watches for camera and microphone activation by meeting apps (Zoom, Teams, FaceTime, etc.)", systemImage: "video")
                            Label("Only activation status is checked. No audio is captured or recorded until you accept.", systemImage: "lock.shield")
                            Label("When a meeting is detected, you get a macOS notification to start transcribing.", systemImage: "bell")
                            Label("You can always dismiss the notification or mark it as \"not a meeting\".", systemImage: "hand.raised")
                        }
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)

                        HStack {
                            Button("Cancel") {
                                showAutoDetectExplanation = false
                            }
                            .keyboardShortcut(.cancelAction)

                            Button("Enable Detection") {
                                settings.hasShownAutoDetectExplanation = true
                                settings.meetingAutoDetectEnabled = true
                                showAutoDetectExplanation = false
                            }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(24)
                    .frame(width: 400)
                }

                if settings.meetingAutoDetectEnabled {
                    DisclosureGroup(isExpanded: $showAdvancedDetection, content: {
                        Toggle("Detection log", isOn: $settings.detectionLogEnabled)
                            .font(.system(size: 12))
                        Text("Print detection events to the system console for debugging.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }, label: {
                        HStack {
                            Text("Advanced Detection Settings")
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .onTapGesture { showAdvancedDetection.toggle() }
                        .padding(.vertical, -10)
                    })
                    .font(.system(size: 12))
                }

                Section("Auto-Stop on Silence") {
                    HStack {
                        Text("Silence timeout")
                            .font(.system(size: 12))
                        Spacer()
                        TextField("", value: silenceTimeoutDisplayValue, format: .number)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 50)
                            .multilineTextAlignment(.trailing)
                        Picker("", selection: $settings.silenceTimeoutUnitIsSeconds) {
                            Text("sec").tag(true)
                            Text("min").tag(false)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 110)
                    }
                    Text("Recordings automatically stop after this much silence — applies to both manual and auto-detected sessions. Set to 0 to disable.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if !settings.ignoredAppBundleIDs.isEmpty {
                    Section("Ignored Apps") {
                        Text("These apps won't trigger meeting detection notifications.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        ForEach(settings.ignoredAppBundleIDs, id: \.self) { bundleID in
                            HStack {
                                Text(bundleID)
                                    .font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Button {
                                    settings.ignoredAppBundleIDs.removeAll { $0 == bundleID }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Stop ignoring this app")
                            }
                        }
                    }
                }

                Section("Privacy") {
                    Toggle("Hide from screen sharing", isOn: $settings.hideFromScreenShare)
                        .font(.system(size: 12))
                        .disabled(coordinator.transcriptionEngine?.isRunning == true)
                    Text(coordinator.transcriptionEngine?.isRunning == true
                        ? "Interview Copilot is always visible while an interview is running."
                        : "For ordinary sessions only. Starting Interview Copilot resets this to visible.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Section("Updates") {
                    Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                        .font(.system(size: 12))
                        .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                            Task { @MainActor in
                                updater.automaticallyChecksForUpdates = newValue
                            }
                        }
                }

                Section("Setup") {
                    Button("Re-run Setup Wizard") {
                        showWizard = true
                    }
                    .font(.system(size: 12))

                    Text("Re-runs the initial setup wizard. Your current settings will be shown as starting values.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Section("Troubleshooting") {
                    Toggle("Diagnostic logging", isOn: $settings.diagnosticLoggingEnabled)
                        .font(.system(size: 12))

                    Text("Keeps a small internal breadcrumb trail for session and batch lifecycle debugging. Use Export Diagnostics to share recent technical logs without exposing API keys.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Button(diagnosticsExportInFlight ? "Exporting…" : "Export Diagnostics…") {
                        exportDiagnostics()
                    }
                    .font(.system(size: 12))
                    .disabled(diagnosticsExportInFlight)

                    Text("Exports a plain-text bundle with recent unified logs, non-sensitive app settings, and any diagnostic breadcrumbs collected while the toggle was enabled.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if let diagnosticsExportMessage {
                        Text(diagnosticsExportMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(diagnosticsExportHadError ? .red : .secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            Task { @MainActor in
                automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            }
        }
        .sheet(isPresented: $showWizard) {
            SetupWizardView(
                isPresented: $showWizard,
                settings: settings,
                isReconfiguration: true
            )
            .frame(width: 500, height: 550)
        }
    }

    private func chooseNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to save meeting transcripts"

        if panel.runModal() == .OK, let url = panel.url {
            settings.notesFolderPath = url.path
            settings.saveNotesFolderBookmark(from: url)
        }
    }

    private func exportDiagnostics() {
        diagnosticsExportInFlight = true
        diagnosticsExportMessage = nil
        diagnosticsExportHadError = false

        Task { @MainActor in
            defer { diagnosticsExportInFlight = false }
            do {
                let url = try await DiagnosticsSupport.exportInteractively(settings: settings)
                diagnosticsExportMessage = "Saved diagnostics to \(url.lastPathComponent)."
                diagnosticsExportHadError = false
            } catch let error as DiagnosticsSupport.Error {
                switch error {
                case .cancelled:
                    diagnosticsExportMessage = nil
                default:
                    diagnosticsExportMessage = error.localizedDescription
                    diagnosticsExportHadError = true
                }
            } catch {
                diagnosticsExportMessage = error.localizedDescription
                diagnosticsExportHadError = true
            }
        }
    }
}

// MARK: - Transcription Settings Tab

private struct TranscriptionSettingsTab: View {
    @Bindable var settings: AppSettings
    @State private var inputDevices: [(id: AudioDeviceID, name: String)] = []
    @State private var outputDevices: [(id: AudioDeviceID, name: String)] = []
    @State private var isValidatingElevenLabsKey = false
    @State private var elevenLabsValidation: APIKeyValidator.ValidationResult?
    @State private var elevenLabsValidationTask: Task<Void, Never>?
    @State private var isValidatingCohereKey = false
    @State private var cohereValidation: APIKeyValidator.ValidationResult?
    @State private var cohereValidationTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            Form {
                Section("Audio Input") {
                    Picker("Microphone", selection: $settings.inputDeviceID) {
                        Text("System Default").tag(AudioDeviceID(0))
                        ForEach(inputDevices, id: \.id) { device in
                            Text(device.name).tag(device.id)
                        }
                        if settings.inputDeviceID > 0,
                           !inputDevices.contains(where: { $0.id == settings.inputDeviceID }),
                           let name = settings.inputDeviceName {
                            Text("\(name) (unavailable)").tag(settings.inputDeviceID)
                        }
                    }
                    .font(.system(size: 12))
                    .accessibilityIdentifier("settings.microphonePicker")

                    Picker("Speaker / Output", selection: $settings.outputDeviceID) {
                        Text("System Default").tag(AudioDeviceID(0))
                        ForEach(outputDevices, id: \.id) { device in
                            Text(device.name).tag(device.id)
                        }
                        if settings.outputDeviceID > 0,
                           !outputDevices.contains(where: { $0.id == settings.outputDeviceID }),
                           let name = settings.outputDeviceName {
                            Text("\(name) (unavailable)").tag(settings.outputDeviceID)
                        }
                    }
                    .font(.system(size: 12))
                    .accessibilityIdentifier("settings.outputDevicePicker")
                    Text("Select the output device carrying your meeting audio. If using AirPods or Bluetooth headphones, select them explicitly.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Section("Recording") {
                    Toggle("Save audio recording", isOn: $settings.saveAudioRecording)
                        .font(.system(size: 12))
                    Text("Enabled by default for interviews. Saves a local .m4a file and can be turned off before starting; the saved recording never leaves your device.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Toggle("Echo cancellation", isOn: $settings.enableEchoCancellation)
                        .font(.system(size: 12))
                    Text("Reduces duplicate transcription when using speakers and microphone simultaneously. Currently disabled during recording because it conflicts with system audio capture on macOS.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Section("Transcription") {
                    Picker("Model", selection: $settings.transcriptionModel) {
                        Section("Local") {
                            ForEach(TranscriptionModel.allCases.filter { !$0.isCloud }) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        Section("Cloud") {
                            ForEach(TranscriptionModel.allCases.filter { $0.isCloud }) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                    }
                    .font(.system(size: 12))
                    .accessibilityIdentifier("settings.transcriptionModelPicker")

                    if settings.transcriptionModel.isCloud {
                        switch settings.transcriptionModel {
                        case .assemblyAI:
                            SecureField("AssemblyAI API Key", text: $settings.assemblyAIApiKey)
                                .font(.system(size: 12, design: .monospaced))
                            Text("Audio segments are sent to AssemblyAI for transcription. AssemblyAI states audio is deleted after processing. Review their privacy policy at assemblyai.com/security.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        case .elevenLabsScribe:
                            HStack(spacing: 8) {
                                SecureField("ElevenLabs API Key", text: $settings.elevenLabsApiKey)
                                    .font(.system(size: 12, design: .monospaced))
                                    .accessibilityIdentifier("settings.elevenLabsApiKeyField")

                                apiKeyValidationIndicator(
                                    isValidating: isValidatingElevenLabsKey,
                                    result: elevenLabsValidation
                                )
                            }
                            .onAppear {
                                scheduleElevenLabsValidation(for: settings.elevenLabsApiKey)
                            }
                            .onChange(of: settings.elevenLabsApiKey) { _, newValue in
                                scheduleElevenLabsValidation(for: newValue)
                            }

                            apiKeyValidationMessage(result: elevenLabsValidation, providerName: "ElevenLabs")

                            Text("Audio segments are sent to ElevenLabs for transcription. Review their privacy policy at elevenlabs.io/privacy.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Toggle("Remove filler words", isOn: $settings.removeFillerWords)
                                .font(.system(size: 12))
                            Text("Strips filler words, false starts, and non-speech sounds server-side before returning the transcript.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        case .cohereTranscribeArabic:
                            HStack(spacing: 8) {
                                SecureField("Cohere API Key", text: $settings.cohereApiKey)
                                    .font(.system(size: 12, design: .monospaced))
                                    .accessibilityIdentifier("settings.cohereApiKeyField")

                                apiKeyValidationIndicator(
                                    isValidating: isValidatingCohereKey,
                                    result: cohereValidation
                                )
                            }
                            .onAppear {
                                scheduleCohereValidation(for: settings.cohereApiKey)
                            }
                            .onChange(of: settings.cohereApiKey) { _, newValue in
                                scheduleCohereValidation(for: newValue)
                            }

                            apiKeyValidationMessage(result: cohereValidation, providerName: "Cohere")

                            Text("Audio segments are sent to Cohere for transcription. Cohere Transcribe Arabic does not return provider timestamps or speaker diarization; LiveInterviewCopilot still uses local stream separation and diarization where available.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        default:
                            EmptyView()
                        }
                    }

                    TextField(
                        "\(settings.transcriptionModel.localeFieldTitle) (e.g. en-US)",
                        text: $settings.transcriptionLocale
                    )
                    .font(.system(size: 12, design: .monospaced))

                    Text(settings.transcriptionModel.localeHelpText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Show live transcript", isOn: $settings.showLiveTranscript)
                        .font(.system(size: 12))
                    Text("When disabled, the transcript panel is hidden during meetings. Transcription still runs in the background for suggestions and notes. Cloud models only show finalized transcript segments after pauses; inline partial live text is unavailable.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Toggle("Clean up transcript during recording", isOn: $settings.enableLiveTranscriptCleanup)
                        .font(.system(size: 12))
                    Text("Automatically removes filler words and fixes punctuation as you record. You can always clean up past transcripts manually from the Notes window.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Custom Keywords")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        ZStack(alignment: .topLeading) {
                            if settings.transcriptionCustomVocabulary.isEmpty {
                                Text("One term per line. Optional aliases: LiveInterviewCopilot: open oats")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.quaternary)
                                    .padding(.top, 6)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }

                            TextEditor(text: $settings.transcriptionCustomVocabulary)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(height: 90)
                                .frame(maxWidth: .infinity)
                                .scrollContentBackground(.hidden)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(.quaternary)
                        )

                        Text(
                            "Boost meeting-specific jargon, names, and product terms. Enter one term per line, or use `Preferred Term: alias one, alias two`. Parakeet: full alias support. AssemblyAI: aliases map to custom spelling. ElevenLabs: terms boost recognition. Cohere: preferred terms are sent as prompt guidance."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Transcript Quality") {
                    Toggle("Re-transcribe with higher accuracy after meeting", isOn: $settings.enableBatchRetranscription)
                        .font(.system(size: 12))
                    Text("Re-transcribes audio with a higher-quality model after each meeting for better accuracy. Runs in the background.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if settings.enableBatchRetranscription {
                        Picker("Batch Model", selection: $settings.batchTranscriptionModel) {
                            ForEach(TranscriptionModel.batchSuitableModels) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .font(.system(size: 12))
                    }
                }

                Section("Speaker Diarization") {
                    Toggle("Identify multiple remote speakers", isOn: $settings.enableDiarization)
                        .font(.system(size: 12))
                    Text("Uses LS-EEND to distinguish different speakers on system audio. Requires a one-time model download (~50 MB).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if settings.enableDiarization {
                        Picker("Variant", selection: $settings.diarizationVariant) {
                            ForEach(DiarizationVariant.allCases) { variant in
                                Text(variant.displayName).tag(variant)
                            }
                        }
                        .font(.system(size: 12))
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            inputDevices = MicCapture.availableInputDevices()
            outputDevices = SystemAudioCapture.availableOutputDevices()
            // Auto-restore devices by stable UID when the stored ID is stale.
            if settings.inputDeviceID > 0,
               !inputDevices.contains(where: { $0.id == settings.inputDeviceID }),
               let uid = settings.inputDeviceUID,
               let resolved = MicCapture.inputDeviceID(forUID: uid) {
                settings.inputDeviceID = resolved
            }
            if settings.outputDeviceID > 0,
               !outputDevices.contains(where: { $0.id == settings.outputDeviceID }),
               let uid = settings.outputDeviceUID,
               let resolved = SystemAudioCapture.outputDeviceID(forUID: uid) {
                settings.outputDeviceID = resolved
            }
        }
        .onDisappear {
            cancelElevenLabsValidation()
            cancelCohereValidation()
        }
    }

    @ViewBuilder
    private func apiKeyValidationIndicator(
        isValidating: Bool,
        result: APIKeyValidator.ValidationResult?
    ) -> some View {
        Group {
            if isValidating {
                ProgressView()
                    .controlSize(.mini)
            } else if let result {
                switch result {
                case .valid:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .invalid:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .networkError:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } else {
                Color.clear
            }
        }
        .font(.system(size: 14))
        .frame(width: 18, height: 18)
    }

    @ViewBuilder
    private func apiKeyValidationMessage(result: APIKeyValidator.ValidationResult?, providerName: String) -> some View {
        if let result {
            switch result {
            case .valid:
                Text("Connected to \(providerName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            case .invalid(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            case .networkError(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func scheduleElevenLabsValidation(for key: String) {
        elevenLabsValidationTask?.cancel()

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            elevenLabsValidation = nil
            isValidatingElevenLabsKey = false
            return
        }

        isValidatingElevenLabsKey = true
        elevenLabsValidation = nil
        elevenLabsValidationTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            let result = await APIKeyValidator.validateElevenLabsKey(trimmed)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                elevenLabsValidation = result
                isValidatingElevenLabsKey = false
            }
        }
    }

    private func cancelElevenLabsValidation() {
        elevenLabsValidationTask?.cancel()
        elevenLabsValidationTask = nil
        isValidatingElevenLabsKey = false
    }

    private func scheduleCohereValidation(for key: String) {
        cohereValidationTask?.cancel()

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cohereValidation = nil
            isValidatingCohereKey = false
            return
        }

        isValidatingCohereKey = true
        cohereValidation = nil
        cohereValidationTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            let result = await APIKeyValidator.validateCohereKey(trimmed)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                cohereValidation = result
                isValidatingCohereKey = false
            }
        }
    }

    private func cancelCohereValidation() {
        cohereValidationTask?.cancel()
        cohereValidationTask = nil
        isValidatingCohereKey = false
    }
}

// MARK: - Intelligence Settings Tab

private struct IntelligenceSettingsTab: View {
    @Bindable var settings: AppSettings

    private var knowledgeBaseConfigured: Bool {
        !settings.kbFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            Form {
                Section("Notes generation") {
                    Text("Choose the model LiveInterviewCopilot uses to generate meeting notes and other writing tasks. This is separate from knowledge-base retrieval.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("Provider", selection: $settings.llmProvider) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .font(.system(size: 12))
                    .accessibilityIdentifier("settings.llmProviderPicker")

                    switch settings.llmProvider {
                    case .openRouter:
                        SecureField("API Key", text: $settings.openRouterApiKey)
                            .font(.system(size: 12, design: .monospaced))

                        TextField("Model", text: $settings.selectedModel, prompt: Text("e.g. google/gemini-3-flash-preview"))
                            .font(.system(size: 12, design: .monospaced))
                    case .requesty:
                        TextField("Requesty URL", text: $settings.requestyBaseURL, prompt: Text("https://router.requesty.ai/v1"))
                            .font(.system(size: 12, design: .monospaced))

                        SecureField("Requesty API Key", text: $settings.requestyApiKey)
                            .font(.system(size: 12, design: .monospaced))

                        TextField("Model", text: $settings.requestyModel, prompt: Text("e.g. openai/gpt-4o-mini"))
                            .font(.system(size: 12, design: .monospaced))

                        Link("Get API key", destination: URL(string: "https://app.requesty.ai/api-keys")!)
                            .font(.system(size: 11))
                    case .openAI:
                        TextField("OpenAI URL", text: $settings.openAIBaseURL, prompt: Text("https://api.openai.com"))
                            .font(.system(size: 12, design: .monospaced))

                        SecureField("OpenAI API Key", text: $settings.openAIApiKey)
                            .font(.system(size: 12, design: .monospaced))

                        TextField("Model", text: $settings.openAIModel, prompt: Text("e.g. gpt-4.1-mini"))
                            .font(.system(size: 12, design: .monospaced))
                    case .anthropic:
                        TextField("Anthropic URL", text: $settings.anthropicBaseURL, prompt: Text("https://api.anthropic.com"))
                            .font(.system(size: 12, design: .monospaced))

                        SecureField("Anthropic API Key", text: $settings.anthropicApiKey)
                            .font(.system(size: 12, design: .monospaced))

                        TextField("Model", text: $settings.anthropicModel, prompt: Text("e.g. claude-sonnet-4-5-20250929"))
                            .font(.system(size: 12, design: .monospaced))
                    case .ollama:
                        TextField("Ollama URL", text: $settings.ollamaBaseURL, prompt: Text("http://localhost:11434"))
                            .font(.system(size: 12, design: .monospaced))

                        OllamaModelField(modelName: $settings.ollamaLLMModel, baseURL: settings.ollamaBaseURL, placeholder: "e.g. qwen3:8b")
                    case .lmStudio:
                        TextField("LM Studio URL", text: $settings.lmStudioBaseURL, prompt: Text("http://localhost:1234"))
                            .font(.system(size: 12, design: .monospaced))

                        SecureField("API Key (optional)", text: $settings.lmStudioApiKey)
                            .font(.system(size: 12, design: .monospaced))

                        TextField("Model", text: $settings.lmStudioModel, prompt: Text("e.g. qwen3-8b"))
                            .font(.system(size: 12, design: .monospaced))
                    case .mlx:
                        TextField("MLX Server URL", text: $settings.mlxBaseURL, prompt: Text("http://localhost:8080"))
                            .font(.system(size: 12, design: .monospaced))

                        TextField("Model", text: $settings.mlxModel, prompt: Text("e.g. mlx-community/Llama-3.2-3B-Instruct-4bit"))
                            .font(.system(size: 12, design: .monospaced))
                    case .openAICompatible:
                        TextField("Endpoint URL", text: $settings.openAILLMBaseURL, prompt: Text("http://localhost:4000"))
                            .font(.system(size: 12, design: .monospaced))

                        SecureField("API Key (optional)", text: $settings.openAILLMApiKey)
                            .font(.system(size: 12, design: .monospaced))

                        TextField("Model", text: $settings.openAILLMModel, prompt: Text("e.g. gpt-4o-mini"))
                            .font(.system(size: 12, design: .monospaced))
                    }
                }

                Section("Knowledge Base") {
                    Text("Optional. Point this to a folder of reference material such as docs, notes, PRDs, or customer context. LiveInterviewCopilot reads this folder to find relevant background during meetings. It is separate from where your meeting notes are organized.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    HStack {
                        Text(settings.kbFolderPath.isEmpty ? "Not set" : settings.kbFolderPath)
                            .font(.system(size: 12))
                            .foregroundStyle(settings.kbFolderPath.isEmpty ? .tertiary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        if !settings.kbFolderPath.isEmpty {
                            Button("Clear") {
                                settings.kbFolderPath = ""
                            }
                            .font(.system(size: 12))
                        }

                        Button("Choose...") {
                            chooseKBFolder()
                        }
                    }
                }

                Section("Knowledge base retrieval") {
                    if knowledgeBaseConfigured {
                        Text("Choose how LiveInterviewCopilot indexes and searches your Knowledge Base folder. This affects knowledge retrieval during meetings, not note generation. Indexed chunks and vectors are still cached locally on this Mac.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        Picker("Provider", selection: $settings.embeddingProvider) {
                            ForEach(EmbeddingProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .font(.system(size: 12))

                        switch settings.embeddingProvider {
                        case .voyageAI:
                            SecureField("Voyage AI Key", text: $settings.voyageApiKey)
                                .font(.system(size: 12, design: .monospaced))
                        case .ollama:
                            OllamaModelField(modelName: $settings.ollamaEmbedModel, baseURL: settings.ollamaBaseURL, placeholder: "e.g. nomic-embed-text")

                            if settings.llmProvider != .ollama && settings.llmProvider != .mlx {
                                TextField("Ollama URL", text: $settings.ollamaBaseURL, prompt: Text("http://localhost:11434"))
                                    .font(.system(size: 12, design: .monospaced))
                            }
                        case .openAICompatible:
                            TextField("Endpoint URL", text: $settings.openAIEmbedBaseURL, prompt: Text("http://localhost:8080"))
                                .font(.system(size: 12, design: .monospaced))

                            SecureField("API Key (optional)", text: $settings.openAIEmbedApiKey)
                                .font(.system(size: 12, design: .monospaced))

                            TextField("Model", text: $settings.openAIEmbedModel, prompt: Text("e.g. text-embedding-3-small"))
                                .font(.system(size: 12, design: .monospaced))
                        }
                    } else {
                        Text("Choose a Knowledge Base folder above to turn on retrieval settings. These controls are only used for Knowledge Base features such as relevant context and suggestions.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Interview Workspace") {
                    Toggle("Keep the main window always on top", isOn: $settings.suggestionsAlwaysOnTop)
                        .font(.system(size: 12))
                    Text("Use the pin button in the main window header to change this at any time. Interview Copilot, transcript, and notes share the same window.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Section("Classic Suggestions") {
                    switch settings.llmProvider {
                    case .openRouter:
                        TextField("Speed Model", text: $settings.realtimeModel, prompt: Text("e.g. google/gemini-2.0-flash-001"))
                            .font(.system(size: 12, design: .monospaced))
                        Text("A fast model used for real-time suggestion synthesis. Separate from your main model.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    case .requesty:
                        TextField("Speed Model", text: $settings.requestyModel, prompt: Text("e.g. openai/gpt-4o-mini"))
                            .font(.system(size: 12, design: .monospaced))
                        Text("A fast model used for real-time suggestion synthesis. Separate from your main model.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    case .ollama:
                        OllamaModelField(modelName: $settings.realtimeOllamaModel, baseURL: settings.ollamaBaseURL, placeholder: "Leave empty to use main model")
                        Text("Optional Ollama model for real-time suggestions. Uses your main model if empty.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    case .openAI, .anthropic, .lmStudio, .mlx, .openAICompatible:
                        Text("Real-time suggestions currently reuse the active provider model for this provider.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Suggestions") {
                    Picker("Verbosity", selection: $settings.suggestionVerbosity) {
                        ForEach(SuggestionVerbosity.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .font(.system(size: 12))

                    Text(settings.suggestionVerbosity.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func chooseKBFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder containing your knowledge base documents (.md, .txt)"

        if panel.runModal() == .OK, let url = panel.url {
            settings.kbFolderPath = url.path
        }
    }
}

// MARK: - Templates Settings Tab

private struct TemplatesSettingsTab: View {
    private enum TemplateField: Hashable {
        case name
    }

    @Bindable var settings: AppSettings
    @Environment(AppCoordinator.self) private var coordinator
    @State private var templates: [MeetingTemplate] = []
    @State private var isAddingTemplate = false
    @State private var editingTemplateID: UUID?
    @State private var newTemplateName = ""
    @State private var newTemplateIcon = "doc.text"
    @State private var newTemplatePrompt = ""
    @FocusState private var focusedTemplateField: TemplateField?

    var body: some View {
        ScrollView {
            Form {
                Section("Meeting Templates") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Default template")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Picker("Default template", selection: defaultTemplateSelection) {
                            Text("Generic").tag(Optional<UUID>.none)
                            ForEach(templatesForPicker) { template in
                                Text(template.name).tag(Optional(template.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260, alignment: .leading)

                        Text("Used when a session has no explicit template and the meeting family does not have its own default.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)

                    ForEach(templates) { template in
                        HStack {
                            Image(systemName: template.icon)
                                .frame(width: 20)
                                .foregroundStyle(.secondary)
                            Text(template.name)
                                .font(.system(size: 12))
                            Spacer()
                            if template.isBuiltIn {
                                Image(systemName: "lock")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                Button("Reset") {
                                    resetTemplate(id: template.id)
                                }
                                .font(.system(size: 11))
                                .buttonStyle(.plain)
                                .foregroundStyle(.blue)
                                .disabled(!isBuiltInTemplateModified(template))
                            } else {
                                Button {
                                    beginEditing(template)
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)
                                Button {
                                    deleteTemplate(id: template.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Text("Built-in templates are shipped defaults. Reset only applies if a built-in template was changed outside this view.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !isAddingTemplate && editingTemplateID == nil {
                        Button("New Template") {
                            isAddingTemplate = true
                            Task { @MainActor in
                                focusedTemplateField = .name
                            }
                        }
                        .font(.system(size: 12))
                    }
                }
            }
            .formStyle(.grouped)

            if isAddingTemplate || editingTemplateID != nil {
                VStack(alignment: .leading, spacing: 10) {
                    // Name
                    HStack(alignment: .center, spacing: 6) {
                        Text("Name")
                            .font(.system(size: 13, weight: .semibold))
                        Text("e.g. Sprint Planning")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 20)
                        TextField("", text: $newTemplateName)
                            .font(.system(size: 12))
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedTemplateField, equals: .name)
                    }

                    // Icon picker
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Icon")
                            .font(.system(size: 13, weight: .semibold))
                        IconPickerGrid(selected: $newTemplateIcon)
                    }

                    // System prompt
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Notes Prompt")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Instructions for how the AI should format notes for this meeting type.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        ZStack(alignment: .topLeading) {
                            if newTemplatePrompt.isEmpty {
                                Text("e.g. You are a meeting notes assistant. Given a transcript, produce structured notes with sections for...")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.quaternary)
                                    .padding(.top, 6)
                                    .padding(.leading, 6)
                                    .allowsHitTesting(false)
                            }
                            FixedLeftTextEditor(text: $newTemplatePrompt)
                        }
                        .frame(height: 100)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(.quaternary)
                        )
                    }

                    HStack {
                        Button("Cancel") {
                            resetNewTemplateForm()
                        }
                        .buttonStyle(.plain)
                        Button("Save") {
                            if let editID = editingTemplateID {
                                let template = MeetingTemplate(
                                    id: editID,
                                    name: trimmedTemplateName,
                                    icon: newTemplateIcon,
                                    systemPrompt: trimmedTemplatePrompt,
                                    isBuiltIn: false
                                )
                                updateTemplate(template)
                            } else {
                                let template = MeetingTemplate(
                                    id: UUID(),
                                    name: trimmedTemplateName,
                                    icon: newTemplateIcon,
                                    systemPrompt: trimmedTemplatePrompt,
                                    isBuiltIn: false
                                )
                                addTemplate(template)
                            }
                            resetNewTemplateForm()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSaveNewTemplate)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .onAppear {
            Task { @MainActor in
                refreshTemplates()
            }
        }
    }

    private var trimmedTemplateName: String {
        newTemplateName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedTemplatePrompt: String {
        newTemplatePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSaveNewTemplate: Bool {
        !trimmedTemplateName.isEmpty && !trimmedTemplatePrompt.isEmpty
    }

    private var defaultTemplateSelection: Binding<UUID?> {
        Binding(
            get: {
                guard let templateID = settings.defaultNotesTemplateID,
                      coordinator.templateStore.template(for: templateID) != nil else {
                    return nil
                }
                return templateID
            },
            set: { settings.defaultNotesTemplateID = $0 }
        )
    }

    private var templatesForPicker: [MeetingTemplate] {
        templates.filter { $0.id != TemplateStore.genericID }
    }

    private func addTemplate(_ template: MeetingTemplate) {
        Task { @MainActor in
            coordinator.templateStore.add(template)
            refreshTemplates()
        }
    }

    private func resetTemplate(id: UUID) {
        Task { @MainActor in
            coordinator.templateStore.resetBuiltIn(id: id)
            refreshTemplates()
        }
    }

    private func deleteTemplate(id: UUID) {
        Task { @MainActor in
            coordinator.templateStore.delete(id: id)
            if settings.defaultNotesTemplateID == id {
                settings.defaultNotesTemplateID = nil
            }
            refreshTemplates()
        }
    }

    private func beginEditing(_ template: MeetingTemplate) {
        editingTemplateID = template.id
        newTemplateName = template.name
        newTemplateIcon = template.icon
        newTemplatePrompt = template.systemPrompt
        isAddingTemplate = false
        Task { @MainActor in
            focusedTemplateField = .name
        }
    }

    private func updateTemplate(_ template: MeetingTemplate) {
        Task { @MainActor in
            coordinator.templateStore.update(template)
            refreshTemplates()
        }
    }

    private func isBuiltInTemplateModified(_ template: MeetingTemplate) -> Bool {
        guard let builtIn = TemplateStore.builtInTemplates.first(where: { $0.id == template.id }) else {
            return false
        }
        return template != builtIn
    }

    private func refreshTemplates() {
        templates = coordinator.templateStore.templates
        if let templateID = settings.defaultNotesTemplateID,
           coordinator.templateStore.template(for: templateID) == nil {
            settings.defaultNotesTemplateID = nil
        }
    }

    private func resetNewTemplateForm() {
        isAddingTemplate = false
        editingTemplateID = nil
        newTemplateName = ""
        newTemplateIcon = "doc.text"
        newTemplatePrompt = ""
        focusedTemplateField = nil
    }
}

// MARK: - Integrations Settings Tab

private struct IntegrationsSettingsTab: View {
    @Bindable var settings: AppSettings
    @State private var appleNotesAuthFailed = false

    var body: some View {
        ScrollView {
            Form {
                Section("Apple Notes") {
                    Toggle("Enable Apple Notes export", isOn: $settings.appleNotesEnabled)
                        .font(.system(size: 12))
                        .onChange(of: settings.appleNotesEnabled) { _, enabled in
                            if enabled {
                                Task {
                                    let authorized = await AppleNotesService.requestAuthorization()
                                    if !authorized {
                                        settings.appleNotesEnabled = false
                                        appleNotesAuthFailed = true
                                    }
                                }
                            }
                        }

                    Text("Creates or updates a note in Apple Notes for each meeting. Use the \"Sync to Apple Notes\" button in the Notes view to push updated notes manually.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if appleNotesAuthFailed {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.system(size: 12))
                            Text("Permission denied. Enable LiveInterviewCopilot under System Settings → Privacy & Security → Automation.")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                    }

                    if settings.appleNotesEnabled {
                        Toggle("Include transcript", isOn: $settings.appleNotesIncludeTranscript)
                            .font(.system(size: 12))

                        Toggle("Auto-export transcript when meeting ends", isOn: $settings.appleNotesAutoExport)
                            .font(.system(size: 12))
                            .disabled(!settings.appleNotesIncludeTranscript)
                        Text(settings.appleNotesIncludeTranscript
                             ? "Exports the transcript to Apple Notes immediately when the meeting ends. Notes are generated later — use the Export button in the Notes view to sync them."
                             : "Enable \"Include transcript\" to auto-export when a meeting ends.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        TextField("Account", text: $settings.appleNotesAccountName, prompt: Text("iCloud"))
                            .font(.system(size: 12))
                        Text("Enter the exact account name as it appears in the Notes sidebar (e.g. \"iCloud\" or your email address).")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        TextField("Folder name", text: $settings.appleNotesFolderName, prompt: Text("Live Interview Copilot"))
                            .font(.system(size: 12))
                    }
                }

                Section("Webhook") {
                    Toggle("Send webhook when meeting ends", isOn: $settings.webhookEnabled)
                        .font(.system(size: 12))
                    Text("POST a JSON payload to a URL after each meeting with session metadata and transcript.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if settings.webhookEnabled {
                        TextField("URL", text: $settings.webhookURL, prompt: Text("https://example.com/webhook"))
                            .font(.system(size: 12, design: .monospaced))

                        SecureField("Signing Secret (optional)", text: $settings.webhookSecret)
                            .font(.system(size: 12, design: .monospaced))
                        Text("If set, each request includes an X-LiveInterviewCopilot-Signature header (HMAC-SHA256) for payload verification.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Import") {
                    Text("Import meetings from Granola. Generate an API key in the Granola desktop app under Settings.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    SecureField("Granola API Key", text: $settings.granolaApiKey)
                        .font(.system(size: 12, design: .monospaced))

                    GranolaImportButton(apiKey: settings.granolaApiKey)
                }
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - Icon Picker

private struct IconPickerGrid: View {
    @Binding var selected: String

    private static let icons = [
        "doc.text", "person.2", "person.3", "person.badge.plus",
        "calendar", "clock", "arrow.up.circle", "magnifyingglass",
        "lightbulb", "star", "flag", "bolt",
        "bubble.left.and.bubble.right", "phone", "video",
        "briefcase", "chart.bar", "list.bullet",
        "checkmark.circle", "gear", "globe", "book",
        "pencil", "megaphone",
    ]

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Self.icons, id: \.self) { icon in
                Button {
                    selected = icon
                } label: {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selected == icon ? Color.accentColor.opacity(0.2) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(selected == icon ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected == icon ? .primary : .secondary)
            }
        }
    }
}

// MARK: - Granola Import Button

private struct GranolaImportButton: View {
    @Environment(AppCoordinator.self) private var coordinator
    let apiKey: String
    @State private var importState: GranolaImportState = .idle
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch importState {
            case .idle:
                EmptyView()
            case .fetching(let progress):
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .importing(let current, let total):
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Importing \(current) of \(total)...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .completed(let imported, let skipped):
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                    Text("Imported \(imported) meeting\(imported == 1 ? "" : "s")\(skipped > 0 ? ", \(skipped) already existed" : "")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .failed(let error):
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 12))
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }

            Button("Import from Granola") {
                startImport()
            }
            .font(.system(size: 12))
            .disabled(isImporting)
        }
    }

    private func startImport() {
        guard !apiKey.isEmpty else {
            importState = .failed("Enter your Granola API key above.")
            return
        }

        isImporting = true
        importState = .fetching(progress: "Connecting to Granola...")

        let repo = coordinator.sessionRepository
        let importer = GranolaImporter()

        Task { @MainActor in
            do {
                let result = try await importer.importAll(
                    apiKey: apiKey,
                    sessionRepository: repo,
                    onProgress: { state in
                        Task { @MainActor in
                            self.importState = state
                        }
                    }
                )
                importState = .completed(imported: result.imported, skipped: result.skipped)
                isImporting = false
                await coordinator.loadHistory()
            } catch {
                importState = .failed(error.localizedDescription)
                isImporting = false
            }
        }
    }
}

// A fixed-height, left-aligned NSTextView wrapper that doesn't expand with content.
private struct FixedLeftTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.alignment = .left
        tv.textContainerInset = NSSize(width: 4, height: 5)
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.delegate = context.coordinator

        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.borderType = .noBorder
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: 100)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        init(text: Binding<String>) { _text = text }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text = tv.string
        }
    }
}
