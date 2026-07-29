import CryptoKit
import Foundation
import Observation
import PDFKit

enum KnowledgeSourceCategory: String, Codable, CaseIterable, Sendable {
    case resume
    case storyBank = "story-bank"
    case jobDescription = "job-description"
    case company
    case domain
    case uncategorized

    var label: String {
        switch self {
        case .resume: "简历"
        case .storyBank: "经历库"
        case .jobDescription: "岗位 JD"
        case .company: "公司资料"
        case .domain: "领域知识"
        case .uncategorized: "未分类"
        }
    }

    var canSupportCandidateFact: Bool { self == .resume || self == .storyBank }

    static func infer(from relativePath: String) -> KnowledgeSourceCategory {
        let first = relativePath.split(separator: "/").first.map(String.init)?.lowercased() ?? ""
        if first.contains("resume") || first.contains("简历") { return .resume }
        if first.contains("story") || first.contains("经历") || first.contains("案例库") { return .storyBank }
        if first.contains("job-description") || first == "jd" || first.contains("岗位") { return .jobDescription }
        if first.contains("company") || first.contains("公司") { return .company }
        if first.contains("domain") || first.contains("领域") || first.contains("专业") { return .domain }
        return .uncategorized
    }
}

struct KnowledgeSource: Codable, Equatable, Sendable {
    let id: String
    let relativePath: String
    let title: String
    let contentHash: String
    let modifiedAt: Date
    let category: KnowledgeSourceCategory?

    var effectiveCategory: KnowledgeSourceCategory {
        category ?? KnowledgeSourceCategory.infer(from: relativePath)
    }
}

struct KnowledgeBlock: Codable, Equatable, Sendable {
    let id: String
    let sourceID: String
    let heading: String?
    let location: String
    let text: String
}

struct KnowledgePackageSnapshot: Codable, Equatable, Sendable {
    let version: String
    let hash: String
    let compiledAt: Date
    let sources: [KnowledgeSource]
    let blocks: [KnowledgeBlock]
    let text: String
    let characterCount: Int
    let estimatedTokenCount: Int
    let failedFiles: [String]

    var validCitationIDs: Set<String> {
        Set(sources.map(\.id)).union(blocks.map(\.id))
    }

    var candidateFactCitationIDs: Set<String> {
        let sourceIDs = Set(sources.filter { $0.effectiveCategory.canSupportCandidateFact }.map(\.id))
        return sourceIDs.union(blocks.filter { sourceIDs.contains($0.sourceID) }.map(\.id))
    }

    var categoryCounts: [KnowledgeSourceCategory: Int] {
        Dictionary(grouping: sources, by: \.effectiveCategory).mapValues(\.count)
    }

    var classificationWarnings: [String] {
        sources.filter { $0.effectiveCategory == .uncategorized }
            .map { "\($0.relativePath)：未放入约定的分类子文件夹，不能作为候选人经历依据。" }
    }
}

struct RealtimeInterviewBrief: Codable, Equatable, Sendable {
    let version: String
    let hash: String
    let text: String
    let characterCount: Int
    let estimatedTokenCount: Int
    let includedBlockIDs: [String]
}

