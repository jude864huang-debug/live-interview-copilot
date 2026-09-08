import AppKit
import SwiftUI

private enum CopilotFontSize: Int, CaseIterable {
    case small
    case compact
    case standard
    case large
    case extraLarge

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small: .small
        case .compact: .medium
        case .standard: .large
        case .large: .xLarge
        case .extraLarge: .xxLarge
        }
    }

    var percentageLabel: String {
        switch self {
        case .small: "85%"
        case .compact: "95%"
        case .standard: "100%"
        case .large: "115%"
        case .extraLarge: "130%"
        }
    }
}

struct CustomerCopilotPanelContent: View {
    @Bindable var engine: CustomerCopilotEngine
    @Bindable var liveSessionController: LiveSessionController
    @Bindable var interviewLensManager: InterviewLensManager
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("copilotFontSizeLevel") private var copilotFontSizeLevel = CopilotFontSize.standard.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error = engine.errorMessage { errorBanner(error) }
                progressiveAnswerSection
                followUpSection
                interviewHistorySection
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.48))
        .accessibilityIdentifier("copilot.details.scrollView")
        .dynamicTypeSize(selectedFontSize.dynamicTypeSize)
    }

    private var candidateContextSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("候选人转写")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(
                    "用于后续提示",
                    isOn: Binding(
                        get: { engine.includeCandidateAnswersInContext },
                        set: { engine.includeCandidateAnswersInContext = $0 }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(engine.interviewAudioMode != .manualStreamingASR)
                .help("下一次文字模型请求生效；关闭后仍会转写并保存在本机")
            }

            if engine.interviewAudioMode == .manualStreamingASR {
                Label(
                    engine.includeCandidateAnswersInContext
                        ? "会用于后续问题 · 历史每轮最多 500 字"
                        : "仅本地转写 · 不发送给文字模型",
                    systemImage: engine.includeCandidateAnswersInContext ? "arrow.up.circle" : "lock.fill"
                )
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(engine.includeCandidateAnswersInContext ? Color.accentColor : Color.secondary)
            } else {
                Label("GPT Realtime 实验模式不适用此开关", systemImage: "waveform.badge.exclamationmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            let activePartial = engine.activeInterviewRole == .candidate
                ? engine.asrPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let liveText = activePartial.isEmpty
                ? engine.candidateLiveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                : activePartial
            let contextText = engine.candidateContextText.trimmingCharacters(in: .whitespacesAndNewlines)
            Text(!liveText.isEmpty ? liveText : (!contextText.isEmpty ? contextText : "Start 后请对着麦克风说一句话。主窗口 Mic 电平会跳动，识别结果会在这里出现。"))
                .font(.system(size: 11))
                .foregroundStyle(liveText.isEmpty && contextText.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text("面试 Copilot").font(.callout.weight(.semibold))
                badge(audioModeLabel, color: .accentColor)
                badge(asrProviderLabel, color: engine.isUsingLocalASRFallback ? .orange : .secondary)
                Spacer()
                fontSizeControls
                if let duration = engine.lastASRDurationMilliseconds {
                    timingLabel("ASR", milliseconds: duration)
                }
                if let duration = engine.lastDurationMilliseconds {
                    timingLabel("LLM", milliseconds: duration)
                }
            }

            HStack(spacing: 8) {
                Label(compactRoleStatusTitle, systemImage: roleStatusSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(roleStatusColor)
                    .lineLimit(1)
                if engine.lastASRWasLowConfidence {
                    Image(systemName: "waveform.badge.exclamationmark")
                        .foregroundStyle(.orange)
                        .help("ASR 低置信度")
                        .accessibilityLabel("ASR 低置信度")
                }
                if engine.referenceGenerationState == .generating {
                    badge(
                        engine.isUsingFallbackAnswerModelForSession
                            ? "\(friendlyModelName(engine.activeAnswerModel)) 主回答生成中"
                            : "\(friendlyModelName(engine.primaryAnswerModel)) 主回答生成中",
                        color: .blue
                    )
                } else {
                    badge(engine.activeProvider.label, color: engine.isUsingSlowFallback ? .orange : .secondary)
                }
                Spacer(minLength: 4)
                compactAudioMeter(
                    title: "Mic",
                    level: liveSessionController.state.micAudioLevel,
                    active: !isAudioCapturePaused && !isMicMuted && engine.activeInterviewRole == .candidate
                )
                compactAudioMeter(
                    title: "Sys",
                    level: liveSessionController.state.systemAudioLevel,
                    active: !isAudioCapturePaused && engine.activeInterviewRole == .interviewer
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var selectedFontSize: CopilotFontSize {
        CopilotFontSize(rawValue: copilotFontSizeLevel) ?? .standard
    }

    private var fontSizeControls: some View {
        HStack(spacing: 2) {
            Button {
                adjustFontSize(by: -1)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(selectedFontSize == .small)
            .accessibilityLabel("减小字体")

            Text(selectedFontSize.percentageLabel)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 30)
                .accessibilityLabel("当前字体大小")
                .accessibilityValue(selectedFontSize.percentageLabel)

            Button {
                adjustFontSize(by: 1)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(selectedFontSize == .extraLarge)
            .accessibilityLabel("增大字体")
        }
        .padding(.horizontal, 3)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help("调整面试提示字体大小")
    }

    private func adjustFontSize(by offset: Int) {
        let range = CopilotFontSize.small.rawValue...CopilotFontSize.extraLarge.rawValue
        copilotFontSizeLevel = min(max(copilotFontSizeLevel + offset, range.lowerBound), range.upperBound)
    }

    private var turnStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Label(roleStatusTitle, systemImage: roleStatusSymbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(roleStatusColor)
                Spacer()
                Text(engine.asrStatusMessage)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                compactAudioMeter(
                    title: "Mic",
                    level: liveSessionController.state.micAudioLevel,
                    active: !isAudioCapturePaused && !isMicMuted && engine.activeInterviewRole == .candidate
                )
                compactAudioMeter(
                    title: "System",
                    level: liveSessionController.state.systemAudioLevel,
                    active: !isAudioCapturePaused && engine.activeInterviewRole == .interviewer
                )
            }

            let partial = engine.asrPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("实时识别 · 尚未保存")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(partial)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func questionSection(compactHeight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("当前问题", systemImage: "person.wave.2.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if engine.isAnswerFrozen { badge("回答中", color: .orange) }
                Spacer()
                if let type = engine.progressiveAnswer?.metadata.questionType
                    ?? engine.answerProgress.metadata?.questionType {
                    badge(type.label, color: .accentColor)
                }
                interviewLensButton(.question, title: "当前问题")
            }
            Text(displayedQuestion)
                .font(.callout.weight(.medium))
                .textSelection(.enabled)
                .lineLimit(compactHeight || dynamicTypeSize.isAccessibilitySize ? 1 : 2, reservesSpace: true)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("当前面试官问题")
                .accessibilityValue(displayedQuestion)
            if engine.previousResultWasSuperseded {
                Label("已按面试官补充重新生成", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func quickIdeaSection(compactHeight: Bool) -> some View {
        let items = displayedQuickIdeaItems(compactHeight: compactHeight)
        let hasResult = !items.isEmpty

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(
                    "快速思路",
                    systemImage: hasResult ? "bolt.fill" : "bolt"
                )
                    .font(.caption.weight(.bold))
                    .foregroundStyle(hasResult ? Color.accentColor : Color.secondary)
                if let status = quickIdeaStatusLabel {
                    badge(status, color: engine.generationState == .generating ? .orange : .accentColor)
                }
                if engine.generationState == .generating {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Text("自动更新")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                interviewLensButton(.quickIdea, title: "快速思路")
            }

            Group {
                if hasResult {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: item.systemImage)
                                    .foregroundStyle(item.color)
                                    .frame(width: 13)
                                    .accessibilityHidden(true)
                                Text(item.text)
                                    .font(.caption)
                                    .lineLimit(compactHeight && dynamicTypeSize.isAccessibilitySize ? 1 : 2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(item.accessibilityPrefix)：\(item.text)")
                        }
                    }
                } else if shouldReserveQuickIdea {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("正在生成快速思路…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Label(quickIdeaPlaceholder, systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .id(quickIdeaSignature)
            .transition(.opacity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(
            maxWidth: .infinity,
            minHeight: compactHeight || dynamicTypeSize.isAccessibilitySize ? 64 : 62,
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(hasResult ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(hasResult ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.30), lineWidth: hasResult ? 1.5 : 1)
        )
        .animation(
            accessibilityReduceMotion ? nil : .easeOut(duration: 0.20),
            value: quickIdeaSignature
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("快速回答思路")
    }

    private var footerControls: some View {
        VStack(spacing: 6) {
            Button(primaryActionTitle) { engine.commitActiveInterviewTurn() }
                .buttonStyle(.borderedProminent)
                .disabled(!canCommitTurn)
                .help(primaryActionHelp)
                .frame(maxWidth: .infinity)
                .controlSize(.large)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityIdentifier("copilot.turn.commit")
            HStack(spacing: 8) {
                Button("合并上一段", systemImage: "arrow.triangle.merge") { engine.mergePreviousCustomerUtterance() }
                    .buttonStyle(.bordered)
                    .disabled(engine.currentQuestion.isEmpty)
                    .help("⌃⌥M")
                    .lineLimit(1)
                Button {
                    liveSessionController.toggleRecordingPause()
                } label: {
                    Label(
                        isAudioCapturePaused ? "继续收音" : "暂停收音",
                        systemImage: isAudioCapturePaused ? "play.fill" : "pause.fill"
                    )
                    .foregroundStyle(isAudioCapturePaused ? Color.orange : Color.primary)
                }
                .buttonStyle(.bordered)
                .disabled(!liveSessionController.state.isRunning)
                .help(isAudioCapturePaused ? "恢复麦克风和系统音频收音" : "暂停麦克风和系统音频收音")
                .accessibilityIdentifier("copilot.audio.pauseToggle")
                .lineLimit(1)
                Spacer()
                Text("⌥Z")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(3)
    }

    private var roleCorrectionSection: some View {
        HStack(spacing: 8) {
            Label("角色纠正", systemImage: "arrow.left.arrow.right")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button("切到面试官") { engine.forceInterviewRole(.interviewer) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(engine.activeInterviewRole == .interviewer)
            Button("切到候选人") { engine.forceInterviewRole(.candidate) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(engine.activeInterviewRole == .candidate)
        }
        .help("强制切换会将当前稳定片段暂存 30 秒")
    }

    @ViewBuilder
    private var pendingSegmentSection: some View {
        if let text = engine.pendingSegmentText, !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("待恢复的\(engine.pendingSegmentRole?.label ?? "")片段", systemImage: "arrow.uturn.backward.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("保留并合并片段") { engine.restorePendingSegment() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
                Text(text)
                    .font(.system(size: 10))
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .padding(9)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var progressiveAnswerSection: some View {
        let final = engine.progressiveAnswer
        let entry = final?.entry ?? engine.answerProgress.entry
        let spine = final?.spine ?? engine.answerProgress.spine
        let segments = final?.segments ?? engine.answerProgress.segments
        let closing = final?.closing ?? engine.answerProgress.closing
        let isGenerating = engine.referenceGenerationState == .generating

        VStack(alignment: .leading, spacing: 16) {
            if let predictedQuestion = engine.predictedFollowUpQuestion,
               let predictedAnswer = engine.predictedFollowUpAnswer {
                VStack(alignment: .leading, spacing: 6) {
                    Label("预判参考", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(predictedQuestion)
                        .font(.caption.weight(.semibold))
                        .textSelection(.enabled)
                    Text(predictedAnswer.sampleAnswer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(isGenerating ? nil : 3)
                        .textSelection(.enabled)
                    if let source = engine.predictedFollowUpSourceQuestion {
                        Text("来源于上一轮：\(source)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }

            HStack(spacing: 8) {
                Label("参考回答", systemImage: entry == nil ? "text.bubble" : "text.bubble.fill")
                    .font(.headline)
                if isGenerating { ProgressView().controlSize(.small) }
                Spacer()
                interviewLensButton(.answer, title: "参考回答")
            }

            if let entry {
                VStack(alignment: .leading, spacing: 7) {
                    Text("先说这句")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                    Text(entry.text)
                        .font(.title3.weight(.semibold))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let assumption = entry.assumption, !assumption.isEmpty {
                        Label(assumption, systemImage: "questionmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.095))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if isGenerating {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            engine.isUsingFallbackAnswerModelForSession
                                ? "\(friendlyModelName(engine.primaryAnswerModel)) 本场不可用，正在用 \(friendlyModelName(engine.activeAnswerModel)) 形成第一句…"
                                : "正在用 \(friendlyModelName(engine.primaryAnswerModel)) 形成第一句可直接开口的回答…"
                        )
                            .font(.callout.weight(.semibold))
                        Text("半句话不会显示；首个通过引用校验的完整 entry 会锁定本轮答案。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }

            if !spine.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("逻辑主线")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(spine.enumerated()), id: \.element.id) { index, point in
                            let segment = segments.first { $0.pointID == point.id }
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.caption2.monospacedDigit().weight(.bold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 24, height: 24)
                                    .background(Color(nsColor: .windowBackgroundColor))
                                    .overlay(Circle().stroke(Color.accentColor.opacity(0.65), lineWidth: 1.5))
                                    .clipShape(Circle())
                                    .zIndex(1)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(point.label)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if let segment {
                                        Text(segment.text)
                                            .font(.callout)
                                            .lineSpacing(3)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    } else if isGenerating {
                                        Text("正在补全这一段…")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.bottom, index == spine.count - 1 ? 0 : 16)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("第 \(index + 1) 点，\(point.label)\(segment.map { "，\($0.text)" } ?? "")")
                        }
                    }
                    .overlay(alignment: .leading) {
                        if spine.count > 1 {
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.24))
                                .frame(width: 1)
                                .padding(.leading, 11.5)
                                .padding(.vertical, 12)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }

            if let closing {
                VStack(alignment: .leading, spacing: 4) {
                    Text("收束")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(closing.text)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }

            let sourceIDs = Array(Set(
                (entry?.sourceIDs ?? [])
                    + spine.flatMap(\.sourceIDs)
                    + segments.flatMap(\.sourceIDs)
                    + (closing?.sourceIDs ?? [])
            )).sorted()
            sourceLabels(sourceIDs)

            if engine.referenceGenerationState == .failed {
                HStack(alignment: .center, spacing: 8) {
                    Label(engine.referenceErrorMessage ?? "回答生成中断，已保留通过校验的内容。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("重试", systemImage: "arrow.clockwise") { engine.retryReferenceAnswer() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.2), value: spine.count + segments.count)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("渐进参考回答")
    }

    @ViewBuilder
    private func sourceLabels(_ sourceIDs: [String]) -> some View {
        let labels = engine.sourceLabels(for: sourceIDs)
        if !labels.isEmpty {
            Label(labels.joined(separator: " · "), systemImage: "doc.text")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help(labels.joined(separator: "\n"))
        }
    }

    private func friendlyModelName(_ model: String) -> String {
        switch model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "gpt-5.6-terra": return "Terra"
        case "gpt-5.6-luna": return "Luna"
        case "gpt-5.3-codex-spark": return "Spark"
        default: return model
        }
    }

    @ViewBuilder
    private var completeAnswerSection: some View {
        if let answer = engine.referenceAnswer {
            completeAnswerContent(answer)
        } else {
            switch engine.referenceGenerationState {
            case .generating:
                if engine.referenceAnswerPreviewSegments.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("正在同步生成完整回答…")
                                .font(.callout.weight(.semibold))
                            Text("与快速思路并行请求；已完成的段落会先显示。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let provider = engine.referenceProvider {
                            badge(provider.label, color: provider == .codexSubscription ? .orange : .blue)
                        }
                        interviewLensButton(.referenceAnswer, title: "完整回答")
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                } else {
                    completeAnswerPreviewContent(engine.referenceAnswerPreviewSegments)
                }

            case .failed:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("完整回答", systemImage: "text.bubble")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        interviewLensButton(.referenceAnswer, title: "完整回答")
                    }
                    if let error = engine.referenceErrorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if engine.canGenerateReferenceAnswerManually {
                        Button("重试完整回答", systemImage: "arrow.clockwise") {
                            engine.retryReferenceAnswer()
                        }
                        .buttonStyle(.bordered)
                    }
                }

            case .idle, .stopped, .superseded, .completed:
                if engine.canGenerateReferenceAnswerManually {
                    HStack {
                        Button(completeAnswerManualButtonTitle, systemImage: "text.bubble") {
                            engine.retryReferenceAnswer()
                        }
                        .buttonStyle(.bordered)
                        .help("默认自动生成；关闭自动完整回答后可在这里手动触发")
                        Spacer()
                        interviewLensButton(.referenceAnswer, title: "完整回答")
                    }
                }
            }
        }
    }

    private func completeAnswerContent(_ answer: InterviewReferenceAnswer) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Label("完整回答", systemImage: "text.bubble.fill")
                    .font(.headline)
                badge("约 \(answer.estimatedSpeakingSeconds) 秒", color: .blue)
                if let provider = engine.referenceProvider {
                    badge(provider.label, color: provider == .codexSubscription ? .orange : .secondary)
                }
                Spacer()
                if let firstSegment = engine.lastReferenceFirstSegmentMilliseconds {
                    timingLabel("首段", milliseconds: firstSegment)
                }
                if let duration = engine.lastReferenceDurationMilliseconds {
                    timingLabel("总计", milliseconds: duration)
                }
                interviewLensButton(.referenceAnswer, title: "完整回答")
            }

            ForEach(Array(answer.segments.enumerated()), id: \.offset) { _, segment in
                VStack(alignment: .leading, spacing: 4) {
                    Text(segment.label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(segment.text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.055))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private func completeAnswerPreviewContent(_ segments: [InterviewReferenceAnswerSegment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Label("完整回答生成中", systemImage: "text.bubble")
                    .font(.headline)
                badge("已出 \(segments.count)/3 段", color: .blue)
                Spacer()
                if let firstSegment = engine.lastReferenceFirstSegmentMilliseconds {
                    timingLabel("首段", milliseconds: firstSegment)
                }
                interviewLensButton(.referenceAnswer, title: "完整回答")
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                VStack(alignment: .leading, spacing: 4) {
                    Text(segment.label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(segment.text)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.055))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var followUpSection: some View {
        if engine.followUpGenerationState != .idle || engine.followUpSuggestions != nil {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Label("可能追问", systemImage: "arrow.turn.down.right")
                        .font(.headline)
                    if let count = engine.followUpSuggestions?.items.count {
                        badge("\(count)", color: .secondary)
                    }
                    if followUpPipelineIsGenerating {
                        ProgressView().controlSize(.small)
                    }
                    if let status = followUpPipelineStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(followUpPipelineIsFailure ? Color.red : Color.secondary)
                    }
                    Spacer()
                    interviewLensButton(.followUps, title: "可能追问")
                }

                if let suggestions = engine.followUpSuggestions {
                    ForEach(Array(suggestions.items.enumerated()), id: \.offset) { index, item in
                        followUpSuggestionRow(index: index, suggestion: item)
                    }
                } else if engine.followUpGenerationState == .generating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("主回答完成后，会先列出 3 个问题，再依次补全对应回答。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if engine.followUpGenerationState == .failed {
                    HStack(alignment: .center, spacing: 8) {
                        Label(engine.followUpErrorMessage ?? "可能追问生成失败。", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("重试", systemImage: "arrow.clockwise") {
                            engine.retryFollowUps()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var interviewHistorySection: some View {
        if !engine.archivedRounds.isEmpty {
            DisclosureGroup("本场历史（\(engine.archivedRounds.count)）") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(engine.archivedRounds) { round in
                        DisclosureGroup {
                            archivedRoundContent(round)
                                .padding(.top, 10)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(round.question)
                                    .font(.callout.weight(.semibold))
                                    .textSelection(.enabled)
                                Text(round.createdAt, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func archivedRoundContent(_ round: InterviewHistoryAnswer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("主回答")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                if let progressive = round.progressiveAnswer {
                    Text(progressive.entry.text)
                        .font(.callout.weight(.semibold))
                        .textSelection(.enabled)
                    ForEach(progressive.spine) { point in
                        if let segment = progressive.segments.first(where: { $0.pointID == point.id }) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(point.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(segment.text)
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    if let closing = progressive.closing {
                        Text(closing.text)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                } else {
                    ForEach(Array(round.answer.segments.enumerated()), id: \.offset) { _, segment in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(segment.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(segment.text)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if let suggestions = round.followUpSuggestions {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("可能追问与预判答案")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                    ForEach(Array(suggestions.items.enumerated()), id: \.element.id) { index, suggestion in
                        archivedFollowUpContent(
                            index: index,
                            suggestion: suggestion,
                            answer: round.followUpAnswers?[suggestion.question]
                        )
                    }
                }
            }

            if let predictedQuestion = round.predictedFollowUpQuestion,
               let predictedAnswer = round.predictedFollowUpAnswer {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("本轮命中的预判参考")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                    Text(predictedQuestion)
                        .font(.caption.weight(.semibold))
                    Text(predictedAnswer.sampleAnswer)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func archivedFollowUpContent(
        index: Int,
        suggestion: InterviewFollowUpSuggestion,
        answer: InterviewFollowUpAnswer?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Q\(index + 1) · \(suggestion.question)")
                .font(.caption.weight(.semibold))
                .textSelection(.enabled)
            if !suggestion.intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("考察：\(suggestion.intent)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let answer {
                Text(answer.directOpening)
                    .font(.caption.weight(.semibold))
                    .textSelection(.enabled)
                ForEach(Array(answer.talkingPoints.enumerated()), id: \.offset) { pointIndex, point in
                    Text("\(pointIndex + 1). \(point)")
                        .font(.caption)
                        .textSelection(.enabled)
                }
                Text(answer.sampleAnswer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("答案补全中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func followUpSuggestionRow(
        index: Int,
        suggestion: InterviewFollowUpSuggestion
    ) -> some View {
        let number = index + 1
        return VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text("Q\(number)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(.secondary)
                    Text("问题")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text(suggestion.question)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !suggestion.intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("考察：\(suggestion.intent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("追问 \(number)，\(suggestion.question)")
            .accessibilityIdentifier("copilot.followUp.question.\(number)")

            followUpAnswerContent(index: index, suggestion: suggestion)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(
            accessibilityReduceMotion ? nil : .easeOut(duration: 0.18),
            value: engine.followUpAnswerState(for: suggestion.question)
        )
    }

    private func followUpAnswerContent(
        index: Int,
        suggestion: InterviewFollowUpSuggestion
    ) -> some View {
        let state = engine.followUpAnswerState(for: suggestion.question)
        let number = index + 1
        return Group {
            if let answer = engine.followUpAnswer(for: suggestion.question) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("A\(number)")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(Color.accentColor)
                        Text("回答")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Menu {
                            Button("重新生成", systemImage: "arrow.clockwise") {
                                engine.answerFollowUp(suggestion)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .disabled(followUpPipelineIsBusy || state == .generating)
                        .help(
                            followUpPipelineIsBusy
                                ? "等待当前追问队列完成后再重新生成"
                                : "重新生成 A\(number)"
                        )
                        .accessibilityLabel("重新生成第 \(number) 个追问回答")
                        interviewLensButton(
                            .followUpAnswer(question: suggestion.question),
                            title: "第 \(number) 个追问回答"
                        )
                    }
                    Text(answer.directOpening)
                        .font(.callout.weight(.semibold))
                        .textSelection(.enabled)
                    if state == .generating {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("正在更新 A\(number)，旧回答会保留到新结果通过校验。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    } else if state == .failed {
                        HStack(alignment: .top, spacing: 7) {
                            Label(
                                engine.followUpAnswerError(for: suggestion.question) ?? "更新失败，已保留上一版回答。",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.red)
                            Spacer()
                            Button("重试", systemImage: "arrow.clockwise") {
                                engine.answerFollowUp(suggestion)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(followUpPipelineIsBusy)
                            .help(
                                followUpPipelineIsBusy
                                    ? "等待当前追问队列完成后再重试"
                                    : "重试更新 A\(number)"
                            )
                            .accessibilityLabel("重试更新第 \(number) 个追问回答")
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(answer.talkingPoints.enumerated()), id: \.offset) { pointIndex, point in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(pointIndex + 1)")
                                    .font(.caption2.monospacedDigit().weight(.bold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 16)
                                Text(point)
                                    .font(.caption)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    let sampleAnswer = answer.sampleAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sampleAnswer.isEmpty {
                        DisclosureGroup("展开口述稿（20–40 秒）") {
                            Text(sampleAnswer)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(.top, 2)
                        }
                        .font(.caption.weight(.medium))
                        .accessibilityLabel("展开第 \(number) 个追问的口述稿")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .padding(.leading, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.075))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .accessibilityHidden(true)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("第 \(number) 个追问回答")
            } else if state == .generating {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("A\(number) 回答生成中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    interviewLensButton(
                        .followUpAnswer(question: suggestion.question),
                        title: "第 \(number) 个追问回答"
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            } else if state == .failed {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 7) {
                        Label(
                            engine.followUpAnswerError(for: suggestion.question) ?? "A\(number) 生成失败，后续回答仍会继续。",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                        Spacer()
                        Button("重试", systemImage: "arrow.clockwise") {
                            engine.answerFollowUp(suggestion)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(followUpPipelineIsBusy)
                        .help(
                            followUpPipelineIsBusy
                                ? "等待其余追问答案生成完成后再重试"
                                : "重试 A\(number)"
                        )
                        .accessibilityLabel("重试第 \(number) 个追问回答")
                    }
                    if followUpPipelineIsBusy {
                        Text("其余追问答案生成完成后即可重试这一项。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "clock")
                    Text("A\(number) 等待生成")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                .background(Color.accentColor.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityIdentifier("copilot.followUp.answer.\(number)")
    }

    private var followUpPipelineIsBusy: Bool {
        switch engine.followUpPipelineState {
        case .generatingQuestions, .generatingAnswer:
            true
        default:
            false
        }
    }

    private var followUpPipelineIsGenerating: Bool {
        switch engine.followUpPipelineState {
        case .generatingQuestions, .generatingAnswer: true
        default: false
        }
    }

    private var followUpPipelineIsFailure: Bool {
        switch engine.followUpPipelineState {
        case .failed, .partiallyFailed: true
        default: false
        }
    }

    private var followUpPipelineStatus: String? {
        switch engine.followUpPipelineState {
        case .idle: nil
        case .generatingQuestions: "正在准备 3 个问题…"
        case .generatingAnswer(let index, let total): "正在生成 A\(index)/\(total)"
        case .completed: "3 个回答已完成"
        case .partiallyFailed(let failedIndices):
            "A\(failedIndices.map(String.init).joined(separator: "、A")) 失败"
        case .failed: "追问生成失败"
        case .stopped: "已停止"
        case .superseded: "已由新问题替换"
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !engine.recentCues.isEmpty {
            DisclosureGroup("最近问题（\(engine.recentCues.count)）") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(engine.recentCues) { item in
                        DisclosureGroup(item.question) {
                            Text(item.cue.directOpening).font(.system(size: 11)).padding(.top, 5)
                        }
                    }
                }.padding(.top, 8)
            }
        }
    }

    private var knowledgeStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("面试材料：\(engine.compiler.status.label)").font(.system(size: 10, weight: .medium))
            if let package = engine.compiler.snapshot {
                Text("\(package.sources.count) 个文件 · \(package.characterCount.formatted()) 字符 · 约 \(package.estimatedTokenCount.formatted()) tokens")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                if let brief = engine.configuredKnowledgeBrief {
                    Text("模型简报：约 \(brief.estimatedTokenCount.formatted()) tokens · \(brief.includedBlockIDs.count) 个来源块")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.blue)
                }
                if engine.isUsingKnowledgeBrief {
                    Text(engine.isUsingConfiguredKnowledgeBrief
                        ? "本次使用精简知识包（约 \((engine.activeKnowledgeTokenCount ?? 0).formatted()) tokens）"
                        : "完整材料超过上下文上限，本次已自动使用来源简报（约 \((engine.activeKnowledgeTokenCount ?? 0).formatted()) tokens）")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                }
                let categories = KnowledgeSourceCategory.allCases.compactMap { category -> String? in
                    guard let count = package.categoryCounts[category], count > 0 else { return nil }
                    return "\(category.label) \(count)"
                }
                Text(categories.joined(separator: " · ")).font(.system(size: 9)).foregroundStyle(.tertiary)
                if !package.classificationWarnings.isEmpty {
                    Text("有 \(package.classificationWarnings.count) 个未分类文件不能作为个人经历依据")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                }
            } else {
                Text("未选择材料时仍会给出可直接作答的专业方法与假设方案，但不会编造过往经历。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }.padding(.top, 4)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14))).foregroundStyle(color)
    }

    private func interviewLensButton(
        _ selection: InterviewLensSelection,
        title: String
    ) -> some View {
        let isActive = interviewLensManager.isVisible
            && interviewLensManager.activeSelection == selection
        let accessibilityHint = if isActive {
            "再次点击会关闭镜头卡"
        } else if let activeTitle = interviewLensManager.activeSelection?.title,
                  interviewLensManager.isVisible {
            "将替换当前镜头卡中的\(activeTitle)"
        } else {
            "打开一张不会抢走会议软件焦点的大字卡片"
        }

        return Button {
            interviewLensManager.toggle(
                selection,
                engine: engine,
                sourceWindow: NSApp.keyWindow
            )
        } label: {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .frame(width: 36, height: 36)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
            }
        }
        .help("在摄像头旁大字显示\(title)")
        .accessibilityLabel("在摄像头旁大字显示\(title)")
        .accessibilityValue(isActive ? "正在镜头卡显示" : "未在镜头卡显示")
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityIdentifier("copilot.interviewLens.\(selection.accessibilityIdentifier)")
    }

    private func timingLabel(_ title: String, milliseconds: Int) -> some View {
        Text(String(format: "\(title) %.1fs", Double(milliseconds) / 1_000))
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(title) 耗时")
            .accessibilityValue(String(format: "%.1f 秒", Double(milliseconds) / 1_000))
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11)).foregroundStyle(.red).padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func compactAudioMeter(title: String, level: Float, active: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(active ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 9, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? .primary : .secondary)
            ProgressView(value: Double(level), total: 1)
                .frame(width: 42)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) 音频电平")
        .accessibilityValue(level > 0.002 ? "检测到声音" : "音量低")
    }

    private var displayedQuestion: String {
        let question = engine.currentQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !question.isEmpty { return question }
        if engine.activeInterviewRole == .interviewer {
            let partial = engine.asrPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty { return "\(partial)…" }
        }
        return "等待面试官提问…"
    }

    private var quickIdeaItems: [InterviewLiveSupplementItem] {
        if engine.generationState == .generating, !engine.cuePreviewItems.isEmpty {
            return engine.cuePreviewItems
        }
        let bestCue = engine.supplementalSuggestion ?? engine.suggestion
        return InterviewLiveSupplementComposer.compose(
            supplementalCue: bestCue,
            referenceAnswer: nil,
            primaryCueFallback: nil,
            candidateIsAnswering: true
        )
    }

    /// In the shortest window, or at accessibility text sizes, three multi-line
    /// items would push the turn button off-screen. Keep the highest-priority
    /// warning or point visible; the complete supplement remains expanded in
    /// the scrolling detail area.
    private func displayedQuickIdeaItems(compactHeight: Bool) -> [InterviewLiveSupplementItem] {
        Array(quickIdeaItems.prefix(compactHeight || dynamicTypeSize.isAccessibilitySize ? 1 : 3))
    }

    private var quickIdeaSignature: String {
        if !quickIdeaItems.isEmpty {
            return quickIdeaItems.map(\.id).joined(separator: "|")
        }
        return shouldReserveQuickIdea ? "loading" : "idle-\(engine.currentQuestion)"
    }

    private var shouldReserveQuickIdea: Bool {
        !engine.currentQuestion.isEmpty && engine.generationState == .generating
    }

    private var quickIdeaPlaceholder: String {
        if engine.currentQuestion.isEmpty {
            return "问题确认后，思路会立即固定在这里"
        }
        if engine.generationState == .generating {
            return "正在生成快速思路…"
        }
        return "正在等待问题内容…"
    }

    private var quickIdeaStatusLabel: String? {
        guard !engine.currentQuestion.isEmpty else { return nil }
        if engine.generationState == .generating, engine.isUsingSlowFallback { return "回退生成中" }
        if engine.generationState == .generating, !engine.cuePreviewItems.isEmpty { return "实时生成" }
        if engine.generationState == .generating { return "个性化中" }
        if engine.supplementalSuggestion != nil { return "已更新" }
        if engine.lastCueFallbackReason != nil { return "已回退" }
        if engine.activeProvider == .local { return "即时" }
        return "已就绪"
    }

    private var completeAnswerManualButtonTitle: String {
        if engine.inferencePreference == .codexOnly || engine.activeProvider == .codexSubscription {
            return "生成完整回答（慢速）"
        }
        return "生成完整回答"
    }

    private var compactRoleStatusTitle: String {
        if isAudioCapturePaused { return "收音已暂停" }
        if isMicMuted, engine.activeInterviewRole == .candidate { return "Mic 已关闭 · 可保存" }
        if engine.interviewAudioMode == .openAIRealtimeExperimental {
            return "Realtime 实验"
        }
        return switch engine.manualTurnState {
        case .idle: "等待开始"
        case .listeningInterviewer: "听面试官 · System"
        case .finalizingInterviewer: "确认面试官问题"
        case .listeningCandidate: "听候选人 · Mic"
        case .finalizingCandidate: "保存候选人回答"
        case .fallbackTranscribing: "Qwen 慢速兜底"
        case .failed: "语音识别不可用"
        }
    }

    private var audioModeLabel: String {
        engine.interviewAudioMode == .manualStreamingASR ? "手动分轮" : "Realtime 实验"
    }

    private var asrProviderLabel: String {
        if engine.interviewAudioMode == .openAIRealtimeExperimental { return "GPT Realtime" }
        return engine.isUsingLocalASRFallback
            ? InterviewASRProvider.qwenLocalFallback.label
            : InterviewASRProvider.tencentStreaming.label
    }

    private var primaryActionTitle: String {
        if engine.interviewAudioMode == .openAIRealtimeExperimental {
            return "立即确认并生成"
        }
        return switch engine.activeInterviewRole {
        case .interviewer: "面试官提问完毕 → 生成"
        case .candidate: "我的回答完毕 → 保存"
        case nil: "等待音频采集开始"
        }
    }

    private var canCommitTurn: Bool {
        if engine.interviewAudioMode == .openAIRealtimeExperimental { return true }
        if engine.activeInterviewRole == .candidate {
            return engine.manualTurnState != .finalizingCandidate
        }
        return switch engine.manualTurnState {
        case .listeningInterviewer: true
        case .fallbackTranscribing: engine.activeInterviewRole != nil
        default: false
        }
    }

    private var primaryActionHelp: String {
        if engine.activeInterviewRole == .candidate, isMicMuted {
            return "麦克风已关闭；仍可结束并保存当前候选人轮。主分轮快捷键可在设置中修改。"
        }
        return "主分轮快捷键，可在设置中修改"
    }

    private var roleStatusTitle: String {
        if isAudioCapturePaused { return "收音已暂停 · 点击底部继续" }
        if isMicMuted, engine.activeInterviewRole == .candidate {
            return "麦克风已关闭 · 当前回答仍可保存"
        }
        if engine.interviewAudioMode == .openAIRealtimeExperimental {
            return "GPT Realtime 实验音频"
        }
        return switch engine.manualTurnState {
        case .idle: "等待开始"
        case .listeningInterviewer: "正在听：面试官（系统音频）"
        case .finalizingInterviewer: "正在确认面试官问题"
        case .listeningCandidate: "正在听：候选人（麦克风）"
        case .finalizingCandidate: "正在保存候选人回答"
        case .fallbackTranscribing: "Qwen 本地慢速兜底"
        case .failed: "语音识别不可用"
        }
    }

    private var roleStatusSymbol: String {
        if isAudioCapturePaused { return "pause.fill" }
        if isMicMuted, engine.activeInterviewRole == .candidate { return "mic.slash.fill" }
        return switch engine.manualTurnState {
        case .listeningInterviewer: "speaker.wave.2.fill"
        case .listeningCandidate: "mic.fill"
        case .finalizingInterviewer, .finalizingCandidate: "hourglass"
        case .fallbackTranscribing: "desktopcomputer"
        case .failed: "exclamationmark.triangle.fill"
        case .idle: "pause.circle"
        }
    }

    private var roleStatusColor: Color {
        if isAudioCapturePaused { return .orange }
        if isMicMuted, engine.activeInterviewRole == .candidate { return .orange }
        return switch engine.manualTurnState {
        case .listeningInterviewer, .listeningCandidate: .green
        case .finalizingInterviewer, .finalizingCandidate, .fallbackTranscribing: .orange
        case .failed: .red
        case .idle: .secondary
        }
    }

    private var statusColor: Color {
        if isAudioCapturePaused { return .orange }
        if isMicMuted, engine.activeInterviewRole == .candidate { return .orange }
        if engine.manualTurnState == .failed
            || engine.generationState == .failed
            || engine.referenceGenerationState == .failed {
            return .red
        }
        switch engine.manualTurnState {
        case .listeningInterviewer, .listeningCandidate: return .green
        case .finalizingInterviewer, .finalizingCandidate, .fallbackTranscribing: return .orange
        case .idle, .failed: break
        }
        switch engine.generationState {
        case .generating, .waitingForEndpoint: return .orange
        case .completed: return .green
        case .failed: return .red
        default:
            return engine.referenceGenerationState == .generating ? .orange : .secondary
        }
    }

    private var isAudioCapturePaused: Bool {
        liveSessionController.state.isRecordingPaused
    }

    private var isMicMuted: Bool {
        liveSessionController.state.isMicMuted
    }
}

// MARK: - Full-width interview workspace chrome

struct InterviewWorkspaceHeader: View {
    @Bindable var engine: CustomerCopilotEngine
    @Bindable var liveSessionController: LiveSessionController
    @Bindable var interviewLensManager: InterviewLensManager
    @Bindable var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @AppStorage("copilotFontSizeLevel") private var copilotFontSizeLevel = CopilotFontSize.standard.rawValue
    @State private var diagnosticsHovered = false
    @State private var diagnosticsPinned = false
    @State private var diagnosticsDismissTask: Task<Void, Never>?
    @FocusState private var diagnosticsFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("面试 Copilot")
                        .font(.callout.weight(.semibold))
                    HStack(spacing: 5) {
                        Label(roleStatusTitle, systemImage: roleStatusSymbol)
                            .font(.caption)
                            .foregroundStyle(roleStatusColor)
                            .lineLimit(1)
                        Text(asrProviderLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(asrProviderColor)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(asrProviderColor.opacity(0.1)))
                            .accessibilityLabel("当前语音识别：\(asrProviderLabel)")
                            .accessibilityIdentifier("copilot.asr.provider")
                    }
                }
            }
            .accessibilityElement(children: .contain)

            Divider().frame(height: 30)

            audioMeter(
                title: "Mic",
                level: liveSessionController.state.micAudioLevel,
                active: micMeterIsActive,
                identifier: "copilot.audio.micMeter"
            )
            audioMeter(
                title: "System",
                level: liveSessionController.state.systemAudioLevel,
                active: !engine.isLocalMicrophoneInterviewMode
                    && !isAudioCapturePaused
                    && engine.activeInterviewRole == .interviewer,
                identifier: "copilot.audio.systemMeter"
            )

            Spacer(minLength: 12)

            Button {
                interviewLensManager.toggleVisibility(
                    engine: engine,
                    sourceWindow: NSApp.windows.first(where: {
                        $0.identifier?.rawValue == LiveInterviewCopilotRootApp.mainWindowID
                    })
                )
            } label: {
                HStack(spacing: 6) {
                    Label("镜头卡", systemImage: "rectangle.on.rectangle")
                    Text(CopilotTurnHotkey.lensToggle.displayName)
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .accessibilityHidden(true)
                }
                    .frame(minHeight: 36)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(interviewLensManager.isVisible ? Color.accentColor : Color.secondary)
            .help("打开或关闭镜头卡 · \(CopilotTurnHotkey.lensToggle.displayName)")
            .accessibilityLabel("打开或关闭镜头卡，快捷键 Option A")
            .accessibilityValue(interviewLensManager.isVisible ? "已打开" : "已关闭")
            .accessibilityIdentifier("copilot.interviewLens.header")

            fontSizeControls

            Button {
                settings.suggestionsAlwaysOnTop.toggle()
            } label: {
                Image(systemName: settings.suggestionsAlwaysOnTop ? "pin.fill" : "pin")
                    .frame(width: 36, height: 36)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(settings.suggestionsAlwaysOnTop ? Color.accentColor : Color.secondary)
            .help(settings.suggestionsAlwaysOnTop ? "取消主窗口置顶" : "将主窗口固定在最前")
            .accessibilityLabel(settings.suggestionsAlwaysOnTop ? "取消主窗口置顶" : "将主窗口固定在最前")
            .accessibilityValue(settings.suggestionsAlwaysOnTop ? "已开启" : "已关闭")
            .accessibilityIdentifier("app.alwaysOnTopButton")

            diagnosticsControl
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .topTrailing) {
            if showsDiagnostics {
                diagnosticsCard
                    .offset(x: -12, y: 51)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
                    .zIndex(100)
            }
        }
        .zIndex(100)
        .animation(
            accessibilityReduceMotion ? nil : .easeOut(duration: 0.18),
            value: showsDiagnostics
        )
        .onKeyPress(.escape) {
            guard showsDiagnostics else { return .ignored }
            diagnosticsPinned = false
            diagnosticsHovered = false
            diagnosticsFocused = false
            return .handled
        }
        .onDisappear { diagnosticsDismissTask?.cancel() }
    }

    private var diagnosticsControl: some View {
        Button {
            diagnosticsPinned.toggle()
            if diagnosticsPinned { diagnosticsHovered = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: diagnosticsPinned ? "info.circle.fill" : "info.circle")
                Text("运行详情")
                    .font(.caption.weight(.medium))
            }
            .frame(minHeight: 36)
            .padding(.horizontal, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(showsDiagnostics ? Color.accentColor : Color.secondary)
        .focused($diagnosticsFocused)
        .onHover(perform: updateDiagnosticsHover)
        .help("查看模型、延迟和生成状态；点击可固定")
        .accessibilityLabel("运行详情")
        .accessibilityValue(diagnosticsPinned ? "已固定展开" : (showsDiagnostics ? "已展开" : "已收起"))
        .accessibilityHint("鼠标悬停、键盘聚焦或点击均可展开")
        .accessibilityIdentifier("copilot.runDiagnostics.button")
    }

    private var diagnosticsCard: some View {
        let diagnostics = engine.runDiagnostics
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("本轮运行详情", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.callout.weight(.semibold))
                Spacer()
                if diagnosticsPinned {
                    Text("已固定")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }

            diagnosticsGroup("模型") {
                diagnosticRow(
                    "本轮发起",
                    friendlyModelName(diagnostics.mainModel),
                    fullValue: diagnostics.mainModel
                )
                diagnosticRow(
                    "失败后备用",
                    diagnostics.fallbackModel.map(friendlyModelName)
                        ?? (engine.isUsingFallbackAnswerModelForSession ? "本场已切换" : "未配置"),
                    fullValue: diagnostics.fallbackModel
                )
                diagnosticRow(
                    "实际产出",
                    friendlyModelName(diagnostics.ownerModel ?? diagnostics.mainModel),
                    fullValue: diagnostics.ownerModel ?? diagnostics.mainModel
                )
                diagnosticRow(
                    "本轮尝试",
                    (diagnostics.attemptedModels.isEmpty
                        ? [diagnostics.mainModel]
                        : diagnostics.attemptedModels)
                        .map(friendlyModelName)
                        .joined(separator: " → "),
                    fullValue: (diagnostics.attemptedModels.isEmpty
                        ? [diagnostics.mainModel]
                        : diagnostics.attemptedModels)
                        .joined(separator: " → ")
                )
                diagnosticRow("生成通路", diagnostics.provider?.label ?? "等待请求")
                diagnosticRow("思考深度", diagnostics.reasoningEffort.rawValue)
                diagnosticRow(
                    "模型切换",
                    engine.isUsingFallbackAnswerModelForSession
                        ? "本场后续锁定 \(friendlyModelName(engine.activeAnswerModel))"
                        : (diagnostics.fallbackTriggered ? "本轮已触发" : "未触发")
                )
            }

            diagnosticsGroup("延迟") {
                diagnosticRow("首个 delta", durationText(diagnostics.firstDeltaMilliseconds))
                diagnosticRow("ASR", durationText(diagnostics.asrMilliseconds))
                diagnosticRow("可开口 entry", durationText(diagnostics.firstUsefulEntryMilliseconds))
                diagnosticRow("逻辑主线", durationText(diagnostics.spineReadyMilliseconds))
                diagnosticRow("主回答完成", durationText(diagnostics.answerCompleteMilliseconds))
                diagnosticRow("追问问题", durationText(diagnostics.followUpQuestionsMilliseconds))
                if !diagnostics.followUpAnswerMilliseconds.isEmpty {
                    diagnosticRow("追问答案", followUpDurationText(diagnostics.followUpAnswerMilliseconds))
                }
            }

            diagnosticsGroup("状态") {
                diagnosticRow(
                    "追问回答",
                    "\(diagnostics.followUpAnswersCompleted)/\(max(diagnostics.followUpAnswersTotal, 3)) · \(pipelineLabel(diagnostics.followUpPipelineState))"
                )
                diagnosticRow("引用校验", citationValidationText(diagnostics.citationValidationPassed))
                diagnosticRow("主线锁定", diagnostics.mainlineLocked ? "已锁定" : "未锁定")
                diagnosticRow("问题修订", "\(diagnostics.revisionCount) 次")
                diagnosticRow("开口时机", diagnostics.candidateStartedBeforeEntry ? "早于 entry" : "entry 后")
            }
        }
        .padding(14)
        .frame(width: 318, alignment: .leading)
        .background(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 7)
        .onHover(perform: updateDiagnosticsHover)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("copilot.runDiagnostics.popover")
    }

    private func diagnosticsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func diagnosticRow(
        _ label: String,
        _ value: String,
        fullValue: String? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value.isEmpty ? "—" : value)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .help(fullValue ?? value)
    }

    private var fontSizeControls: some View {
        HStack(spacing: 0) {
            Button {
                adjustFontSize(by: -1)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(selectedFontSize == .small)
            .help("减小回答字体")
            .accessibilityLabel("减小回答字体")

            Text(selectedFontSize.percentageLabel)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 32)
                .accessibilityLabel("当前回答字体大小")
                .accessibilityValue(selectedFontSize.percentageLabel)

            Button {
                adjustFontSize(by: 1)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(selectedFontSize == .extraLarge)
            .help("增大回答字体")
            .accessibilityLabel("增大回答字体")
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func audioMeter(
        title: String,
        level: Float,
        active: Bool,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(active ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.caption2.weight(active ? .semibold : .regular))
                    .foregroundStyle(active ? .primary : .secondary)
            }
            ProgressView(value: Double(level), total: 1)
                .progressViewStyle(.linear)
                .frame(width: 82)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) 音频电平")
        .accessibilityValue(level > 0.002 ? "检测到声音" : "音量低")
        .accessibilityIdentifier(identifier)
    }

    private func updateDiagnosticsHover(_ isInside: Bool) {
        diagnosticsDismissTask?.cancel()
        if isInside {
            diagnosticsHovered = true
            return
        }
        diagnosticsDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            diagnosticsHovered = false
        }
    }

    private func adjustFontSize(by offset: Int) {
        let range = CopilotFontSize.small.rawValue...CopilotFontSize.extraLarge.rawValue
        copilotFontSizeLevel = min(max(copilotFontSizeLevel + offset, range.lowerBound), range.upperBound)
    }

    private func durationText(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "—" }
        return String(format: "%.1fs", Double(milliseconds) / 1_000)
    }

    private func friendlyModelName(_ model: String) -> String {
        switch model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "gpt-5.6-terra": return "Terra"
        case "gpt-5.6-luna": return "Luna"
        case "gpt-5.3-codex-spark": return "Spark"
        default: break
        }
        return model
    }

    private func followUpDurationText(_ values: [Int?]) -> String {
        values.enumerated().map { index, milliseconds in
            "A\(index + 1) \(durationText(milliseconds))"
        }.joined(separator: " · ")
    }

    private func citationValidationText(_ passed: Bool?) -> String {
        switch passed {
        case true: "已通过"
        case false: "未通过"
        case nil: "等待校验"
        }
    }

    private func pipelineLabel(_ state: InterviewFollowUpPipelineState) -> String {
        switch state {
        case .idle: "等待"
        case .generatingQuestions: "生成问题"
        case .generatingAnswer(let index, let total): "生成 A\(index)/\(total)"
        case .completed: "完成"
        case .partiallyFailed(let failedIndices):
            "部分失败（\(failedIndices.map { "A\($0)" }.joined(separator: "、"))）"
        case .failed: "失败"
        case .stopped: "已停止"
        case .superseded: "已替换"
        }
    }

    private var showsDiagnostics: Bool {
        diagnosticsHovered || diagnosticsPinned || diagnosticsFocused
    }

    private var selectedFontSize: CopilotFontSize {
        CopilotFontSize(rawValue: copilotFontSizeLevel) ?? .standard
    }

    private var roleStatusTitle: String {
        if isAudioCapturePaused { return "收音已暂停" }
        if engine.isLocalMicrophoneInterviewMode {
            if engine.isFinishingExternalInterviewQuestion { return "正在完成听题" }
            return engine.isListeningToExternalInterviewQuestion
                ? "听面试官 · 本机麦克风"
                : "等待开始听题"
        }
        if isMicMuted, engine.activeInterviewRole == .candidate { return "Mic 已关闭 · 可保存" }
        return switch engine.manualTurnState {
        case .idle: "等待开始"
        case .listeningInterviewer: "听面试官 · System"
        case .finalizingInterviewer: "确认面试官问题"
        case .listeningCandidate: "听候选人 · Mic"
        case .finalizingCandidate: "保存候选人回答"
        case .fallbackTranscribing: "Qwen 慢速兜底"
        case .failed: "语音识别不可用"
        }
    }

    private var roleStatusSymbol: String {
        if isAudioCapturePaused { return "pause.fill" }
        if engine.isLocalMicrophoneInterviewMode {
            return engine.isFinishingExternalInterviewQuestion ? "hourglass" : "mic.fill"
        }
        if isMicMuted, engine.activeInterviewRole == .candidate { return "mic.slash.fill" }
        return switch engine.manualTurnState {
        case .listeningInterviewer: "speaker.wave.2.fill"
        case .listeningCandidate: "mic.fill"
        case .finalizingInterviewer, .finalizingCandidate: "hourglass"
        case .fallbackTranscribing: "desktopcomputer"
        case .failed: "exclamationmark.triangle.fill"
        case .idle: "pause.circle"
        }
    }

    private var roleStatusColor: Color {
        if engine.isLocalMicrophoneInterviewMode {
            if isAudioCapturePaused || engine.isFinishingExternalInterviewQuestion { return .orange }
            return engine.isListeningToExternalInterviewQuestion ? .green : .secondary
        }
        if isAudioCapturePaused || (isMicMuted && engine.activeInterviewRole == .candidate) { return .orange }
        return switch engine.manualTurnState {
        case .listeningInterviewer, .listeningCandidate: .green
        case .finalizingInterviewer, .finalizingCandidate, .fallbackTranscribing: .orange
        case .failed: .red
        case .idle: .secondary
        }
    }

    private var asrProviderLabel: String {
        if engine.interviewAudioMode == .openAIRealtimeExperimental {
            return "GPT Realtime"
        }
        return engine.isUsingLocalASRFallback
            ? InterviewASRProvider.qwenLocalFallback.label
            : InterviewASRProvider.tencentStreaming.label
    }

    private var asrProviderColor: Color {
        engine.isUsingLocalASRFallback ? .orange : .secondary
    }

    private var statusColor: Color {
        if engine.isLocalMicrophoneInterviewMode {
            if engine.isFinishingExternalInterviewQuestion || isAudioCapturePaused { return .orange }
            return engine.isListeningToExternalInterviewQuestion ? .green : .secondary
        }
        if engine.manualTurnState == .failed || engine.referenceGenerationState == .failed { return .red }
        if isAudioCapturePaused || engine.referenceGenerationState == .generating { return .orange }
        return switch engine.manualTurnState {
        case .listeningInterviewer, .listeningCandidate: .green
        case .finalizingInterviewer, .finalizingCandidate, .fallbackTranscribing: .orange
        case .failed: .red
        case .idle: .secondary
        }
    }

    private var isAudioCapturePaused: Bool { liveSessionController.state.isRecordingPaused }
    private var isMicMuted: Bool { liveSessionController.state.isMicMuted }
    private var micMeterIsActive: Bool {
        guard !isAudioCapturePaused, !isMicMuted else { return false }
        if engine.isLocalMicrophoneInterviewMode {
            return engine.isListeningToExternalInterviewQuestion
                && !engine.isFinishingExternalInterviewQuestion
        }
        return engine.activeInterviewRole == .candidate
    }
}

struct InterviewWorkspaceQuestionBar: View {
    @Bindable var engine: CustomerCopilotEngine
    @Bindable var interviewLensManager: InterviewLensManager
    @AppStorage("copilotFontSizeLevel") private var copilotFontSizeLevel = CopilotFontSize.standard.rawValue
    @State private var keywordReplacementDraft = ""
    @FocusState private var isFullSentenceFocused: Bool
    @FocusState private var isKeywordInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Label("当前问题", systemImage: "person.wave.2.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if engine.isAnswerFrozen {
                            badge("回答中", color: .orange)
                        }
                        if engine.questionWasCorrected {
                            badge("已校正", color: .green)
                        }
                        if engine.previousResultWasSuperseded {
                            Label(
                                engine.questionWasCorrected ? "已按修正问题重新生成" : "已按补充重新生成",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        }
                        if engine.isCorrectingQuestion {
                            badge(engine.questionCorrectionMode == .fullSentence ? "整句修改中" : "关键词校正中", color: .blue)
                        }
                    }

                    questionBody
                }

                Spacer(minLength: 8)

                if !engine.isLocalMicrophoneInterviewMode {
                    HStack(spacing: 6) {
                        if let type = engine.progressiveAnswer?.metadata.questionType
                            ?? engine.answerProgress.metadata?.questionType {
                            badge(type.label, color: .secondary)
                        }

                        Button {
                            engine.beginQuestionFullSentenceCorrection()
                            isFullSentenceFocused = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .disabled(!engine.canCorrectCurrentQuestion)
                        .help("整句修改：可改问题中任何部分，确定后重新生成")
                        .accessibilityLabel("整句修改当前问题")
                        .accessibilityIdentifier("copilot.question.fullSentenceEdit")

                        if !engine.isCorrectingQuestion, engine.canCorrectCurrentQuestion {
                            Button("校正") {
                                engine.beginQuestionKeywordCorrection()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption.weight(.semibold))
                            .help("高亮易错关键词，点击后可选手选或原位输入")
                            .accessibilityIdentifier("copilot.question.keywordCorrect")
                        }
                    }
                }
            }

            if !engine.isLocalMicrophoneInterviewMode, engine.isCorrectingQuestion {
                correctionActions
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .dynamicTypeSize(selectedFontSize.dynamicTypeSize)
        .accessibilityIdentifier("copilot.currentQuestion")
        .onChange(of: engine.activeQuestionHighlightID) { _, newValue in
            keywordReplacementDraft = ""
            isKeywordInputFocused = newValue != nil
        }
        .onChange(of: engine.questionCorrectionMode) { _, mode in
            if mode == .fullSentence {
                isFullSentenceFocused = true
            }
            if mode == .idle {
                keywordReplacementDraft = ""
                isKeywordInputFocused = false
                isFullSentenceFocused = false
            }
        }
    }

    @ViewBuilder
    private var questionBody: some View {
        switch engine.questionCorrectionMode {
        case .idle:
            highlightedQuestionText(interactive: false)
                .font(.callout.weight(.semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard engine.canCorrectCurrentQuestion else { return }
                    engine.beginQuestionKeywordCorrection()
                }
                .accessibilityLabel("当前面试官问题")
                .accessibilityValue(displayedQuestion)

        case .keyword:
            VStack(alignment: .leading, spacing: 8) {
                highlightedQuestionText(interactive: true)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let active = activeHighlight {
                    keywordEditor(for: active)
                } else {
                    Text("点高亮关键词可原位替换；也可点右侧铅笔做整句修改。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

        case .fullSentence:
            VStack(alignment: .leading, spacing: 6) {
                TextField("编辑完整问题", text: fullSentenceBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2...4)
                    .focused($isFullSentenceFocused)
                    .padding(8)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                    )
                    .onSubmit {
                        engine.applyCorrectedQuestionAndRegenerate()
                    }
                    .accessibilityIdentifier("copilot.question.fullSentenceField")

                Text("可改句子中任何部分。确定后按修正问题重新生成。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var correctionActions: some View {
        HStack(spacing: 8) {
            Button("确定并重新生成") {
                engine.applyCorrectedQuestionAndRegenerate()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(engine.questionCorrectionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("copilot.question.applyCorrection")

            Button("取消") {
                engine.cancelQuestionCorrection()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("copilot.question.cancelCorrection")

            Spacer()

            if engine.questionCorrectionHasChanges {
                Text("已修改，确认后会替换当前回答")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func keywordEditor(for highlight: QuestionRiskHighlight) -> some View {
        // Candidates stay near the active in-place input; the input itself is
        // rendered inside the highlighted sentence span.
        VStack(alignment: .leading, spacing: 6) {
            if !highlight.candidates.isEmpty {
                HStack(spacing: 6) {
                    Text("候选")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(highlight.candidates, id: \.self) { candidate in
                        Button(candidate) {
                            keywordReplacementDraft = ""
                            engine.replaceQuestionHighlight(id: highlight.id, with: candidate)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    Button("收起") {
                        engine.selectQuestionHighlight(nil)
                        keywordReplacementDraft = ""
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            } else {
                HStack(spacing: 8) {
                    Text("无可靠候选，在高亮位置直接输入后按 Return 替换")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("收起") {
                        engine.selectQuestionHighlight(nil)
                        keywordReplacementDraft = ""
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
    }

    private func commitKeywordReplacement(_ highlight: QuestionRiskHighlight) {
        let value = keywordReplacementDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty input keeps original word (placeholder-only interaction).
        engine.replaceQuestionHighlight(id: highlight.id, with: value)
        keywordReplacementDraft = ""
    }

    @ViewBuilder
    private func highlightedQuestionText(interactive: Bool) -> some View {
        let text = interactive ? engine.questionCorrectionDraft : displayedQuestion
        let highlights = engine.questionRiskHighlights
        if text == "等待面试官提问…" {
            Text(text).foregroundStyle(.secondary)
        } else {
            questionSegmentsView(text: text, highlights: highlights, interactive: interactive)
        }
    }

    private func questionSegmentsView(
        text: String,
        highlights: [QuestionRiskHighlight],
        interactive: Bool
    ) -> some View {
        let segments = Self.makeSegments(text: text, highlights: highlights)
        return FlowQuestionSegments(
            segments: segments,
            activeID: engine.activeQuestionHighlightID,
            interactive: interactive,
            replacementDraft: $keywordReplacementDraft,
            isInputFocused: $isKeywordInputFocused,
            onSelect: { highlight in
                keywordReplacementDraft = ""
                engine.selectQuestionHighlight(highlight.id)
            },
            onSubmitReplacement: { highlight in
                commitKeywordReplacement(highlight)
            }
        )
    }

    private var activeHighlight: QuestionRiskHighlight? {
        guard let id = engine.activeQuestionHighlightID else { return nil }
        return engine.questionRiskHighlights.first(where: { $0.id == id })
    }

    private var fullSentenceBinding: Binding<String> {
        Binding(
            get: { engine.questionCorrectionDraft },
            set: { engine.updateQuestionCorrectionDraft($0) }
        )
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
            .foregroundStyle(color)
    }

    private var displayedQuestion: String {
        let question = engine.currentQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !question.isEmpty { return question }
        if engine.activeInterviewRole == .interviewer {
            let partial = engine.asrPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty { return "\(partial)…" }
        }
        return "等待面试官提问…"
    }

    private var selectedFontSize: CopilotFontSize {
        CopilotFontSize(rawValue: copilotFontSizeLevel) ?? .standard
    }

    private static func makeSegments(
        text: String,
        highlights: [QuestionRiskHighlight]
    ) -> [QuestionTextSegment] {
        let ordered = highlights.sorted {
            ($0.utf16Range.location, -$0.utf16Range.length) < ($1.utf16Range.location, -$1.utf16Range.length)
        }
        var segments: [QuestionTextSegment] = []
        var cursor = text.startIndex
        let ns = text as NSString

        for highlight in ordered {
            guard highlight.utf16Range.location != NSNotFound,
                  NSMaxRange(highlight.utf16Range) <= ns.length,
                  let range = Range(highlight.utf16Range, in: text),
                  range.lowerBound >= cursor else { continue }
            if cursor < range.lowerBound {
                segments.append(.plain(String(text[cursor..<range.lowerBound])))
            }
            segments.append(.highlight(highlight))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            segments.append(.plain(String(text[cursor...])))
        }
        if segments.isEmpty {
            segments = [.plain(text)]
        }
        return segments
    }
}

private enum QuestionTextSegment: Identifiable {
    case plain(String)
    case highlight(QuestionRiskHighlight)

    var id: String {
        switch self {
        case .plain(let text): "p-\(text.hashValue)"
        case .highlight(let item): "h-\(item.id.uuidString)"
        }
    }
}

/// Lightweight wrapping layout for continuous sentence segments.
private struct FlowQuestionSegments: View {
    let segments: [QuestionTextSegment]
    let activeID: UUID?
    let interactive: Bool
    @Binding var replacementDraft: String
    var isInputFocused: FocusState<Bool>.Binding
    let onSelect: (QuestionRiskHighlight) -> Void
    let onSubmitReplacement: (QuestionRiskHighlight) -> Void

    var body: some View {
        FlexibleQuestionLine(
            segments: segments,
            activeID: activeID,
            interactive: interactive,
            replacementDraft: $replacementDraft,
            isInputFocused: isInputFocused,
            onSelect: onSelect,
            onSubmitReplacement: onSubmitReplacement
        )
    }
}

private struct FlexibleQuestionLine: View {
    let segments: [QuestionTextSegment]
    let activeID: UUID?
    let interactive: Bool
    @Binding var replacementDraft: String
    var isInputFocused: FocusState<Bool>.Binding
    let onSelect: (QuestionRiskHighlight) -> Void
    let onSubmitReplacement: (QuestionRiskHighlight) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            QuestionWrapLayout(spacing: 0) {
                ForEach(segments) { segment in
                    switch segment {
                    case .plain(let text):
                        Text(text)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                    case .highlight(let item):
                        if interactive, activeID == item.id {
                            // In-place empty input; original word is grey placeholder only.
                            TextField(
                                "",
                                text: $replacementDraft,
                                prompt: Text(item.text).foregroundStyle(.secondary)
                            )
                            .textFieldStyle(.plain)
                            .font(.callout.weight(.semibold))
                            .focused(isInputFocused)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .frame(minWidth: max(28, CGFloat(item.text.count) * 14))
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.accentColor.opacity(0.10))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.accentColor.opacity(0.8), lineWidth: 1)
                            )
                            .onSubmit { onSubmitReplacement(item) }
                        } else if interactive {
                            Button {
                                onSelect(item)
                            } label: {
                                Text(item.text)
                                    .font(.callout.weight(.semibold))
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.accentColor.opacity(0.12))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                                    )
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .help(item.candidates.isEmpty ? "点击后输入替换" : "点击后选择候选或输入替换")
                        } else {
                            Text(item.text)
                                .font(.callout.weight(.semibold))
                                .padding(.horizontal, 2)
                                .background(Color.accentColor.opacity(0.10))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
    }
}

private struct QuestionWrapLayout: Layout {
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct InterviewWorkspaceActionBar: View {
    @Bindable var engine: CustomerCopilotEngine
    @Bindable var liveSessionController: LiveSessionController
    let onOpenSettings: () -> Void
    let onEndInterview: () -> Void
    @State private var confirmsEndingInterview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if liveSessionController.state.isRunning {
                recordingStatus
            }
            if isLocalMicrophoneInterviewMode {
                localMicrophoneControls
            } else {
                ViewThatFits(in: .horizontal) {
                    wideControls
                    compactControls
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 78)
        .background(.regularMaterial)
        .confirmationDialog(
            "结束本次面试？",
            isPresented: $confirmsEndingInterview,
            titleVisibility: .visible
        ) {
            Button("结束面试", role: .destructive, action: onEndInterview)
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                isLocalMicrophoneInterviewMode
                    ? "当前听题与转写会停止；本场文字会保存，原始麦克风音频不会保存。"
                    : "当前录音与生成会停止；本地录音将合并为 M4A，并保存到本场面试历史。"
            )
        }
        .accessibilityIdentifier("copilot.actionBar")
    }

    private var recordingStatus: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(recordingStatusColor)
                .frame(width: 7, height: 7)
            Text(recordingStatusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("copilot.audio.recordingStatus")
    }

    private var recordingStatusText: String {
        if isLocalMicrophoneInterviewMode {
            if isAudioCapturePaused { return "面试会话已暂停 · 继续后可开始听题" }
            if engine.isFinishingExternalInterviewQuestion { return "正在完成本题转写 · 原始音频不保存" }
            if engine.isListeningToExternalInterviewQuestion { return "正在听题 · 本机麦克风 · 原始音频不保存" }
            return "等待开始听题 · 手机请开免提 · 原始音频不保存"
        }
        guard liveSessionController.state.isLocalRecordingEnabled else {
            return "本场录音保存已关闭 · 可在设置 → Recording 中开启"
        }
        if isAudioCapturePaused {
            return "本地录音已暂停 · \(formattedRecordingDuration) · 继续后恢复麦克风与系统音频"
        }
        return "正在本地录音 \(formattedRecordingDuration) · 麦克风 + 系统音频 · 结束后保存到本场历史"
    }

    private var recordingStatusColor: Color {
        guard liveSessionController.state.isLocalRecordingEnabled else { return .secondary }
        return isAudioCapturePaused ? .orange : .red
    }

    private var formattedRecordingDuration: String {
        let elapsed = max(0, liveSessionController.state.recordingElapsedSeconds)
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    private var wideControls: some View {
        HStack(spacing: 10) {
            primaryButton
            pauseButton(compact: false)
            regenerateButton(compact: false)
            endInterviewButton(compact: false)
            moreMenu
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var compactControls: some View {
        HStack(spacing: 8) {
            primaryButton
            pauseButton(compact: true)
            regenerateButton(compact: true)
            endInterviewButton(compact: true)
            moreMenu
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var localMicrophoneControls: some View {
        HStack(spacing: 10) {
            if engine.isFinishingExternalInterviewQuestion {
                ProgressView()
                    .controlSize(.small)
                Text("正在完成听题…")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if engine.isListeningToExternalInterviewQuestion {
                Button {
                    engine.endExternalInterviewQuestion()
                } label: {
                    Label("结束听题", systemImage: "stop.fill")
                        .frame(minWidth: 126, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAudioCapturePaused)
                .help("停止本题收音并保存最终转写")
                .accessibilityIdentifier("copilot.externalQuestion.finish")

                Button {
                    engine.discardExternalInterviewQuestion()
                } label: {
                    Label("放弃并重录", systemImage: "arrow.counterclockwise")
                        .frame(minWidth: 112, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .disabled(isAudioCapturePaused)
                .help("丢弃当前听题片段，重新开始")
                .accessibilityIdentifier("copilot.externalQuestion.discard")
            } else {
                Button {
                    engine.startExternalInterviewQuestion()
                } label: {
                    Label("开始听题", systemImage: "mic.fill")
                        .frame(minWidth: 126, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAudioCapturePaused)
                .help("开始收取手机免提里的面试官问题")
                .accessibilityIdentifier("copilot.externalQuestion.start")
            }

            Spacer(minLength: 8)
            endInterviewButton(compact: false)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var primaryButton: some View {
        Button {
            if shouldRetryPrimaryAnswer {
                engine.retryReferenceAnswer()
            } else {
                engine.commitActiveInterviewTurn()
            }
        } label: {
            Label(primaryActionTitle, systemImage: primaryActionSystemImage)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .disabled(!canPerformPrimaryAction)
        .help(primaryActionHelp)
        .accessibilityIdentifier("copilot.turn.commit")
    }

    private func pauseButton(compact: Bool) -> some View {
        Button {
            liveSessionController.toggleRecordingPause()
        } label: {
            if compact {
                Image(systemName: isAudioCapturePaused ? "play.fill" : "pause.fill")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            } else {
                Label(
                    isAudioCapturePaused ? "继续收音" : "暂停收音",
                    systemImage: isAudioCapturePaused ? "play.fill" : "pause.fill"
                )
                .frame(minWidth: 88, minHeight: 44)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.bordered)
        .disabled(!liveSessionController.state.isRunning)
        .help(isAudioCapturePaused ? "恢复麦克风和系统音频收音" : "暂停麦克风和系统音频收音")
        .accessibilityLabel(isAudioCapturePaused ? "继续收音" : "暂停收音")
        .accessibilityIdentifier("copilot.audio.pauseToggle")
    }

    private func regenerateButton(compact: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                engine.regenerateCurrentAnswer()
            } label: {
                Label("重新生成", systemImage: "arrow.clockwise")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(minWidth: compact ? 80 : 92, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .disabled(!engine.canRegenerateCurrentAnswer)
            .help(engine.canRegenerateCurrentAnswer ? "重新生成当前回答" : "当前没有可重新生成的回答")
            .accessibilityLabel("重新生成当前回答")
            .accessibilityIdentifier("copilot.actions.regenerate")

            Menu {
                Section("思考深度后重新生成") {
                    ForEach(thinkingDepthOptions, id: \.rawValue) { effort in
                        Button {
                            engine.regenerateCurrentAnswer(reasoningEffort: effort)
                        } label: {
                            if effort == currentThinkingDepth {
                                Label(effort.label, systemImage: "checkmark")
                            } else {
                                Text(effort.label)
                            }
                        }
                        .disabled(!engine.canRegenerateCurrentAnswer)
                    }
                }
            } label: {
                Image(systemName: "brain.head.profile")
                    .frame(minWidth: compact ? 34 : 40, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.bordered)
            .disabled(!engine.canRegenerateCurrentAnswer)
            .help("选择思考深度并按该深度重新生成；会同步更新后续配置")
            .accessibilityLabel("选择思考深度后重新生成")
            .accessibilityIdentifier("copilot.actions.regenerate.thinkingDepth")
        }
    }

    private var thinkingDepthOptions: [InterviewReasoningEffort] {
        [.none, .low, .medium, .high, .xhigh]
    }

    private var currentThinkingDepth: InterviewReasoningEffort {
        engine.selectedThinkingDepth
    }

    private func endInterviewButton(compact: Bool) -> some View {
        Button(role: .destructive) {
            confirmsEndingInterview = true
        } label: {
            Label("结束面试", systemImage: "xmark.circle")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(minWidth: compact ? 82 : 88, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .help("结束本次面试")
        .accessibilityLabel("结束面试")
        .accessibilityIdentifier("copilot.actions.endInterview")
    }

    private var moreMenu: some View {
        Menu {
            Button("合并上一段", systemImage: "arrow.triangle.merge") {
                engine.mergePreviousCustomerUtterance()
            }
            .disabled(engine.currentQuestion.isEmpty)

            Menu("切换角色", systemImage: "arrow.left.arrow.right") {
                Button("面试官 · System") { engine.forceInterviewRole(.interviewer) }
                    .disabled(engine.activeInterviewRole == .interviewer)
                Button("候选人 · Mic") { engine.forceInterviewRole(.candidate) }
                    .disabled(engine.activeInterviewRole == .candidate)
            }

            Button("恢复待处理片段", systemImage: "arrow.uturn.backward.circle") {
                engine.restorePendingSegment()
            }
            .disabled(engine.pendingSegmentText?.isEmpty != false)

            Divider()

            Button("打开设置", systemImage: "gearshape", action: onOpenSettings)
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .help("更多面试操作")
        .accessibilityLabel("更多面试操作")
        .accessibilityIdentifier("copilot.actions.more")
    }

    private var shouldRetryPrimaryAnswer: Bool {
        engine.referenceGenerationState == .failed && engine.canGenerateReferenceAnswerManually
    }

    private var primaryActionTitle: String {
        if shouldRetryPrimaryAnswer { return "重试主回答" }
        if engine.interviewAudioMode == .openAIRealtimeExperimental { return "立即确认并生成" }
        return switch engine.activeInterviewRole {
        case .interviewer: "面试官提问完毕 → 生成"
        case .candidate: "我的回答完毕 → 保存"
        case nil: "等待音频采集开始"
        }
    }

    private var primaryActionSystemImage: String {
        if shouldRetryPrimaryAnswer { return "arrow.clockwise" }
        return engine.activeInterviewRole == .candidate ? "checkmark" : "sparkles"
    }

    private var canPerformPrimaryAction: Bool {
        if shouldRetryPrimaryAnswer { return true }
        if engine.interviewAudioMode == .openAIRealtimeExperimental { return true }
        if engine.activeInterviewRole == .candidate {
            return engine.manualTurnState != .finalizingCandidate
        }
        return switch engine.manualTurnState {
        case .listeningInterviewer: true
        case .fallbackTranscribing: engine.activeInterviewRole != nil
        default: false
        }
    }

    private var primaryActionHelp: String {
        if engine.activeInterviewRole == .candidate, isMicMuted {
            return "麦克风已关闭；仍可结束并保存当前候选人轮。"
        }
        return "结束当前说话轮并进入下一步；快捷键可在设置中修改"
    }

    private var isAudioCapturePaused: Bool { liveSessionController.state.isRecordingPaused }
    private var isMicMuted: Bool { liveSessionController.state.isMicMuted }
    private var isLocalMicrophoneInterviewMode: Bool {
        engine.isLocalMicrophoneInterviewMode
    }
}

private extension InterviewLiveSupplementItem {
    var systemImage: String {
        switch kind {
        case .talkingPoint: "lightbulb.fill"
        case .referenceSegment: "text.bubble.fill"
        case .missingFact: "exclamationmark.shield.fill"
        case .evidence: "person.crop.circle.badge.checkmark"
        }
    }

    var color: Color {
        switch kind {
        case .talkingPoint: .accentColor
        case .referenceSegment: .blue
        case .missingFact: .orange
        case .evidence: .green
        }
    }

    var accessibilityPrefix: String {
        switch kind {
        case .talkingPoint: "回答要点"
        case .referenceSegment: "完整回答补充"
        case .missingFact: "事实核对提醒"
        case .evidence: "个人经历锚点"
        }
    }
}

typealias InterviewCopilotPanelContent = CustomerCopilotPanelContent
