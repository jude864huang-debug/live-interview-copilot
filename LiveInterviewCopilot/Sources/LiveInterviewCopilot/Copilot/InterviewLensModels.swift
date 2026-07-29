import AppKit
import Foundation

/// The interview content currently mirrored into the camera-adjacent lens card.
///
/// The enum deliberately keeps a stable Codable representation instead of relying
/// on Swift's synthesized associated-value encoding. That representation is safe
/// to persist in UserDefaults or a session record and remains easy to extend.
enum InterviewLensSelection: Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case question
        case answer
        case quickIdea = "quick_idea"
        case referenceAnswer = "reference_answer"
        case followUps = "follow_ups"
        case followUpAnswer = "follow_up_answer"
    }

    case question
    case answer
    case quickIdea
    case referenceAnswer
    case followUps
    case followUpAnswer(question: String)

    var kind: Kind {
        switch self {
        case .question: .question
        case .answer: .answer
        case .quickIdea: .quickIdea
        case .referenceAnswer: .referenceAnswer
        case .followUps: .followUps
        case .followUpAnswer: .followUpAnswer
        }
    }

    var followUpQuestion: String? {
        guard case .followUpAnswer(let question) = self else { return nil }
        return question
    }

    var id: String { persistenceID }

    /// A stable string suitable for lightweight persistence.
    var persistenceID: String {
        switch self {
        case .question, .answer, .quickIdea, .referenceAnswer, .followUps:
            return kind.rawValue
        case .followUpAnswer(let question):
            let encoded = Data(question.utf8).base64EncodedString()
            return "\(Kind.followUpAnswer.rawValue):\(encoded)"
        }
    }

    init?(persistenceID: String) {
        if let kind = Kind(rawValue: persistenceID), kind != .followUpAnswer {
            switch kind {
            case .question: self = .question
            case .answer: self = .answer
            case .quickIdea: self = .quickIdea
            case .referenceAnswer: self = .referenceAnswer
            case .followUps: self = .followUps
            case .followUpAnswer: return nil
            }
            return
        }

        let prefix = "\(Kind.followUpAnswer.rawValue):"
        guard persistenceID.hasPrefix(prefix),
              let data = Data(base64Encoded: String(persistenceID.dropFirst(prefix.count))),
              let question = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        self = .followUpAnswer(question: question)
    }
}

extension InterviewLensSelection: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case question
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .question:
            self = .question
        case .answer:
            self = .answer
        case .quickIdea:
            self = .quickIdea
        case .referenceAnswer:
            self = .referenceAnswer
        case .followUps:
            self = .followUps
        case .followUpAnswer:
            self = .followUpAnswer(
                question: try container.decode(String.self, forKey: .question)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if case .followUpAnswer(let question) = self {
            try container.encode(question, forKey: .question)
        }
    }
}

/// Character-based source coordinates for a piece of lens text.
///
/// Character offsets are used instead of UTF-16 offsets so Chinese, emoji and
/// composed Unicode characters remain indivisible when a page is reconstructed.
struct InterviewLensTextAnchor: Codable, Equatable, Hashable, Sendable {
    var sourceID: String
    var lowerBound: Int
    var upperBound: Int

    init(sourceID: String, lowerBound: Int, upperBound: Int) {
        self.sourceID = sourceID
        self.lowerBound = lowerBound
        self.upperBound = max(lowerBound, upperBound)
    }

    var range: Range<Int> { lowerBound..<upperBound }
    var length: Int { upperBound - lowerBound }
}

/// A meaningful unit supplied by the interview state machine before visual
/// pagination. Complete-answer sections and sample answers can request a fresh
/// page without the paginator needing to understand domain model internals.
struct InterviewLensSemanticUnit: Codable, Equatable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case question
        case directOpening = "direct_opening"
        case quickIdea = "quick_idea"
        case talkingPoint = "talking_point"
        case referenceSegment = "reference_segment"
        case followUpQuestion = "follow_up_question"
        case followUpAnswer = "follow_up_answer"
        case sampleAnswer = "sample_answer"
        case warning
        case other
    }

    var id: String
    var kind: Kind
    var text: String
    var label: String?
    var anchor: InterviewLensTextAnchor
    var startNewPage: Bool

    init(
        id: String,
        kind: Kind,
        text: String,
        label: String? = nil,
        anchor: InterviewLensTextAnchor? = nil,
        startNewPage: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.label = label
        self.anchor = anchor ?? InterviewLensTextAnchor(
            sourceID: id,
            lowerBound: 0,
            upperBound: text.count
        )
        self.startNewPage = startNewPage
    }
}