extension KnowledgePackageSnapshot {
    /// Builds a compact, source-preserving deterministic prefix. The budget is
    /// shared across every available category so a long resume/story file cannot
    /// silently crowd the JD, company and domain context out of the prompt.
    func makeRealtimeBrief(maxTokens: Int = 8_000, question: String? = nil) -> RealtimeInterviewBrief {
        let sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let weightedCategories: [(category: KnowledgeSourceCategory, weight: Int)] = [
            (.resume, 45),
            (.storyBank, 30),
            (.jobDescription, 12),
            (.company, 7),
            (.domain, 6),
        ]
        let presentCategories = weightedCategories.filter { item in
            blocks.contains { sourceByID[$0.sourceID]?.effectiveCategory == item.category }
        }
        let totalWeight = max(1, presentCategories.reduce(0) { $0 + $1.weight })
        let maxUTF8Bytes = max(1_500, maxTokens * 3)
        var output = "# REALTIME INTERVIEW BRIEF\n"
        var included: [String] = []
        let availableBodyBytes = max(0, maxUTF8Bytes - output.utf8.count)

        for (index, item) in presentCategories.enumerated() {
            let remainingGlobalBytes = maxUTF8Bytes - output.utf8.count
            guard remainingGlobalBytes > 0 else { break }
            let weightedBudget = Int(
                floor(Double(availableBodyBytes) * Double(item.weight) / Double(totalWeight))
            )
            let sectionBudget = index == presentCategories.index(before: presentCategories.endIndex)
                ? remainingGlobalBytes
                : min(weightedBudget, remainingGlobalBytes)
            let heading = "\n## \(item.category.label)\n"
            guard sectionBudget > heading.utf8.count + 96 else { continue }
            var section = heading
            var sectionBlockIDs: [String] = []
            let categoryBlocks = blocks
                .filter { sourceByID[$0.sourceID]?.effectiveCategory == item.category }
                .sorted { lhs, rhs in
                    let lhsScore = Self.relevanceScore(
                        block: lhs,
                        source: sourceByID[lhs.sourceID],
                        question: question
                    )
                    let rhsScore = Self.relevanceScore(
                        block: rhs,
                        source: sourceByID[rhs.sourceID],
                        question: question
                    )
                    if lhsScore != rhsScore { return lhsScore > rhsScore }
                    return lhs.sourceID == rhs.sourceID ? lhs.id < rhs.id : lhs.sourceID < rhs.sourceID
                }
            for block in categoryBlocks {
                let source = sourceByID[block.sourceID]
                let metadata = "\n[\(block.id)] source=\(source?.relativePath ?? block.sourceID) location=\(block.location)\n"
                let fullEntry = "\(metadata)\(block.text)\n"
                let remainingSectionBytes = sectionBudget - section.utf8.count
                guard remainingSectionBytes > metadata.utf8.count + 64 else { break }
                if fullEntry.utf8.count <= remainingSectionBytes {
                    section += fullEntry
                } else {
                    let marker = "\n…[excerpt truncated]\n"
                    let textBudget = remainingSectionBytes - metadata.utf8.count - marker.utf8.count
                    let excerpt = Self.utf8Prefix(block.text, maxBytes: textBudget)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !excerpt.isEmpty else { break }
                    section += "\(metadata)\(excerpt)\(marker)"
                }
                sectionBlockIDs.append(block.id)
                if section.utf8.count >= sectionBudget - 64 { break }
            }
            if !sectionBlockIDs.isEmpty {
                output += section
                included.append(contentsOf: sectionBlockIDs)
            }
        }

        let digest = SHA256.hash(data: Data(output.utf8)).map { String(format: "%02x", $0) }.joined()
        return RealtimeInterviewBrief(
            version: version,
            hash: digest,
            text: output,
            characterCount: output.count,
            estimatedTokenCount: max(1, Int(ceil(Double(output.utf8.count) / 3.0))),
            includedBlockIDs: included
        )
    }

    private static func utf8Prefix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var end = text.startIndex
        var byteCount = 0
        while end < text.endIndex {
            let next = text.index(after: end)
            let characterBytes = text[end..<next].utf8.count
            guard byteCount + characterBytes <= maxBytes else { break }
            byteCount += characterBytes
            end = next
        }
        return String(text[..<end])
    }

    private static func relevanceScore(
        block: KnowledgeBlock,
        source: KnowledgeSource?,
        question: String?
    ) -> Int {
        guard let question, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return 0
        }
        let terms = relevanceTerms(in: question)
        guard !terms.isEmpty else { return 0 }
        let title = "\(source?.title ?? "") \(source?.relativePath ?? "")".lowercased()
        let heading = (block.heading ?? "").lowercased()
        let body = block.text.lowercased()
        return terms.reduce(into: 0) { score, term in
            if title.contains(term) { score += 6 }
            if heading.contains(term) { score += 5 }
            if body.contains(term) { score += term.count >= 4 ? 3 : 1 }
        }
    }

    private static func relevanceTerms(in text: String) -> Set<String> {
        let lowered = text.lowercased()
        var terms = Set(
            lowered.split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 2 }
        )
        let hanRuns = lowered.split { character in
            !character.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains(Int($0.value)) }
        }
        for run in hanRuns {
            let characters = Array(run)
            guard characters.count >= 2 else { continue }
            for width in 2...min(4, characters.count) {
                for start in 0...(characters.count - width) {
                    terms.insert(String(characters[start..<(start + width)]))
                }
            }
        }
        return terms
    }
}

