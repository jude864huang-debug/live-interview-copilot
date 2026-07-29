import AppKit
import Foundation
import XCTest
@testable import LiveInterviewCopilotKit

final class InterviewLensPaginatorTests: XCTestCase {
    func testSelectionPersistenceAndCodableRoundTripPreserveFollowUpQuestion() throws {
        let selections: [InterviewLensSelection] = [
            .question,
            .answer,
            .quickIdea,
            .referenceAnswer,
            .followUps,
            .followUpAnswer(question: "Why this role？为什么现在加入？"),
        ]

        for selection in selections {
            XCTAssertEqual(
                InterviewLensSelection(persistenceID: selection.persistenceID),
                selection
            )
            let data = try JSONEncoder().encode(selection)
            XCTAssertEqual(try JSONDecoder().decode(InterviewLensSelection.self, from: data), selection)
        }
    }

    func testExactCharacterCounts43_66_114_144_234RemainLossless() {
        let configuration = InterviewLensPaginator.Configuration(
            fontSize: 20,
            width: 190,
            height: 120,
            lineSpacing: 3
        )

        for length in [43, 66, 114, 144, 234] {
            let text = patternedChineseText(length: length)
            let unit = InterviewLensSemanticUnit(
                id: "length-\(length)",
                kind: .referenceSegment,
                text: text,
                label: "第 \(length) 字测试"
            )
            let pages = InterviewLensPaginator.paginate(
                units: [unit],
                configuration: configuration
            )

            XCTAssertFalse(pages.isEmpty, "length \(length)")
            XCTAssertLessThanOrEqual(pages.count, 12, "length \(length)")
            XCTAssertNil(pages.last?.overflow, "length \(length) should fit within 12 pages")
            assertLossless(units: [unit], pages: pages)
        }
    }

    func testConfigured43By66And114By144BoundsRemainLossless() {
        let text = "窄窗口 mixed English words 与中文字符不会丢失。"
        let unit = InterviewLensSemanticUnit(
            id: "geometry",
            kind: .quickIdea,
            text: text
        )
        let configurations = [
            InterviewLensPaginator.Configuration(fontSize: 13, width: 43, height: 66),
            InterviewLensPaginator.Configuration(fontSize: 20, width: 114, height: 144),
        ]

        for configuration in configurations {
            let pages = InterviewLensPaginator.paginate(
                units: [unit],
                configuration: configuration
            )
            XCTAssertFalse(pages.isEmpty)
            assertLossless(units: [unit], pages: pages)
        }
    }

