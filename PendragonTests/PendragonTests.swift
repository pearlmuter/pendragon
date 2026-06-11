import XCTest
@testable import Pendragon

final class PendragonTests: XCTestCase {

    // MARK: - extractVisibleText

    func testExtractVisibleText_stripsThinkingBlock() {
        let raw = "<|channel>some thinking here<channel|>The actual answer"
        XCTAssertEqual(ChatEngine.extractVisibleText(from: raw, thinkingEnabled: true), "The actual answer")
    }

    func testExtractVisibleText_returnsEmptyWhileInsideThinkingBlock() {
        // Model has opened the thinking tag but not closed it yet — show nothing
        let raw = "<|channel>still thinking, no close tag yet"
        XCTAssertEqual(ChatEngine.extractVisibleText(from: raw, thinkingEnabled: true), "")
    }

    func testExtractVisibleText_thinkingDisabledReturnsPlainText() {
        let raw = "A plain response with no thinking tokens"
        XCTAssertEqual(ChatEngine.extractVisibleText(from: raw, thinkingEnabled: false), "A plain response with no thinking tokens")
    }

    func testExtractVisibleText_emptyBubbleFallback() {
        // The empty-bubble fallback path: thinking never closed, caller retries with
        // thinkingEnabled:false so at least something is shown rather than empty bubble.
        let raw = "<|channel>deep thought, never closed"
        let result = ChatEngine.extractVisibleText(from: raw, thinkingEnabled: false)
        XCTAssertFalse(result.isEmpty)
    }

    func testExtractVisibleText_stripsResidualChannelTokens() {
        let raw = "<channel|>leftover token in response"
        let result = ChatEngine.extractVisibleText(from: raw, thinkingEnabled: false)
        XCTAssertFalse(result.contains("<channel|>"))
        XCTAssertFalse(result.isEmpty)
    }

    func testExtractVisibleText_trailingWhitespaceStripped() {
        let raw = "<|channel>thinking<channel|>  answer with spaces  "
        XCTAssertEqual(ChatEngine.extractVisibleText(from: raw, thinkingEnabled: true), "answer with spaces")
    }

    // MARK: - extractSearchQuery

    func testExtractSearchQuery_officialTokenFormat() {
        let raw = "call:web_search{query:<|\"|>latest macOS version<|\"|>}"
        XCTAssertEqual(ChatEngine.extractSearchQuery(from: raw), "latest macOS version")
    }

    func testExtractSearchQuery_quotedFormat() {
        let raw = #"call:web_search{query: "current bitcoin price"}"#
        XCTAssertEqual(ChatEngine.extractSearchQuery(from: raw), "current bitcoin price")
    }

    func testExtractSearchQuery_noToolCallReturnsNil() {
        XCTAssertNil(ChatEngine.extractSearchQuery(from: "This is a plain response with no tool call"))
    }

    func testExtractSearchQuery_wrongToolReturnsNil() {
        let raw = "call:fetch_url{url:<|\"|>https://example.com<|\"|>}"
        XCTAssertNil(ChatEngine.extractSearchQuery(from: raw))
    }

    // MARK: - extractCalendarEventCall

    func testExtractCalendarEventCall_validEvent() {
        let raw = "create_calendar_event{title:<|\"|>Team Meeting<|\"|>,start_date:<|\"|>2026-06-15T14:00:00<|\"|>}"
        let params = ChatEngine.extractCalendarEventCall(from: raw)
        XCTAssertNotNil(params)
        XCTAssertEqual(params?.title, "Team Meeting")
        XCTAssertEqual(params?.startDate, "2026-06-15T14:00:00")
    }

    func testExtractCalendarEventCall_withOptionalFields() {
        let raw = "create_calendar_event{title:<|\"|>Dentist<|\"|>,start_date:<|\"|>2026-07-01T09:00:00<|\"|>,location:<|\"|>City Clinic<|\"|>}"
        let params = ChatEngine.extractCalendarEventCall(from: raw)
        XCTAssertNotNil(params)
        XCTAssertEqual(params?.location, "City Clinic")
    }

