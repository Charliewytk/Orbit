import XCTest
@testable import OrbitCore

final class GapDetectorTests: XCTestCase {
    func date(_ s: String) -> Date { ISO8601.parse(s)! }

    func testFindsMissingSummariesMissingNotesAndLowConfidencePages() {
        let hwOnly = LectureNote(id: "w6", title: "Lecture", moduleCode: "BEM2031", week: 6,
                                 created: date("2025-10-21T10:00:00Z"),
                                 segments: [NoteSegment(kind: .handwriting, text: "scribbles", confidence: 0.5)])
        let complete = LectureNote(id: "w4", title: "Week 4", moduleCode: "BEM2031", week: 4,
                                   created: date("2025-10-07T10:30:00Z"),
                                   segments: [NoteSegment(kind: .handwriting, text: "detail", confidence: 0.4),
                                              NoteSegment(kind: .typed, text: "key points")])
        let unsure = LectureNote(id: "e1", title: "Sorting", moduleCode: "ECM1400", created: date("2025-10-20T09:00:00Z"),
                                 segments: [NoteSegment(kind: .typed, text: "k"),
                                            NoteSegment(kind: .handwriting, text: "a b c d e", confidence: 0.9,
                                                        uncertainWords: ["a", "b", "c", "d", "e"])])
        let untitled = LectureNote(id: "u", title: "Misc", created: date("2025-10-01T09:00:00Z"),
                                   segments: [NoteSegment(kind: .handwriting, text: "x", confidence: 0.9)])

        let lectures = [
            // Tue 14 Oct: no BEM2031 note that day → gap.
            CalendarEvent(id: "L1", title: "BEM2031 Lecture", start: date("2025-10-14T09:00:00Z"), end: date("2025-10-14T10:00:00Z"), source: .timetable),
            // Second hour of the same lecture → reported once.
            CalendarEvent(id: "L1b", title: "BEM2031 Lecture", start: date("2025-10-14T10:00:00Z"), end: date("2025-10-14T11:00:00Z"), source: .timetable),
            // Tue 7 Oct: covered by the Week 4 note.
            CalendarEvent(id: "L2", title: "BEM2031 Lecture", start: date("2025-10-07T09:00:00Z"), end: date("2025-10-07T10:00:00Z"), source: .timetable),
            // Covered by a note made the next day.
            CalendarEvent(id: "L3", title: "Lecture: ECM1400 Programming", start: date("2025-10-19T14:00:00Z"), end: date("2025-10-19T15:00:00Z")),
            // Future lecture and one too long ago are ignored; so is an event without a module code.
            CalendarEvent(id: "L4", title: "BEM2031 Lecture", start: date("2025-10-28T09:00:00Z"), end: date("2025-10-28T10:00:00Z")),
            CalendarEvent(id: "L5", title: "BEM2031 Lecture", start: date("2025-08-01T09:00:00Z"), end: date("2025-08-01T10:00:00Z")),
            CalendarEvent(id: "L6", title: "Careers talk", start: date("2025-10-15T09:00:00Z"), end: date("2025-10-15T10:00:00Z")),
        ]

        let gaps = GapDetector.detect(notes: [hwOnly, complete, unsure, untitled], lectures: lectures,
                                      now: date("2025-10-22T12:00:00Z"))
        XCTAssertEqual(gaps.map(\.message), [
            "BEM2031 Week 6 has handwriting but no typed summary",
            "“Misc” has handwriting but no typed summary",
            "No notes for BEM2031 lecture on Tue 14 Oct",
            "3 low-confidence pages to check",
        ])
        XCTAssertEqual(gaps[2].eventID, "L1")
        XCTAssertEqual(gaps[3].noteIDs, ["w6", "w4", "e1"])
        XCTAssertEqual(gaps.map(\.kind), [.missingTypedSummary, .missingTypedSummary, .missingNotes, .lowConfidence])
    }

    func testNothingToReport() {
        XCTAssertTrue(GapDetector.detect(notes: [], lectures: [], now: Date()).isEmpty)
    }
}