enum KnowledgeCompilationStatus: Equatable, Sendable {
    case idle
    case compiling
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Not compiled"
        case .compiling: "Compiling…"
        case .ready: "Ready"
        case .failed(let message): "Failed: \(message)"
        }
    }
}

@Observable
@MainActor
final class KnowledgePackageCompiler {
    nonisolated private static let ignoredKnowledgeFilenames = Set([
        "interview-prep.md",
        "readme.md",
        "retro.md",
    ])

    private(set) var snapshot: KnowledgePackageSnapshot?
    private(set) var status: KnowledgeCompilationStatus = .idle
    private(set) var lastCompileDuration: TimeInterval?
    private(set) var failedFiles: [String] = []

    var realtimeBrief: RealtimeInterviewBrief? { snapshot?.makeRealtimeBrief() }

    private let stateDirectory: URL
    private let sourceMapURL: URL
    private let packageURL: URL
    private var watchedFolder: URL?
    @ObservationIgnored nonisolated(unsafe) private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored nonisolated(unsafe) private var watcherFileDescriptor: Int32 = -1
    private var debounceTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var lastObservedFingerprint = ""

    init(stateDirectory: URL) {
        self.stateDirectory = stateDirectory.appendingPathComponent("copilot", isDirectory: true)
        self.sourceMapURL = self.stateDirectory.appendingPathComponent("knowledge-source-map.json")
        self.packageURL = self.stateDirectory.appendingPathComponent("knowledge-package.json")
        try? FileManager.default.createDirectory(at: self.stateDirectory, withIntermediateDirectories: true)
        loadLastSuccessfulSnapshot()
    }

    deinit {
        watcher?.cancel()
        if watcherFileDescriptor >= 0 { close(watcherFileDescriptor) }
    }