    func testExtractCalendarEventCall_titleFallbackToNotes() {
        // Gemma 12B sometimes puts the event name in `notes` instead of `title` —
        // observed live in tool-debug.log. The extractor falls back so the call succeeds.
        let raw = "create_calendar_event{notes:<|\"|>Doctor Appointment<|\"|>,start_date:<|\"|>2026-07-01T10:00:00<|\"|>}"
        let params = ChatEngine.extractCalendarEventCall(from: raw)
        XCTAssertNotNil(params)
        XCTAssertEqual(params?.title, "Doctor Appointment")
    }

    func testExtractCalendarEventCall_missingStartDateReturnsNil() {
        let raw = "create_calendar_event{title:<|\"|>Dentist<|\"|>}"
        XCTAssertNil(ChatEngine.extractCalendarEventCall(from: raw))
    }

    func testExtractCalendarEventCall_noMatchReturnsNil() {
        XCTAssertNil(ChatEngine.extractCalendarEventCall(from: "Just a regular message"))
    }

    // MARK: - ContextSizeOption.kvCacheGB

    func testContextSizeOption_kvCacheScalesWithContext() {
        XCTAssertLessThan(ContextSizeOption.k8.kvCacheGB,   ContextSizeOption.k32.kvCacheGB)
        XCTAssertLessThan(ContextSizeOption.k32.kvCacheGB,  ContextSizeOption.k128.kvCacheGB)
        XCTAssertLessThan(ContextSizeOption.k128.kvCacheGB, ContextSizeOption.k256.kvCacheGB)
    }

    func testContextSizeOption_swaFixedComponentPresent() {
        // Even at 8K the fixed SWA component (~335 MB) means we exceed 0.3 GB
        XCTAssertGreaterThan(ContextSizeOption.k8.kvCacheGB, 0.3)
    }

    func testContextSizeOption_k32InExpectedRange() {
        // 32K: ~335 MB SWA + ~512 MB global = ~0.85 GB
        XCTAssertGreaterThan(ContextSizeOption.k32.kvCacheGB, 0.8)
        XCTAssertLessThan(ContextSizeOption.k32.kvCacheGB,   1.0)
    }

    func testContextSizeOption_allCasesHavePositiveRAM() {
        for option in ContextSizeOption.allCases {
            XCTAssertGreaterThan(option.kvCacheGB, 0, "\(option.label) reported non-positive RAM")
        }
    }

    // MARK: - KokoroBridge.stripMarkdown
    // Called via MainActor.run because KokoroBridge is @MainActor.

    func testStripMarkdown_removesInlineCode() async {
        let result = await MainActor.run { KokoroBridge.stripMarkdown("Use `print()` to debug") }
        XCTAssertFalse(result.contains("`"))
        // Inline code content is intentionally stripped (not spoken)
        XCTAssertTrue(result.contains("Use"))
        XCTAssertTrue(result.contains("to debug"))
    }

    func testStripMarkdown_removesCodeFence() async {
        let input = "Here is code:\n```swift\nlet x = 1\n```\nDone."
        let result = await MainActor.run { KokoroBridge.stripMarkdown(input) }
        XCTAssertFalse(result.contains("```"))
        XCTAssertFalse(result.contains("let x"))
        XCTAssertTrue(result.contains("Done"))
    }

    func testStripMarkdown_removesHeadings() async {
        let input = "## Introduction\nSome text here."
        let result = await MainActor.run { KokoroBridge.stripMarkdown(input) }
        XCTAssertFalse(result.contains("#"))
        XCTAssertTrue(result.contains("Introduction"))
        XCTAssertTrue(result.contains("Some text here"))
    }

    func testStripMarkdown_removesBoldAndItalic() async {
        let input = "This is **bold** and _italic_ text."
        let result = await MainActor.run { KokoroBridge.stripMarkdown(input) }
        XCTAssertFalse(result.contains("**"))
        XCTAssertFalse(result.contains("_italic_"))
        XCTAssertTrue(result.contains("bold"))
        XCTAssertTrue(result.contains("italic"))
    }

    func testStripMarkdown_removesLinks() async {
        let input = "See [Apple](https://apple.com) for details."
        let result = await MainActor.run { KokoroBridge.stripMarkdown(input) }
        XCTAssertFalse(result.contains("https://apple.com"))
        XCTAssertTrue(result.contains("Apple"))
    }

