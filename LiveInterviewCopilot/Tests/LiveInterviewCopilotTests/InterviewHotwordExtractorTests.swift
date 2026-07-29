import Foundation
import XCTest
@testable import LiveInterviewCopilotKit

final class InterviewHotwordExtractorTests: XCTestCase {
    func testManualTermsWinDuplicatesAndUseManualWeight() {
        let snapshot = makeSnapshot(
            sourceTitle: "Qwen3-ASR",
            heading: "Realtime ASR"
        )

        let hotwords = InterviewHotwordExtractor.extract(
            manualTerms: ["Qwen3-ASR", "qwen3-asr", "RAG|11"],
            snapshot: snapshot
        )

        XCTAssertEqual(hotwords.first?.phrase, "Qwen3ASR")
        XCTAssertEqual(hotwords.first?.weight, 10)
        XCTAssertEqual(hotwords.first?.source, .manual)
        XCTAssertEqual(hotwords.filter { $0.phrase.lowercased() == "qwen3asr" }.count, 1)
        XCTAssertEqual(hotwords.first(where: { $0.phrase == "RAG" })?.weight, 11)
    }

    func testKnowledgeTermsUseLowerWeightAndIncludeTechnicalHeadings() {
        let snapshot = makeSnapshot(
            sourceTitle: "AI项目经理",
            heading: "Qwen3-ASR 与 RAG 交付方案"
        )

        let hotwords = InterviewHotwordExtractor.extract(manualTerms: [], snapshot: snapshot)

        XCTAssertTrue(hotwords.contains {
            $0.phrase == "AI项目经理" && $0.weight == 5 && $0.source == .knowledgePackage
        })
        XCTAssertTrue(hotwords.contains {
            $0.phrase == "Qwen3ASR" && $0.weight == 5 && $0.source == .knowledgePackage
        })
        XCTAssertTrue(hotwords.contains {
            $0.phrase == "RAG" && $0.weight == 5 && $0.source == .knowledgePackage
        })
    }

    func testCapsCombinedHotwordListAtTencentLimit() {
        let terms = (0..<140).map { "Term\($0)" }
        let hotwords = InterviewHotwordExtractor.extract(
            manualTerms: terms,
            snapshot: makeSnapshot(sourceTitle: "ExtraTerm", heading: nil),
            maximumCount: 500
        )

        XCTAssertEqual(hotwords.count, 128)
        XCTAssertTrue(hotwords.allSatisfy { $0.source == .manual })
    }

    func testTencentParameterContainsOnlyValidatedWeightedTerms() {
        let value = InterviewHotwordExtractor.tencentParameterValue([
            InterviewHotword(phrase: "Qwen3-ASR", weight: 10, source: .manual),
            InterviewHotword(phrase: "RAG", weight: 5, source: .knowledgePackage),
            InterviewHotword(phrase: "x", weight: 10, source: .manual),
        ])

        XCTAssertEqual(value, "Qwen3ASR|10,RAG|5")
    }

    func testTencentParameterRemovesInternalPunctuationAndSpecialCharacters() {
        let value = InterviewHotwordExtractor.tencentParameterValue([
            InterviewHotword(phrase: "AI 项目经理（国际）/交付", weight: 10, source: .manual),
            InterviewHotword(phrase: "API-2.0", weight: 5, source: .knowledgePackage),
        ])

        XCTAssertEqual(value, "AI项目经理国际交付|10,API20|5")
    }

    private func makeSnapshot(
        sourceTitle: String,
        heading: String?
    ) -> KnowledgePackageSnapshot {
        let source = KnowledgeSource(
            id: "SRC-001",
            relativePath: "05-domain/terms.md",
            title: sourceTitle,
            contentHash: "source-hash",
            modifiedAt: Date(timeIntervalSince1970: 0),
            category: .domain
        )
        let block = KnowledgeBlock(
            id: "SRC-001-B001",
            sourceID: source.id,
            heading: heading,
            location: "line 1",
            text: "熟悉 Qwen3-ASR、RAG、LLMOps 和 API2.0。"
        )
        return KnowledgePackageSnapshot(
            version: "v1",
            hash: "package-hash",
            compiledAt: Date(timeIntervalSince1970: 0),
            sources: [source],
            blocks: [block],
            text: block.text,
            characterCount: block.text.count,
            estimatedTokenCount: 20,
            failedFiles: []
        )
    }
}
