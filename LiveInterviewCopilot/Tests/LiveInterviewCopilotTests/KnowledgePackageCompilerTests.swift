import AppKit
import XCTest
@testable import LiveInterviewCopilotKit

final class KnowledgePackageCompilerTests: XCTestCase {
    @MainActor
    func testCompilesSupportedDocumentsAndKeepsStableSourceIDs() async throws {
        let root = temporaryDirectory()
        let source = root.appendingPathComponent("knowledge", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let markdownURL = source.appendingPathComponent("policy.md")
        try "# 退款政策\n客户在七天内可以申请退款。".write(to: markdownURL, atomically: true, encoding: .utf8)
        try "人工客服工作时间为 9:00 至 18:00。".write(
            to: source.appendingPathComponent("hours.txt"),
            atomically: true,
            encoding: .utf8
        )
        try makePDF(text: "产品 A 的保修期为一年。", at: source.appendingPathComponent("product.pdf"))
        try makeDOCX(text: "升级服务需要客户确认。", at: source.appendingPathComponent("service.docx"))

        let compiler = KnowledgePackageCompiler(stateDirectory: state)
        await compiler.compile(folderURL: source)

        let first = try XCTUnwrap(compiler.snapshot)
        XCTAssertEqual(first.sources.count, 4)
        XCTAssertTrue(first.text.contains("客户在七天内可以申请退款"))
        XCTAssertTrue(first.text.contains("人工客服工作时间"))
        XCTAssertTrue(first.text.contains("产品 A 的保修期"))
        XCTAssertTrue(first.text.contains("升级服务需要客户确认"))
        XCTAssertGreaterThan(first.characterCount, 0)
        XCTAssertGreaterThan(first.estimatedTokenCount, 0)
        XCTAssertTrue(first.failedFiles.isEmpty)

        let firstID = try XCTUnwrap(first.sources.first(where: { $0.relativePath == "policy.md" })?.id)
        try "# 退款政策\n客户在十四天内可以申请退款。".write(to: markdownURL, atomically: true, encoding: .utf8)
        await compiler.compile(folderURL: source)

        let second = try XCTUnwrap(compiler.snapshot)
        XCTAssertEqual(second.sources.first(where: { $0.relativePath == "policy.md" })?.id, firstID)
        XCTAssertTrue(second.text.contains("十四天"))
        XCTAssertNotEqual(first.hash, second.hash)
    }

    @MainActor
    func testRejectsScannedPDFWithoutReplacingLastSuccessfulPackage() async throws {
        let root = temporaryDirectory()
        let source = root.appendingPathComponent("knowledge", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "可用知识".write(to: source.appendingPathComponent("valid.txt"), atomically: true, encoding: .utf8)

        let compiler = KnowledgePackageCompiler(stateDirectory: state)
        await compiler.compile(folderURL: source)
        let initialHash = try XCTUnwrap(compiler.snapshot?.hash)

        let blankView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        try blankView.dataWithPDF(inside: blankView.bounds).write(to: source.appendingPathComponent("scan.pdf"))
        await compiler.compile(folderURL: source)

        let package = try XCTUnwrap(compiler.snapshot)
        XCTAssertEqual(package.hash, initialHash)
        XCTAssertTrue(compiler.failedFiles.contains(where: { $0.contains("scan.pdf") }))
    }

    @MainActor
    func testClassifiesInterviewMaterialFoldersAndRestrictsCandidateEvidence() async throws {
        let root = temporaryDirectory()
        let source = root.appendingPathComponent("interview", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let resume = source.appendingPathComponent("01-resume", isDirectory: true)
        let jd = source.appendingPathComponent("03-job-description", isDirectory: true)
        try FileManager.default.createDirectory(at: resume, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jd, withIntermediateDirectories: true)
        try "# 简历\n我负责过支付产品。".write(to: resume.appendingPathComponent("resume.md"), atomically: true, encoding: .utf8)
        try "要求有五年风控经验。".write(to: jd.appendingPathComponent("jd.txt"), atomically: true, encoding: .utf8)

        let compiler = KnowledgePackageCompiler(stateDirectory: state)
        await compiler.compile(folderURL: source)
        let package = try XCTUnwrap(compiler.snapshot)
        XCTAssertEqual(package.categoryCounts[.resume], 1)
        XCTAssertEqual(package.categoryCounts[.jobDescription], 1)
        XCTAssertTrue(package.classificationWarnings.isEmpty)

        let resumeSource = try XCTUnwrap(package.sources.first { $0.effectiveCategory == .resume })
        let jdSource = try XCTUnwrap(package.sources.first { $0.effectiveCategory == .jobDescription })
        XCTAssertTrue(package.candidateFactCitationIDs.contains(resumeSource.id))
        XCTAssertFalse(package.candidateFactCitationIDs.contains(jdSource.id))
        XCTAssertTrue(package.text.contains("category: resume"))
        XCTAssertTrue(package.text.contains("category: job-description"))

        let brief = package.makeRealtimeBrief(maxTokens: 2_000)
        XCTAssertLessThanOrEqual(brief.estimatedTokenCount, 2_000)
        XCTAssertTrue(brief.text.contains("我负责过支付产品"))
        XCTAssertTrue(brief.text.contains("要求有五年风控经验"))
        XCTAssertFalse(brief.includedBlockIDs.isEmpty)
    }

    @MainActor
    func testIgnoresInterviewPackManagementFiles() async throws {
        let root = temporaryDirectory()
        let source = root.appendingPathComponent("interview", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let resume = source.appendingPathComponent("01-resume", isDirectory: true)
        try FileManager.default.createDirectory(at: resume, withIntermediateDirectories: true)
        try "# 基线履历\nAI 产品经理。".write(
            to: resume.appendingPathComponent("resume.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# 分类目录说明\n这份内容仍属于简历材料。".write(
            to: resume.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        for filename in ["interview-prep.md", "retro.md", "README.md"] {
            try "# 面试包管理文件".write(
                to: source.appendingPathComponent(filename),
                atomically: true,
                encoding: .utf8
            )
        }

        let compiler = KnowledgePackageCompiler(stateDirectory: state)
        await compiler.compile(folderURL: source)

        let package = try XCTUnwrap(compiler.snapshot)
        XCTAssertEqual(
            package.sources.map(\.relativePath),
            ["01-resume/README.md", "01-resume/resume.md"]
        )
        XCTAssertTrue(package.classificationWarnings.isEmpty)
    }

    func testCompactBriefSharesBudgetAcrossAllAvailableCategories() {
        let categories: [KnowledgeSourceCategory] = [
            .resume, .storyBank, .jobDescription, .company, .domain,
        ]
        let sources = categories.enumerated().map { index, category in
            KnowledgeSource(
                id: "KB\(index + 1)",
                relativePath: "\(category.rawValue)/material.md",
                title: category.label,
                contentHash: "hash-\(index)",
                modifiedAt: .now,
                category: category
            )
        }
        let blocks = sources.enumerated().map { index, source in
            KnowledgeBlock(
                id: "\(source.id):H001",
                sourceID: source.id,
                heading: source.title,
                location: "lines 1-100",
                text: "CATEGORY_MARKER_\(index) " + String(repeating: "内容", count: 8_000)
            )
        }
        let package = KnowledgePackageSnapshot(
            version: "test",
            hash: "test-hash",
            compiledAt: .now,
            sources: sources,
            blocks: blocks,
            text: "",
            characterCount: 0,
            estimatedTokenCount: 50_000,
            failedFiles: []
        )

        let brief = package.makeRealtimeBrief(maxTokens: 4_000)

        XCTAssertLessThanOrEqual(brief.estimatedTokenCount, 4_000)
        XCTAssertEqual(Set(brief.includedBlockIDs), Set(blocks.map(\.id)))
        for index in categories.indices {
            XCTAssertTrue(brief.text.contains("CATEGORY_MARKER_\(index)"))
        }
        XCTAssertTrue(brief.text.contains("excerpt truncated"))
    }

    private func temporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("KnowledgePackageCompilerTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    private func makePDF(text: String, at url: URL) throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 700))
        textView.string = text
        try textView.dataWithPDF(inside: textView.bounds).write(to: url)
    }

    private func makeDOCX(text: String, at url: URL) throws {
        let work = url.deletingLastPathComponent().appendingPathComponent("docx-work-\(UUID().uuidString)")
        let word = work.appendingPathComponent("word", isDirectory: true)
        try FileManager.default.createDirectory(at: word, withIntermediateDirectories: true)
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;")
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body><w:p><w:r><w:t>\(escaped)</w:t></w:r></w:p></w:body>
        </w:document>
        """
        try xml.write(to: word.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", url.path, "word"]
        zip.currentDirectoryURL = work
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        try? FileManager.default.removeItem(at: work)
    }
}
