import Foundation
import Observation

/// The single source of truth for the identity and visible lifecycle of the
/// active Interview Round. Generation, persistence, and audio adapters remain
/// outside this interface during the first migration slice.
@MainActor
@Observable
final class InterviewRoundModule {
    private(set) var presentation = InterviewRoundPresentation()

    func accept(_ event: InterviewRoundEvent) {
        switch event {
        case .interviewerQuestionObserved:
            presentation = InterviewRoundPresentation(
                roundID: UUID(),
                createdAt: Date(),
                turnID: UUID(),
                revision: 0
            )
        case .questionRevised, .answerRegenerated:
            ensureRound()
            presentation.revision += 1
            presentation.backgroundCompletionAvailable = false
        case .candidateBeganAnswering:
            ensureRound()
            presentation.candidateSpokeSincePrompt = true
            presentation.isAnswerFrozen = true
        case .candidateAnswerAlreadyInProgress:
            ensureRound()
            presentation.candidateSpokeSincePrompt = true
            presentation.isAnswerFrozen = true
        case .backgroundCompletionAvailable:
            ensureRound()
            presentation.backgroundCompletionAvailable = true
        case .clearCurrentRound:
            presentation.roundID = nil
            presentation.createdAt = nil
        case .reset:
            presentation = InterviewRoundPresentation()
        }
    }

    func establishRoundIdentity(fallbackID: UUID) {
        if presentation.roundID == nil { presentation.roundID = fallbackID }
        if presentation.createdAt == nil { presentation.createdAt = Date() }
    }

    func accepts(turnID: UUID, revision: Int) -> Bool {
        presentation.turnID == turnID && presentation.revision == revision
    }

    private func ensureRound() {
        if presentation.roundID == nil { presentation.roundID = UUID() }
        if presentation.createdAt == nil { presentation.createdAt = Date() }
    }
}

enum InterviewRoundEvent: Sendable {
    case interviewerQuestionObserved
    case questionRevised
    case answerRegenerated
    case candidateBeganAnswering
    case candidateAnswerAlreadyInProgress
    case backgroundCompletionAvailable
    case clearCurrentRound
    case reset
}

struct InterviewRoundPresentation: Equatable, Sendable {
    fileprivate(set) var roundID: UUID?
    fileprivate(set) var createdAt: Date?
    fileprivate(set) var turnID: UUID
    fileprivate(set) var revision: Int
    fileprivate(set) var candidateSpokeSincePrompt: Bool
    fileprivate(set) var isAnswerFrozen: Bool
    fileprivate(set) var backgroundCompletionAvailable: Bool

    init(
        roundID: UUID? = nil,
        createdAt: Date? = nil,
        turnID: UUID = UUID(),
        revision: Int = 0,
        candidateSpokeSincePrompt: Bool = false,
        isAnswerFrozen: Bool = false,
        backgroundCompletionAvailable: Bool = false
    ) {
        self.roundID = roundID
        self.createdAt = createdAt
        self.turnID = turnID
        self.revision = revision
        self.candidateSpokeSincePrompt = candidateSpokeSincePrompt
        self.isAnswerFrozen = isAnswerFrozen
        self.backgroundCompletionAvailable = backgroundCompletionAvailable
    }
}
