import AppKit
import ColorSync
import Observation
import SwiftUI

@Observable
@MainActor
final class InterviewLensManager {
    let state = InterviewLensPresentationState()

    private(set) var isVisible = false

    @ObservationIgnored private var panel: InterviewLensPanel?
    @ObservationIgnored private var hostingView: NSHostingView<AnyView>?
    @ObservationIgnored private weak var engine: CustomerCopilotEngine?
    @ObservationIgnored private var settings: SettingsStore?
    @ObservationIgnored private var defaults: UserDefaults = .standard
    @ObservationIgnored private var screenChangeObserver: NSObjectProtocol?
    @ObservationIgnored private lazy var panelDelegate = InterviewLensPanelDelegate(owner: self)
    @ObservationIgnored private var isApplyingContentDrivenFrame = false
    @ObservationIgnored private var pendingPanelResizeTask: Task<Void, Never>?
    @ObservationIgnored private var lastAppliedContentHeight: CGFloat?

    var activeSelection: InterviewLensSelection? { state.activeSelection }
    var displayTitle: String {
        guard let selection = activeSelection else { return "镜头卡" }
        let contentTitle: String
        if selection == .referenceAnswer,
           let unitID = state.currentPage?.items.first?.unitID,
           let suffix = unitID.split(separator: ".").last,
           let index = Int(suffix) {
            contentTitle = "完整回答 \(index + 1)"
        } else {
            contentTitle = selection.title
        }
        return "镜头卡｜\(contentTitle)"
    }

    var canNavigatePrevious: Bool {
        state.canGoBack || neighboringSelection(offset: -1) != nil
    }

    var canNavigateNext: Bool {
        state.canGoForward || neighboringSelection(offset: 1) != nil
    }