    func watch(folderURL: URL?) {
        stopWatching()
        guard let folderURL else { return }
        watchedFolder = folderURL
        watcherFileDescriptor = open(folderURL.path, O_EVTONLY)
        guard watcherFileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watcherFileDescriptor,
            eventMask: [.write, .rename, .delete, .extend],
            // KnowledgePackageCompiler is main-actor isolated. Dispatch source
            // handlers inherit that isolation, so running cancellation on a
            // global queue trips Swift's executor check when a folder is
            // selected again or the compiler is torn down.
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleRecompile()
        }
        source.setCancelHandler { [fd = watcherFileDescriptor] in
            if fd >= 0 { close(fd) }
        }
        watcher = source
        source.resume()
        lastObservedFingerprint = Self.folderFingerprint(folderURL)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, let folder = self.watchedFolder else { return }
                let fingerprint = await Task.detached(priority: .utility) {
                    Self.folderFingerprint(folder)
                }.value
                guard fingerprint != self.lastObservedFingerprint else { continue }
                self.lastObservedFingerprint = fingerprint
                self.scheduleRecompile()
            }
        }
        Task { await compile(folderURL: folderURL) }
    }

    func compile(folderURL: URL) async {
        status = .compiling
        let startedAt = Date()
        let existingMap = loadSourceMap()
        let nextNumber = (existingMap.values.compactMap(Self.numericSourceID).max() ?? 0) + 1

        do {
            let result = try await Task.detached(priority: .utility) {
                try Self.buildPackage(folderURL: folderURL, existingMap: existingMap, nextNumber: nextNumber)
            }.value
            guard result.snapshot.failedFiles.isEmpty else {
                failedFiles = result.snapshot.failedFiles
                status = .failed("One or more documents could not be compiled; the last successful package is still active.")
                lastCompileDuration = Date().timeIntervalSince(startedAt)
                return
            }
            try persist(snapshot: result.snapshot, sourceMap: result.sourceMap)
            snapshot = result.snapshot
            failedFiles = []
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
        }
        lastCompileDuration = Date().timeIntervalSince(startedAt)
    }

    private func scheduleRecompile() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled, let self, let folder = self.watchedFolder else { return }
            await self.compile(folderURL: folder)
        }
    }

    private func stopWatching() {
        debounceTask?.cancel()
        debounceTask = nil
        pollTask?.cancel()
        pollTask = nil
        watcher?.cancel()
        watcher = nil
        watcherFileDescriptor = -1
        watchedFolder = nil
    }

    private func loadLastSuccessfulSnapshot() {
        guard let data = try? Data(contentsOf: packageURL),
              let saved = try? JSONDecoder.copilot.decode(KnowledgePackageSnapshot.self, from: data) else { return }
        snapshot = saved
        failedFiles = []
        status = .ready
    }

    private func loadSourceMap() -> [String: String] {
        guard let data = try? Data(contentsOf: sourceMapURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    private func persist(snapshot: KnowledgePackageSnapshot, sourceMap: [String: String]) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder.copilot
        try encoder.encode(sourceMap).write(to: sourceMapURL, options: .atomic)
        try encoder.encode(snapshot).write(to: packageURL, options: .atomic)
    }

    private struct BuildResult: Sendable {
        let snapshot: KnowledgePackageSnapshot
        let sourceMap: [String: String]
    }

    nonisolated private static func buildPackage(
        folderURL: URL,
        existingMap: [String: String],
        nextNumber: Int
    ) throws -> BuildResult {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw CompilerError.unreadableFolder }

        let extensions = Set(["md", "markdown", "txt", "pdf", "docx"])
        let files = enumerator.compactMap { $0 as? URL }.filter { url in
            extensions.contains(url.pathExtension.lowercased())
                && !url.lastPathComponent.hasPrefix("~$")
                && !isIgnoredKnowledgeFile(url, relativeTo: folderURL)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        var sourceMap = existingMap
        var number = nextNumber
        var sources: [KnowledgeSource] = []
        var blocks: [KnowledgeBlock] = []
        var failures: [String] = []

        for file in files {
            let relative = relativePath(of: file, to: folderURL)
            let sourceID: String
            if let existing = sourceMap[relative] {
                sourceID = existing
            } else {
                sourceID = String(format: "KB%03d", number)
                sourceMap[relative] = sourceID
                number += 1
            }

            do {
                let data = try Data(contentsOf: file)
                let hash = sha256(data)
                let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
                let title = file.deletingPathExtension().lastPathComponent
                let parsed = try parse(file: file, sourceID: sourceID, data: data)
                sources.append(KnowledgeSource(
                    id: sourceID,
                    relativePath: relative,
                    title: parsed.title ?? title,
                    contentHash: hash,
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    category: KnowledgeSourceCategory.infer(from: relative)
                ))
                blocks.append(contentsOf: parsed.blocks)
            } catch {
                failures.append("\(relative): \(error.localizedDescription)")
            }
        }

        sources.sort { $0.id < $1.id }
        blocks.sort { lhs, rhs in lhs.sourceID == rhs.sourceID ? lhs.id < rhs.id : lhs.sourceID < rhs.sourceID }
        let compiledAt = Date()
        let body = render(sources: sources, blocks: blocks)
        let bodyHash = sha256(Data(body.utf8))
        let formatter = ISO8601DateFormatter()
        let snapshot = KnowledgePackageSnapshot(
            version: formatter.string(from: compiledAt),
            hash: bodyHash,
            compiledAt: compiledAt,
            sources: sources,
            blocks: blocks,
            text: body,
            characterCount: body.count,
            estimatedTokenCount: estimateTokens(body),
            failedFiles: failures
        )
        return BuildResult(snapshot: snapshot, sourceMap: sourceMap)
    }

    private struct ParsedFile {
        let title: String?
        let blocks: [KnowledgeBlock]
    }

    nonisolated private static func parse(file: URL, sourceID: String, data: Data) throws -> ParsedFile {
        switch file.pathExtension.lowercased() {
        case "md", "markdown": return parseMarkdown(data: data, sourceID: sourceID)
        case "txt": return parseText(data: data, sourceID: sourceID)
        case "pdf": return try parsePDF(url: file, sourceID: sourceID)
        case "docx": return try parseDOCX(url: file, sourceID: sourceID)
        default: throw CompilerError.unsupportedFormat
        }
    }

    nonisolated private static func parseMarkdown(data: Data, sourceID: String) -> ParsedFile {
        let text = decodeText(data)
        let lines = text.components(separatedBy: .newlines)
        var title: String?
        var heading = "Document"
        var blockStart = 1
        var buffer: [String] = []
        var output: [KnowledgeBlock] = []
        var blockNumber = 1

        func flush(endLine: Int) {
            let cleaned = cleanParagraphs(buffer)
            guard !cleaned.isEmpty else { return }
            output.append(KnowledgeBlock(
                id: String(format: "%@:H%03d", sourceID, blockNumber),
                sourceID: sourceID,
                heading: heading,
                location: "lines \(blockStart)-\(max(blockStart, endLine))",
                text: cleaned
            ))
            blockNumber += 1
        }

        for (offset, line) in lines.enumerated() {
            let lineNumber = offset + 1
            if line.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) != nil {
                flush(endLine: lineNumber - 1)
                buffer.removeAll(keepingCapacity: true)
                heading = line.replacingOccurrences(of: #"^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if title == nil { title = heading }
                blockStart = lineNumber + 1
            } else {
                buffer.append(line)
            }
        }
        flush(endLine: lines.count)
        return ParsedFile(title: title, blocks: output)
    }

    nonisolated private static func parseText(data: Data, sourceID: String) -> ParsedFile {
        let lines = decodeText(data).components(separatedBy: .newlines)
        var blocks: [KnowledgeBlock] = []
        var start = 0
        var number = 1
        while start < lines.count {
            let end = min(start + 120, lines.count)
            let cleaned = cleanParagraphs(Array(lines[start..<end]))
            if !cleaned.isEmpty {
                blocks.append(KnowledgeBlock(
                    id: String(format: "%@:L%04d-L%04d", sourceID, start + 1, end),
                    sourceID: sourceID,
                    heading: nil,
                    location: "lines \(start + 1)-\(end)",
                    text: cleaned
                ))
                number += 1
            }
            start = end
        }
        return ParsedFile(title: nil, blocks: blocks)
    }

    nonisolated private static func parsePDF(url: URL, sourceID: String) throws -> ParsedFile {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw CompilerError.unreadablePDF }
        let pages = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        guard pages.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CompilerError.scannedPDF
        }
        let repeatedEdges = repeatedPDFEdgeLines(pages)
        let blocks = pages.enumerated().compactMap { index, page -> KnowledgeBlock? in
            let filtered = page.components(separatedBy: .newlines).filter {
                !repeatedEdges.contains(normalizeLine($0))
            }
            let cleaned = cleanParagraphs(filtered)
            guard !cleaned.isEmpty else { return nil }
            return KnowledgeBlock(
                id: String(format: "%@:P%03d", sourceID, index + 1),
                sourceID: sourceID,
                heading: nil,
                location: "page \(index + 1)",
                text: cleaned
            )
        }
        return ParsedFile(title: document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, blocks: blocks)
    }

    nonisolated private static func parseDOCX(url: URL, sourceID: String) throws -> ParsedFile {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "word/document.xml"]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let xml = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !xml.isEmpty else { throw CompilerError.unreadableDOCX }

        let delegate = DOCXTextParser()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? CompilerError.unreadableDOCX }

        let paragraphs = delegate.paragraphs
        var blocks: [KnowledgeBlock] = []
        var start = 0
        while start < paragraphs.count {
            let end = min(start + 80, paragraphs.count)
            let cleaned = cleanParagraphs(Array(paragraphs[start..<end]))
            if !cleaned.isEmpty {
                blocks.append(KnowledgeBlock(
                    id: String(format: "%@:R%04d-R%04d", sourceID, start + 1, end),
                    sourceID: sourceID,
                    heading: nil,
                    location: "paragraphs \(start + 1)-\(end)",
                    text: cleaned
                ))
            }
            start = end
        }
        return ParsedFile(title: nil, blocks: blocks)
    }

    nonisolated private static func render(
        sources: [KnowledgeSource],
        blocks: [KnowledgeBlock]
    ) -> String {
        var lines = [
            "=== KNOWLEDGE_PACKAGE ===",
            ""
        ]
        for source in sources {
            lines += [
                "[SOURCE \(source.id)]",
                "title: \(source.title)",
                "file: \(source.relativePath)",
                "category: \(source.effectiveCategory.rawValue)",
                ""
            ]
            for block in blocks where block.sourceID == source.id {
                lines.append("[\(block.id)]")
                if let heading = block.heading { lines.append("heading: \(heading)") }
                lines.append("location: \(block.location)")
                lines.append(block.text)
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func cleanParagraphs(_ lines: [String]) -> String {
        let normalizedCounts = Dictionary(grouping: lines.map(normalizeLine).filter { !$0.isEmpty }, by: { $0 })
            .mapValues(\.count)
        var seen: [String: Int] = [:]
        var output: [String] = []
        for raw in lines {
            let line = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                if output.last != "" { output.append("") }
                continue
            }
            let key = normalizeLine(line)
            let count = seen[key, default: 0]
            seen[key] = count + 1
            if key.count >= 30, normalizedCounts[key, default: 0] >= 3, count >= 1 { continue }
            output.append(line)
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func repeatedPDFEdgeLines(_ pages: [String]) -> Set<String> {
        guard pages.count >= 3 else { return [] }
        var counts: [String: Int] = [:]
        for page in pages {
            let lines = page.components(separatedBy: .newlines).map(normalizeLine).filter { !$0.isEmpty }
            for line in Set(Array(lines.prefix(3)) + Array(lines.suffix(3))) where line.count >= 3 {
                counts[line, default: 0] += 1
            }
        }
        let threshold = Int(ceil(Double(pages.count) * 0.6))
        return Set(counts.compactMap { $0.value >= threshold ? $0.key : nil })
    }

    nonisolated private static func decodeText(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func estimateTokens(_ text: String) -> Int {
        let ascii = text.unicodeScalars.filter { $0.isASCII }.count
        let nonASCII = max(0, text.unicodeScalars.count - ascii)
        return max(1, Int(ceil(Double(ascii) / 4.0)) + nonASCII)
    }

    nonisolated private static func normalizeLine(_ line: String) -> String {
        line.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func relativePath(of file: URL, to folder: URL) -> String {
        String(file.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    nonisolated private static func isIgnoredKnowledgeFile(_ file: URL, relativeTo folder: URL) -> Bool {
        let relative = relativePath(of: file, to: folder)
        return !relative.contains("/")
            && ignoredKnowledgeFilenames.contains(file.lastPathComponent.lowercased())
    }

    nonisolated private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func numericSourceID(_ value: String) -> Int? {
        guard value.hasPrefix("KB") else { return nil }
        return Int(value.dropFirst(2))
    }

    nonisolated private static func folderFingerprint(_ folder: URL) -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return "" }
        let supported = Set(["md", "markdown", "txt", "pdf", "docx"])
        let rows = enumerator.compactMap { $0 as? URL }.filter {
            supported.contains($0.pathExtension.lowercased())
                && !$0.lastPathComponent.hasPrefix("~$")
                && !isIgnoredKnowledgeFile($0, relativeTo: folder)
        }.map { url -> String in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(url.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
        }.sorted()
        return sha256(Data(rows.joined(separator: "\n").utf8))
    }

    private enum CompilerError: LocalizedError {
        case unreadableFolder, unsupportedFormat, unreadablePDF, scannedPDF, unreadableDOCX

        var errorDescription: String? {
            switch self {
            case .unreadableFolder: "Knowledge folder cannot be read."
            case .unsupportedFormat: "Unsupported document format."
            case .unreadablePDF: "PDF cannot be opened."
            case .scannedPDF: "PDF has no selectable text; OCR is not included in the MVP."
            case .unreadableDOCX: "DOCX cannot be opened."
            }
        }
    }
}

private final class DOCXTextParser: NSObject, XMLParserDelegate {
    private(set) var paragraphs: [String] = []
    private var currentParagraph = ""
    private var currentText = ""
    private var insideText = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "w:p" || elementName == "p" { currentParagraph = "" }
        if elementName == "w:t" || elementName == "t" { insideText = true; currentText = "" }
        if elementName == "w:tab" || elementName == "tab" { currentParagraph += "\t" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideText { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "w:t" || elementName == "t" {
            currentParagraph += currentText
            insideText = false
        }
        if elementName == "w:p" || elementName == "p" {
            let trimmed = currentParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { paragraphs.append(trimmed) }
        }
    }
}

private extension JSONEncoder {
    static var copilot: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var copilot: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
