import XCTest
@testable import LiveInterviewCopilotKit

final class QuestionRiskHighlighterTests: XCTestCase {
    func testHighlightsDomainAndEnglishTermsWithoutFragmentingSentence() {
        let question = "资源减半时你会如何重新排列产品优先级，并解释ROI和OKR？"
        let highlights = QuestionRiskHighlighter.highlights(in: question, knowledgeTerms: [])

        let texts = highlights.map(\.text)
        XCTAssertTrue(texts.contains("排列") || texts.contains("优先级"))
        XCTAssertTrue(texts.contains { $0.uppercased() == "ROI" })
        XCTAssertTrue(texts.contains { $0.uppercased() == "OKR" })
        XCTAssertLessThanOrEqual(highlights.count, 4)

        // Function words should not dominate highlights.
        XCTAssertFalse(texts.contains("如何"))
        XCTAssertFalse(texts.contains("你会"))
    }

    func testKnowledgeEntityAndCandidatesPreferCanonicalForms() {
        let question = "请说明大匠在核保场景的ROI怎么算"
        let highlights = QuestionRiskHighlighter.highlights(
            in: question,
            knowledgeTerms: ["大疆", "核保"]
        )
        let texts = highlights.map(\.text)
        XCTAssertTrue(texts.contains("大匠") || texts.contains("大疆") || texts.contains("ROI"))

        let roiCandidates = QuestionRiskHighlighter.candidates(for: "肉眼", knowledgeTerms: ["ROI"])
        XCTAssertTrue(roiCandidates.contains("ROI"))

        let arrangeCandidates = QuestionRiskHighlighter.candidates(for: "排列", knowledgeTerms: [])
        XCTAssertTrue(arrangeCandidates.contains("排定") || arrangeCandidates.contains("重排"))
        XCTAssertLessThanOrEqual(arrangeCandidates.count, 3)
    }

    func testNoHighlightsForEmptyQuestion() {
        XCTAssertTrue(QuestionRiskHighlighter.highlights(in: "   ").isEmpty)
    }

    func testHighlightsEnglishTokensAdjacentToCJK() {
        let question = "介绍下你自己做过的agent和做的JSB"
        let highlights = QuestionRiskHighlighter.highlights(in: question, knowledgeTerms: [])
        let texts = highlights.map { $0.text.lowercased() }
        XCTAssertTrue(texts.contains("agent"))
        XCTAssertTrue(texts.contains("jsb"))
        XCTAssertLessThanOrEqual(highlights.count, 4)
    }
}
