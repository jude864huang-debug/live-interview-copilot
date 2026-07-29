import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private enum ControlBarAction {
        case toggle
        case confirmDownload
    }

    @Bindable var settings: AppSettings
    @Environment(AppContainer.self) private var container
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var miniBarManager = MiniBarManager()
    @State private var interviewLensManager = InterviewLensManager()
    @State private var copilotHotkeyManager = CopilotHotkeyManager()
    @State private var liveSessionController: LiveSessionController?
    @State private var customerCopilotEngine: CustomerCopilotEngine?
    @State private var workspaceInitializationAttempted = false
    @AppStorage("interviewContextSelectedTab") private var interviewContextSelectedTab = "transcript"
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @State private var showConsentSheet = false
    @State private var pendingControlBarAction: ControlBarAction?

    var body: some View {
        bodyWithModifiers
    }

    private var rootContent: some View {
        let controllerState = liveSessionController?.state ?? LiveSessionState()

        return VStack(spacing: 0) {
            if !controllerState.isRunning {
                HStack {
                Text("Live Interview Copilot")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Button {
                    settings.suggestionsAlwaysOnTop.toggle()
                } label: {
                    Image(systemName: settings.suggestionsAlwaysOnTop ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(settings.suggestionsAlwaysOnTop ? Color.accentColor : Color.secondary)
                .help(settings.suggestionsAlwaysOnTop ? "取消主窗口置顶" : "将主窗口固定在最前")
                .accessibilityLabel(settings.suggestionsAlwaysOnTop ? "取消主窗口置顶" : "将主窗口固定在最前")
                .accessibilityValue(settings.suggestionsAlwaysOnTop ? "已开启" : "已关闭")
                .accessibilityIdentifier("app.alwaysOnTopButton")

                Button {
                    openWindow(id: "notes")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "note.text")
                            .font(.system(size: 11))
                        Text("Notes Workspace")
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open the advanced notes workspace")
                .accessibilityIdentifier("app.notesWorkspaceButton")

                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .padding(4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings")
                .accessibilityIdentifier("app.settingsButton")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()
            }

            // Post-session banner
            if let lastSession = controllerState.lastEndedSession {
                PostSessionBanner(
                    session: lastSession,
                    lastSessionHasNotes: controllerState.lastSessionHasNotes,
                    canRetranscribe: controllerState.lastEndedSessionCanRetranscribe,
                    recoveryIsPending: coordinator.pendingRecoverySessionID == lastSession.id,
                    onOpenTranscript: {
                        coordinator.queueHomeTranscriptSessionSelection(lastSession.id)
                    },
                    onOpenNotes: {
                        coordinator.queueHomeSessionSelection(lastSession.id)
                    },
                    onGenerateNotes: {
                        coordinator.queueHomeSessionSelection(lastSession.id)
                    },
                    onRetranscribe: {
                        coordinator.queueHomeSessionRetranscription(lastSession.id)
                    }
                )
            }

            if controllerState.isRunning, let event = controllerState.matchedCalendarEvent {
                MatchedCalendarEventBanner(event: event)

                Divider()
            }

            if controllerState.isRunning {
                liveInterviewWorkspace(state: controllerState)
            } else {
                HomeTimelineWorkspaceView(settings: settings)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if !controllerState.isRunning {
                Divider()

                IsolatedControlBarWrapper(
                    state: controllerState,
                    onToggle: {
                        pendingControlBarAction = .toggle
                    },
                    onMuteToggle: {
                        liveSessionController?.toggleMicMute()
                    },
                    onPauseToggle: {
                        liveSessionController?.toggleRecordingPause()
                    },
                    onConfirmDownload: {
                        pendingControlBarAction = .confirmDownload
                    },
                    onOpenSettings: {
                        openSettingsWindow()
                    },
                    onOpenMicrophonePrivacySettings: {
                        openMicrophonePrivacySettings()
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func liveInterviewWorkspace(state: LiveSessionState) -> some View {
        if let engine = customerCopilotEngine,
           let liveSessionController {
            VStack(spacing: 0) {
                InterviewWorkspaceHeader(
                    engine: engine,
                    liveSessionController: liveSessionController,
                    interviewLensManager: interviewLensManager,
                    settings: settings
                )
                Divider()

                InterviewWorkspaceQuestionBar(
                    engine: engine,
                    interviewLensManager: interviewLensManager
                )
                Divider()

                GeometryReader { proxy in
                    HSplitView {
                        CustomerCopilotPanelContent(
                            engine: engine,
                            liveSessionController: liveSessionController,
                            interviewLensManager: interviewLensManager
                        )
                        .frame(
                            minWidth: 440,
                            idealWidth: 540,
                            maxWidth: .infinity,
                            minHeight: 0,
                            maxHeight: .infinity
                        )

                        liveContextPane(state: state, engine: engine)
                            .frame(
                                minWidth: 300,
                                idealWidth: 340,
                                maxWidth: 440,
                                minHeight: 0,
                                maxHeight: .infinity
                            )
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                }
                .frame(minHeight: 0, maxHeight: .infinity)

                Divider()
                InterviewWorkspaceActionBar(
                    engine: engine,
                    liveSessionController: liveSessionController,
                    onOpenSettings: openSettingsWindow,
                    onEndInterview: stopSession
                )
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .accessibilityIdentifier("app.interviewWorkspace")
        } else {
            VStack(spacing: 10) {
                if workspaceInitializationAttempted {
                    Label("面试工作区初始化失败", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("重试初始化", systemImage: "arrow.clockwise") {
                        prepareInterviewWorkspace()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    ProgressView("正在准备面试工作区…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                prepareInterviewWorkspace()
            }
        }
    }

    private func liveContextPane(
        state: LiveSessionState,
        engine: CustomerCopilotEngine
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                contextTabButton(
                    title: "实时转写",
                    systemImage: "text.quote",
                    selection: "transcript",
                    identifier: "app.interviewContext.transcriptTab"
                )
                contextTabButton(
                    title: "随手笔记",
                    systemImage: "square.and.pencil",
                    selection: "scratchpad",
                    identifier: "app.interviewContext.scratchpadTab"
                )
            }
            .padding(4)
            .background(Color.primary.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ZStack {
                transcriptContextTab(state: state, engine: engine)
                    .opacity(interviewContextSelectedTab == "transcript" ? 1 : 0)
                    .allowsHitTesting(interviewContextSelectedTab == "transcript")
                    .accessibilityHidden(interviewContextSelectedTab != "transcript")

                ScratchpadSection(
                    text: Binding(
                        get: { state.scratchpadText },
                        set: { liveSessionController?.updateScratchpad($0) }
                    ),
                    onPasteAssetProviders: handleScratchpadAssetPaste
                )
                .opacity(interviewContextSelectedTab == "scratchpad" ? 1 : 0)
                .allowsHitTesting(interviewContextSelectedTab == "scratchpad")
                .accessibilityHidden(interviewContextSelectedTab != "scratchpad")
            }
            .frame(minHeight: 0, maxHeight: .infinity)
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .clipped()
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.36))
        .onAppear {
            if interviewContextSelectedTab != "transcript"
                && interviewContextSelectedTab != "scratchpad" {
                interviewContextSelectedTab = "transcript"
            }
        }
    }

    private func contextTabButton(
        title: String,
        systemImage: String,
        selection: String,
        identifier: String
    ) -> some View {
        let isSelected = interviewContextSelectedTab == selection
        return Button {
            interviewContextSelectedTab = selection
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
    }

    private func transcriptContextTab(
        state: LiveSessionState,
        engine: CustomerCopilotEngine
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text("实时转写")
                    .font(.caption.weight(.semibold))
                if !state.liveTranscript.isEmpty {
                    Text("\(state.liveTranscript.count)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if state.recordingElapsedSeconds > 0 {
                    Text(ElapsedTimeFormatter.compactMinutesSeconds(state.recordingElapsedSeconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !state.liveTranscript.isEmpty {
                Button {
                    openWindow(id: "transcript")
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                    .help("在独立窗口打开转写")
                    .accessibilityLabel("在独立窗口打开转写")

                Button {
                    copyTranscript()
                } label: {
                    Image(systemName: "doc.on.doc")
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                    .help("复制转写")
                    .accessibilityLabel("复制转写")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 7) {
                Toggle(
                    "候选人转写用于后续提示",
                    isOn: Binding(
                        get: { engine.includeCandidateAnswersInContext },
                        set: { engine.includeCandidateAnswersInContext = $0 }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(engine.interviewAudioMode != .manualStreamingASR)

                Label(
                    engine.includeCandidateAnswersInContext
                        ? "会用于后续问题 · 历史每轮最多 500 字"
                        : "仅保存在本机，不发送给后续文字模型",
                    systemImage: engine.includeCandidateAnswersInContext ? "arrow.up.circle" : "lock.fill"
                )
                .font(.caption2)
                .foregroundStyle(engine.includeCandidateAnswersInContext ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 9)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let notice = state.liveTranscriptNotice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            if state.showLiveTranscript {
                IsolatedTranscriptWrapper(state: state)
                    .frame(minHeight: 0, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "实时转写已关闭",
                    systemImage: "text.quote",
                    description: Text("可在设置中重新启用；音频采集和面试回答不受影响。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
    }

    private var bodyWithModifiers: some View {
        contentWithEventHandlers
    }

    private var sizedRootContent: some View {
        let isRunning = liveSessionController?.state.isRunning == true

        return rootContent
            .frame(
                minWidth: isRunning ? 820 : 460,
                maxWidth: .infinity,
                minHeight: 400,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.ultraThinMaterial)
    }

    private var contentWithOverlay: some View {
        sizedRootContent.overlay {
            if showOnboarding {
                SetupWizardView(
                    isPresented: $showOnboarding,
                    settings: settings
                )
                    .transition(.opacity)
            }
            if showConsentSheet {
                RecordingConsentView(
                    isPresented: $showConsentSheet,
                    settings: settings
                )
                .transition(.opacity)
            }
        }
    }

    private var contentWithLifecycle: some View {
        contentWithOverlay
        .onChange(of: showOnboarding) { _, isShowing in
            if !isShowing {
                hasCompletedOnboarding = true
            }
        }
        .onChange(of: showConsentSheet) { _, isShowing in
            if !isShowing && settings.hasAcknowledgedRecordingConsent
                && !(liveSessionController?.state.isRunning ?? false) {
                liveSessionController?.startSession(settings: settings)
            }
        }
        .task {
            if !hasCompletedOnboarding {
                // Customer Copilot does not require an API/embedding provider wizard.
                hasCompletedOnboarding = true
            }

            // Make session actions available before initializing the heavier
            // Copilot workspace and history stores. A launch-time shortcut can
            // otherwise sit queued for several seconds while those services load.
            let controller = LiveSessionController(coordinator: coordinator, container: container)
            controller.onRunningStateChanged = { [weak miniBarManager, weak interviewLensManager] isRunning in
                if isRunning {
                    prepareInterviewWorkspace()
                    miniBarManager?.state.onTap = {
                        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == LiveInterviewCopilotRootApp.mainWindowID }) {
                            window.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                    showMiniBar(controller: controller, miniBarManager: miniBarManager)
                    interviewLensManager?.restoreIfNeeded(
                        engine: coordinator.customerCopilotEngine,
                        sourceWindow: NSApp.windows.first(where: {
                            $0.identifier?.rawValue == LiveInterviewCopilotRootApp.mainWindowID
                        })
                    )
                } else {
                    miniBarManager?.hide()
                    interviewLensManager?.suspendForSessionEnd()
                }
                configureMainWindowForInterview(isRunning)
            }
            controller.openNotesWindow = {
                openWindow(id: "notes")
            }
            controller.onMiniBarContentUpdate = { [weak controller, weak miniBarManager] in
                showMiniBar(controller: controller, miniBarManager: miniBarManager)
            }
            coordinator.liveSessionController = controller
            liveSessionController = controller
            configureMainWindowForInterview(controller.state.isRunning)

            prepareInterviewWorkspace()
            interviewLensManager.configure(settings: settings, defaults: container.defaults)

            copilotHotkeyManager.configure(primaryShortcut: settings.copilotTurnHotkey)
            copilotHotkeyManager.onCommitTurn = { coordinator.customerCopilotEngine?.commitActiveInterviewTurn() }
            copilotHotkeyManager.onMerge = { coordinator.customerCopilotEngine?.mergePreviousCustomerUtterance() }
            copilotHotkeyManager.onStop = { coordinator.customerCopilotEngine?.stopGeneration() }
            copilotHotkeyManager.isLensToggleEnabled = { [weak controller] in
                controller?.state.isRunning == true
            }
            copilotHotkeyManager.onToggleLens = { [weak controller, weak interviewLensManager, weak coordinator] in
                guard controller?.state.isRunning == true,
                      let interviewLensManager,
                      let engine = coordinator?.customerCopilotEngine else { return }
                interviewLensManager.toggleVisibility(
                    engine: engine,
                    sourceWindow: NSApp.windows.first(where: {
                        $0.identifier?.rawValue == LiveInterviewCopilotRootApp.mainWindowID
                    })
                )
            }
            copilotHotkeyManager.isLensNavigationEnabled = { [weak interviewLensManager] in
                interviewLensManager?.isVisible == true
            }
            copilotHotkeyManager.onLensPrevious = { [weak interviewLensManager] in
                interviewLensManager?.previousPage()
            }
            copilotHotkeyManager.onLensNext = { [weak interviewLensManager] in
                interviewLensManager?.nextPage()
            }
            copilotHotkeyManager.start()

            miniBarManager.defaults = container.defaults

            // Setup calendar integration before the first await so the home timeline
            // never transiently shows "Waiting for calendar access" on users who already
            // granted permission. updateCalendarIntegration is synchronous and safe to
            // call here.
            container.updateCalendarIntegration(enabled: settings.calendarIntegrationEnabled)

            await container.seedIfNeeded(coordinator: coordinator)
            await coordinator.loadHistory()
            controller.handlePendingExternalCommandIfPossible(settings: settings) {
                openWindow(id: "notes")
            }

            await controller.performInitialSetup()

            // Setup meeting detection if enabled
            if settings.meetingAutoDetectEnabled {
                container.enableDetection(settings: settings, coordinator: coordinator)
                await container.detectionController?.evaluateImmediate()
            }

            // Start the 100ms polling loop (runs until task cancelled)
            await controller.runPollingLoop(settings: settings)
        }
        .onChange(of: settings.meetingAutoDetectEnabled) {
            if settings.meetingAutoDetectEnabled {
                container.enableDetection(settings: settings, coordinator: coordinator)
                Task {
                    await container.detectionController?.evaluateImmediate()
                }
            } else {
                container.disableDetection(coordinator: coordinator)
            }
        }
        .onChange(of: settings.calendarIntegrationEnabled) {
            container.updateCalendarIntegration(enabled: settings.calendarIntegrationEnabled)
        }
        .onChange(of: settings.suggestionsAlwaysOnTop) {
            configureMainWindowForInterview(liveSessionController?.state.isRunning == true)
        }
        .onChange(of: settings.copilotTurnHotkey) { _, shortcut in
            copilotHotkeyManager.configure(primaryShortcut: shortcut)
        }
        .onChange(of: settings.hideFromScreenShare) { _, hidden in
            interviewLensManager.updateSharingType(hidden: hidden)
        }
        .onDisappear {
            copilotHotkeyManager.stop()
            interviewLensManager.tearDown()
        }
    }

    private var contentWithEventHandlers: some View {
        contentWithLifecycle
        .onReceive(NotificationCenter.default.publisher(for: .toggleSuggestionPanel)) { _ in
            revealInterviewWorkspace()
        }
        .onChange(of: pendingControlBarAction) {
            guard let action = pendingControlBarAction else { return }
            pendingControlBarAction = nil
            handleControlBarAction(action)
        }
    }

    // MARK: - Actions

    private func startSession() {
        guard settings.hasAcknowledgedRecordingConsent else {
            withAnimation(.easeInOut(duration: 0.25)) {
                showConsentSheet = true
            }
            return
        }
        guard let liveSessionController else {
            coordinator.queueExternalCommand(.startSession())
            return
        }
        liveSessionController.startSession(settings: settings)
    }

    private func stopSession() {
        guard let liveSessionController else {
            coordinator.queueExternalCommand(.stopSession)
            return
        }
        liveSessionController.stopSession(settings: settings)
    }

    private func openSettingsWindow() {
        NSApp.activate()
        openSettings()
    }

    private func openMicrophonePrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func showMiniBar(controller: LiveSessionController?, miniBarManager: MiniBarManager?) {
        guard let controller, let miniBarManager else { return }
        miniBarManager.update(
            audioLevel: controller.state.audioLevel,
            suggestions: controller.state.suggestions,
            isGenerating: controller.state.isGeneratingSuggestions
        )
        miniBarManager.show()
    }

    private func prepareInterviewWorkspace() {
        container.ensureViewServicesInitialized(settings: settings, coordinator: coordinator)
        customerCopilotEngine = coordinator.customerCopilotEngine
        workspaceInitializationAttempted = true
    }

    private func revealInterviewWorkspace() {
        configureMainWindowForInterview(liveSessionController?.state.isRunning == true)
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == LiveInterviewCopilotRootApp.mainWindowID
        }) else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func configureMainWindowForInterview(_ isRunning: Bool) {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == LiveInterviewCopilotRootApp.mainWindowID
        }) else { return }

        if case .live = container.mode,
           window.frameAutosaveName != LiveInterviewCopilotWindowSizing.mainWindowFrameAutosaveName {
            _ = window.setFrameUsingName(LiveInterviewCopilotWindowSizing.mainWindowFrameAutosaveName)
            _ = window.setFrameAutosaveName(LiveInterviewCopilotWindowSizing.mainWindowFrameAutosaveName)
        }

        window.level = settings.suggestionsAlwaysOnTop ? .floating : .normal
        var collectionBehavior = window.collectionBehavior
        if isRunning {
            collectionBehavior.insert(.canJoinAllSpaces)
            collectionBehavior.insert(.fullScreenAuxiliary)
        } else {
            collectionBehavior.remove(.canJoinAllSpaces)
            collectionBehavior.remove(.fullScreenAuxiliary)
        }
        window.collectionBehavior = collectionBehavior

        let minimumSize = isRunning
            ? LiveInterviewCopilotWindowSizing.interviewWorkspaceMinSize
            : LiveInterviewCopilotWindowSizing.mainWindowCollapsedMinSize
        window.contentMinSize = minimumSize

        let currentFrame = window.frame
        let newWidth = max(currentFrame.width, minimumSize.width)
        let newHeight = max(currentFrame.height, minimumSize.height)

        var frame = currentFrame
        if isRunning {
            frame.origin.x -= max(0, newWidth - currentFrame.width)
        }
        frame.size.width = newWidth
        frame.size.height = newHeight

        if let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            frame.size.width = min(max(frame.width, minimumSize.width), visibleFrame.width)
            frame.size.height = min(max(frame.height, minimumSize.height), visibleFrame.height)
            let maximumX = max(visibleFrame.minX, visibleFrame.maxX - frame.width)
            let maximumY = max(visibleFrame.minY, visibleFrame.maxY - frame.height)
            frame.origin.x = min(max(frame.minX, visibleFrame.minX), maximumX)
            frame.origin.y = min(max(frame.minY, visibleFrame.minY), maximumY)
        }

        guard frame != currentFrame else { return }
        let shouldAnimate: Bool = if case .live = container.mode { true } else { false }
        window.setFrame(frame, display: true, animate: shouldAnimate)
    }

    private func copyTranscript() {
        guard let controller = liveSessionController else { return }
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        let lines = controller.state.liveTranscript.map { u in
            "[\(timeFmt.string(from: u.timestamp))] \(u.speaker.displayLabel): \(u.displayText)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func handleScratchpadAssetPaste(_ providers: [NSItemProvider]) {
        guard liveSessionController?.state.isRunning == true else { return }

        Task {
            let assets = await loadPastedScratchpadAssets(from: providers)
            guard !assets.isEmpty else { return }
            await MainActor.run {
                liveSessionController?.insertScratchpadAssets(assets)
            }
        }
    }

    private func loadPastedScratchpadAssets(
        from providers: [NSItemProvider]
    ) async -> [LiveSessionController.ScratchpadAssetInsertion] {
        var assets: [LiveSessionController.ScratchpadAssetInsertion] = []

        for provider in providers {
            if let fileURL = await loadPastedFileURL(from: provider) {
                if LiveSessionController.isImageFile(url: fileURL) {
                    assets.append(.imageFile(fileURL))
                } else {
                    assets.append(.attachmentFile(fileURL))
                }
                continue
            }
            if let imageData = await loadPastedImageData(from: provider) {
                assets.append(.imageData(imageData))
            }
        }

        return assets
    }

    private func loadPastedFileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let resolvedURL: URL?
                switch item {
                case let url as URL:
                    resolvedURL = url
                case let data as Data:
                    resolvedURL = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL?
                case let string as String:
                    resolvedURL = URL(string: string)
                default:
                    resolvedURL = nil
                }
                continuation.resume(returning: resolvedURL)
            }
        }
    }

    private func loadPastedImageData(from provider: NSItemProvider) async -> Data? {
        for identifier in [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier, UTType.image.identifier] {
            guard provider.hasItemConformingToTypeIdentifier(identifier) else { continue }
            let data = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            if data != nil {
                return data
            }
        }
        return nil
    }

    @MainActor
    private func handleControlBarAction(_ action: ControlBarAction) {
        switch action {
        case .toggle:
            if liveSessionController?.state.isRunning ?? false {
                stopSession()
            } else if liveSessionController?.state.downloadProgress == nil {
                startSession()
            }
        case .confirmDownload:
            liveSessionController?.downloadModelOnly(settings: settings)
        }
    }

}

// MARK: - Scratchpad Section

private struct PostSessionBanner: View {
    let session: SessionIndex
    let lastSessionHasNotes: Bool
    let canRetranscribe: Bool
    let recoveryIsPending: Bool
    let onOpenTranscript: () -> Void
    let onOpenNotes: () -> Void
    let onGenerateNotes: () -> Void
    let onRetranscribe: () -> Void

    @ViewBuilder
    var body: some View {
        if session.utteranceCount > 0 {
            successfulSessionBanner
        } else if let transcriptIssue = session.transcriptIssue {
            failedSessionBanner(transcriptIssue: transcriptIssue)
        }
    }

    private var successfulSessionBanner: some View {
        VStack(spacing: 0) {
            HStack {
                Text(sessionEndedBannerText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("app.sessionEndedBanner")
                Spacer()
                if session.transcriptRecovery != nil {
                    Button(action: onOpenTranscript) {
                        Label("Open Transcript", systemImage: "text.quote")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(LiveInterviewCopilotProminentButtonStyle())
                    .controlSize(.small)
                    .accessibilityIdentifier("app.openTranscriptButton")

                    if lastSessionHasNotes {
                        Button(action: onOpenNotes) {
                            Label("View Notes", systemImage: "doc.text")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("app.viewNotesButton")
                    }
                } else if lastSessionHasNotes {
                    Button(action: onOpenNotes) {
                        Label("View Notes", systemImage: "doc.text")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("app.viewNotesButton")
                } else {
                    Button(action: onGenerateNotes) {
                        Label("Generate Notes", systemImage: "sparkles")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(LiveInterviewCopilotProminentButtonStyle())
                    .controlSize(.small)
                    .accessibilityIdentifier("app.generateNotesButton")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()
        }
    }

    private func failedSessionBanner(transcriptIssue: SessionTranscriptIssue) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)

                Text(transcriptIssue.sessionEndedBannerText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("app.sessionEndedBanner")
                Spacer()
                if recoveryIsPending {
                    Text("Recovery queued")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("app.recoveryQueuedLabel")
                } else if canRetranscribe {
                    Button(action: onRetranscribe) {
                        Label("Re-transcribe", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(LiveInterviewCopilotProminentButtonStyle())
                    .controlSize(.small)
                    .accessibilityIdentifier("app.retranscribeSessionButton")
                }
                Button(action: onOpenTranscript) {
                    Label("Open Transcript", systemImage: "text.quote")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("app.openTranscriptButton")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()
        }
    }

    private var sessionEndedBannerText: String {
        if let recovery = session.transcriptRecovery {
            return "\(recovery.sessionEndedBannerText) \u{00B7} \(session.utteranceCount) utterances"
        }
        return "Session ended \u{00B7} \(session.utteranceCount) utterances"
    }
}

private struct ScratchpadSection: View {
    @Binding var text: String
    let onPasteAssetProviders: ([NSItemProvider]) -> Void

    private let pasteAssetTypes: [UTType] = [.png, .jpeg, .tiff, .image, .fileURL]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("随手笔记")
                    .font(.caption.weight(.semibold))
                if !text.isEmpty {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                }
                Spacer()
                Text("自动保存")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            TextEditor(text: $text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 0, maxHeight: .infinity)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )
                .accessibilityIdentifier("app.scratchpadEditor")
                .accessibilityLabel("随手笔记编辑器")
                .onPasteCommand(of: pasteAssetTypes) { providers in
                    onPasteAssetProviders(providers)
                }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Isolated View Wrappers

private struct IsolatedTranscriptWrapper: View {
    let state: LiveSessionState
    
    var body: some View {
        TranscriptView(
            utterances: state.liveTranscript,
            emptyStateMessage: state.liveTranscriptEmptyStateMessage,
            volatileYouText: state.volatileYouText,
            volatileThemText: state.volatileThemText
        )
    }
}

private struct IsolatedControlBarWrapper: View {
    let state: LiveSessionState
    let onToggle: () -> Void
    let onMuteToggle: () -> Void
    let onPauseToggle: () -> Void
    let onConfirmDownload: () -> Void
    let onOpenSettings: () -> Void
    let onOpenMicrophonePrivacySettings: () -> Void

    var body: some View {
        ControlBar(
            isRunning: state.isRunning,
            audioLevel: state.audioLevel,
            micAudioLevel: state.micAudioLevel,
            systemAudioLevel: state.systemAudioLevel,
            micHasCapturedFrames: state.micHasCapturedFrames,
            recordingElapsedSeconds: state.recordingElapsedSeconds,
            isMicMuted: state.isMicMuted,
            isRecordingPaused: state.isRecordingPaused,
            modelDisplayName: state.modelDisplayName,
            transcriptionPrompt: state.transcriptionPrompt,
            batchStatus: state.batchStatus,
            batchIsImporting: state.batchIsImporting,
            kbIndexingStatus: state.kbIndexingStatus,
            statusMessage: state.statusMessage,
            errorMessage: state.errorMessage,
            recordingHealthNotice: state.recordingHealthNotice,
            needsDownload: state.needsDownload,
            downloadProgress: state.downloadProgress,
            downloadDetail: state.downloadDetail,
            onToggle: onToggle,
            onMuteToggle: onMuteToggle,
            onPauseToggle: onPauseToggle,
            onConfirmDownload: onConfirmDownload,
            onOpenSettings: onOpenSettings,
            onOpenMicrophonePrivacySettings: onOpenMicrophonePrivacySettings
        )
    }
}
