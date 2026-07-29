import XCTest
@testable import LiveInterviewCopilotKit

final class CandidateEchoTailTrimmerTests: XCTestCase {
    func testRemovesExactInterviewerEchoAndPreservesCandidatePrefix() {
        let interviewer = "请具体讲一下你在项目里负责了什么以及最终结果。"
        let candidate = "我会先说明项目目标和我的核心决策。请具体讲一下你在项目里负责了什么以及最终结果。"

        XCTAssertEqual(
            CandidateEchoTailTrimmer.trim(candidateText: candidate, interviewerText: interviewer),
            "我会先说明项目目标和我的核心决策。"
        )
    }

    func testRemovesHighSimilarityEnglishEchoFromNaturalBoundary() {
        let interviewer = "Could you walk me through the pricing project and explain your specific contribution?"
        let candidate = "I would start with the customer impact. Could you walk me through pricing project and explain your specific contributions?"

        XCTAssertEqual(
            CandidateEchoTailTrimmer.trim(candidateText: candidate, interviewerText: interviewer),
            "I would start with the customer impact."
        )
    }

    func testDoesNotRemoveShortFeedbackEvenWhenItMatchesExactly() {
        XCTAssertEqual(
            CandidateEchoTailTrimmer.trim(candidateText: "我的回答。好的", interviewerText: "好的"),
            "我的回答。好的"
        )
    }

    func testDoesNotChangeDistinctCandidateAnswer() {
        let interviewer = "请介绍一下你负责的 AI 项目以及最终结果。"
        let candidate = "我负责需求拆解和交付管理，试点完成后再根据用户反馈迭代。"

        XCTAssertEqual(
            CandidateEchoTailTrimmer.trim(candidateText: candidate, interviewerText: interviewer),
            candidate
        )
    }

    func testReturnsEmptyWhenEntireCandidateTranscriptIsLongEcho() {
        let echo = "Could you explain how you measured the final project outcome?"
        XCTAssertEqual(
            CandidateEchoTailTrimmer.trim(candidateText: echo, interviewerText: echo),
            ""
        )
    }
}
