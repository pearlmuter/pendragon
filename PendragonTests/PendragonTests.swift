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
}