    func testStartNewPageKeepsSemanticUnitsIntact() {
        let units = [
            InterviewLensSemanticUnit(
                id: "opening",
                kind: .directOpening,
                text: "先给出直接结论。",
                label: "开场"
            ),
            InterviewLensSemanticUnit(
                id: "example",
                kind: .sampleAnswer,
                text: "然后补充一个具体项目示例。",
                label: "示例回答",
                startNewPage: true
            ),
        ]
        let pages = InterviewLensPaginator.paginate(
            units: units,
            configuration: .init(fontSize: 18, width: 400, height: 200)
        )

        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].items.map(\.unitID), ["opening"])
        XCTAssertEqual(pages[1].items.map(\.unitID), ["example"])
        XCTAssertFalse(pages[0].continuation.continuesUnitOnNextPage)
        XCTAssertFalse(pages[1].continuation.continuesUnitFromPrevious)
        assertLossless(units: units, pages: pages)
    }

    func testOversizedSemanticCardsPaginateWithoutInnerScrolling() throws {
        let opening = InterviewLensSemanticUnit(
            id: "answer.entry",
            kind: .directOpening,
            text: String(repeating: "先把结论完整说清楚，再补充判断依据。", count: 12),
            label: "先说这句"
        )
        let configuration = InterviewLensPaginator.Configuration(
            fontSize: 36,
            width: 150,
            height: 60,
            lineSpacing: 8
        )

        let pages = InterviewLensPaginator.paginate(
            units: [opening],
            configuration: configuration
        )

        let page = try XCTUnwrap(pages.first)
        let item = try XCTUnwrap(page.items.first)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertFalse(item.continuesFromPrevious)
        XCTAssertTrue(item.continuesToNext)
        XCTAssertFalse(page.continuation.continuesUnitFromPrevious)
        XCTAssertTrue(page.continuation.continuesUnitOnNextPage)
        assertLossless(units: [opening], pages: pages)

        var ordinaryPoint = opening
        ordinaryPoint.id = "answer.spine.p1"
        ordinaryPoint.kind = .talkingPoint
        ordinaryPoint.label = "逻辑主线"
        ordinaryPoint.anchor = InterviewLensTextAnchor(
            sourceID: ordinaryPoint.id,
            lowerBound: 0,
            upperBound: ordinaryPoint.text.count
        )
        let ordinaryPages = InterviewLensPaginator.paginate(
            units: [ordinaryPoint],
            configuration: configuration
        )
        XCTAssertGreaterThan(ordinaryPages.count, 1)
        assertLossless(units: [ordinaryPoint], pages: ordinaryPages)

        ordinaryPoint.startNewPage = true
        let semanticCardPages = InterviewLensPaginator.paginate(
            units: [ordinaryPoint],
            configuration: configuration
        )
        XCTAssertGreaterThan(semanticCardPages.count, 1)
        assertLossless(units: [ordinaryPoint], pages: semanticCardPages)
    }

    func testMixedChineseEnglishSplitsOnSemanticBoundariesWithoutMutation() {
        let text = "First align the goal；再确认 success metrics! 然后 compare trade-offs？最后用 A/B test 验证。"
        let unit = InterviewLensSemanticUnit(
            id: "mixed",
            kind: .referenceSegment,
            text: text,
            label: "中英混排"
        )
        let pages = InterviewLensPaginator.paginate(
            units: [unit],
            configuration: .init(fontSize: 22, width: 178, height: 74)
        )

        XCTAssertGreaterThan(pages.count, 1)
        assertLossless(units: [unit], pages: pages)
        XCTAssertTrue(allItems(in: pages).dropLast().allSatisfy {
            $0.text.last.map { "。！？!?；;".contains($0) } == true
                || $0.continuesToNext
        })
    }

    func testUnpunctuatedEnglishWordAndChineseCharactersFallBackWithoutLoss() {
        let text = String(repeating: "extraordinarilylongword", count: 5)
            + String(repeating: "无标点中文内容", count: 12)
        let unit = InterviewLensSemanticUnit(
            id: "no-punctuation",
            kind: .sampleAnswer,
            text: text
        )
        let pages = InterviewLensPaginator.paginate(
            units: [unit],
            configuration: .init(fontSize: 18, width: 126, height: 68)
        )

        XCTAssertGreaterThan(pages.count, 1)
        assertLossless(units: [unit], pages: pages)
    }

    func testNewlinesIncludingBlankLineArePreservedExactly() {
        let text = "第一行保留换行。\nSecond line remains exact.\n\n第四行也不能被 trim；\n"
        let unit = InterviewLensSemanticUnit(
            id: "newlines",
            kind: .referenceSegment,
            text: text
        )
        let pages = InterviewLensPaginator.paginate(
            units: [unit],
            configuration: .init(fontSize: 20, width: 170, height: 62)
        )

        XCTAssertGreaterThan(pages.count, 1)
        assertLossless(units: [unit], pages: pages)
        XCTAssertEqual(allText(includingOverflowFrom: pages), text)
    }

    func testTwoHundredPercentTextCreatesAtLeastAsManyPagesAndRemainsLossless() {
        let text = patternedChineseText(length: 144)
        let unit = InterviewLensSemanticUnit(
            id: "dynamic-type",
            kind: .followUpAnswer,
            text: text,
            label: "追问回答"
        )
        let normalPages = InterviewLensPaginator.paginate(
            units: [unit],
            configuration: .init(fontSize: 20, width: 320, height: 160)
        )
        let twoHundredPercentPages = InterviewLensPaginator.paginate(
            units: [unit],
            configuration: .init(fontSize: 40, width: 320, height: 160)
        )

        XCTAssertGreaterThanOrEqual(twoHundredPercentPages.count, normalPages.count)
        XCTAssertGreaterThan(twoHundredPercentPages.count, 1)
        assertLossless(units: [unit], pages: twoHundredPercentPages)
    }

    func testPaginatorMeasuresTheSameMediumWeightRenderedByQuickIdeas() {
        let text = String(repeating: "W", count: 12)
        let fontSize: CGFloat = 36
        let regular = NSFont.systemFont(ofSize: fontSize)
        let medium = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let regularWidth = (text as NSString).size(withAttributes: [.font: regular]).width
        let mediumWidth = (text as NSString).size(withAttributes: [.font: medium]).width
        XCTAssertGreaterThan(mediumWidth, regularWidth)

        let lineSpacing = max(0, fontSize * 1.4 - regular.boundingRectForFont.height)
        let pages = InterviewLensPaginator.paginate(
            units: [InterviewLensSemanticUnit(
                id: "weighted-quick-idea",
                kind: .quickIdea,
                text: text
            )],
            configuration: .init(
                fontSize: fontSize,
                width: (regularWidth + mediumWidth) / 2,
                height: ceil(fontSize * 1.4 + 1),
                lineSpacing: lineSpacing
            )
        )

        XCTAssertGreaterThan(pages.count, 1)
        assertLossless(units: [InterviewLensSemanticUnit(
            id: "weighted-quick-idea",
            kind: .quickIdea,
            text: text
        )], pages: pages)
    }

    func testMaximumTwelvePagesRetainsOverflowAndShowsMainWindowMessage() {
        let text = patternedChineseText(length: 2_000)
        let unit = InterviewLensSemanticUnit(
            id: "overflow",
            kind: .referenceSegment,
            text: text
        )
        let pages = InterviewLensPaginator.paginate(
            units: [unit],
            configuration: .init(fontSize: 24, width: 90, height: 52)
        )

        XCTAssertEqual(pages.count, 12)
        let overflow = pages.last?.overflow
        XCTAssertNotNil(overflow)
        XCTAssertTrue(overflow?.message.contains("主窗口") == true)
        XCTAssertGreaterThan(overflow?.remainingCharacterCount ?? 0, 0)
        assertLossless(units: [unit], pages: pages)
    }

    func testSnapshotPaginationUsesSnapshotUnitsAndPreservesMetadata() {
        let unit = InterviewLensSemanticUnit(
            id: "snapshot-unit",
            kind: .quickIdea,
            text: "结论明确，先讲目标，再讲行动与结果。"
        )
        let snapshot = InterviewLensSnapshot(
            turnToken: "turn-42",
            questionContext: "请介绍一个复杂项目",
            units: [unit],
            isFrozen: true,
            isStreaming: true,
            failure: InterviewLensFailure(message: "后台更新失败", recoverySuggestion: "保留稳定内容"),
            selection: .quickIdea
        )
        let pages = InterviewLensPaginator.paginate(
            snapshot: snapshot,
            configuration: .init(fontSize: 20, width: 300, height: 120)
        )

        XCTAssertEqual(snapshot.turnToken, "turn-42")
        XCTAssertTrue(snapshot.isFrozen)
        XCTAssertTrue(snapshot.isStreaming)
        XCTAssertEqual(snapshot.selection, .quickIdea)
        assertLossless(units: [unit], pages: pages)
    }

    private func assertLossless(
        units: [InterviewLensSemanticUnit],
        pages: [InterviewLensPage],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            allText(includingOverflowFrom: pages),
            units.map(\.text).joined(),
            "Page text must reconstruct every source Character exactly once",
            file: file,
            line: line
        )

        let outputItems = allItems(in: pages)
        for unit in units {
            let fragments = outputItems.filter { $0.unitID == unit.id }
            XCTAssertEqual(
                fragments.map(\.text).joined(),
                unit.text,
                "Unit \(unit.id) text mismatch",
                file: file,
                line: line
            )

            var expectedLowerBound = unit.anchor.lowerBound
            for fragment in fragments {
                XCTAssertEqual(
                    fragment.anchor.sourceID,
                    unit.anchor.sourceID,
                    file: file,
                    line: line
                )
                XCTAssertEqual(
                    fragment.anchor.lowerBound,
                    expectedLowerBound,
                    "Anchors must be contiguous and non-overlapping",
                    file: file,
                    line: line
                )
                XCTAssertEqual(fragment.anchor.length, fragment.text.count, file: file, line: line)
                expectedLowerBound = fragment.anchor.upperBound
            }
            XCTAssertEqual(
                expectedLowerBound,
                unit.anchor.lowerBound + unit.text.count,
                file: file,
                line: line
            )
        }

        for page in pages {
            XCTAssertEqual(page.textRangeAnchors, page.items.map(\.anchor), file: file, line: line)
        }
    }

    private func allItems(in pages: [InterviewLensPage]) -> [InterviewLensPageItem] {
        pages.flatMap(\.items) + (pages.last?.overflow?.remainingItems ?? [])
    }

    private func allText(includingOverflowFrom pages: [InterviewLensPage]) -> String {
        allItems(in: pages).map(\.text).joined()
    }

    private func patternedChineseText(length: Int) -> String {
        let pattern = Array("甲乙丙丁戊己庚辛壬癸天地玄黄宇宙洪荒")
        return String((0..<length).map { pattern[$0 % pattern.count] })
    }
}
