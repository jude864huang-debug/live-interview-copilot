import XCTest
@testable import LiveInterviewCopilotKit

@MainActor
final class InterviewRoundModuleTests: XCTestCase {
    func testRevisionAndRegenerationInvalidateOlderGenerationIdentity() {
        let rounds = InterviewRoundModule()

        rounds.accept(.interviewerQuestionObserved)
        let initial = rounds.presentation
        rounds.accept(.questionRevised)
        let corrected = rounds.presentation
        rounds.accept(.answerRegenerated)
        let regenerated = rounds.presentation

        XCTAssertEqual(initial.roundID, corrected.roundID)
        XCTAssertEqual(corrected.roundID, regenerated.roundID)
        XCTAssertEqual(initial.turnID, corrected.turnID)
        XCTAssertEqual(corrected.turnID, regenerated.turnID)
        XCTAssertEqual(initial.revision, 0)
        XCTAssertEqual(corrected.revision, 1)
        XCTAssertEqual(regenerated.revision, 2)
        XCTAssertFalse(rounds.accepts(turnID: initial.turnID, revision: initial.revision))
        XCTAssertTrue(rounds.accepts(turnID: regenerated.turnID, revision: regenerated.revision))
    }

    func testCandidateAnswerFreezesPresentationUntilNextQuestion() {
        let rounds = InterviewRoundModule()

        rounds.accept(.interviewerQuestionObserved)
        rounds.accept(.candidateBeganAnswering)
        XCTAssertTrue(rounds.presentation.candidateSpokeSincePrompt)
        XCTAssertTrue(rounds.presentation.isAnswerFrozen)

        rounds.accept(.interviewerQuestionObserved)
        XCTAssertFalse(rounds.presentation.candidateSpokeSincePrompt)
        XCTAssertFalse(rounds.presentation.isAnswerFrozen)
    }
}
