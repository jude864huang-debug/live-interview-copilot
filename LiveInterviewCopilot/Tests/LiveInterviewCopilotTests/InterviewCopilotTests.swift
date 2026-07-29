import XCTest
@testable import LiveInterviewCopilotKit

@MainActor
final class InterviewCopilotTests: XCTestCase {
    func testQuestionClassifierCoversProductBusinessInterviewShapes() {
        XCTAssertEqual(InterviewQuestionClassifier.classify("请先做一个自我介绍"), .selfIntroduction)
        XCTAssertEqual(InterviewQuestionClassifier.classify("讲讲你在这个项目中具体负责什么"), .projectDeepDive)
        XCTAssertEqual(InterviewQuestionClassifier.classify("请设计一个面向老年人的支付产品"), .productCase)
        XCTAssertEqual(InterviewQuestionClassifier.classify("为什么当时选择这个指标？"), .followUp)
        XCTAssertEqual(InterviewQuestionClassifier.classify("How would you size this market?"), .businessAnalysis)
    }

    func testLocalSkeletonNeverInventsCandidateEvidence() {
        let cue = InterviewCue.localSkeleton(for: "说一个你处理团队冲突的例子")
        XCTAssertEqual(cue.questionType, .behavioral)
        XCTAssertTrue(cue.evidenceAnchors.isEmpty)
        XCTAssertEqual(cue.confidence, "low")
        XCTAssertTrue(cue.missingFacts.isEmpty)
        XCTAssertEqual(cue.directOpening, "面对这类情况，我会先对齐目标和事实，再推动行动并复盘结果。")
        XCTAssertTrue((3...5).contains(cue.talkingPoints.count))
    }

    func testEveryLocalSkeletonOpeningIsDirectlySpeakableAndHasNoWarning() {
        let questions = [
            "请先做一个自我介绍",
            "为什么选择这个岗位",
            "说一个你处理团队冲突的例子",
            "讲讲你在这个项目中具体负责什么",
            "请设计一个新产品",
            "How would you size this market?",
            "请解释一下模型评估方法",
            "为什么当时选择这个指标？",
            "你怎么看这个问题",
        ]

        for question in questions {
            let cue = InterviewCue.localSkeleton(for: question)
            XCTAssertFalse(cue.directOpening.isEmpty, question)
            XCTAssertFalse(cue.directOpening.hasPrefix("先"), question)
            XCTAssertTrue(cue.missingFacts.isEmpty, question)
        }
    }

    func testDefaultPromptRequiresAUsefulAnswerWithoutInventingPastExperience() {
        let prompt = CustomerCopilotEngine.defaultPrompt

        XCTAssertTrue(prompt.contains("无论是否存在候选人的个人材料，都必须给出"))
        XCTAssertTrue(prompt.contains("允许使用“我会”“我的判断是”“如果由我负责”"))
        XCTAssertTrue(prompt.contains("过去发生的候选人经历"))
        XCTAssertFalse(prompt.contains("材料不足时必须"))
        XCTAssertFalse(prompt.contains("missingFacts 中写明“待补充，勿声称”"))
    }
}
