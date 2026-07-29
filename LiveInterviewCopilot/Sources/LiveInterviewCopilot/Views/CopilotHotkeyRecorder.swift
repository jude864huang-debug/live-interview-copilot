import AppKit
import SwiftUI

struct CopilotHotkeyRecorder: View {
    @Binding var shortcut: CopilotTurnHotkey
    @State private var isRecording = false
    @State private var message: String?
    @State private var pendingSystemConflict: CopilotTurnHotkey?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    message = nil
                    pendingSystemConflict = nil
                    isRecording = true
                    CopilotHotkeyRecordingState.isRecording = true
                } label: {
                    Text(isRecording ? "请按新的组合键…" : shortcut.displayName)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(minWidth: 118)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("录制主分轮快捷键")
                .accessibilityHint("按下后，再按包含修饰键的新快捷键")

                Button("恢复默认") {
                    shortcut = .defaultTurn
                    message = nil
                    pendingSystemConflict = nil
                    isRecording = false
                    CopilotHotkeyRecordingState.isRecording = false
                }
                .disabled(shortcut == .defaultTurn && !isRecording)
            }

            if let message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(pendingSystemConflict == nil ? Color.red : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("先按主快捷键结束面试官问题并生成；回答结束后再按一次保存并切回面试官。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background {
            CopilotHotkeyCaptureView(
                isActive: isRecording,
                onCapture: capture,
                onCancel: {
                    isRecording = false
                    CopilotHotkeyRecordingState.isRecording = false
                    pendingSystemConflict = nil
                    message = nil
                }
            )
            .frame(width: 1, height: 1)
            .opacity(0.001)
        }
        .onDisappear {
            CopilotHotkeyRecordingState.isRecording = false
        }
    }

    private func capture(_ candidate: CopilotTurnHotkey) {
        switch CopilotTurnHotkeyValidation.validate(candidate) {
        case .valid:
            shortcut = candidate
            isRecording = false
            CopilotHotkeyRecordingState.isRecording = false
            pendingSystemConflict = nil
            message = nil
        case .invalid(let reason):
            pendingSystemConflict = nil
            message = reason
        case .systemConflict(let warning):
            if pendingSystemConflict == candidate {
                shortcut = candidate
                isRecording = false
                CopilotHotkeyRecordingState.isRecording = false
                pendingSystemConflict = nil
                message = nil
            } else {
                pendingSystemConflict = candidate
                message = warning
            }
        }
    }
}

private struct CopilotHotkeyCaptureView: NSViewRepresentable {
    let isActive: Bool
    let onCapture: (CopilotTurnHotkey) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureNSView {
        let view = CaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: CaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        nsView.isActive = isActive
        guard isActive else { return }
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView, nsView.isActive else { return }
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class CaptureNSView: NSView {
        var isActive = false
        var onCapture: ((CopilotTurnHotkey) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { isActive }

        override func keyDown(with event: NSEvent) {
            guard isActive else {
                super.keyDown(with: event)
                return
            }
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                onCancel?()
                return
            }
            guard let shortcut = CopilotHotkeyManager.shortcut(from: event) else {
                NSSound.beep()
                return
            }
            onCapture?(shortcut)
        }
    }
}