    func testStripMarkdown_preservesParagraphBreaks() async {
        let input = "First paragraph.\n\nSecond paragraph."
        let result = await MainActor.run { KokoroBridge.stripMarkdown(input) }
        XCTAssertTrue(result.contains("\n"))
    }

    func testStripMarkdown_collapsesManyBlankLines() async {
        let input = "Line one.\n\n\n\nLine two."
        let result = await MainActor.run { KokoroBridge.stripMarkdown(input) }
        XCTAssertFalse(result.contains("\n\n\n"))
    }

    func testStripMarkdown_emptyInputReturnsEmpty() async {
        let result = await MainActor.run { KokoroBridge.stripMarkdown("") }
        XCTAssertEqual(result, "")
    }

    func testStripMarkdown_plainTextUnchanged() async {
        let input = "Hello, this is plain text with no markdown."
        let result = await MainActor.run { KokoroBridge.stripMarkdown(input) }
        XCTAssertEqual(result, input)
    }

    // MARK: - kokoroVoices catalogue

    func testKokoroVoices_noDuplicateIds() {
        let ids = kokoroVoices.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate voice IDs found")
    }

    func testKokoroVoices_noDuplicateDisplayNames() {
        let names = kokoroVoices.map(\.displayName)
        XCTAssertEqual(names.count, Set(names).count, "Duplicate display names found")
    }

    func testKokoroVoices_allIdsHaveValidPrefix() {
        let validPrefixes = ["af_", "am_", "bf_", "bm_", "jf_", "jm_", "zf_", "zm_"]
        for v in kokoroVoices {
            let hasPrefix = validPrefixes.contains { v.id.hasPrefix($0) }
            XCTAssertTrue(hasPrefix, "\(v.id) has unrecognised prefix")
        }
    }

    func testKokoroVoices_allGradesNonEmpty() {
        for v in kokoroVoices {
            XCTAssertFalse(v.grade.isEmpty, "\(v.id) has empty grade")
        }
    }

    func testKokoroVoices_knownGradesOnly() {
        let allowed: Set<String> = ["A", "A−", "B−", "C+", "C", "C−"]
        for v in kokoroVoices {
            XCTAssertTrue(allowed.contains(v.grade), "\(v.id) has unexpected grade '\(v.grade)'")
        }
    }

    func testKokoroVoices_defaultVoiceExistsInCatalogue() {
        let ids = kokoroVoices.map(\.id)
        XCTAssertTrue(ids.contains(KokoroBridge.defaultVoice),
                      "Default voice '\(KokoroBridge.defaultVoice)' not in catalogue")
    }

    func testKokoroVoices_defaultVoiceIsTopGrade() {
        let defaultVoice = kokoroVoices.first { $0.id == KokoroBridge.defaultVoice }
        XCTAssertEqual(defaultVoice?.grade, "A", "Default voice should be grade A")
    }

    func testKokoroVoices_gradeASortedFirst() {
        // All grade-A voices must appear before any grade-B or lower voice
        let gradeOrder = ["A", "A−", "B−", "C+", "C", "C−"]
        var lastRank = -1
        for v in kokoroVoices {
            let rank = gradeOrder.firstIndex(of: v.grade) ?? gradeOrder.count
            XCTAssertGreaterThanOrEqual(rank, lastRank,
                "\(v.id) (grade \(v.grade)) appears after a lower-ranked voice")
            lastRank = rank
        }
    }

    func testKokoroVoices_atLeastOneMaleAndOneFemale() {
        let hasFemale = kokoroVoices.contains { $0.id.contains("f_") }
        let hasMale   = kokoroVoices.contains { $0.id.contains("m_") }
        XCTAssertTrue(hasFemale, "No female voices in catalogue")
        XCTAssertTrue(hasMale,   "No male voices in catalogue")
    }

    func testKokoroVoices_minimumCount() {
        XCTAssertGreaterThanOrEqual(kokoroVoices.count, 8, "Fewer voices than expected in catalogue")
    }

    // MARK: - KokoroVoice identifiable

    func testKokoroVoice_idIsIdentifier() {
        let v = KokoroVoice(id: "af_heart", displayName: "Heart", grade: "A")
        XCTAssertEqual(v.id, "af_heart")
    }
}