    func configure(settings: SettingsStore, defaults: UserDefaults) {
        self.settings = settings
        self.defaults = defaults
        guard screenChangeObserver == nil else { return }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recoverPanelToVisibleScreen()
            }
        }
    }

    func toggle(
        _ selection: InterviewLensSelection,
        engine: CustomerCopilotEngine,
        sourceWindow: NSWindow?
    ) {
        let resolvedSelection: InterviewLensSelection = selection == .question ? .answer : selection
        if isVisible, activeSelection == resolvedSelection {
            closeByUser()
            return
        }
        show(
            selection: resolvedSelection,
            engine: engine,
            sourceWindow: sourceWindow,
            userInitiated: true
        )
    }

    /// Opens the default answer card when hidden and closes the lens regardless
    /// of which answer/follow-up page is currently selected.
    func toggleVisibility(engine: CustomerCopilotEngine, sourceWindow: NSWindow?) {
        if isVisible {
            closeByUser()
            return
        }
        show(
            selection: .answer,
            engine: engine,
            sourceWindow: sourceWindow,
            userInitiated: true
        )
    }

    func restoreIfNeeded(engine: CustomerCopilotEngine?, sourceWindow: NSWindow?) {
        guard let settings, settings.interviewLensEnabled, let engine else { return }
        // A follow-up selection belongs to the previous interview. Every new
        // session starts from the answer overview so the first useful opening
        // and the logic spine are what the user sees first.
        show(
            selection: .answer,
            engine: engine,
            sourceWindow: sourceWindow,
            userInitiated: false
        )
    }

    func suspendForSessionEnd() {
        pendingPanelResizeTask?.cancel()
        pendingPanelResizeTask = nil
        isApplyingContentDrivenFrame = false
        lastAppliedContentHeight = nil
        panel?.orderOut(nil)
        hostingView?.rootView = AnyView(EmptyView())
        engine = nil
        state.clear()
        isVisible = false
    }

    func tearDown() {
        suspendForSessionEnd()
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
    }

    func closeByUser() {
        settings?.interviewLensEnabled = false
        suspendForSessionEnd()
    }

    func previousPage() {
        guard isVisible else { return }
        if state.canGoBack {
            state.previousPage()
            resizePanelToCurrentContent()
        } else if let selection = neighboringSelection(offset: -1) {
            replaceSelection(selection, landing: .last)
        }
    }

    func nextPage() {
        guard isVisible else { return }
        if state.canGoForward {
            state.nextPage()
            resizePanelToCurrentContent()
        } else if let selection = neighboringSelection(offset: 1) {
            replaceSelection(selection, landing: .first)
        }
    }

    func replaceWithQuestion() {
        replaceSelection(.answer)
    }

    func replaceWithQuickIdea() {
        replaceSelection(.answer)
    }

    func retryCurrentSelection() {
        guard let engine, let selection = activeSelection else { return }
        switch selection {
        case .question:
            replaceWithQuickIdea()
        case .answer:
            engine.retryReferenceAnswer()
        case .quickIdea:
            engine.generateNow()
        case .referenceAnswer:
            engine.retryReferenceAnswer()
        case .followUps:
            engine.retryFollowUps()
        case .followUpAnswer(let question):
            guard let suggestion = engine.followUpSuggestions?.items.first(where: {
                $0.question == question
            }) else {
                replaceWithQuickIdea()
                return
            }
            engine.answerFollowUp(suggestion)
        }
    }

    func setFontScale(_ scale: InterviewLensFontScale) {
        guard let settings else { return }
        settings.interviewLensFontScale = scale
        updatePaginationForCurrentFrame()
    }

    func decreaseFontScale() {
        guard let settings,
              let index = InterviewLensFontScale.allCases.firstIndex(of: settings.interviewLensFontScale),
              index > InterviewLensFontScale.allCases.startIndex else { return }
        setFontScale(InterviewLensFontScale.allCases[index - 1])
    }

    func increaseFontScale() {
        guard let settings,
              let index = InterviewLensFontScale.allCases.firstIndex(of: settings.interviewLensFontScale),
              index + 1 < InterviewLensFontScale.allCases.endIndex else { return }
        setFontScale(InterviewLensFontScale.allCases[index + 1])
    }

    func updateSharingType(hidden: Bool) {
        panel?.sharingType = hidden ? .none : .readOnly
    }

    func receive(_ projected: InterviewLensSnapshot) {
        guard isVisible else { return }
        if case .selectionChanged(let selection) = state.receive(projected) {
            persistSelection(selection)
            if let engine {
                state.activate(
                    selection,
                    initialSnapshot: InterviewLensProjector.snapshot(
                        from: engine,
                        selection: selection
                    )
                )
            }
        }
        updatePaginationForCurrentFrame()
    }

    func finishDragging() {
        guard let panel, let screen = panel.screen ?? screen(containing: panel.frame) else { return }
        let snapped = InterviewLensGeometry.snappedFrame(panel.frame, in: screen.visibleFrame)
        if snapped != panel.frame {
            panel.setFrame(snapped, display: true)
        }
        persistFrame(panel.frame, on: screen)
    }

    fileprivate func panelDidMove() {
        guard isVisible, let panel, let screen = panel.screen ?? screen(containing: panel.frame) else { return }
        panel.updateSizeLimits(for: screen.visibleFrame)
        // The custom drag region persists once performDrag finishes. Avoid
        // mutating observable settings for every intermediate move/resize tick.
    }

    fileprivate func panelDidResize() {
        guard isVisible, let panel, !isApplyingContentDrivenFrame else { return }
        // Never start another content-driven resize from the callback of a
        // resize already in progress. Only repaginate for the new width here.
        updatePaginationForCurrentFrame(resizeToContent: false)
        guard !panel.inLiveResize else { return }
        if let screen = panel.screen ?? screen(containing: panel.frame) {
            persistFrame(panel.frame, on: screen)
        }
    }

    fileprivate func panelDidEndLiveResize() {
        guard isVisible, let panel,
              let screen = panel.screen ?? screen(containing: panel.frame) else { return }
        updatePaginationForCurrentFrame(resizeToContent: false)
        resizePanelToCurrentContent()
        persistFrame(panel.frame, on: screen)
    }

    fileprivate func panelDidChangeScreen() {
        guard let panel, let screen = panel.screen ?? screen(containing: panel.frame) else { return }
        panel.updateSizeLimits(for: screen.visibleFrame)
        let clamped = InterviewLensGeometry.clampedFrame(panel.frame, to: screen.visibleFrame)
        if clamped != panel.frame {
            panel.setFrame(clamped, display: true)
        }
        updatePaginationForCurrentFrame(resizeToContent: false)
        resizePanelToCurrentContent()
        persistFrame(panel.frame, on: screen)
    }

    private func show(
        selection: InterviewLensSelection,
        engine: CustomerCopilotEngine,
        sourceWindow: NSWindow?,
        userInitiated: Bool
    ) {
        guard let settings else { return }
        self.engine = engine

        let projection = InterviewLensProjector.snapshot(from: engine, selection: selection)
        state.activate(selection, initialSnapshot: projection)
        persistSelection(selection)
        if userInitiated {
            settings.interviewLensEnabled = true
        }

        let sourceScreen = sourceWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        ensurePanel(on: sourceScreen)
        guard let panel else { return }
        installRootView(engine: engine)
        updatePaginationForCurrentFrame()
        panel.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .none
            : .utilityWindow
        panel.orderFrontRegardless()
        isVisible = true
    }

    private enum LandingPage {
        case first
        case last
    }

    private func replaceSelection(
        _ selection: InterviewLensSelection,
        landing: LandingPage = .first
    ) {
        guard isVisible, let engine else { return }
        let resolvedSelection: InterviewLensSelection = selection == .question ? .answer : selection
        let projection = InterviewLensProjector.snapshot(from: engine, selection: resolvedSelection)
        state.activate(resolvedSelection, initialSnapshot: projection)
        if case .last = landing {
            state.goToLastPage()
        }
        persistSelection(resolvedSelection)
        updatePaginationForCurrentFrame()
    }

    private func neighboringSelection(offset: Int) -> InterviewLensSelection? {
        guard let activeSelection else { return nil }
        let routes = state.snapshot?.navigationSelections ?? []
        guard let index = routes.firstIndex(of: activeSelection) else { return nil }
        let destination = index + offset
        guard routes.indices.contains(destination) else { return nil }
        return routes[destination]
    }

    private func ensurePanel(on sourceScreen: NSScreen?) {
        let screen = sourceScreen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)

        if panel == nil {
            let frame = restoredOrDefaultFrame(on: screen, visibleFrame: visibleFrame)
            let hidden = settings?.hideFromScreenShare
                ?? (defaults.object(forKey: "hideFromScreenShare") != nil
                    && defaults.bool(forKey: "hideFromScreenShare"))
            let value = InterviewLensPanel(
                contentRect: frame,
                hideFromScreenShare: hidden,
                screenVisibleFrame: visibleFrame
            )
            value.delegate = panelDelegate
            panel = value
        } else if !isVisible, let panel {
            panel.updateSizeLimits(for: visibleFrame)
            panel.setFrame(
                restoredOrDefaultFrame(on: screen, visibleFrame: visibleFrame),
                display: true
            )
            panel.sharingType = settings?.hideFromScreenShare == true ? .none : .readOnly
        }
    }

    private func installRootView(engine: CustomerCopilotEngine) {
        let root = AnyView(InterviewLensRootView(
            engine: engine,
            manager: self
        ))
        if let hostingView {
            hostingView.sizingOptions = []
            hostingView.rootView = root
        } else {
            let value = NSHostingView(rootView: root)
            // The panel owns its frame. SwiftUI content must not resize the
            // window back to its intrinsic size while content is streaming.
            value.sizingOptions = []
            value.translatesAutoresizingMaskIntoConstraints = true
            value.autoresizingMask = [.width, .height]
            let contentFrame = panel?.contentView?.bounds
                ?? NSRect(origin: .zero, size: panel?.frame.size ?? .zero)
            let container = InterviewLensContentContainerView(frame: contentFrame)
            container.translatesAutoresizingMaskIntoConstraints = true
            container.autoresizesSubviews = true
            value.frame = container.bounds
            container.addSubview(value)
            panel?.contentView = container
            // AppKit can query sizing while replacing a window's direct
            // content view, so reassert this after attachment as well.
            value.sizingOptions = []
            hostingView = value
        }
    }

    private func restoredOrDefaultFrame(
        on screen: NSScreen?,
        visibleFrame: NSRect
    ) -> NSRect {
        guard let settings, let screen else {
            return InterviewLensGeometry.defaultFrame(in: visibleFrame)
        }
        let key = displayIdentifier(for: screen)
        guard let placement = settings.interviewLensDisplayPlacements[key] else {
            let hasSavedGlobalSize = defaults.object(forKey: "interviewLensSize") != nil
            guard hasSavedGlobalSize || !settings.interviewLensDisplayPlacements.isEmpty else {
                return InterviewLensGeometry.defaultFrame(in: visibleFrame)
            }
            return InterviewLensGeometry.topAnchoredFrame(
                size: CGSize(
                    width: settings.interviewLensSize.width,
                    height: settings.interviewLensSize.height
                ),
                in: visibleFrame,
                anchor: .center
            )
        }
        let savedSize = placement.size ?? settings.interviewLensSize
        return InterviewLensGeometry.restoredFrame(
            size: CGSize(width: savedSize.width, height: savedSize.height),
            normalizedOrigin: CGPoint(
                x: placement.normalizedX,
                y: placement.normalizedY
            ),
            in: visibleFrame
        )
    }

    private func persistSelection(_ selection: InterviewLensSelection) {
        guard let settings else { return }
        if let persistent = selection.persistentSelection {
            settings.interviewLensLastSelection = persistent
        } else {
            settings.interviewLensLastSelection = .answer
        }
    }

    private func persistFrame(_ frame: NSRect, on screen: NSScreen) {
        guard let settings else { return }
        let constrained = InterviewLensGeometry.clampedFrame(frame, to: screen.visibleFrame)
        let origin = InterviewLensGeometry.normalizedOrigin(
            for: constrained,
            in: screen.visibleFrame
        )
        let size = InterviewLensSize(
            width: constrained.width,
            height: constrained.height
        )
        var placements = settings.interviewLensDisplayPlacements
        placements[displayIdentifier(for: screen)] = InterviewLensDisplayPlacement(
            normalizedX: origin.x,
            normalizedY: origin.y,
            size: size
        )
        settings.interviewLensDisplayPlacements = placements
        settings.interviewLensSize = size
    }

    private func displayIdentifier(for screen: NSScreen) -> String {
        let numberKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[numberKey] as? NSNumber else {
            return "screen|\(screen.localizedName)"
        }
        if let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(number.uint32Value) {
            let uuid = unmanagedUUID.takeRetainedValue()
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "screen|\(number.stringValue)"
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        let visible = InterviewLensGeometry.visibleFrameContainingLargestPortion(
            of: frame,
            among: NSScreen.screens.map(\.visibleFrame)
        )
        guard let visible else { return nil }
        return NSScreen.screens.first { $0.visibleFrame == visible }
    }

    private func updatePaginationForCurrentFrame(resizeToContent: Bool = true) {
        guard let settings else { return }
        let size = panel?.frame.size
            ?? CGSize(
                width: settings.interviewLensSize.width,
                height: settings.interviewLensSize.height
            )
        let visibleFrame = panel.flatMap { panel in
            (panel.screen ?? screen(containing: panel.frame))?.visibleFrame
        } ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let maximumPanelHeight = InterviewLensGeometry.maximumSize(in: visibleFrame).height
        state.updateLayout(
            panelSize: size,
            fontScale: settings.interviewLensFontScale,
            maximumPanelHeight: maximumPanelHeight
        )
        if resizeToContent {
            resizePanelToCurrentContent()
        }
    }

    private func resizePanelToCurrentContent() {
        // Coalesce to one resize per display interval. Keeping the first task
        // avoids starving the resize while model deltas arrive faster than the
        // delay; the task always reads the newest preferred height when it runs.
        guard pendingPanelResizeTask == nil else { return }
        pendingPanelResizeTask = Task { @MainActor [weak self] in
            do {
                // Leave SwiftUI's projection/update transaction before touching
                // NSWindow.frame, and coalesce rapid streaming deltas.
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.pendingPanelResizeTask = nil
            self.applyPanelSizeForCurrentContent()
        }
    }

    private func applyPanelSizeForCurrentContent() {
        guard let panel,
              !panel.inLiveResize,
              !isApplyingContentDrivenFrame,
              let screen = panel.screen ?? screen(containing: panel.frame) else { return }
        let fitted = InterviewLensGeometry.contentFittedFrame(
            panel.frame,
            preferredHeight: ceil(state.preferredPanelHeight),
            in: screen.visibleFrame
        )
        if let lastAppliedContentHeight,
           abs(lastAppliedContentHeight - fitted.height) < 0.5,
           abs(fitted.height - panel.frame.height) < 1.5 {
            return
        }
        guard abs(fitted.height - panel.frame.height) > 0.5
                || abs(fitted.minY - panel.frame.minY) > 0.5 else { return }

        isApplyingContentDrivenFrame = true
        lastAppliedContentHeight = fitted.height
        panel.setFrame(fitted, display: false, animate: false)
        // setFrame may synchronously emit windowDidResize. The guard only needs
        // to cover that re-entrant callback: asynchronous callbacks merely
        // repaginate and never initiate another frame change.
        isApplyingContentDrivenFrame = false
    }

    private func recoverPanelToVisibleScreen() {
        guard let panel, isVisible else { return }
        let screens = NSScreen.screens
        guard let fallback = NSScreen.main ?? screens.first else { return }
        if let current = panel.screen ?? screen(containing: panel.frame) {
            panelDidChangeScreen()
            persistFrame(panel.frame, on: current)
            return
        }

        let placement = settings?.interviewLensDisplayPlacements[displayIdentifier(for: fallback)]
        let normalized = CGPoint(
            x: placement?.normalizedX ?? 0.5,
            y: placement?.normalizedY ?? 1
        )
        let recovered = InterviewLensGeometry.recoveredFrame(
            panel.frame,
            normalizedOrigin: normalized,
            availableVisibleFrames: [fallback.visibleFrame]
        ) ?? InterviewLensGeometry.defaultFrame(in: fallback.visibleFrame)
        panel.updateSizeLimits(for: fallback.visibleFrame)
        panel.setFrame(recovered, display: true)
        updatePaginationForCurrentFrame()
        persistFrame(recovered, on: fallback)
    }
}

@MainActor
private final class InterviewLensPanelDelegate: NSObject, NSWindowDelegate {
    weak var owner: InterviewLensManager?

    init(owner: InterviewLensManager) {
        self.owner = owner
    }

    func windowDidMove(_ notification: Notification) {
        owner?.panelDidMove()
    }

    func windowDidResize(_ notification: Notification) {
        owner?.panelDidResize()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        owner?.panelDidEndLiveResize()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        owner?.panelDidChangeScreen()
    }
}

private struct InterviewLensRootView: View {
    @Bindable var engine: CustomerCopilotEngine
    @Bindable var manager: InterviewLensManager

    private var projection: InterviewLensSnapshot? {
        guard let selection = manager.activeSelection else { return nil }
        return InterviewLensProjector.snapshot(from: engine, selection: selection)
    }

    var body: some View {
        InterviewLensCardView(manager: manager)
            .onChange(of: projection, initial: true) { _, value in
                guard let value else { return }
                manager.receive(value)
            }
    }
}

private struct InterviewLensCardView: View {
    @Bindable var manager: InterviewLensManager
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var state: InterviewLensPresentationState { manager.state }
    private var fontScale: InterviewLensFontScale {
        manager.settingsFontScale
    }
    private var bodyFontSize: CGFloat { CGFloat(18 * fontScale.multiplier) }
    private var bodyLineSpacing: CGFloat {
        let systemLineHeight = NSFont.systemFont(ofSize: bodyFontSize).boundingRectForFont.height
        return max(0, bodyFontSize * 1.4 - systemLineHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            lensBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
            Divider()
            pageFooter
        }
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(
                            reduceTransparency || colorSchemeContrast == .increased
                                ? 1
                                : 0.93
                        )
                )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    Color.primary.opacity(colorSchemeContrast == .increased ? 0.38 : 0.18),
                    lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("面试镜头卡")
        .accessibilityIdentifier("copilot.interviewLens.panel")
    }

    private var titleBar: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                InterviewLensDragRegion(onDragEnded: manager.finishDragging)
                HStack(spacing: 6) {
                    Text(manager.displayTitle)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(manager.displayTitle)
                        .accessibilityIdentifier("copilot.interviewLens.title")
                    if let status = statusLabel {
                        Label(status.text, systemImage: status.icon)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 8)
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button(action: manager.decreaseFontScale) {
                Text("A−")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(fontScale == InterviewLensFontScale.allCases.first)
            .help("减小镜头卡字体")
            .accessibilityLabel("减小镜头卡字体")
            .accessibilityIdentifier("copilot.interviewLens.fontDecrease")

            Text("\(fontScale.rawValue)%")
                .font(.system(size: 10, design: .monospaced).weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 36)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("镜头卡字号 \(fontScale.rawValue)%")
                .accessibilityValue("\(fontScale.rawValue)%")
                .accessibilityIdentifier("copilot.interviewLens.fontScale")

            Button(action: manager.increaseFontScale) {
                Text("A+")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(fontScale == InterviewLensFontScale.allCases.last)
            .help("增大镜头卡字体")
            .accessibilityLabel("增大镜头卡字体")
            .accessibilityIdentifier("copilot.interviewLens.fontIncrease")

            Button(action: manager.closeByUser) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("关闭镜头卡")
            .accessibilityLabel("关闭镜头卡")
            .accessibilityIdentifier("copilot.interviewLens.close")
            .padding(.trailing, 4)
        }
        .frame(height: 36)
    }

    @ViewBuilder
    private var lensBody: some View {
        if let page = state.currentPage {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(page.items) { item in
                    pageItem(item)
                }
            }
            .id(contentIdentity)
        } else {
            emptyState
        }
    }

    private func pageItem(_ item: InterviewLensPageItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if item.continuesFromPrevious || !(item.label ?? "").isEmpty {
                HStack(spacing: 5) {
                    if item.continuesFromPrevious {
                        Text("续")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(
                                    Color.accentColor.opacity(
                                        colorSchemeContrast == .increased ? 0.28 : 0.16
                                    )
                                )
                            )
                            .foregroundStyle(Color.primary)
                    }
                    if let label = item.label, !label.isEmpty {
                        Text(label)
                            .font(.system(
                                size: InterviewLensPaginator.labelFontSize(for: bodyFontSize),
                                weight: .bold
                            ))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(item.text)
                .font(.system(size: bodyFontSize, weight: textWeight(for: item.kind)))
                .foregroundStyle(item.kind == .other ? Color.secondary : Color.primary)
                .lineSpacing(bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let failure = state.snapshot?.failure {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Button("重试") {
                        manager.retryCurrentSelection()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityHint(failure.recoverySuggestion ?? failure.message)
                    if state.activeSelection != .answer {
                        Button("切到参考回答") {
                            manager.replaceWithQuickIdea()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(emptyStateLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var pageFooter: some View {
        HStack(spacing: 5) {
            Button(action: manager.previousPage) {
                Image(systemName: "chevron.left")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!manager.canNavigatePrevious)
            .help("上一项或上一页 · ←")
            .accessibilityLabel("上一项或上一页")
            .accessibilityIdentifier("copilot.interviewLens.previous")

            Text(state.pages.isEmpty ? "0 / 0" : "\(state.pageIndex + 1) / \(state.pages.count)")
                .font(.system(size: 10, design: .monospaced).weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 42)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(pageCounterAccessibilityLabel)
                .accessibilityIdentifier("copilot.interviewLens.pageCounter")

            Button(action: manager.nextPage) {
                Image(systemName: "chevron.right")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!manager.canNavigateNext)
            .help("下一项或下一页 · →")
            .accessibilityLabel("下一项或下一页")
            .accessibilityIdentifier("copilot.interviewLens.next")

            if state.currentPage?.overflow != nil {
                Label("其余内容见主窗口", systemImage: "ellipsis.circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text("切换内容 · ← / →")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
    }

    private var contentIdentity: String {
        let itemIDs = state.currentPage?.items.map(\.unitID).joined(separator: "|") ?? "empty"
        return "\(state.activeSelection?.id ?? "none"):\(state.pageIndex):\(itemIDs)"
    }

    private var pageCounterAccessibilityLabel: String {
        guard !state.pages.isEmpty else { return "暂无分页内容" }
        return "第 \(state.pageIndex + 1) 页，共 \(state.pages.count) 页"
    }

    private var emptyStateLabel: String {
        switch state.activeSelection {
        case .question: "等待面试官问题确认…"
        case .answer: "正在形成可直接开口的回答…"
        case .quickIdea: "正在准备快速思路…"
        case .referenceAnswer: "正在实时生成完整回答…"
        case .followUps: "正在准备可能追问…"
        case .followUpAnswer: "正在准备这条追问的回答…"
        case nil: "等待镜头卡内容…"
        }
    }

    private var statusLabel: (text: String, icon: String)? {
        if state.snapshot?.failure != nil {
            return ("生成中断", "exclamationmark.triangle.fill")
        }
        if state.snapshot?.isStreaming == true {
            return ("实时生成", "dot.radiowaves.left.and.right")
        }
        if state.snapshot?.isFrozen == true {
            return ("回答中 · 实时同步", "waveform")
        }
        return nil
    }

    private func textWeight(for kind: InterviewLensSemanticUnit.Kind) -> Font.Weight {
        switch kind {
        case .question, .directOpening: .semibold
        case .quickIdea, .talkingPoint, .followUpQuestion: .medium
        default: .regular
        }
    }
}

private struct InterviewLensDragRegion: NSViewRepresentable {
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> DragView {
        DragView(onDragEnded: onDragEnded)
    }

    func updateNSView(_ nsView: DragView, context: Context) {
        nsView.onDragEnded = onDragEnded
    }

    @MainActor
    final class DragView: NSView {
        var onDragEnded: () -> Void

        init(onDragEnded: @escaping () -> Void) {
            self.onDragEnded = onDragEnded
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
            onDragEnded()
        }
    }
}

private extension InterviewLensManager {
    var settingsFontScale: InterviewLensFontScale {
        settings?.interviewLensFontScale ?? .defaultValue
    }
}
