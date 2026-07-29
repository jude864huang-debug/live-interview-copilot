import AppKit

enum CopilotHotkeyAction: Equatable, Sendable {
    case commitTurn
    case mergePreviousSegment
    case stopGeneration
    case toggleLens
    case lensPreviousPage
    case lensNextPage
}

/// Prevents the active global shortcut monitor from consuming keystrokes while
/// the settings recorder owns keyboard focus.
@MainActor
enum CopilotHotkeyRecordingState {
    static var isRecording = false
}

@MainActor
final class CopilotHotkeyManager {
    var onCommitTurn: (() -> Void)?
    var onMerge: (() -> Void)?
    var onStop: (() -> Void)?
    var onToggleLens: (() -> Void)?
    var onLensPrevious: (() -> Void)?
    var onLensNext: (() -> Void)?
    var isLensToggleEnabled: () -> Bool = { false }
    var isLensNavigationEnabled: () -> Bool = { false }

    /// Backward-compatible name for callers created before manual interview turns.
    var onGenerate: (() -> Void)? {
        get { onCommitTurn }
        set { onCommitTurn = newValue }
    }

    private(set) var primaryShortcut: CopilotTurnHotkey = .defaultTurn
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func configure(primaryShortcut: CopilotTurnHotkey) {
        guard case .invalid = CopilotTurnHotkeyValidation.validate(primaryShortcut) else {
            self.primaryShortcut = primaryShortcut
            return
        }
        self.primaryShortcut = .defaultTurn
    }

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard !CopilotHotkeyRecordingState.isRecording else { return false }

        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty, isLensNavigationEnabled() {
            if event.keyCode == CopilotTurnHotkey.lensPrevious.keyCode {
                onLensPrevious?()
                return true
            }
            if event.keyCode == CopilotTurnHotkey.lensNext.keyCode {
                onLensNext?()
                return true
            }
        }

        guard
              !event.isARepeat,
              let shortcut = Self.shortcut(from: event),
              let action = Self.action(for: shortcut, primaryShortcut: primaryShortcut) else {
            return false
        }
        switch action {
        case .commitTurn: onCommitTurn?()
        case .mergePreviousSegment: onMerge?()
        case .stopGeneration: onStop?()
        case .toggleLens:
            guard isLensToggleEnabled() else { return false }
            onToggleLens?()
        case .lensPreviousPage:
            guard isLensNavigationEnabled() else { return false }
            onLensPrevious?()
        case .lensNextPage:
            guard isLensNavigationEnabled() else { return false }
            onLensNext?()
        }
        return true
    }

    static func action(
        for shortcut: CopilotTurnHotkey,
        primaryShortcut: CopilotTurnHotkey
    ) -> CopilotHotkeyAction? {
        // Fixed actions take precedence over a legacy custom shortcut that may
        // have been saved before the lens shortcut became reserved.
        if shortcut == .lensToggle { return .toggleLens }
        if shortcut == primaryShortcut { return .commitTurn }
        if shortcut == .merge { return .mergePreviousSegment }
        if shortcut == .stop { return .stopGeneration }
        if shortcut == .lensPrevious { return .lensPreviousPage }
        if shortcut == .lensNext { return .lensNextPage }
        return nil
    }

    static func shortcut(from event: NSEvent) -> CopilotTurnHotkey? {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option, .shift])
        guard !modifiers.isEmpty else { return nil }
        let label = keyLabel(for: event)
        guard !label.isEmpty else { return nil }
        return CopilotTurnHotkey(
            keyCode: event.keyCode,
            modifierRawValue: modifiers.rawValue,
            keyLabel: label
        )
    }

    private static func keyLabel(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36, 76: "RETURN"
        case 48: "TAB"
        case 49: "SPACE"
        case 51: "DELETE"
        case 53: "ESC"
        case 115: "HOME"
        case 116: "PAGE UP"
        case 117: "FORWARD DELETE"
        case 119: "END"
        case 121: "PAGE DOWN"
        case 123: "LEFT"
        case 124: "RIGHT"
        case 125: "DOWN"
        case 126: "UP"
        default:
            event.charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() ?? ""
        }
    }
}