struct InterviewLensFailure: Codable, Equatable, Hashable, Sendable {
    var message: String
    var recoverySuggestion: String?

    init(message: String, recoverySuggestion: String? = nil) {
        self.message = message
        self.recoverySuggestion = recoverySuggestion
    }
}

/// An immutable-by-convention state-machine payload. AI output may update this
/// snapshot incrementally; text anchors keep the reader on the same source range.
struct InterviewLensSnapshot: Codable, Equatable, Hashable, Sendable {
    var turnToken: String
    var questionContext: String
    var units: [InterviewLensSemanticUnit]
    var isFrozen: Bool
    var isStreaming: Bool
    var failure: InterviewLensFailure?
    var selection: InterviewLensSelection
    var navigationSelections: [InterviewLensSelection]

    init(
        turnToken: String,
        questionContext: String,
        units: [InterviewLensSemanticUnit],
        isFrozen: Bool = false,
        isStreaming: Bool = false,
        failure: InterviewLensFailure? = nil,
        selection: InterviewLensSelection,
        navigationSelections: [InterviewLensSelection] = []
    ) {
        self.turnToken = turnToken
        self.questionContext = questionContext
        self.units = units
        self.isFrozen = isFrozen
        self.isStreaming = isStreaming
        self.failure = failure
        self.selection = selection
        self.navigationSelections = navigationSelections
    }
}

/// A rendered fragment of one semantic unit. Adjacent fragments from the same
/// unit are coalesced within a page, while their source range remains exact.
struct InterviewLensPageItem: Codable, Equatable, Hashable, Sendable, Identifiable {
    var unitID: String
    var kind: InterviewLensSemanticUnit.Kind
    var text: String
    var label: String?
    var anchor: InterviewLensTextAnchor
    var continuesFromPrevious: Bool
    var continuesToNext: Bool

    var id: String {
        "\(unitID):\(anchor.sourceID):\(anchor.lowerBound)-\(anchor.upperBound)"
    }
}

struct InterviewLensPageContinuation: Codable, Equatable, Hashable, Sendable {
    var hasPreviousPage: Bool
    var hasNextPage: Bool
    var continuesUnitFromPrevious: Bool
    var continuesUnitOnNextPage: Bool
}

/// Content beyond the hard page limit is retained here rather than discarded.
/// The lens UI should render `message` at the tail of the final visible page and
/// direct the user to the main window for the retained remainder.
struct InterviewLensOverflow: Codable, Equatable, Hashable, Sendable {
    var message: String
    var remainingItems: [InterviewLensPageItem]

    var remainingCharacterCount: Int {
        remainingItems.reduce(0) { $0 + $1.text.count }
    }

    var remainingText: String {
        remainingItems.map(\.text).joined()
    }
}

struct InterviewLensPage: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Zero-based page index. UI should display `index + 1`.
    var index: Int
    var items: [InterviewLensPageItem]
    var textRangeAnchors: [InterviewLensTextAnchor]
    var continuation: InterviewLensPageContinuation
    var overflow: InterviewLensOverflow?

    var id: Int { index }
    var text: String { items.map(\.text).joined() }
}

/// AppKit-backed semantic paginator for the camera-adjacent interview lens.
///
/// Pagination first attempts to keep every semantic unit intact. Oversized units
/// split at sentence punctuation/newlines, then at English word boundaries and
/// finally by Swift `Character`. All separators and whitespace stay attached to
/// the output, so page fragments can reconstruct the source without loss.
enum InterviewLensPaginator {
    static func labelFontSize(for bodyFontSize: CGFloat) -> CGFloat {
        max(14, bodyFontSize * 0.70)
    }

    struct Configuration: Equatable, Sendable {
        var fontSize: CGFloat
        var width: CGFloat
        var height: CGFloat
        var lineSpacing: CGFloat
        var unitSpacing: CGFloat
        var labelSpacing: CGFloat
        var maximumPages: Int
        var overflowMessage: String

        init(
            fontSize: CGFloat = 20,
            width: CGFloat = 468,
            height: CGFloat = 188,
            lineSpacing: CGFloat = 4,
            unitSpacing: CGFloat = 8,
            labelSpacing: CGFloat = 6,
            maximumPages: Int = 12,
            overflowMessage: String = "内容较长，请在主窗口查看全文"
        ) {
            self.fontSize = max(1, fontSize)
            self.width = max(1, width)
            self.height = max(1, height)
            self.lineSpacing = max(0, lineSpacing)
            self.unitSpacing = max(0, unitSpacing)
            self.labelSpacing = max(0, labelSpacing)
            self.maximumPages = min(12, max(1, maximumPages))
            self.overflowMessage = overflowMessage
        }
    }

