import XCTest
@testable import AirPodsTranslator

final class MeetingMinutesTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1000)
    private func part(_ text: String, start: Double = 0, provisional: Bool = false) -> CommittedSegment {
        CommittedSegment(segment: SpeechSegment(text: text, start: start, end: start + 1),
                         isProvisional: provisional, subtitleOnly: false)
    }

    func testConfirmationRetainsEarlyTranslationAndOnlyFinalCorrectionSurvives() {
        let prefix = part("ship Friday", provisional: true)
        let changed = part("Tuesday", start: 2, provisional: true)
        var m = MeetingMinutes()
        m.ingest(CommitBatch(segments: [prefix, changed]), audioOrigin: origin)
        m.setTranslation("周五发货", for: prefix.segment.id)
        XCTAssertTrue(m.lines.isEmpty)
        let correct = part("not Tuesday", start: 2)
        m.ingest(CommitBatch(segments: [correct], revisedIDs: [changed.segment.id], confirmedIDs: [prefix.segment.id]), audioOrigin: origin)
        m.setTranslation("旧译文", for: changed.segment.id)
        m.setTranslation("不是周二", for: correct.segment.id)
        XCTAssertEqual(m.lines.map(\.original), ["ship Friday", "not Tuesday"])
        XCTAssertEqual(m.lines.map(\.translated), ["周五发货", "不是周二"])
        XCTAssertEqual(m.lines.last?.time, origin.addingTimeInterval(2))
        XCTAssertFalse(m.export(summary: nil).contains("旧译文"))
    }

    func testPauseDiscardsDraftAndResumePreservesEarlierConfirmedLines() {
        let unfinished = part("draft", provisional: true)
        var m = MeetingMinutes()
        m.ingest(CommitBatch(segments: [part("first"), unfinished]), audioOrigin: origin)
        m.discardUnconfirmed()
        m.ingest(CommitBatch(segments: [part("second")], confirmedIDs: [unfinished.segment.id]), audioOrigin: origin.addingTimeInterval(60))
        XCTAssertEqual(m.lines.map(\.original), ["first", "second"])
        XCTAssertEqual(m.lines.last?.time, origin.addingTimeInterval(60))
    }

    func testLongMeetingExceedsLiveCaptionWindowAndReportsCapacity() {
        var m = MeetingMinutes(limit: 240)
        for n in 0..<242 { m.ingest(CommitBatch(segments: [part("line \(n)")]), audioOrigin: origin) }
        XCTAssertEqual(m.lines.first?.original, "line 0")
        XCTAssertEqual(m.lines.last?.original, "line 239")
        XCTAssertEqual(m.omitted, 2)
        XCTAssertTrue(m.export(summary: "小结").contains("另有 2 段"))
    }

    func testChunkingRetainsAllTextAndReferencesAcrossOversizedSingleUtterance() {
        var m = MeetingMinutes()
        let speech = String(repeating: "明天👩🏽‍💻开会", count: 30)
        m.ingest(CommitBatch(segments: [part("start"), part(speech), part("end")]), audioOrigin: origin)
        let chunks = m.summaryChunks(limit: 40)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 40 })
        let fragments = chunks.flatMap { $0.text.components(separatedBy: "\n") }
        XCTAssertEqual(fragments.filter { $0.hasPrefix("[2] ") }.map { String($0.dropFirst(4)) }.joined(), speech)
        XCTAssertEqual(chunks.flatMap { $0.sources }.sorted().first, 1)
        XCTAssertEqual(fragments.last, "[3] end")
    }

    func testSummaryRejectsWrongCitationAndDeduplicatesFindings() {
        var m = MeetingMinutes()
        m.ingest(CommitBatch(segments: [part("We meet on Friday.")]), audioOrigin: origin)
        var findings = MeetingFindings()
        let valid = MeetingFact(kind: .decision, text: "周五开会", source: 1, quote: "meet on Friday")
        findings.add(valid, from: m, allowedSources: [1])
        findings.add(valid, from: m, allowedSources: [1])
        findings.add(.init(kind: .action, text: "错误日期", source: 1, quote: "Thursday"), from: m, allowedSources: [1])
        findings.add(.init(kind: .action, text: "串段", source: 1, quote: "meet"), from: m, allowedSources: [2])
        XCTAssertEqual(findings.formatted.components(separatedBy: "周五开会 [1]").count, 2)
        XCTAssertFalse(findings.formatted.contains("错误日期"))
        XCTAssertFalse(findings.formatted.contains("串段"))
        XCTAssertTrue(findings.formatted.contains("已略去"))
    }
}