    private struct Fragment {
        var unitID: String
        var kind: InterviewLensSemanticUnit.Kind
        var text: String
        var label: String?
        var anchor: InterviewLensTextAnchor
        var continuesFromPrevious: Bool
        var continuesToNext: Bool
    }

    static func paginate(
        snapshot: InterviewLensSnapshot,
        configuration: Configuration = Configuration()
    ) -> [InterviewLensPage] {
        paginate(units: snapshot.units, configuration: configuration)
    }

    static func paginate(
        units: [InterviewLensSemanticUnit],
        configuration: Configuration = Configuration()
    ) -> [InterviewLensPage] {
        let font = NSFont.systemFont(ofSize: configuration.fontSize)
        let labelFont = NSFont.systemFont(
            ofSize: labelFontSize(for: configuration.fontSize),
            weight: .bold
        )

        var rawPages: [[Fragment]] = []
        var current: [Fragment] = []

        func flushCurrentPage() {
            guard !current.isEmpty else { return }
            rawPages.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for unit in units {
            guard !unit.text.isEmpty || !(unit.label ?? "").isEmpty else { continue }

            if unit.startNewPage {
                flushCurrentPage()
            }

            let whole = fragment(for: unit, localRange: 0..<unit.text.count)
            if fits(
                current + [whole],
                configuration: configuration,
                font: font,
                labelFont: labelFont
            ) {
                current.append(whole)
                continue
            }

            if !current.isEmpty {
                flushCurrentPage()
                if fits(
                    [whole],
                    configuration: configuration,
                    font: font,
                    labelFont: labelFont
                ) {
                    current.append(whole)
                    continue
                }
            }

            // Normal semantic cards fit whole because the manager paginates
            // against the largest usable lens height. Exceptionally long cards
            // split losslessly here instead of creating a nested scroll area.
            let fragments = splitOversizedUnit(
                unit,
                configuration: configuration,
                font: font,
                labelFont: labelFont
            )
            for fragment in fragments {
                if fits(
                    current + [fragment],
                    configuration: configuration,
                    font: font,
                    labelFont: labelFont
                ) {
                    current.append(fragment)
                } else {
                    flushCurrentPage()
                    // A pathological geometry may be shorter than a single
                    // glyph. Keep that Character rather than dropping it.
                    current.append(fragment)
                }
            }
        }
        flushCurrentPage()

        var pageItems = rawPages.map(coalescedPageItems)
        guard !pageItems.isEmpty else { return [] }

        var overflow: InterviewLensOverflow?
        if pageItems.count > configuration.maximumPages {
            let remaining = pageItems
                .dropFirst(configuration.maximumPages)
                .flatMap { $0 }
            pageItems = Array(pageItems.prefix(configuration.maximumPages))
            overflow = InterviewLensOverflow(
                message: configuration.overflowMessage,
                remainingItems: remaining
            )
        }

        return pageItems.enumerated().map { index, items in
            let isLast = index == pageItems.count - 1
            return InterviewLensPage(
                index: index,
                items: items,
                textRangeAnchors: items.map(\.anchor),
                continuation: InterviewLensPageContinuation(
                    hasPreviousPage: index > 0,
                    hasNextPage: index < pageItems.count - 1,
                    continuesUnitFromPrevious: items.first?.continuesFromPrevious ?? false,
                    continuesUnitOnNextPage: items.last?.continuesToNext ?? false
                ),
                overflow: isLast ? overflow : nil
            )
        }
    }

    private static func splitOversizedUnit(
        _ unit: InterviewLensSemanticUnit,
        configuration: Configuration,
        font: NSFont,
        labelFont: NSFont
    ) -> [Fragment] {
        let characters = Array(unit.text)
        guard !characters.isEmpty else {
            return [fragment(for: unit, localRange: 0..<0)]
        }

        let semanticRanges = sentenceRanges(in: characters)
        var ranges: [Range<Int>] = []
        for range in semanticRanges {
            let candidate = fragment(for: unit, localRange: range, characters: characters)
            if fits(
                [candidate],
                configuration: configuration,
                font: font,
                labelFont: labelFont
            ) {
                ranges.append(range)
            } else {
                ranges.append(contentsOf: fittingRanges(
                    in: range,
                    characters: characters,
                    unit: unit,
                    configuration: configuration,
                    font: font,
                    labelFont: labelFont
                ))
            }
        }

        return ranges.map { range in
            fragment(for: unit, localRange: range, characters: characters)
        }
    }

    /// Split after punctuation/newline and keep the delimiter in the preceding
    /// fragment. No trimming is allowed because whitespace is source content.
    private static func sentenceRanges(in characters: [Character]) -> [Range<Int>] {
        guard !characters.isEmpty else { return [] }
        let terminators: Set<Character> = ["。", "！", "？", "!", "?", "；", ";"]
        var result: [Range<Int>] = []
        var start = 0

        for index in characters.indices {
            let character = characters[index]
            if terminators.contains(character) || isNewline(character) {
                let end = index + 1
                result.append(start..<end)
                start = end
            }
        }
        if start < characters.count {
            result.append(start..<characters.count)
        }
        return result
    }

    private static func fittingRanges(
        in sourceRange: Range<Int>,
        characters: [Character],
        unit: InterviewLensSemanticUnit,
        configuration: Configuration,
        font: NSFont,
        labelFont: NSFont
    ) -> [Range<Int>] {
        let tokens = tokenRanges(in: sourceRange, characters: characters)
        var result: [Range<Int>] = []
        var current: Range<Int>?

        func fragmentFits(_ range: Range<Int>) -> Bool {
            fits(
                [fragment(for: unit, localRange: range, characters: characters)],
                configuration: configuration,
                font: font,
                labelFont: labelFont
            )
        }

        func appendCharacterRanges(from range: Range<Int>) {
            var characterChunk: Range<Int>?
            for index in range {
                let candidate = (characterChunk?.lowerBound ?? index)..<(index + 1)
                if fragmentFits(candidate) {
                    characterChunk = candidate
                } else {
                    if let characterChunk {
                        result.append(characterChunk)
                    }
                    // Preserve even a glyph that cannot fit pathological bounds.
                    characterChunk = index..<(index + 1)
                }
            }
            if let characterChunk {
                result.append(characterChunk)
            }
        }

        for token in tokens {
            let candidate = (current?.lowerBound ?? token.lowerBound)..<token.upperBound
            if fragmentFits(candidate) {
                current = candidate
                continue
            }

            if let current {
                result.append(current)
            }
            current = nil

            if fragmentFits(token) {
                current = token
            } else {
                appendCharacterRanges(from: token)
            }
        }
        if let current {
            result.append(current)
        }
        return result
    }

    /// ASCII words stay intact where possible; whitespace stays as its own exact
    /// token; CJK and all remaining grapheme clusters become Character tokens.
    private static func tokenRanges(
        in sourceRange: Range<Int>,
        characters: [Character]
    ) -> [Range<Int>] {
        enum TokenClass: Equatable {
            case asciiWord
            case whitespace
            case character
        }

        func tokenClass(for character: Character) -> TokenClass {
            if character.unicodeScalars.allSatisfy({
                CharacterSet.whitespacesAndNewlines.contains($0)
            }) {
                return .whitespace
            }
            if character.unicodeScalars.allSatisfy({ scalar in
                scalar.isASCII && (
                    CharacterSet.alphanumerics.contains(scalar)
                        || scalar.value == 39
                        || scalar.value == 45
                        || scalar.value == 95
                )
            }) {
                return .asciiWord
            }
            return .character
        }

        var result: [Range<Int>] = []
        var start = sourceRange.lowerBound
        var currentClass: TokenClass?

        for index in sourceRange {
            let nextClass = tokenClass(for: characters[index])
            if let currentClass,
               nextClass != currentClass || nextClass == .character {
                result.append(start..<index)
                start = index
            }
            currentClass = nextClass
        }
        if start < sourceRange.upperBound {
            result.append(start..<sourceRange.upperBound)
        }
        return result
    }

    private static func fragment(
        for unit: InterviewLensSemanticUnit,
        localRange: Range<Int>,
        characters: [Character]? = nil
    ) -> Fragment {
        let sourceCharacters = characters ?? Array(unit.text)
        let text = String(sourceCharacters[localRange])
        return Fragment(
            unitID: unit.id,
            kind: unit.kind,
            text: text,
            label: unit.label,
            anchor: InterviewLensTextAnchor(
                sourceID: unit.anchor.sourceID,
                lowerBound: unit.anchor.lowerBound + localRange.lowerBound,
                upperBound: unit.anchor.lowerBound + localRange.upperBound
            ),
            continuesFromPrevious: localRange.lowerBound > 0,
            continuesToNext: localRange.upperBound < sourceCharacters.count
        )
    }

    private static func fits(
        _ fragments: [Fragment],
        configuration: Configuration,
        font: NSFont,
        labelFont: NSFont
    ) -> Bool {
        measuredHeight(
            of: fragments,
            configuration: configuration,
            font: font,
            labelFont: labelFont
        ) <= configuration.height + 0.5
    }

    private static func measuredHeight(
        of fragments: [Fragment],
        configuration: Configuration,
        font: NSFont,
        labelFont: NSFont
    ) -> CGFloat {
        var height: CGFloat = 0
        var previousUnitID: String?

        for fragment in fragments {
            let beginsUnit = previousUnitID != fragment.unitID
            if previousUnitID != nil, beginsUnit {
                height += configuration.unitSpacing
            }
            if beginsUnit {
                let continuationFont = NSFont.systemFont(ofSize: 9, weight: .bold)
                let continuationBadgeWidth = ceil(
                    ("续" as NSString).size(withAttributes: [.font: continuationFont]).width + 8
                )
                let labelWidth = max(
                    1,
                    configuration.width - (fragment.continuesFromPrevious
                        ? continuationBadgeWidth + 5
                        : 0)
                )
                let labelHeight = fragment.label.flatMap { label -> CGFloat? in
                    guard !label.isEmpty else { return nil }
                    return textHeight(
                        label,
                        width: labelWidth,
                        font: labelFont,
                        lineSpacing: 0
                    )
                } ?? 0
                let continuationHeight: CGFloat = fragment.continuesFromPrevious
                    ? ceil(continuationFont.boundingRectForFont.height + 2)
                    : 0
                let headerHeight = max(labelHeight, continuationHeight)
                if headerHeight > 0 {
                    height += headerHeight
                    height += configuration.labelSpacing
                }
            }
            if !fragment.text.isEmpty {
                let bodyFont = NSFont.systemFont(
                    ofSize: font.pointSize,
                    weight: fontWeight(for: fragment.kind)
                )
                height += textHeight(
                    fragment.text,
                    width: configuration.width,
                    font: bodyFont,
                    lineSpacing: configuration.lineSpacing
                )
            }
            previousUnitID = fragment.unitID
        }
        return ceil(height)
    }

    static func measuredContentHeight(
        of page: InterviewLensPage,
        configuration: Configuration
    ) -> CGFloat {
        let font = NSFont.systemFont(ofSize: configuration.fontSize)
        let labelFont = NSFont.systemFont(
            ofSize: labelFontSize(for: configuration.fontSize),
            weight: .bold
        )
        let fragments = page.items.map { item in
            Fragment(
                unitID: item.unitID,
                kind: item.kind,
                text: item.text,
                label: item.label,
                anchor: item.anchor,
                continuesFromPrevious: item.continuesFromPrevious,
                continuesToNext: item.continuesToNext
            )
        }
        return measuredHeight(
            of: fragments,
            configuration: configuration,
            font: font,
            labelFont: labelFont
        )
    }

    /// Keep pagination metrics identical to the SwiftUI card's semantic text
    /// weights. A medium/semibold line can wrap where regular text does not.
    private static func fontWeight(
        for kind: InterviewLensSemanticUnit.Kind
    ) -> NSFont.Weight {
        switch kind {
        case .question, .directOpening:
            return .semibold
        case .quickIdea, .talkingPoint, .followUpQuestion:
            return .medium
        default:
            return .regular
        }
    }

    /// Uses TextKit-compatible AppKit drawing metrics and the current macOS system
    /// font. The large height prevents clipping before the paginator compares the
    /// measured result with the requested content box.
    private static func textHeight(
        _ text: String,
        width: CGFloat,
        font: NSFont,
        lineSpacing: CGFloat
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = lineSpacing
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .paragraphStyle: paragraph,
            ]
        )
        return ceil(bounds.height)
    }

    private static func coalescedPageItems(_ fragments: [Fragment]) -> [InterviewLensPageItem] {
        var items: [InterviewLensPageItem] = []
        for fragment in fragments {
            if var last = items.last,
               last.unitID == fragment.unitID,
               last.anchor.sourceID == fragment.anchor.sourceID,
               last.anchor.upperBound == fragment.anchor.lowerBound {
                last.text += fragment.text
                last.anchor.upperBound = fragment.anchor.upperBound
                last.continuesToNext = fragment.continuesToNext
                items[items.count - 1] = last
            } else {
                items.append(InterviewLensPageItem(
                    unitID: fragment.unitID,
                    kind: fragment.kind,
                    text: fragment.text,
                    label: fragment.label,
                    anchor: fragment.anchor,
                    continuesFromPrevious: fragment.continuesFromPrevious,
                    continuesToNext: fragment.continuesToNext
                ))
            }
        }
        return items
    }

    private static func isNewline(_ character: Character) -> Bool {
        !character.unicodeScalars.isEmpty && character.unicodeScalars.allSatisfy {
            CharacterSet.newlines.contains($0)
        }
    }
}
